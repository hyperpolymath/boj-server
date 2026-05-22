// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// neo4j_mcp_ffi.zig — C-ABI FFI implementation for the neo4j-mcp cartridge.
//
// Implements the connection state machine defined in the Idris2 ABI layer
// (Neo4jMcp.SafeDatabase). Thread-safe via std.Thread.Mutex. No heap
// allocations for results. State machine: Disconnected | Connected |
// QueryRunning | Error. Designed for Neo4j graph database operations
// over HTTP REST API and Bolt protocol. Auth: basic auth or bearer token.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Connection states for Neo4j graph database.
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    query_running = 2,
    err = 3,
};

/// Neo4j API actions.
pub const Neo4jAction = enum(c_int) {
    list_databases = 0,
    create_database = 1,
    drop_database = 2,
    cypher_query = 3,
    explain_query = 4,
    profile_query = 5,
    create_node = 6,
    get_node = 7,
    update_node = 8,
    delete_node = 9,
    create_relationship = 10,
    get_relationship = 11,
    delete_relationship = 12,
    list_labels = 13,
    list_relationship_types = 14,
    list_property_keys = 15,
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
    node_count: u32 = 0,
    relationship_count: u32 = 0,
    query_count: u32 = 0,
    database_name_len: usize = 0,
    database_name_buf: [256]u8 = .{0} ** 256,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn neo4j_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new connection session. Returns slot index (>= 0) or -1 if no slots.
pub export fn neo4j_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.in_use) {
            slot.in_use = true;
            slot.state = .connected;
            slot.context_len = 0;
            slot.node_count = 0;
            slot.relationship_count = 0;
            slot.query_count = 0;
            slot.database_name_len = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a connection session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn neo4j_mcp_session_close(slot_idx: c_int) c_int {
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
pub export fn neo4j_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intFromEnum(slot.state);
}

/// Begin a Cypher query. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn neo4j_mcp_begin_query(slot_idx: c_int) c_int {
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
pub export fn neo4j_mcp_end_query(slot_idx: c_int) c_int {
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
pub export fn neo4j_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Recover from error state (transition to disconnected). Returns 0 on success.
pub export fn neo4j_mcp_error_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.state = .disconnected;
    return 0;
}

/// Get the query count for a session. Returns count or -1 if invalid slot.
pub export fn neo4j_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.query_count);
}

/// Check if an action requires an active connection. Returns 1 (yes) or 0 (no).
pub export fn neo4j_mcp_action_requires_connection(action: c_int) c_int {
    const a = std.meta.intToEnum(Neo4jAction, action) catch return 0;
    return switch (a) {
        .cypher_query,
        .explain_query,
        .profile_query,
        .create_node,
        .get_node,
        .update_node,
        .delete_node,
        .create_relationship,
        .get_relationship,
        .delete_relationship,
        .list_labels,
        .list_relationship_types,
        .list_property_keys,
        => 1,
        else => 0,
    };
}

/// Reset all sessions (test/debug use only).
pub export fn neo4j_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "neo4j-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "neo4j_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "neo4j_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "neo4j_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "neo4j_write"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "neo4j_schema"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    neo4j_mcp_reset();

    const slot = neo4j_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in connected state
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_session_state(slot));

    // Begin query (Cypher)
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 2), neo4j_mcp_session_state(slot));

    // End query
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_session_state(slot));

    // Query count should be 1
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_query_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    neo4j_mcp_reset();

    const slot = neo4j_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can not go connected -> error (must go through query_running)
    try std.testing.expectEqual(@as(c_int, -2), neo4j_mcp_signal_error(slot));

    // Can not close while query running
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, -2), neo4j_mcp_session_close(slot));
}

test "error recovery path" {
    neo4j_mcp_reset();

    const slot = neo4j_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Connected -> QueryRunning -> Error -> Disconnected
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), neo4j_mcp_session_state(slot));

    // Error -> Disconnected via error_recover
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_error_recover(slot));
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_session_state(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(0, 1)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(1, 2)); // connected -> query_running
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(2, 1)); // query_running -> connected
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(1, 0)); // connected -> disconnected
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(2, 3)); // query_running -> error
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_can_transition(3, 0)); // error -> disconnected

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_can_transition(3, 1));
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    neo4j_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots, 0..) |*s, i| {
        _ = i;
        s.* = neo4j_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), neo4j_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_session_close(slots[0]));
    const new_slot = neo4j_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "action requires connection" {
    // Actions that require connection
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(3)); // cypher_query
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(4)); // explain_query
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(5)); // profile_query
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(6)); // create_node
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(7)); // get_node
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(10)); // create_relationship
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(13)); // list_labels
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(14)); // list_relationship_types
    try std.testing.expectEqual(@as(c_int, 1), neo4j_mcp_action_requires_connection(15)); // list_property_keys

    // Actions that do NOT require connection
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_action_requires_connection(0)); // list_databases
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_action_requires_connection(1)); // create_database
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_action_requires_connection(2)); // drop_database
    try std.testing.expectEqual(@as(c_int, 0), neo4j_mcp_action_requires_connection(99)); // out of range
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns neo4j-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("neo4j-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "neo4j_connect",
        "neo4j_disconnect",
        "neo4j_query",
        "neo4j_write",
        "neo4j_schema",
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
    const rc = boj_cartridge_invoke("neo4j_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
