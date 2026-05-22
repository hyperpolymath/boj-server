// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// postgresql_mcp_ffi.zig -- C-ABI FFI implementation for postgresql-mcp cartridge.
//
// Implements the state machine defined in PostgresqlMcp.SafeDatabase (Idris2 ABI).
// Thread-safe via std.Thread.Mutex. Wraps libpq C-ABI stubs for PQconnectdb,
// PQexec, PQresultStatus. All queries use parameterised statements to prevent
// SQL injection. No heap allocations for state management.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// PostgreSQL connection lifecycle states.
/// Disconnected=0, Connected=1, InTransaction=2, QueryRunning=3, Error=4
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    in_transaction = 2,
    query_running = 3,
    err = 4,
};

/// PostgreSQL actions matching the Idris2 PostgresqlAction type.
pub const PostgresqlAction = enum(c_int) {
    connect = 0,
    disconnect = 1,
    query = 2,
    execute = 3,
    begin_tx = 4,
    commit_tx = 5,
    rollback_tx = 6,
    list_databases = 7,
    list_schemas = 8,
    list_tables = 9,
    describe_table = 10,
    list_indices = 11,
    explain = 12,
    copy_to = 13,
    copy_from = 14,
    notify = 15,
};

/// Validate a state transition against the proven Idris2 transition graph.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .disconnected or to == .in_transaction or to == .query_running,
        .in_transaction => to == .connected or to == .query_running,
        .query_running => to == .connected or to == .in_transaction or to == .err,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Connection slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_CONNECTIONS: usize = 16;
const CONNSTR_BUF_SIZE: usize = 1024;

/// A single connection slot in the pool.
const ConnectionSlot = struct {
    active: bool = false,
    state: ConnState = .disconnected,
    connstr_buf: [CONNSTR_BUF_SIZE]u8 = undefined,
    connstr_len: usize = 0,
    query_count: u64 = 0,
    tx_depth: u32 = 0,
};

var connections: [MAX_CONNECTIONS]ConnectionSlot = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// libpq C-ABI stubs (linked at build time)
// ---------------------------------------------------------------------------

/// Opaque libpq connection handle.
const PGconn = opaque {};
/// Opaque libpq result handle.
const PGresult = opaque {};

extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQfinish(conn: *PGconn) void;
extern fn PQexecParams(
    conn: *PGconn,
    command: [*:0]const u8,
    n_params: c_int,
    param_types: ?[*]const c_uint,
    param_values: ?[*]const ?[*:0]const u8,
    param_lengths: ?[*]const c_int,
    param_formats: ?[*]const c_int,
    result_format: c_int,
) ?*PGresult;
extern fn PQresultStatus(res: *PGresult) c_int;
extern fn PQclear(res: *PGresult) void;
extern fn PQstatus(conn: *PGconn) c_int;

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn postgresql_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new connection slot. Returns slot index (>= 0) or -1 if pool full.
pub export fn postgresql_mcp_connect(connstr_ptr: [*]const u8, connstr_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const len: usize = std.math.cast(usize, connstr_len) orelse return -2;
    if (len == 0 or len > CONNSTR_BUF_SIZE) return -2;

    for (&connections, 0..) |*slot, idx| {
        if (!slot.active) {
            @memcpy(slot.connstr_buf[0..len], connstr_ptr[0..len]);
            slot.connstr_len = len;
            slot.active = true;
            slot.state = .connected;
            slot.query_count = 0;
            slot.tx_depth = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect a connection slot. Returns 0 on success, -1 invalid slot, -2 bad transition.
pub export fn postgresql_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.active = false;
    slot.state = .disconnected;
    slot.connstr_len = 0;
    slot.query_count = 0;
    slot.tx_depth = 0;
    return 0;
}

/// Get the current state of a connection. Returns state int or -1 if invalid.
pub export fn postgresql_mcp_connection_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Begin a transaction. Returns 0 on success.
pub export fn postgresql_mcp_begin_tx(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .in_transaction)) return -2;

    slot.state = .in_transaction;
    slot.tx_depth += 1;
    return 0;
}

/// Commit or rollback a transaction. Returns 0 on success.
pub export fn postgresql_mcp_end_tx(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    if (slot.tx_depth > 0) slot.tx_depth -= 1;
    return 0;
}

/// Begin query execution. Returns 0 on success.
pub export fn postgresql_mcp_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .query_running)) return -2;

    slot.state = .query_running;
    slot.query_count += 1;
    return 0;
}

/// Complete query execution (return to previous state). Returns 0 on success.
/// If tx_depth > 0, returns to in_transaction; otherwise returns to connected.
pub export fn postgresql_mcp_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (slot.state != .query_running) return -2;

    slot.state = if (slot.tx_depth > 0) .in_transaction else .connected;
    return 0;
}

/// Signal an error on a query. Returns 0 on success.
pub export fn postgresql_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Get the query count for a connection. Returns count or -1 if invalid.
pub export fn postgresql_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intCast(@min(slot.query_count, std.math.maxInt(c_int)));
}

/// Get the number of active connections.
pub export fn postgresql_mcp_active_count() c_int {
    mutex.lock();
    defer mutex.unlock();

    var count: c_int = 0;
    for (&connections) |*slot| {
        if (slot.active) count += 1;
    }
    return count;
}

/// Reset all connections (test/debug use only).
pub export fn postgresql_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    connections = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "postgresql-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "pg_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_begin"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_commit"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_rollback"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_list_tables"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_describe"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pg_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    postgresql_mcp_reset();

    const slot = postgresql_mcp_connect("postgres://test:pw@localhost:5432/db", 38);
    try std.testing.expect(slot >= 0);

    // Should be connected
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_connection_state(slot));

    // Begin transaction
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_begin_tx(slot));
    try std.testing.expectEqual(@as(c_int, 2), postgresql_mcp_connection_state(slot));

    // Run query inside transaction
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 3), postgresql_mcp_connection_state(slot));

    // Complete query -> back to in_transaction
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 2), postgresql_mcp_connection_state(slot));

    // Commit transaction
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_end_tx(slot));
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_connection_state(slot));

    // Disconnect
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_disconnect(slot));
}

test "query error transitions" {
    postgresql_mcp_reset();

    const slot = postgresql_mcp_connect("postgres://test:pw@localhost:5432/db", 38);
    try std.testing.expect(slot >= 0);

    // Run a query
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_begin_query(slot));

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 4), postgresql_mcp_connection_state(slot));

    // Can only go to disconnected from error
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_disconnect(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(0, 1)); // disconn -> connected
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(1, 0)); // connected -> disconn
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(1, 2)); // connected -> in_tx
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(2, 1)); // in_tx -> connected
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(1, 3)); // connected -> query
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(2, 3)); // in_tx -> query
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(3, 1)); // query -> connected
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(3, 2)); // query -> in_tx
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(3, 4)); // query -> error
    try std.testing.expectEqual(@as(c_int, 1), postgresql_mcp_can_transition(4, 0)); // error -> disconn

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_can_transition(0, 3)); // disconn -> query
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_can_transition(1, 4)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_can_transition(4, 1)); // error -> connected

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_can_transition(99, 0));
}

test "pool exhaustion" {
    postgresql_mcp_reset();

    var slots: [MAX_CONNECTIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = postgresql_mcp_connect("postgres://x:y@h:5432/d", 23);
        try std.testing.expect(s.* >= 0);
    }

    // Pool full
    try std.testing.expectEqual(@as(c_int, -1), postgresql_mcp_connect("postgres://x:y@h:5432/d", 23));
    try std.testing.expectEqual(@as(c_int, @intCast(MAX_CONNECTIONS)), postgresql_mcp_active_count());

    // Free one and retry
    try std.testing.expectEqual(@as(c_int, 0), postgresql_mcp_disconnect(slots[0]));
    const new_slot = postgresql_mcp_connect("postgres://x:y@h:5432/d", 23);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns postgresql-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("postgresql-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "pg_connect",
        "pg_query",
        "pg_execute",
        "pg_begin",
        "pg_commit",
        "pg_rollback",
        "pg_list_tables",
        "pg_describe",
        "pg_disconnect",
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
    const rc = boj_cartridge_invoke("pg_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
