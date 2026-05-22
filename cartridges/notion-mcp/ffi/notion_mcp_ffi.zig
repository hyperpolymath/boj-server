// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// notion_mcp_ffi.zig — C-ABI FFI for the Notion REST API cartridge.
//
// Implements the state machine defined in NotionMcp.SafeComms (Idris2 ABI).
// Provides HTTP client stubs for the Notion API (https://api.notion.com/v1/),
// Notion-Version header management (2022-06-28), rate-limit tracking
// (Notion enforces ~3 requests/second), and Bearer-token authentication
// via integration tokens obtained from vault-mcp.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ConnState exactly)
// ---------------------------------------------------------------------------

/// Connection lifecycle states mirroring NotionMcp.SafeComms.ConnState.
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
// Notion action vocabulary (matches Idris2 NotionAction exactly)
// ---------------------------------------------------------------------------

/// All 16 Notion actions supported by this cartridge.
pub const NotionAction = enum(c_int) {
    search_pages = 0,
    get_page = 1,
    create_page = 2,
    update_page = 3,
    delete_page = 4,
    get_database = 5,
    query_database = 6,
    create_database = 7,
    list_blocks = 8,
    get_block = 9,
    append_blocks = 10,
    delete_block = 11,
    list_users = 12,
    get_user = 13,
    create_comment = 14,
    list_comments = 15,
};

/// Map each action to its Notion REST API endpoint path.
fn actionToEndpoint(action: NotionAction) []const u8 {
    return switch (action) {
        .search_pages => "/v1/search",
        .get_page => "/v1/pages/{page_id}",
        .create_page => "/v1/pages",
        .update_page => "/v1/pages/{page_id}",
        .delete_page => "/v1/pages/{page_id}",
        .get_database => "/v1/databases/{database_id}",
        .query_database => "/v1/databases/{database_id}/query",
        .create_database => "/v1/databases",
        .list_blocks => "/v1/blocks/{block_id}/children",
        .get_block => "/v1/blocks/{block_id}",
        .append_blocks => "/v1/blocks/{block_id}/children",
        .delete_block => "/v1/blocks/{block_id}",
        .list_users => "/v1/users",
        .get_user => "/v1/users/{user_id}",
        .create_comment => "/v1/comments",
        .list_comments => "/v1/comments",
    };
}

/// Map each action to its HTTP method string.
fn actionToMethod(action: NotionAction) []const u8 {
    return switch (action) {
        .search_pages => "POST",
        .get_page => "GET",
        .create_page => "POST",
        .update_page => "PATCH",
        .delete_page => "PATCH",
        .get_database => "GET",
        .query_database => "POST",
        .create_database => "POST",
        .list_blocks => "GET",
        .get_block => "GET",
        .append_blocks => "PATCH",
        .delete_block => "DELETE",
        .list_users => "GET",
        .get_user => "GET",
        .create_comment => "POST",
        .list_comments => "GET",
    };
}

// ---------------------------------------------------------------------------
// Notion-Version header constant
// ---------------------------------------------------------------------------

/// The Notion API version header value. All requests must include
/// `Notion-Version: 2022-06-28` per Notion API requirements.
pub const NOTION_API_VERSION: []const u8 = "2022-06-28";

// ---------------------------------------------------------------------------
// Rate-limit tracking
// ---------------------------------------------------------------------------

/// Tracks rate-limit usage within a sliding window.
/// Notion enforces approximately 3 requests per second.
const RateTracker = struct {
    /// Number of requests made in the current window.
    count: u32 = 0,
    /// Epoch timestamp (seconds) when the current window started.
    window_start: i64 = 0,

    /// Record one request. Returns true if within budget, false if exhausted.
    fn record(self: *RateTracker, now: i64, budget: u32) bool {
        // Reset window every second (Notion rate limits are per-second).
        if (now - self.window_start >= 1) {
            self.window_start = now;
            self.count = 0;
        }
        if (self.count >= budget) return false;
        self.count += 1;
        return true;
    }
};

/// Notion rate budget: ~3 requests per second.
const RATE_BUDGET: u32 = 3;

// ---------------------------------------------------------------------------
// Session slot pool (thread-safe, fixed-size)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 8192;
const TOKEN_MAX: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .unauthenticated,
    /// Bearer token (Notion integration token) obtained from vault-mcp.
    token_buf: [TOKEN_MAX]u8 = undefined,
    token_len: usize = 0,
    /// Workspace name populated after authentication.
    workspace_buf: [256]u8 = undefined,
    workspace_len: usize = 0,
    /// Rate-limit tracker for request budgeting.
    rate_tracker: RateTracker = .{},
    /// Count of pages accessed in this session (for panel metrics).
    page_count: u32 = 0,
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

/// Stub: format a Notion API response into JSON.
/// In production this would perform the actual HTTP request to
/// https://api.notion.com with the Notion-Version: 2022-06-28 header.
fn formatStubResponse(buf: []u8, endpoint: []const u8, method: []const u8) usize {
    const prefix = "{\"object\":\"stub\",\"endpoint\":\"";
    const mid = "\",\"method\":\"";
    const suffix = "\",\"notion_version\":\"2022-06-28\",\"results\":[]}";
    var pos: usize = 0;

    for (prefix) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (endpoint) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (mid) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (method) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (suffix) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    return pos;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn notion_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate with a Notion integration token (Bearer).
/// Transitions: Unauthenticated -> Authenticated.
/// Returns slot index (>= 0) on success, negative on error.
/// Error codes: -1 = no free slots, -3 = empty token, -4 = invalid token prefix.
pub export fn notion_mcp_authenticate(token: [*c]const u8) c_int {
    if (token == null) return -3;
    // Validate token length: Notion integration tokens start with "secret_" or "ntn_".
    var len: usize = 0;
    while (len < TOKEN_MAX and token[len] != 0) : (len += 1) {}
    if (len < 8) return -4;

    mutex.lock();
    defer mutex.unlock();

    // Find a free slot.
    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.token_len = copyFromCStr(&slot.token_buf, token);
            slot.page_count = 0;
            slot.actions_performed = 0;
            slot.rate_tracker = .{};

            // Stub: in production, GET /v1/users/me to verify token + get workspace.
            const ws = "stub-workspace";
            @memcpy(slot.workspace_buf[0..ws.len], ws);
            slot.workspace_len = ws.len;

            return @intCast(idx);
        }
    }
    return -1; // No free slots.
}

// ---------------------------------------------------------------------------
// C-ABI exports — generic API call
// ---------------------------------------------------------------------------

/// Invoke a Notion REST API operation by action ID.
/// action_id: integer matching NotionAction enum.
/// params: JSON-encoded parameters (C string, may be null).
/// Returns 0 on success, negative on error.
/// Error codes: -1 = invalid slot, -2 = bad state, -5 = rate limited, -6 = unknown action.
pub export fn notion_mcp_api_call(
    slot_idx: c_int,
    action_id: c_int,
    params: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    _ = params;

    const action = std.meta.intToEnum(NotionAction, action_id) catch return -6;

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

    const endpoint = actionToEndpoint(action);
    const method = actionToMethod(action);
    const len = formatStubResponse(&slot.out_buf, endpoint, method);
    slot.out_len = len;
    slot.actions_performed += 1;

    // Track page operations for panel metrics.
    if (action == .get_page or action == .search_pages or action == .create_page) {
        slot.page_count += 1;
    }

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — session management
// ---------------------------------------------------------------------------

/// Disconnect a session gracefully. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = bad state transition.
pub export fn notion_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const rc = tryTransition(slot, .unauthenticated);
    if (rc == 0) {
        slot.active = false;
        slot.token_len = 0;
        slot.workspace_len = 0;
        slot.page_count = 0;
        slot.actions_performed = 0;
    }
    return rc;
}

/// Get the current connection state. Returns state int or -1 if invalid slot.
pub export fn notion_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

/// Get the workspace name for an authenticated session.
/// Writes workspace name into out_buf. Returns 0 on success, -1 if invalid.
pub export fn notion_mcp_workspace(slot_idx: c_int, out_buf: [*c]u8, out_cap: c_int, out_len: *c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.workspace_buf[0..slot.workspace_len]);
    return 0;
}

/// Get the rate-limit request count for a session.
/// Returns count (>= 0) or -1 if invalid.
pub export fn notion_mcp_rate_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.rate_tracker.count);
}

/// Get the page-operation counter for a session.
pub export fn notion_mcp_page_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.page_count);
}

/// Get the actions-performed counter for a session.
pub export fn notion_mcp_actions_performed(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.actions_performed);
}

/// Recover from rate-limited state (RateLimited -> Authenticated).
/// Returns 0 on success, -2 if bad transition.
pub export fn notion_mcp_rate_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return tryTransition(slot, .authenticated);
}

/// Reset all sessions (test/debug use only).
pub export fn notion_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "notion-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "notion_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_search"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_get_page"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_create_page"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_update_page"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_query_database"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "notion_append_blocks"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "state machine transitions" {
    // Valid transitions.
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(2, 3)); // rate_limited -> error
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(3, 0)); // error -> unauth
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_can_transition(1, 0)); // auth -> unauth (graceful)

    // Invalid transitions.
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(3, 1)); // error -> auth
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(2, 0)); // rate_limited -> unauth

    // Out of range.
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_can_transition(0, 99));
}

test "authenticate and disconnect lifecycle" {
    notion_mcp_reset();

    // Authenticate with a valid integration token.
    const slot = notion_mcp_authenticate("secret_test_integration_token_1234");
    try std.testing.expect(slot >= 0);

    // Should be authenticated.
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_session_state(slot));

    // Graceful disconnect.
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_disconnect(slot));
}

test "reject short token" {
    notion_mcp_reset();

    // Token too short.
    try std.testing.expectEqual(@as(c_int, -4), notion_mcp_authenticate("short"));

    // Null token.
    try std.testing.expectEqual(@as(c_int, -3), notion_mcp_authenticate(null));
}

test "api call updates counters" {
    notion_mcp_reset();

    const slot = notion_mcp_authenticate("secret_test_api_call_token_abcdef");
    try std.testing.expect(slot >= 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;

    // Call search_pages (action_id = 0).
    const rc = notion_mcp_api_call(slot, 0, null, &buf, 1024, &out_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_actions_performed(slot));
    try std.testing.expectEqual(@as(c_int, 1), notion_mcp_page_count(slot));

    // Unknown action.
    try std.testing.expectEqual(@as(c_int, -6), notion_mcp_api_call(slot, 99, null, &buf, 1024, &out_len));

    _ = notion_mcp_disconnect(slot);
}

test "workspace retrieval" {
    notion_mcp_reset();

    const slot = notion_mcp_authenticate("secret_test_workspace_token_12345");
    try std.testing.expect(slot >= 0);

    var ws_buf: [256]u8 = undefined;
    var ws_len: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_workspace(slot, &ws_buf, 256, &ws_len));
    try std.testing.expect(ws_len > 0);

    _ = notion_mcp_disconnect(slot);
}

test "slot exhaustion" {
    notion_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = notion_mcp_authenticate("secret_fill_slot_token_abcdefghij");
        try std.testing.expect(s.* >= 0);
    }

    // Next should fail.
    try std.testing.expectEqual(@as(c_int, -1), notion_mcp_authenticate("secret_overflow_token_0000000000"));

    // Free one and retry.
    try std.testing.expectEqual(@as(c_int, 0), notion_mcp_disconnect(slots[0]));
    const new_slot = notion_mcp_authenticate("secret_reuse_slot_token_12345678");
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns notion-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("notion-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "notion_authenticate",
        "notion_search",
        "notion_get_page",
        "notion_create_page",
        "notion_update_page",
        "notion_query_database",
        "notion_append_blocks",
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
    const rc = boj_cartridge_invoke("notion_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
