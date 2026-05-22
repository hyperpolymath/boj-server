// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// duckdb_mcp_ffi.zig — C-ABI FFI implementation for the duckdb-mcp cartridge.
//
// Implements the connection state machine defined in the Idris2 ABI layer
// (DuckdbMcp.SafeDatabase). Thread-safe via std.Thread.Mutex. No heap
// allocations for results. State machine: Closed | Open | QueryRunning |
// Exporting | Error. DuckDB runs in-process — no external server.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Connection states for DuckDB embedded analytics.
pub const ConnState = enum(c_int) {
    closed = 0,
    open = 1,
    query_running = 2,
    exporting = 3,
    err = 4,
};

/// DuckDB embedded analytics actions.
pub const DuckdbAction = enum(c_int) {
    create_database = 0,
    attach_database = 1,
    detach_database = 2,
    query = 3,
    export_parquet = 4,
    export_csv = 5,
    import_parquet = 6,
    import_csv = 7,
    describe_table = 8,
    list_tables = 9,
    get_schema = 10,
    explain = 11,
    create_view = 12,
    drop_view = 13,
    copy_to = 14,
    load_extension = 15,
};

/// Check whether a state transition is valid per the ABI specification.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .closed => to == .open,
        .open => to == .query_running or to == .exporting or to == .closed,
        .query_running => to == .open or to == .err,
        .exporting => to == .open or to == .err,
        .err => to == .closed,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 4096;

const SessionSlot = struct {
    in_use: bool = false,
    state: ConnState = .closed,
    context_buf: [BUF_SIZE]u8 = .{0} ** BUF_SIZE,
    context_len: usize = 0,
    db_path_buf: [256]u8 = .{0} ** 256,
    db_path_len: usize = 0,
    table_count: u32 = 0,
    query_count: u32 = 0,
    export_count: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn duckdb_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new database session. Returns slot index (>= 0) or -1 if no slots.
pub export fn duckdb_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.in_use) {
            slot.in_use = true;
            slot.state = .open;
            slot.context_len = 0;
            slot.db_path_len = 0;
            slot.table_count = 0;
            slot.query_count = 0;
            slot.export_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a database session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn duckdb_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .closed)) return -2;

    slot.in_use = false;
    slot.state = .closed;
    slot.context_len = 0;
    slot.db_path_len = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn duckdb_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intFromEnum(slot.state);
}

/// Begin a query. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn duckdb_mcp_begin_query(slot_idx: c_int) c_int {
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

/// End a query (return to open). Returns 0 on success.
pub export fn duckdb_mcp_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .open)) return -2;

    slot.state = .open;
    slot.query_count += 1;
    return 0;
}

/// Begin an export operation (Parquet/CSV). Returns 0 on success.
pub export fn duckdb_mcp_begin_export(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .exporting)) return -2;

    slot.state = .exporting;
    return 0;
}

/// End an export operation (return to open). Returns 0 on success.
pub export fn duckdb_mcp_end_export(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    if (!isValidTransition(slot.state, .open)) return -2;

    slot.state = .open;
    slot.export_count += 1;
    return 0;
}

/// Signal an error on a running session. Returns 0 on success.
pub export fn duckdb_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn duckdb_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.query_count);
}

/// Get the export count for a session. Returns count or -1 if invalid slot.
pub export fn duckdb_mcp_export_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.in_use) return -1;
    return @intCast(slot.export_count);
}

/// Check if an action requires an open database. Returns 1 (yes) or 0 (no).
pub export fn duckdb_mcp_action_requires_open(action: c_int) c_int {
    const a = std.meta.intToEnum(DuckdbAction, action) catch return 0;
    return switch (a) {
        .create_database, .load_extension => 0,
        else => 1,
    };
}

/// Reset all sessions (test/debug use only).
pub export fn duckdb_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "duckdb-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "duckdb_open"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_import"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_export"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_list_tables"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "duckdb_close"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    duckdb_mcp_reset();

    const slot = duckdb_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in open state
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_session_state(slot));

    // Begin query
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 2), duckdb_mcp_session_state(slot));

    // End query
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_session_state(slot));

    // Query count should be 1
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_query_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_session_close(slot));
}

test "export lifecycle" {
    duckdb_mcp_reset();

    const slot = duckdb_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Begin export
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_begin_export(slot));
    try std.testing.expectEqual(@as(c_int, 3), duckdb_mcp_session_state(slot));

    // End export
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_end_export(slot));
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_session_state(slot));

    // Export count should be 1
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_export_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    duckdb_mcp_reset();

    const slot = duckdb_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can not go open -> error (must go through query_running or exporting)
    try std.testing.expectEqual(@as(c_int, -2), duckdb_mcp_signal_error(slot));

    // Can not close while query running
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, -2), duckdb_mcp_session_close(slot));

    // Can not export while query running
    try std.testing.expectEqual(@as(c_int, -2), duckdb_mcp_begin_export(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(0, 1)); // closed -> open
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(1, 2)); // open -> query_running
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(2, 1)); // query_running -> open
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(1, 3)); // open -> exporting
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(3, 1)); // exporting -> open
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(1, 0)); // open -> closed
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(2, 4)); // query_running -> error
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(3, 4)); // exporting -> error
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_can_transition(4, 0)); // error -> closed

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_can_transition(0, 2)); // closed -> query_running
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_can_transition(1, 4)); // open -> error
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_can_transition(4, 1)); // error -> open
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_can_transition(2, 3)); // query_running -> exporting
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_can_transition(99, 0)); // out of range
}

test "slot exhaustion" {
    duckdb_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots, 0..) |*s, i| {
        _ = i;
        s.* = duckdb_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), duckdb_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_session_close(slots[0]));
    const new_slot = duckdb_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "action requires open" {
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_action_requires_open(3)); // query
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_action_requires_open(4)); // export_parquet
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_action_requires_open(5)); // export_csv
    try std.testing.expectEqual(@as(c_int, 1), duckdb_mcp_action_requires_open(9)); // list_tables
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_action_requires_open(0)); // create_database
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_action_requires_open(15)); // load_extension
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_action_requires_open(99)); // out of range
}

test "error recovery" {
    duckdb_mcp_reset();

    const slot = duckdb_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Enter query, signal error
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 4), duckdb_mcp_session_state(slot));

    // Recover by closing
    try std.testing.expectEqual(@as(c_int, 0), duckdb_mcp_session_close(slot));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns duckdb-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("duckdb-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "duckdb_open",
        "duckdb_query",
        "duckdb_execute",
        "duckdb_import",
        "duckdb_export",
        "duckdb_list_tables",
        "duckdb_close",
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
    const rc = boj_cartridge_invoke("duckdb_open", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
