// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// clickhouse_mcp_ffi.zig — C-ABI FFI implementation for the clickhouse-mcp cartridge.
//
// Implements the connection state machine defined in the Idris2 ABI layer
// (ClickhouseMcp.SafeDatabase). Thread-safe via std.Thread.Mutex. No heap
// allocations for results. State machine: Disconnected | Connected |
// QueryRunning | Error. Designed for ClickHouse column-oriented OLAP semantics
// with HTTP interface at port 8123 and native TCP at port 9000.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Connection states for ClickHouse OLAP database.
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    query_running = 2,
    err = 3,
};

/// ClickHouse HTTP interface actions.
pub const ClickhouseAction = enum(c_int) {
    list_databases = 0,
    create_database = 1,
    drop_database = 2,
    list_tables = 3,
    create_table = 4,
    drop_table = 5,
    describe_table = 6,
    select_query = 7,
    insert_data = 8,
    explain_query = 9,
    show_processlist = 10,
    kill_query = 11,
    optimize_table = 12,
    truncate_table = 13,
    list_partitions = 14,
    system_reload_config = 15,
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
    table_count: u32 = 0,
    query_count: u32 = 0,
    insert_count: u32 = 0,
    active_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn clickhouse_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new connection session. Returns slot index (>= 0) or -1 if no slots.
pub export fn clickhouse_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.in_use) {
            slot.in_use = true;
            slot.state = .connected;
            slot.context_len = 0;
            slot.database_count = 0;
            slot.table_count = 0;
            slot.query_count = 0;
            slot.insert_count = 0;
            slot.active_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a connection session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn clickhouse_mcp_session_close(slot_idx: c_int) c_int {
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
pub export fn clickhouse_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intFromEnum(slot.state);
}

/// Begin a query. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn clickhouse_mcp_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .query_running)) return -2;

    slot.state = .query_running;
    slot.active_queries += 1;
    return 0;
}

/// End a query (return to connected). Returns 0 on success.
pub export fn clickhouse_mcp_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    slot.query_count += 1;
    if (slot.active_queries > 0) slot.active_queries -= 1;
    return 0;
}

/// Signal an error on a query-running session. Returns 0 on success.
pub export fn clickhouse_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn clickhouse_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.query_count);
}

/// Get the insert count for a session. Returns count or -1 if invalid slot.
pub export fn clickhouse_mcp_insert_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.insert_count);
}

/// Record a batch insert completion. Returns 0 on success.
pub export fn clickhouse_mcp_record_insert(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;

    slot.insert_count += 1;
    return 0;
}

/// Check if an action requires an active connection. Returns 1 (yes) or 0 (no).
pub export fn clickhouse_mcp_action_requires_connection(action: c_int) c_int {
    const a = std.meta.intToEnum(ClickhouseAction, action) catch return 0;
    return switch (a) {
        .select_query,
        .insert_data,
        .explain_query,
        .show_processlist,
        .kill_query,
        .optimize_table,
        .truncate_table,
        .list_partitions,
        .system_reload_config,
        => 1,
        else => 0,
    };
}

/// Reset all sessions (test/debug use only).
pub export fn clickhouse_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "clickhouse-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "clickhouse_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_insert"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_ddl"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_list_tables"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_describe"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "clickhouse_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    clickhouse_mcp_reset();

    const slot = clickhouse_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in connected state
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_session_state(slot));

    // Begin query
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 2), clickhouse_mcp_session_state(slot));

    // End query
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_session_state(slot));

    // Query count should be 1
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_query_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    clickhouse_mcp_reset();

    const slot = clickhouse_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can not go connected -> error (must go through query_running)
    try std.testing.expectEqual(@as(c_int, -2), clickhouse_mcp_signal_error(slot));

    // Can not close while query running
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, -2), clickhouse_mcp_session_close(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(0, 1)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(1, 2)); // connected -> query_running
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(2, 1)); // query_running -> connected
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(1, 0)); // connected -> disconnected
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(2, 3)); // query_running -> error
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_can_transition(3, 0)); // error -> disconnected

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_can_transition(3, 1));
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    clickhouse_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots, 0..) |*s, i| {
        _ = i;
        s.* = clickhouse_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), clickhouse_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_session_close(slots[0]));
    const new_slot = clickhouse_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "action requires connection" {
    // Actions requiring connection
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(7)); // select_query
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(8)); // insert_data
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(9)); // explain_query
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(10)); // show_processlist
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(11)); // kill_query
    try std.testing.expectEqual(@as(c_int, 1), clickhouse_mcp_action_requires_connection(15)); // system_reload_config

    // Actions not requiring connection
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_action_requires_connection(0)); // list_databases
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_action_requires_connection(1)); // create_database
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_action_requires_connection(99)); // out of range
}

test "insert tracking" {
    clickhouse_mcp_reset();

    const slot = clickhouse_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Initial insert count should be 0
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_insert_count(slot));

    // Record some inserts
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_record_insert(slot));
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_record_insert(slot));
    try std.testing.expectEqual(@as(c_int, 2), clickhouse_mcp_insert_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_session_close(slot));
}

test "error recovery cycle" {
    clickhouse_mcp_reset();

    const slot = clickhouse_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Connected -> QueryRunning -> Error -> Disconnected
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), clickhouse_mcp_session_state(slot));

    // Error state — can only go to disconnected (close)
    try std.testing.expectEqual(@as(c_int, 0), clickhouse_mcp_session_close(slot));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns clickhouse-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("clickhouse-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "clickhouse_connect",
        "clickhouse_query",
        "clickhouse_insert",
        "clickhouse_ddl",
        "clickhouse_list_tables",
        "clickhouse_describe",
        "clickhouse_disconnect",
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
    const rc = boj_cartridge_invoke("clickhouse_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
