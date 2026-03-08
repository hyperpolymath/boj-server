// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Database-MCP Cartridge — Zig FFI bridge for database operations.
//
// Implements the connection state machine from SafeDatabase.idr.
// Ensures no query can execute on a closed connection, and no
// connection can be double-closed.

const std = @import("std");

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
};

var connections: [MAX_CONNECTIONS]ConnectionSlot = [_]ConnectionSlot{.{
    .active = false,
    .state = .disconnected,
    .backend = .sqlite,
}} ** MAX_CONNECTIONS;

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
pub export fn db_connect(backend: c_int) c_int {
    for (&connections, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.backend = @enumFromInt(backend);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Close a connection by slot index.
pub export fn db_disconnect(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .disconnected)) return -2;

    connections[idx].active = false;
    connections[idx].state = .disconnected;
    return 0;
}

/// Get the state of a connection.
pub export fn db_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return @intFromEnum(ConnState.disconnected);
    return @intFromEnum(connections[idx].state);
}

/// Begin a query (transition Connected -> Querying).
pub export fn db_begin_query(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .querying)) return -2;

    connections[idx].state = .querying;
    return 0;
}

/// End a query successfully (transition Querying -> Connected).
pub export fn db_end_query(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .connected)) return -2;

    connections[idx].state = .connected;
    return 0;
}

/// Record a query error (transition Querying -> Error).
pub export fn db_query_error(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONNECTIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!connections[idx].active) return -1;
    if (!isValidTransition(connections[idx].state, .err)) return -2;

    connections[idx].state = .err;
    return 0;
}

/// Validate a state transition (C-ABI export).
pub export fn db_can_transition(from: c_int, to: c_int) c_int {
    const f: ConnState = @enumFromInt(from);
    const t: ConnState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all connections (for testing).
pub export fn db_reset() void {
    for (&connections) |*slot| {
        slot.active = false;
        slot.state = .disconnected;
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
    return "database-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
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
