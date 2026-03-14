// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Database-MCP Cartridge — Zig FFI bridge for database operations.
//
// Implements the connection state machine from SafeDatabase.idr.
// Ensures no query can execute on a closed connection, and no
// connection can be double-closed.
//
// SQLite integration: when backend == sqlite, db_connect_sqlite opens
// a real sqlite3 handle, and db_execute_sql runs queries against it.

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

// ═══════════════════════════════════════════════════════════════════════
// Types (must match DatabaseMcp.SafeDatabase encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    querying = 2,
    err = 3,
};

pub const DatabaseBackend = enum(c_int) {
    verisimdb = 1,
    postgresql = 2,
    sqlite = 3,
    redis = 4,
    custom = 99,
};

pub const QuerySafety = enum(c_int) {
    read_only = 0,
    mutation = 1,
};

// ═══════════════════════════════════════════════════════════════════════
// Connection State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_CONNECTIONS: usize = 16;

const ConnectionSlot = struct {
    active: bool,
    state: ConnState,
    backend: DatabaseBackend,
    db_handle: ?*c.sqlite3,
};

var connections: [MAX_CONNECTIONS]ConnectionSlot = [_]ConnectionSlot{.{
    .active = false,
    .state = .disconnected,
    .backend = .sqlite,
    .db_handle = null,
}} ** MAX_CONNECTIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .querying or to == .disconnected,
        .querying => to == .connected or to == .err,
        .err => to == .disconnected,
    };
}

/// Open a new connection. Returns slot index or -1 on failure.
/// For non-sqlite backends, this only transitions state (no real handle).
pub export fn db_connect(backend: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&connections, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.backend = @enumFromInt(backend);
            slot.db_handle = null;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Open a new SQLite connection with a file path.
/// path_ptr/path_len: pointer and length of the database file path.
/// Returns slot index or negative error code:
///   -1 = no slots available
///   -3 = sqlite3_open failed
pub export fn db_connect_sqlite(path_ptr: [*]const u8, path_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();

    // Find a free slot
    var free_idx: ?usize = null;
    for (&connections, 0..) |*slot, i| {
        _ = slot;
        if (!connections[i].active) {
            free_idx = i;
            break;
        }
    }
    const idx = free_idx orelse return -1;

    // Build a null-terminated path for sqlite3_open
    var path_buf: [4096]u8 = undefined;
    const safe_len = @min(path_len, path_buf.len - 1);
    @memcpy(path_buf[0..safe_len], path_ptr[0..safe_len]);
    path_buf[safe_len] = 0;

    var db_handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(&path_buf, &db_handle);
    if (rc != c.SQLITE_OK) {
        if (db_handle) |h| {
            _ = c.sqlite3_close(h);
        }
        return -3; // sqlite3_open failed
    }

    connections[idx].active = true;
    connections[idx].state = .connected;
    connections[idx].backend = .sqlite;
    connections[idx].db_handle = db_handle;
    return @intCast(idx);
}

/// Close a connection by slot index.
/// If the slot holds an open sqlite3 handle, closes it first.
pub export fn db_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .disconnected)) return -2;

    // Close the sqlite3 handle if present
    if (connections[idx].db_handle) |h| {
        _ = c.sqlite3_close(h);
        connections[idx].db_handle = null;
    }

    connections[idx].active = false;
    connections[idx].state = .disconnected;
    return 0;
}

/// Get the state of a connection.
pub export fn db_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return @intFromEnum(ConnState.disconnected);
    return @intFromEnum(connections[idx].state);
}

/// Begin a query (transition Connected -> Querying).
pub export fn db_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .querying)) return -2;

    connections[idx].state = .querying;
    return 0;
}

/// End a query successfully (transition Querying -> Connected).
pub export fn db_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .connected)) return -2;

    connections[idx].state = .connected;
    return 0;
}

/// Record a query error (transition Querying -> Error).
pub export fn db_query_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .err)) return -2;

    connections[idx].state = .err;
    return 0;
}

/// Validate a state transition (C-ABI export).
pub export fn db_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: ConnState = @enumFromInt(from);
    const t: ConnState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all connections (for testing).
/// Closes any open sqlite3 handles.
pub export fn db_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&connections) |*slot| {
        if (slot.db_handle) |h| {
            _ = c.sqlite3_close(h);
            slot.db_handle = null;
        }
        slot.active = false;
        slot.state = .disconnected;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// SQL Execution (SQLite only)
// ═══════════════════════════════════════════════════════════════════════

/// Execute a SQL query against an open SQLite connection.
///
/// Manages the state machine: transitions Connected -> Querying, runs the
/// query via sqlite3_exec, then transitions Querying -> Connected (or
/// Querying -> Error on failure).
///
/// Parameters:
///   slot:    connection slot index (must be connected, backend == sqlite)
///   sql_ptr: pointer to the SQL string
///   sql_len: byte length of the SQL string
///   out_ptr: caller-owned buffer for JSON result output
///   out_len: size of the output buffer
///
/// Returns:
///   >= 0  : number of bytes written to out_ptr (JSON array of objects)
///   -1    : invalid slot
///   -2    : invalid state transition (not in connected state)
///   -3    : no sqlite3 handle on this slot (wrong backend)
///   -4    : sqlite3_exec error (state transitions to Error, then Disconnected)
///   -5    : output buffer too small
pub export fn db_execute_sql(slot: u8, sql_ptr: [*]const u8, sql_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) i32 {
    mutex.lock();
    defer mutex.unlock();

    if (slot >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot);
    if (!connections[idx].active) return -1;

    // Must be in connected state to begin querying
    if (!isValidTransition(connections[idx].state, .querying)) return -2;

    // Must have a real sqlite3 handle
    const db_handle = connections[idx].db_handle orelse return -3;

    // Transition to querying
    connections[idx].state = .querying;

    // Build null-terminated SQL from the pointer/length pair
    var sql_buf: [8192]u8 = undefined;
    const safe_sql_len = @min(sql_len, sql_buf.len - 1);
    @memcpy(sql_buf[0..safe_sql_len], sql_ptr[0..safe_sql_len]);
    sql_buf[safe_sql_len] = 0;

    // Use sqlite3_exec with a callback to collect results into a JSON array.
    // We accumulate into a fixed-size arena backed by a stack buffer, using
    // ArrayListUnmanaged (Zig 0.15 API).
    var result_buf: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&result_buf);
    const allocator = fba.allocator();

    var json_out = std.ArrayListUnmanaged(u8){};
    json_out.appendSlice(allocator, "[") catch {
        connections[idx].state = .err;
        return -5;
    };

    var ctx = ExecContext{
        .json_out = &json_out,
        .allocator = allocator,
        .row_count = 0,
    };

    var errmsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(
        db_handle,
        &sql_buf,
        execCallback,
        @ptrCast(&ctx),
        &errmsg,
    );

    if (rc != c.SQLITE_OK) {
        if (errmsg) |msg| c.sqlite3_free(@ptrCast(msg));
        // Transition to error state; caller can recover via db_disconnect.
        connections[idx].state = .err;
        return -4;
    }

    json_out.appendSlice(allocator, "]") catch {
        connections[idx].state = .err;
        return -5;
    };

    // Transition back to connected
    connections[idx].state = .connected;

    const written = json_out.items.len;
    if (written > out_len) return -5;

    @memcpy(out_ptr[0..written], json_out.items[0..written]);
    return @intCast(written);
}

const ExecContext = struct {
    json_out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    row_count: usize,
};

/// sqlite3_exec callback — called once per result row.
/// Serializes each row as a JSON object with column names as keys.
fn execCallback(
    ctx_ptr: ?*anyopaque,
    col_count: c_int,
    col_values: [*c][*c]u8,
    col_names: [*c][*c]u8,
) callconv(.c) c_int {
    const ctx: *ExecContext = @ptrCast(@alignCast(ctx_ptr orelse return 1));
    const ncols: usize = @intCast(col_count);
    const alloc = ctx.allocator;

    // Comma separator between rows
    if (ctx.row_count > 0) {
        ctx.json_out.appendSlice(alloc, ",") catch return 1;
    }
    ctx.row_count += 1;

    ctx.json_out.appendSlice(alloc, "{") catch return 1;

    for (0..ncols) |i| {
        if (i > 0) {
            ctx.json_out.appendSlice(alloc, ",") catch return 1;
        }

        // Key: column name
        ctx.json_out.appendSlice(alloc, "\"") catch return 1;
        if (col_names[i]) |name| {
            const name_slice = std.mem.span(name);
            appendJsonEscaped(ctx.json_out, alloc, name_slice) catch return 1;
        }
        ctx.json_out.appendSlice(alloc, "\":") catch return 1;

        // Value: column value (null-safe)
        if (col_values[i]) |val| {
            ctx.json_out.appendSlice(alloc, "\"") catch return 1;
            const val_slice = std.mem.span(val);
            appendJsonEscaped(ctx.json_out, alloc, val_slice) catch return 1;
            ctx.json_out.appendSlice(alloc, "\"") catch return 1;
        } else {
            ctx.json_out.appendSlice(alloc, "null") catch return 1;
        }
    }

    ctx.json_out.appendSlice(alloc, "}") catch return 1;
    return 0;
}

/// Append a string to the ArrayListUnmanaged, escaping JSON special characters.
fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, input: []const u8) !void {
    for (input) |byte| {
        switch (byte) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (byte < 0x20) {
                    // Control character — encode as \u00XX
                    var hex_buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "\\u{X:0>4}", .{byte}) catch return error.OutOfMemory;
                    try list.appendSlice(alloc, &hex_buf);
                } else {
                    try list.append(alloc, byte);
                }
            },
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the database-mcp cartridge. Resets all connection slots.
pub export fn boj_cartridge_init() c_int {
    db_reset();
    return 0;
}

/// Deinitialise the database-mcp cartridge. Resets all connection slots.
pub export fn boj_cartridge_deinit() void {
    db_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "database-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "connect and disconnect" {
    db_reset();
    const slot = db_connect(@intFromEnum(DatabaseBackend.sqlite));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.connected)), db_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot));
}

test "cannot query on disconnected" {
    db_reset();
    const slot = db_connect(@intFromEnum(DatabaseBackend.postgresql));
    _ = db_disconnect(slot);
    // Should fail — can't begin query on disconnected connection
    try std.testing.expectEqual(@as(c_int, -1), db_begin_query(slot));
}

test "query lifecycle" {
    db_reset();
    const slot = db_connect(@intFromEnum(DatabaseBackend.verisimdb));
    try std.testing.expectEqual(@as(c_int, 0), db_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.querying)), db_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), db_end_query(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.connected)), db_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot));
}

test "cannot double-close" {
    db_reset();
    const slot = db_connect(@intFromEnum(DatabaseBackend.redis));
    _ = db_disconnect(slot);
    // Second disconnect should fail — already disconnected
    try std.testing.expectEqual(@as(c_int, -1), db_disconnect(slot));
}

test "error recovery" {
    db_reset();
    const slot = db_connect(@intFromEnum(DatabaseBackend.sqlite));
    _ = db_begin_query(slot);
    _ = db_query_error(slot);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.err)), db_state(slot));
    // Can only go to disconnected from error
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), db_can_transition(0, 1)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 1), db_can_transition(1, 2)); // connected -> querying
    try std.testing.expectEqual(@as(c_int, 1), db_can_transition(2, 1)); // querying -> connected
    try std.testing.expectEqual(@as(c_int, 1), db_can_transition(1, 0)); // connected -> disconnected
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), db_can_transition(0, 2)); // disconnected -> querying
    try std.testing.expectEqual(@as(c_int, 0), db_can_transition(2, 0)); // querying -> disconnected
}

test "sqlite connect and disconnect with real handle" {
    db_reset();
    // Use in-memory database for testing
    const path = ":memory:";
    const slot = db_connect_sqlite(path, path.len);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.connected)), db_state(slot));
    // Verify the handle is non-null
    const idx: usize = @intCast(slot);
    try std.testing.expect(connections[idx].db_handle != null);
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot));
    // After disconnect, handle should be null
    try std.testing.expect(connections[idx].db_handle == null);
}

test "sqlite execute_sql basic query" {
    db_reset();
    const path = ":memory:";
    const slot_i32 = db_connect_sqlite(path, path.len);
    try std.testing.expect(slot_i32 >= 0);
    const slot: u8 = @intCast(slot_i32);

    // Create a table and insert data
    var discard_buf: [256]u8 = undefined;
    const create_sql = "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);";
    const rc1 = db_execute_sql(slot, create_sql, create_sql.len, &discard_buf, discard_buf.len);
    try std.testing.expect(rc1 >= 0); // empty result is fine: "[]"

    const insert_sql = "INSERT INTO t VALUES(1, 'alice');";
    const rc2 = db_execute_sql(slot, insert_sql, insert_sql.len, &discard_buf, discard_buf.len);
    try std.testing.expect(rc2 >= 0);

    // Query the data
    var out_buf: [1024]u8 = undefined;
    const select_sql = "SELECT id, name FROM t;";
    const written = db_execute_sql(slot, select_sql, select_sql.len, &out_buf, out_buf.len);
    try std.testing.expect(written > 0);

    const json_result = out_buf[0..@intCast(written)];
    // Should contain the row data
    try std.testing.expect(std.mem.indexOf(u8, json_result, "\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_result, "\"1\"") != null);

    // Verify state is back to connected
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.connected)), db_state(slot_i32));

    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot_i32));
}

test "sqlite execute_sql error on invalid SQL" {
    db_reset();
    const path = ":memory:";
    const slot_i32 = db_connect_sqlite(path, path.len);
    try std.testing.expect(slot_i32 >= 0);
    const slot: u8 = @intCast(slot_i32);

    var out_buf: [256]u8 = undefined;
    const bad_sql = "SELEKT * FORM nonexistent;";
    const rc = db_execute_sql(slot, bad_sql, bad_sql.len, &out_buf, out_buf.len);
    try std.testing.expectEqual(@as(i32, -4), rc);

    // State should now be error
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.err)), db_state(slot_i32));

    // Recovery: disconnect from error state
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot_i32));
}

test "sqlite execute_sql rejects non-sqlite slot" {
    db_reset();
    // Connect with verisimdb backend (no sqlite handle)
    const slot_i32 = db_connect(@intFromEnum(DatabaseBackend.verisimdb));
    try std.testing.expect(slot_i32 >= 0);
    const slot: u8 = @intCast(slot_i32);

    var out_buf: [256]u8 = undefined;
    const sql = "SELECT 1;";
    const rc = db_execute_sql(slot, sql, sql.len, &out_buf, out_buf.len);
    // Should return -3 (no sqlite handle)
    try std.testing.expectEqual(@as(i32, -3), rc);

    // State should still be connected — the handle check occurs before
    // the state transition, so no transition happened.
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ConnState.connected)), db_state(slot_i32));

    // Disconnect directly from connected
    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot_i32));
}

test "sqlite execute_sql multiple rows" {
    db_reset();
    const path = ":memory:";
    const slot_i32 = db_connect_sqlite(path, path.len);
    try std.testing.expect(slot_i32 >= 0);
    const slot: u8 = @intCast(slot_i32);

    var discard_buf: [256]u8 = undefined;
    const setup = "CREATE TABLE items(id INT, val TEXT); INSERT INTO items VALUES(1,'a'),(2,'b'),(3,'c');";
    _ = db_execute_sql(slot, setup, setup.len, &discard_buf, discard_buf.len);

    var out_buf: [2048]u8 = undefined;
    const query = "SELECT * FROM items ORDER BY id;";
    const written = db_execute_sql(slot, query, query.len, &out_buf, out_buf.len);
    try std.testing.expect(written > 0);

    const json_result = out_buf[0..@intCast(written)];
    // Should have 3 rows with commas between them
    try std.testing.expect(std.mem.indexOf(u8, json_result, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_result, "\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_result, "\"c\"") != null);

    try std.testing.expectEqual(@as(c_int, 0), db_disconnect(slot_i32));
}
