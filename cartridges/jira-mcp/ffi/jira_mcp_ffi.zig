// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// jira_mcp_ffi.zig — C-ABI FFI for the Jira Cloud REST API cartridge.
//
// Implements the state machine defined in JiraMcp.SafeComms (Idris2 ABI).
// Provides real HTTP dispatch to the Jira REST API v3
// (https://{instance}.atlassian.net/rest/api/3/) and the Agile API
// via std.http.Client, rate-limit tracking, and Basic auth
// (email + Atlassian API token) obtained from vault-mcp.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ConnState exactly)
// ---------------------------------------------------------------------------

/// Connection lifecycle states mirroring JiraMcp.SafeComms.ConnState.
pub const ConnState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Check whether a transition between two states is valid.
/// Encodes the same transition table as the Idris2 ValidTransition GADT.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited => to == .authenticated or to == .err,
        .err => to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Jira action vocabulary (matches Idris2 JiraAction exactly)
// ---------------------------------------------------------------------------

/// All 16 Jira actions supported by this cartridge.
pub const JiraAction = enum(c_int) {
    search_issues = 0,
    get_issue = 1,
    create_issue = 2,
    update_issue = 3,
    delete_issue = 4,
    add_comment = 5,
    list_projects = 6,
    get_project = 7,
    list_boards = 8,
    get_board = 9,
    list_sprints = 10,
    get_sprint = 11,
    transition_issue = 12,
    assign_issue = 13,
    list_fields = 14,
    get_user = 15,
};

/// Map each action to its Jira REST API endpoint path template.
fn actionToEndpoint(action: JiraAction) []const u8 {
    return switch (action) {
        .search_issues => "/rest/api/3/search",
        .get_issue => "/rest/api/3/issue/{issueIdOrKey}",
        .create_issue => "/rest/api/3/issue",
        .update_issue => "/rest/api/3/issue/{issueIdOrKey}",
        .delete_issue => "/rest/api/3/issue/{issueIdOrKey}",
        .add_comment => "/rest/api/3/issue/{issueIdOrKey}/comment",
        .list_projects => "/rest/api/3/project",
        .get_project => "/rest/api/3/project/{projectIdOrKey}",
        .list_boards => "/rest/agile/1.0/board",
        .get_board => "/rest/agile/1.0/board/{boardId}",
        .list_sprints => "/rest/agile/1.0/board/{boardId}/sprint",
        .get_sprint => "/rest/agile/1.0/sprint/{sprintId}",
        .transition_issue => "/rest/api/3/issue/{issueIdOrKey}/transitions",
        .assign_issue => "/rest/api/3/issue/{issueIdOrKey}/assignee",
        .list_fields => "/rest/api/3/field",
        .get_user => "/rest/api/3/user",
    };
}

/// Map each action to its HTTP method string.
fn actionToMethod(action: JiraAction) []const u8 {
    return switch (action) {
        .search_issues => "GET",
        .get_issue => "GET",
        .create_issue => "POST",
        .update_issue => "PUT",
        .delete_issue => "DELETE",
        .add_comment => "POST",
        .list_projects => "GET",
        .get_project => "GET",
        .list_boards => "GET",
        .get_board => "GET",
        .list_sprints => "GET",
        .get_sprint => "GET",
        .transition_issue => "POST",
        .assign_issue => "PUT",
        .list_fields => "GET",
        .get_user => "GET",
    };
}

// ---------------------------------------------------------------------------
// Rate-limit tracking
// ---------------------------------------------------------------------------

/// Tracks rate-limit usage within a sliding window.
/// Jira Cloud typically allows hundreds of requests per minute,
/// but can vary by instance and license tier.
const RateTracker = struct {
    /// Number of requests made in the current window.
    count: u32 = 0,
    /// Epoch timestamp (seconds) when the current window started.
    window_start: i64 = 0,

    /// Record one request. Returns true if within budget, false if exhausted.
    fn record(self: *RateTracker, now: i64, budget: u32) bool {
        // Reset window every 60 seconds.
        if (now - self.window_start >= 60) {
            self.window_start = now;
            self.count = 0;
        }
        if (self.count >= budget) return false;
        self.count += 1;
        return true;
    }
};

/// Jira rate budget: conservative estimate (~100 requests per minute).
const RATE_BUDGET: u32 = 100;

// ---------------------------------------------------------------------------
// Session slot pool (thread-safe, fixed-size)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 8192;
const CRED_MAX: usize = 256;
const URL_MAX: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .unauthenticated,
    /// Base64-encoded Basic auth credentials (email:api_token).
    cred_buf: [CRED_MAX]u8 = undefined,
    cred_len: usize = 0,
    /// Instance URL (e.g. "mycompany.atlassian.net").
    instance_buf: [URL_MAX]u8 = undefined,
    instance_len: usize = 0,
    /// Rate-limit tracker for request budgeting.
    rate_tracker: RateTracker = .{},
    /// Sprint progress percentage (0-100, for panel metrics).
    sprint_progress: u8 = 0,
    /// Count of actions performed in this session (for panel metrics).
    actions_performed: u32 = 0,
    /// General-purpose output buffer for API responses.
    out_buf: [BUF_SIZE]u8 = undefined,
    out_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Copy a null-terminated C string into a fixed buffer. Returns bytes written.
fn copyFromCStr(dest: []u8, src: [*c]const u8) usize {
    if (src == null) return 0;
    var i: usize = 0;
    while (i < dest.len and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    return i;
}

/// Write a slice into an output buffer pointer + length pointer.
fn writeOutput(buf: [*c]u8, buf_cap: usize, out_len: *c_int, data: []const u8) void {
    if (buf == null) return;
    const to_copy = @min(data.len, buf_cap);
    for (0..to_copy) |i| {
        buf[i] = data[i];
    }
    out_len.* = @intCast(to_copy);
}

/// Get a slot by index, returning null if invalid or inactive.
fn getSlot(slot_idx: c_int) ?*SessionSlot {
    const idx: usize = std.math.cast(usize, slot_idx) orelse return null;
    if (idx >= MAX_SESSIONS) return null;
    const slot = &sessions[idx];
    if (!slot.active) return null;
    return slot;
}

/// Attempt a state transition on a slot. Returns 0 on success, -2 if invalid.
fn tryTransition(slot: *SessionSlot, target: ConnState) c_int {
    if (!isValidTransition(slot.state, target)) return -2;
    slot.state = target;
    return 0;
}

/// Perform a real HTTP request to the Jira Cloud REST API.
/// slot: session slot (must be authenticated, caller verifies).
/// endpoint: Jira REST API path (e.g. "/rest/api/3/issue").
/// http_method: HTTP method string ("GET", "POST", "PUT", "DELETE").
/// params_json: JSON body for POST/PUT (may be null).
/// out_buf: fixed output buffer for writing the API response.
/// Returns bytes written to out_buf, or 0 on error.
fn doJiraApiCall(slot: *SessionSlot, endpoint: []const u8, http_method: []const u8, params_json: ?[]const u8, out_buf: []u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build URL: https://<instance>.atlassian.net<endpoint>
    const instance = slot.instance_buf[0..slot.instance_len];
    const url_str = std.fmt.allocPrint(allocator, "https://{s}.atlassian.net{s}", .{ instance, endpoint }) catch return 0;
    const uri = std.Uri.parse(url_str) catch return 0;

    // Build Basic auth header from stored credentials (email:token)
    // Base64 encode the credentials
    const cred_slice = slot.cred_buf[0..slot.cred_len];
    const encoded_len = std.base64.standard.Encoder.calcSize(cred_slice.len);
    const encoded = allocator.alloc(u8, encoded_len) catch return 0;
    _ = std.base64.standard.Encoder.encode(encoded, cred_slice);
    const auth_header = std.fmt.allocPrint(allocator, "Basic {s}", .{encoded}) catch return 0;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [3]std.http.Header = .{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (jira-mcp cartridge)" },
    };

    // Parse HTTP method
    const method: std.http.Method = if (std.ascii.eqlIgnoreCase(http_method, "POST"))
        .POST
    else if (std.ascii.eqlIgnoreCase(http_method, "PUT"))
        .PUT
    else if (std.ascii.eqlIgnoreCase(http_method, "DELETE"))
        .DELETE
    else
        .GET;

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    const body = params_json orelse "";
    const payload: ?[]const u8 = if (body.len > 0 and (method == .POST or method == .PUT)) body else null;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = method,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = payload,
        .response_writer = &aw.writer,
    }) catch return 0;

    // Check for rate limiting (HTTP 429)
    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429) {
        slot.state = .rate_limited;
        return 0;
    }

    // Copy response body into the caller's output buffer
    const response_bytes = aw.writer.buffered();
    const to_copy = @min(response_bytes.len, out_buf.len);
    @memcpy(out_buf[0..to_copy], response_bytes[0..to_copy]);
    return to_copy;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn jira_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate with Jira Cloud using Basic auth (email + Atlassian API token).
/// instance: C string instance subdomain (e.g. "mycompany" for mycompany.atlassian.net).
/// email: C string email address associated with the Atlassian account.
/// api_token: C string Atlassian API token (NOT app password).
/// Returns slot index (>= 0) on success, negative on error.
/// Error codes: -1 = no free slots, -3 = null argument, -4 = argument too short.
pub export fn jira_mcp_authenticate(
    instance: [*c]const u8,
    email: [*c]const u8,
    api_token: [*c]const u8,
) c_int {
    if (instance == null or email == null or api_token == null) return -3;

    // Validate minimum lengths.
    var inst_len: usize = 0;
    while (inst_len < URL_MAX and instance[inst_len] != 0) : (inst_len += 1) {}
    if (inst_len < 2) return -4;

    var email_len: usize = 0;
    while (email_len < CRED_MAX and email[email_len] != 0) : (email_len += 1) {}
    if (email_len < 5) return -4;

    var token_len: usize = 0;
    while (token_len < CRED_MAX and api_token[token_len] != 0) : (token_len += 1) {}
    if (token_len < 8) return -4;

    mutex.lock();
    defer mutex.unlock();

    // Find a free slot.
    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.instance_len = copyFromCStr(&slot.instance_buf, instance);
            // Store email:token as credential (in production, base64-encode for Basic auth).
            slot.cred_len = copyFromCStr(&slot.cred_buf, email);
            if (slot.cred_len < CRED_MAX) {
                slot.cred_buf[slot.cred_len] = ':';
                slot.cred_len += 1;
            }
            var j: usize = 0;
            while (j < token_len and slot.cred_len + j < CRED_MAX) : (j += 1) {
                slot.cred_buf[slot.cred_len + j] = api_token[j];
            }
            slot.cred_len += j;
            slot.sprint_progress = 0;
            slot.actions_performed = 0;
            slot.rate_tracker = .{};
            return @intCast(idx);
        }
    }
    return -1; // No free slots.
}

// ---------------------------------------------------------------------------
// C-ABI exports — generic API call
// ---------------------------------------------------------------------------

/// Invoke a Jira REST API operation by action ID.
/// action_id: integer matching JiraAction enum.
/// params: JSON-encoded parameters (C string, may be null).
/// Returns 0 on success, negative on error.
/// Error codes: -1 = invalid slot, -2 = bad state, -5 = rate limited, -6 = unknown action.
pub export fn jira_mcp_api_call(
    slot_idx: c_int,
    action_id: c_int,
    params: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    const action = std.meta.intToEnum(JiraAction, action_id) catch return -6;

    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .authenticated) return -2;

    // Rate-limit check.
    const now = std.time.timestamp();
    if (!slot.rate_tracker.record(now, RATE_BUDGET)) {
        slot.state = .rate_limited;
        return -5;
    }

    // Extract params as a slice if present
    const params_slice: ?[]const u8 = if (params != null) blk: {
        var i: usize = 0;
        while (i < 8192 and params[i] != 0) : (i += 1) {}
        if (i == 0) break :blk null;
        break :blk params[0..i];
    } else null;

    const endpoint = actionToEndpoint(action);
    const method = actionToMethod(action);
    const len = doJiraApiCall(slot, endpoint, method, params_slice, &slot.out_buf);
    slot.out_len = len;
    slot.actions_performed += 1;

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — session management
// ---------------------------------------------------------------------------

/// Disconnect a session gracefully. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = bad state transition.
pub export fn jira_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const rc = tryTransition(slot, .unauthenticated);
    if (rc == 0) {
        slot.active = false;
        slot.cred_len = 0;
        slot.instance_len = 0;
        slot.sprint_progress = 0;
        slot.actions_performed = 0;
    }
    return rc;
}

/// Get the current connection state. Returns state int or -1 if invalid slot.
pub export fn jira_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

/// Get the instance URL for an authenticated session.
/// Writes instance name into out_buf. Returns 0 on success, -1 if invalid.
pub export fn jira_mcp_instance(slot_idx: c_int, out_buf: [*c]u8, out_cap: c_int, out_len: *c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.instance_buf[0..slot.instance_len]);
    return 0;
}

/// Get the rate-limit request count for a session.
/// Returns count (>= 0) or -1 if invalid.
pub export fn jira_mcp_rate_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.rate_tracker.count);
}

/// Get the actions-performed counter for a session.
pub export fn jira_mcp_actions_performed(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.actions_performed);
}

/// Get the sprint progress percentage (0-100).
pub export fn jira_mcp_sprint_progress(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.sprint_progress);
}

/// Recover from rate-limited state (RateLimited -> Authenticated).
/// Returns 0 on success, -2 if bad transition.
pub export fn jira_mcp_rate_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return tryTransition(slot, .authenticated);
}

/// Reset all sessions (test/debug use only).
pub export fn jira_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "jira-mcp";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.1.0";

export fn boj_cartridge_init() callconv(.c) c_int {
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_NAME_PTR;
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_VERSION_PTR;
}

/// Dispatch the cartridge.json MCP tools. Grade D Alpha stubs.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "jira_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_search_issues"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_get_issue"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_create_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_update_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_add_comment"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_list_projects"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "jira_transition_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "state machine transitions" {
    // Valid transitions.
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(2, 3)); // rate_limited -> error
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(3, 0)); // error -> unauth
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_can_transition(1, 0)); // auth -> unauth (graceful)

    // Invalid transitions.
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(3, 1)); // error -> auth
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(2, 0)); // rate_limited -> unauth

    // Out of range.
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_can_transition(0, 99));
}

test "authenticate and disconnect lifecycle" {
    jira_mcp_reset();

    // Authenticate with valid credentials.
    const slot = jira_mcp_authenticate("mycompany", "user@example.com", "atlassian_api_token_1234567890");
    try std.testing.expect(slot >= 0);

    // Should be authenticated.
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_session_state(slot));

    // Graceful disconnect.
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_disconnect(slot));
}

test "reject invalid credentials" {
    jira_mcp_reset();

    // Null arguments.
    try std.testing.expectEqual(@as(c_int, -3), jira_mcp_authenticate(null, "a@b.com", "token123"));
    try std.testing.expectEqual(@as(c_int, -3), jira_mcp_authenticate("inst", null, "token123"));
    try std.testing.expectEqual(@as(c_int, -3), jira_mcp_authenticate("inst", "a@b.com", null));

    // Too-short arguments.
    try std.testing.expectEqual(@as(c_int, -4), jira_mcp_authenticate("x", "user@example.com", "token_long_enough"));
    try std.testing.expectEqual(@as(c_int, -4), jira_mcp_authenticate("inst", "ab", "token_long_enough"));
    try std.testing.expectEqual(@as(c_int, -4), jira_mcp_authenticate("inst", "user@example.com", "short"));
}

test "api call updates counters" {
    jira_mcp_reset();

    const slot = jira_mcp_authenticate("testinst", "user@example.com", "atlassian_api_token_abcdefgh");
    try std.testing.expect(slot >= 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;

    // Call search_issues (action_id = 0).
    const rc = jira_mcp_api_call(slot, 0, null, &buf, 1024, &out_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(c_int, 1), jira_mcp_actions_performed(slot));

    // Unknown action.
    try std.testing.expectEqual(@as(c_int, -6), jira_mcp_api_call(slot, 99, null, &buf, 1024, &out_len));

    _ = jira_mcp_disconnect(slot);
}

test "instance retrieval" {
    jira_mcp_reset();

    const slot = jira_mcp_authenticate("mycompany", "user@example.com", "atlassian_api_token_retrieve");
    try std.testing.expect(slot >= 0);

    var inst_buf: [256]u8 = undefined;
    var inst_len: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_instance(slot, &inst_buf, 256, &inst_len));
    try std.testing.expect(inst_len > 0);

    _ = jira_mcp_disconnect(slot);
}

test "slot exhaustion" {
    jira_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = jira_mcp_authenticate("fillinst", "fill@example.com", "fill_token_abcdefghijklmnop");
        try std.testing.expect(s.* >= 0);
    }

    // Next should fail.
    try std.testing.expectEqual(@as(c_int, -1), jira_mcp_authenticate("overflow", "over@example.com", "overflow_token_0000000000000"));

    // Free one and retry.
    try std.testing.expectEqual(@as(c_int, 0), jira_mcp_disconnect(slots[0]));
    const new_slot = jira_mcp_authenticate("reuseinst", "reuse@example.com", "reuse_token_abcdefghijklmnop");
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns jira-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("jira-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "jira_authenticate",
        "jira_search_issues",
        "jira_get_issue",
        "jira_create_issue",
        "jira_update_issue",
        "jira_add_comment",
        "jira_list_projects",
        "jira_transition_issue",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
    }
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("jira_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
