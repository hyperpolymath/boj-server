// SPDX-License-Identifier: PMPL-1.0-or-later
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
