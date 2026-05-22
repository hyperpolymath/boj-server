// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// linear_mcp_ffi.zig — C-ABI FFI for the Linear GraphQL API cartridge.
//
// Implements the state machine defined in LinearMcp.SafeComms (Idris2 ABI).
// Provides GraphQL request stubs for the Linear API (https://api.linear.app/graphql),
// rate-limit tracking, and Bearer-token authentication via API keys obtained
// from vault-mcp.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ConnState exactly)
// ---------------------------------------------------------------------------

/// Connection lifecycle states mirroring LinearMcp.SafeComms.ConnState.
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
// Linear action vocabulary (matches Idris2 LinearAction exactly)
// ---------------------------------------------------------------------------

/// All 16 Linear actions supported by this cartridge.
pub const LinearAction = enum(c_int) {
    list_issues = 0,
    get_issue = 1,
    create_issue = 2,
    update_issue = 3,
    delete_issue = 4,
    list_projects = 5,
    get_project = 6,
    list_teams = 7,
    list_cycles = 8,
    create_comment = 9,
    search_issues = 10,
    list_labels = 11,
    assign_issue = 12,
    set_priority = 13,
    move_to_project = 14,
    list_workflow_states = 15,
};

/// Map each action to its Linear GraphQL operation name.
fn actionToOperation(action: LinearAction) []const u8 {
    return switch (action) {
        .list_issues => "issues",
        .get_issue => "issue",
        .create_issue => "issueCreate",
        .update_issue => "issueUpdate",
        .delete_issue => "issueDelete",
        .list_projects => "projects",
        .get_project => "project",
        .list_teams => "teams",
        .list_cycles => "cycles",
        .create_comment => "commentCreate",
        .search_issues => "issueSearch",
        .list_labels => "issueLabels",
        .assign_issue => "issueUpdate",
        .set_priority => "issueUpdate",
        .move_to_project => "issueUpdate",
        .list_workflow_states => "workflowStates",
    };
}

// ---------------------------------------------------------------------------
// Rate-limit tracking
// ---------------------------------------------------------------------------

/// Tracks rate-limit usage within a sliding window.
/// Linear enforces request complexity limits; we approximate with a
/// simple requests-per-minute counter.
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

/// Linear rate budget: ~50 requests per minute (complexity-based, approximated).
const RATE_BUDGET: u32 = 50;

// ---------------------------------------------------------------------------
// Session slot pool (thread-safe, fixed-size)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 8192;
const TOKEN_MAX: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .unauthenticated,
    /// Bearer token (Linear API key) obtained from vault-mcp.
    token_buf: [TOKEN_MAX]u8 = undefined,
    token_len: usize = 0,
    /// Rate-limit tracker for request budgeting.
    rate_tracker: RateTracker = .{},
    /// Count of issues retrieved in this session (for panel metrics).
    issue_count: u32 = 0,
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

/// Stub: format a Linear GraphQL response into JSON.
/// In production this would POST to https://api.linear.app/graphql.
fn formatStubResponse(buf: []u8, operation: []const u8) usize {
    const prefix = "{\"data\":{\"";
    const mid = "\":{},\"stub\":true},\"extensions\":{\"requestId\":\"stub\"}}";
    var pos: usize = 0;

    for (prefix) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (operation) |ch| {
        if (pos >= buf.len) break;
        buf[pos] = ch;
        pos += 1;
    }
    for (mid) |ch| {
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
pub export fn linear_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate with a Linear API key (Bearer token).
/// Transitions: Unauthenticated -> Authenticated (or remains Unauthenticated on error).
/// Returns slot index (>= 0) on success, negative on error.
/// Error codes: -1 = no free slots, -3 = empty token, -4 = token too short.
pub export fn linear_mcp_authenticate(token: [*c]const u8) c_int {
    if (token == null) return -3;
    // Validate minimum token length (Linear API keys are typically 40+ chars).
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
            slot.issue_count = 0;
            slot.actions_performed = 0;
            slot.rate_tracker = .{};
            return @intCast(idx);
        }
    }
    return -1; // No free slots.
}

// ---------------------------------------------------------------------------
// C-ABI exports — generic GraphQL call
// ---------------------------------------------------------------------------

/// Invoke a Linear GraphQL operation by action ID.
/// action_id: integer matching LinearAction enum.
/// params: JSON-encoded GraphQL variables (C string, may be null).
/// Returns 0 on success, negative on error.
/// Error codes: -1 = invalid slot, -2 = bad state, -5 = rate limited, -6 = unknown action.
pub export fn linear_mcp_graphql_call(
    slot_idx: c_int,
    action_id: c_int,
    params: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    _ = params;

    const action = std.meta.intToEnum(LinearAction, action_id) catch return -6;

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

    const operation = actionToOperation(action);
    const len = formatStubResponse(&slot.out_buf, operation);
    slot.out_len = len;
    slot.actions_performed += 1;

    // Track issue queries for panel metrics.
    if (action == .list_issues or action == .search_issues) {
        slot.issue_count += 1;
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
pub export fn linear_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const rc = tryTransition(slot, .unauthenticated);
    if (rc == 0) {
        slot.active = false;
        slot.token_len = 0;
        slot.issue_count = 0;
        slot.actions_performed = 0;
    }
    return rc;
}

/// Get the current connection state. Returns state int or -1 if invalid slot.
pub export fn linear_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

/// Get the rate-limit request count for a session.
/// Returns count (>= 0) or -1 if invalid.
pub export fn linear_mcp_rate_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.rate_tracker.count);
}

/// Get the actions-performed counter for a session.
pub export fn linear_mcp_actions_performed(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.actions_performed);
}

/// Get the issue-query counter for a session.
pub export fn linear_mcp_issue_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.issue_count);
}

/// Recover from rate-limited state (RateLimited -> Authenticated).
/// Returns 0 on success, -2 if bad transition.
pub export fn linear_mcp_rate_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return tryTransition(slot, .authenticated);
}

/// Reset all sessions (test/debug use only).
pub export fn linear_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "linear-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "linear_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_list_issues"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_get_issue"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_create_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_update_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_list_teams"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "linear_search_issues"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "state machine transitions" {
    // Valid transitions.
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(2, 3)); // rate_limited -> error
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(3, 0)); // error -> unauth
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_can_transition(1, 0)); // auth -> unauth (graceful)

    // Invalid transitions.
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(3, 1)); // error -> auth
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(2, 0)); // rate_limited -> unauth

    // Out of range.
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_can_transition(0, 99));
}

test "authenticate and disconnect lifecycle" {
    linear_mcp_reset();

    // Authenticate with a valid API key.
    const slot = linear_mcp_authenticate("lin_api_test_key_1234567890abcdef");
    try std.testing.expect(slot >= 0);

    // Should be authenticated.
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_session_state(slot));

    // Graceful disconnect.
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_disconnect(slot));
}

test "reject short token" {
    linear_mcp_reset();

    // Token too short.
    try std.testing.expectEqual(@as(c_int, -4), linear_mcp_authenticate("short"));

    // Null token.
    try std.testing.expectEqual(@as(c_int, -3), linear_mcp_authenticate(null));
}

test "graphql call updates counters" {
    linear_mcp_reset();

    const slot = linear_mcp_authenticate("lin_api_test_graphql_call_key_0123");
    try std.testing.expect(slot >= 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;

    // Call list_issues (action_id = 0).
    const rc = linear_mcp_graphql_call(slot, 0, null, &buf, 1024, &out_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_actions_performed(slot));
    try std.testing.expectEqual(@as(c_int, 1), linear_mcp_issue_count(slot));

    // Unknown action.
    try std.testing.expectEqual(@as(c_int, -6), linear_mcp_graphql_call(slot, 99, null, &buf, 1024, &out_len));

    _ = linear_mcp_disconnect(slot);
}

test "slot exhaustion" {
    linear_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = linear_mcp_authenticate("lin_api_fill_slot_token_abcdefgh");
        try std.testing.expect(s.* >= 0);
    }

    // Next should fail.
    try std.testing.expectEqual(@as(c_int, -1), linear_mcp_authenticate("lin_api_overflow_token_000000000"));

    // Free one and retry.
    try std.testing.expectEqual(@as(c_int, 0), linear_mcp_disconnect(slots[0]));
    const new_slot = linear_mcp_authenticate("lin_api_reuse_slot_token_1234567");
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns linear-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("linear-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "linear_authenticate",
        "linear_list_issues",
        "linear_get_issue",
        "linear_create_issue",
        "linear_update_issue",
        "linear_list_teams",
        "linear_search_issues",
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
    const rc = boj_cartridge_invoke("linear_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
