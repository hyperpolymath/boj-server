// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// mongodb_mcp_ffi.zig -- C-ABI FFI implementation for mongodb-mcp cartridge.
//
// Implements the state machine defined in MongodbMcp.SafeDatabase (Idris2 ABI).
// Thread-safe via std.Thread.Mutex. Wraps MongoDB wire protocol stubs with
// BSON document handling. Credentials via connection string from vault-mcp.
// No heap allocations for state management.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// MongoDB connection lifecycle states.
/// Disconnected=0, Connected=1, InSession=2, Error=3
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    in_session = 2,
    err = 3,
};

/// MongoDB actions matching the Idris2 MongodbAction type.
pub const MongodbAction = enum(c_int) {
    find = 0,
    find_one = 1,
    insert_one = 2,
    insert_many = 3,
    update_one = 4,
    update_many = 5,
    delete_one = 6,
    delete_many = 7,
    aggregate = 8,
    count_documents = 9,
    create_index = 10,
    drop_index = 11,
    list_collections = 12,
    create_collection = 13,
    drop_collection = 14,
    list_databases = 15,
};

/// BSON wire-protocol field type tags. Matches Idris2
/// `MongodbMcp.SafeDatabase.BsonFieldType` + `bsonFieldTypeToInt`.
/// Integer codes follow the BSON spec — gaps (6, 11–15, 17) are by
/// design (reserved / deprecated BSON codes Idris2 does not expose).
/// Declared here so `iseriser abi-verify` can structurally check the
/// encoding against the Idris2 source; the wire-protocol encoder will
/// use these values when introduced.
pub const BsonFieldType = enum(c_int) {
    bson_double = 1,
    bson_string = 2,
    bson_document = 3,
    bson_array = 4,
    bson_binary = 5,
    bson_object_id = 7,
    bson_bool = 8,
    bson_date_time = 9,
    bson_null = 10,
    bson_int32 = 16,
    bson_int64 = 18,
};

/// Validate a state transition against the proven Idris2 transition graph.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .disconnected or to == .in_session or to == .err,
        .in_session => to == .connected or to == .err,
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
    op_count: u64 = 0,
    collection_count: u32 = 0,
    document_count: u64 = 0,
};

var connections: [MAX_CONNECTIONS]ConnectionSlot = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// MongoDB wire protocol stubs (linked at build time)
// ---------------------------------------------------------------------------

/// Opaque MongoDB client handle.
const MongocClient = opaque {};
/// Opaque MongoDB collection handle.
const MongocCollection = opaque {};
/// Opaque BSON document.
const BsonT = opaque {};

extern fn mongoc_client_new(uri_string: [*:0]const u8) ?*MongocClient;
extern fn mongoc_client_destroy(client: *MongocClient) void;
extern fn mongoc_client_get_collection(client: *MongocClient, db: [*:0]const u8, collection: [*:0]const u8) ?*MongocCollection;
extern fn mongoc_collection_destroy(collection: *MongocCollection) void;
extern fn mongoc_collection_find_with_opts(collection: *MongocCollection, filter: *const BsonT, opts: ?*const BsonT, read_prefs: ?*anyopaque) ?*anyopaque;
extern fn bson_new() ?*BsonT;
extern fn bson_destroy(bson: *BsonT) void;

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn mongodb_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Connect to MongoDB. Returns slot index (>= 0) or -1 if pool full, -2 if bad args.
pub export fn mongodb_mcp_connect(connstr_ptr: [*]const u8, connstr_len: c_int) c_int {
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
            slot.op_count = 0;
            slot.collection_count = 0;
            slot.document_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect a connection slot. Returns 0 on success.
pub export fn mongodb_mcp_disconnect(slot_idx: c_int) c_int {
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
    slot.op_count = 0;
    slot.collection_count = 0;
    slot.document_count = 0;
    return 0;
}

/// Get the current state of a connection. Returns state int or -1 if invalid.
pub export fn mongodb_mcp_connection_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Start a client session. Returns 0 on success.
pub export fn mongodb_mcp_start_session(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .in_session)) return -2;

    slot.state = .in_session;
    return 0;
}

/// End a client session (commit/abort). Returns 0 on success.
pub export fn mongodb_mcp_end_session(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    return 0;
}

/// Signal an error on a connection. Returns 0 on success.
pub export fn mongodb_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Record an operation (for metrics). Returns new count or -1.
pub export fn mongodb_mcp_record_operation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;

    slot.op_count += 1;
    return @intCast(@min(slot.op_count, std.math.maxInt(c_int)));
}

/// Get the operation count for a connection.
pub export fn mongodb_mcp_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intCast(@min(slot.op_count, std.math.maxInt(c_int)));
}

/// Get the number of active connections.
pub export fn mongodb_mcp_active_count() c_int {
    mutex.lock();
    defer mutex.unlock();

    var count: c_int = 0;
    for (&connections) |*slot| {
        if (slot.active) count += 1;
    }
    return count;
}

/// Reset all connections (test/debug use only).
pub export fn mongodb_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    connections = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "mongodb-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "mongo_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_find"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_insert"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_update"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_delete"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_aggregate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_list_collections"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "mongo_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    mongodb_mcp_reset();

    const slot = mongodb_mcp_connect("mongodb://test:pw@localhost:27017/db", 37);
    try std.testing.expect(slot >= 0);

    // Should be connected
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_connection_state(slot));

    // Start session
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_start_session(slot));
    try std.testing.expectEqual(@as(c_int, 2), mongodb_mcp_connection_state(slot));

    // End session
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_end_session(slot));
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_connection_state(slot));

    // Disconnect
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_disconnect(slot));
}

test "error transitions" {
    mongodb_mcp_reset();

    const slot = mongodb_mcp_connect("mongodb://test:pw@localhost:27017/db", 37);
    try std.testing.expect(slot >= 0);

    // Signal error from connected
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), mongodb_mcp_connection_state(slot));

    // Can only disconnect from error
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_disconnect(slot));
}

test "session error" {
    mongodb_mcp_reset();

    const slot = mongodb_mcp_connect("mongodb://test:pw@localhost:27017/db", 37);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_start_session(slot));
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), mongodb_mcp_connection_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_disconnect(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(0, 1)); // disconn -> connected
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(1, 0)); // connected -> disconn
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(1, 2)); // connected -> in_session
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(2, 1)); // in_session -> connected
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(1, 3)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(2, 3)); // in_session -> error
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_can_transition(3, 0)); // error -> disconn

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_can_transition(0, 2)); // disconn -> in_session
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_can_transition(3, 1)); // error -> connected

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_can_transition(99, 0));
}

test "pool exhaustion" {
    mongodb_mcp_reset();

    var slots: [MAX_CONNECTIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = mongodb_mcp_connect("mongodb://x:y@h:27017/d", 24);
        try std.testing.expect(s.* >= 0);
    }

    // Pool full
    try std.testing.expectEqual(@as(c_int, -1), mongodb_mcp_connect("mongodb://x:y@h:27017/d", 24));
    try std.testing.expectEqual(@as(c_int, @intCast(MAX_CONNECTIONS)), mongodb_mcp_active_count());

    // Free one and retry
    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_disconnect(slots[0]));
    const new_slot = mongodb_mcp_connect("mongodb://x:y@h:27017/d", 24);
    try std.testing.expect(new_slot >= 0);
}

test "operation counting" {
    mongodb_mcp_reset();

    const slot = mongodb_mcp_connect("mongodb://x:y@h:27017/d", 24);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), mongodb_mcp_record_operation(slot));
    try std.testing.expectEqual(@as(c_int, 2), mongodb_mcp_record_operation(slot));
    try std.testing.expectEqual(@as(c_int, 2), mongodb_mcp_op_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), mongodb_mcp_disconnect(slot));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns mongodb-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("mongodb-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "mongo_connect",
        "mongo_find",
        "mongo_insert",
        "mongo_update",
        "mongo_delete",
        "mongo_aggregate",
        "mongo_list_collections",
        "mongo_disconnect",
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
    const rc = boj_cartridge_invoke("mongo_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
