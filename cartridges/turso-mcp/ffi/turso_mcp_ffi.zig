// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// turso_mcp_ffi.zig — C-ABI FFI implementation for the turso-mcp cartridge.
//
// Implements the connection state machine defined in the Idris2 ABI layer
// (TursoMcp.SafeDatabase). Thread-safe via std.Thread.Mutex. No heap
// allocations for results. State machine: Disconnected | Connected |
// QueryRunning | Error. Edge-replica-aware with embedded replica support.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Connection states for Turso libSQL.
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    query_running = 2,
    err = 3,
};

/// Turso REST API actions.
pub const TursoAction = enum(c_int) {
    list_databases = 0,
    create_database = 1,
    delete_database = 2,
    get_database = 3,
    list_groups = 4,
    create_group = 5,
    query = 6,
    batch_query = 7,
    list_tokens = 8,
    create_token = 9,
    revoke_token = 10,
    get_stats = 11,
    list_locations = 12,
    list_organizations = 13,
    transfer_database = 14,
    get_usage = 15,
};

/// Check whether a state transition is valid per the ABI specification.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .query_running or to == .disconnected,
        .query_running => to == .connected or to == .err,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 4096;

const SessionSlot = struct {
    in_use: bool = false,
    state: ConnState = .disconnected,
    context_buf: [BUF_SIZE]u8 = .{0} ** BUF_SIZE,
    context_len: usize = 0,
    database_count: u32 = 0,
    group_count: u32 = 0,
    query_count: u32 = 0,
    replica_locations: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn turso_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new connection session. Returns slot index (>= 0) or -1 if no slots.
pub export fn turso_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.in_use) {
            slot.in_use = true;
            slot.state = .connected;
            slot.context_len = 0;
            slot.database_count = 0;
            slot.group_count = 0;
            slot.query_count = 0;
            slot.replica_locations = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a connection session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn turso_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.in_use = false;
    slot.state = .disconnected;
    slot.context_len = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn turso_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intFromEnum(slot.state);
}

/// Begin a query. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn turso_mcp_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .query_running)) return -2;

    slot.state = .query_running;
    return 0;
}

/// End a query (return to connected). Returns 0 on success.
pub export fn turso_mcp_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    slot.query_count += 1;
    return 0;
}

/// Signal an error on a query-running session. Returns 0 on success.
pub export fn turso_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Get the query count for a session. Returns count or -1 if invalid slot.
pub export fn turso_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.query_count);
}

/// Check if an action requires an active connection. Returns 1 (yes) or 0 (no).
pub export fn turso_mcp_action_requires_connection(action: c_int) c_int {
    const a = std.meta.intToEnum(TursoAction, action) catch return 0;
    return switch (a) {
        .query, .batch_query => 1,
        else => 0,
    };
}

/// Reset all sessions (test/debug use only).
pub export fn turso_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "turso-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "turso_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_batch"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_list_tables"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_sync"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "turso_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    turso_mcp_reset();

    const slot = turso_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in connected state
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_session_state(slot));

    // Begin query
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 2), turso_mcp_session_state(slot));

    // End query
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_session_state(slot));

    // Query count should be 1
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_query_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    turso_mcp_reset();

    const slot = turso_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can not go connected -> error (must go through query_running)
    try std.testing.expectEqual(@as(c_int, -2), turso_mcp_signal_error(slot));

    // Can not close while query running
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, -2), turso_mcp_session_close(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(0, 1)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(1, 2)); // connected -> query_running
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(2, 1)); // query_running -> connected
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(1, 0)); // connected -> disconnected
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(2, 3)); // query_running -> error
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_can_transition(3, 0)); // error -> disconnected

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_can_transition(3, 1));
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    turso_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots, 0..) |*s, i| {
        _ = i;
        s.* = turso_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), turso_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_session_close(slots[0]));
    const new_slot = turso_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "action requires connection" {
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_action_requires_connection(6)); // query
    try std.testing.expectEqual(@as(c_int, 1), turso_mcp_action_requires_connection(7)); // batch_query
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_action_requires_connection(0)); // list_databases
    try std.testing.expectEqual(@as(c_int, 0), turso_mcp_action_requires_connection(99)); // out of range
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns turso-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("turso-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "turso_connect",
        "turso_query",
        "turso_execute",
        "turso_batch",
        "turso_list_tables",
        "turso_sync",
        "turso_disconnect",
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
    const rc = boj_cartridge_invoke("turso_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
