// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Queues-MCP Cartridge — Zig FFI bridge for message queue operations.
//
// Implements the connection/subscription state machine from SafeQueues.idr.
// Ensures no publishing to unconnected queues, prevents double-subscribe,
// and enforces ack-before-next-message consumption.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match QueuesMcp.SafeQueues encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const QueueState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    subscribed = 2,
    consuming = 3,
    queue_error = 4,
};

pub const QueueBackend = enum(c_int) {
    redis_stream = 1,
    rabbitmq = 2,
    nats = 3,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Queue State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_QUEUES: usize = 16;

const QueueSlot = struct {
    active: bool,
    state: QueueState,
    backend: QueueBackend,
    msg_count: u64,
};

var queues: [MAX_QUEUES]QueueSlot = [_]QueueSlot{.{
    .active = false,
    .state = .disconnected,
    .backend = .redis_stream,
    .msg_count = 0,
}} ** MAX_QUEUES;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: QueueState, to: QueueState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .subscribed or to == .disconnected,
        .subscribed => to == .consuming or to == .connected,
        .consuming => to == .subscribed or to == .queue_error,
        .queue_error => to == .subscribed,
    };
}

/// Connect to a queue backend. Returns slot index or -1 on failure.
pub export fn queue_connect(backend: c_int) c_int {
    for (&queues, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.backend = @enumFromInt(backend);
            slot.msg_count = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Subscribe to a topic (transition Connected -> Subscribed).
pub export fn queue_subscribe(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    if (!isValidTransition(queues[idx].state, .subscribed)) return -2;

    queues[idx].state = .subscribed;
    return 0;
}

/// Begin consuming a message (transition Subscribed -> Consuming).
pub export fn queue_begin_consume(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    if (!isValidTransition(queues[idx].state, .consuming)) return -2;

    queues[idx].state = .consuming;
    return 0;
}

/// Acknowledge a consumed message (transition Consuming -> Subscribed).
/// Increments the message count.
pub export fn queue_ack(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    if (!isValidTransition(queues[idx].state, .subscribed)) return -2;

    queues[idx].state = .subscribed;
    queues[idx].msg_count += 1;
    return 0;
}

/// Publish a message (requires at least Connected state).
/// Does not change state — publish is a side-effect operation.
pub export fn queue_publish(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    // Publishing requires at least connected state
    if (queues[idx].state == .disconnected or queues[idx].state == .queue_error) return -2;

    queues[idx].msg_count += 1;
    return 0;
}

/// Unsubscribe from a topic (transition Subscribed -> Connected).
pub export fn queue_unsubscribe(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    if (!isValidTransition(queues[idx].state, .connected)) return -2;

    queues[idx].state = .connected;
    return 0;
}

/// Disconnect from the queue backend (transition Connected -> Disconnected).
pub export fn queue_disconnect(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return -1;
    if (!isValidTransition(queues[idx].state, .disconnected)) return -2;

    queues[idx].active = false;
    queues[idx].state = .disconnected;
    queues[idx].msg_count = 0;
    return 0;
}

/// Get the state of a queue connection.
pub export fn queue_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return @intFromEnum(QueueState.disconnected);
    return @intFromEnum(queues[idx].state);
}

/// Get the message count for a queue connection.
pub export fn queue_msg_count(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_QUEUES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!queues[idx].active) return 0;
    return @intCast(queues[idx].msg_count);
}

/// Validate a state transition (C-ABI export).
pub export fn queue_can_transition(from: c_int, to: c_int) c_int {
    const f: QueueState = @enumFromInt(from);
    const t: QueueState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all queue connections (for testing).
pub export fn queue_reset() void {
    for (&queues) |*slot| {
        slot.active = false;
        slot.state = .disconnected;
        slot.msg_count = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the queues-mcp cartridge. Resets all queue slots.
pub export fn boj_cartridge_init() c_int {
    queue_reset();
    return 0;
}

/// Deinitialise the queues-mcp cartridge. Resets all queue slots.
pub export fn boj_cartridge_deinit() void {
    queue_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "queues-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "connect and disconnect" {
    queue_reset();
    const slot = queue_connect(@intFromEnum(QueueBackend.redis_stream));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(QueueState.connected)), queue_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_disconnect(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(QueueState.disconnected)), queue_state(slot));
}

test "cannot publish to disconnected queue" {
    queue_reset();
    // No queue connected — publish on slot 0 should fail
    try std.testing.expectEqual(@as(c_int, -1), queue_publish(0));
}

test "cannot consume without subscription" {
    queue_reset();
    const slot = queue_connect(@intFromEnum(QueueBackend.rabbitmq));
    // Connected but not subscribed — should fail
    try std.testing.expectEqual(@as(c_int, -2), queue_begin_consume(slot));
    _ = queue_disconnect(slot);
}

test "full consume lifecycle with message count" {
    queue_reset();
    const slot = queue_connect(@intFromEnum(QueueBackend.nats));
    try std.testing.expectEqual(@as(c_int, 0), queue_subscribe(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_msg_count(slot));

    // First consume cycle
    try std.testing.expectEqual(@as(c_int, 0), queue_begin_consume(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(QueueState.consuming)), queue_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_ack(slot));
    try std.testing.expectEqual(@as(c_int, 1), queue_msg_count(slot));

    // Second consume cycle
    try std.testing.expectEqual(@as(c_int, 0), queue_begin_consume(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_ack(slot));
    try std.testing.expectEqual(@as(c_int, 2), queue_msg_count(slot));
}

test "publish increments message count" {
    queue_reset();
    const slot = queue_connect(@intFromEnum(QueueBackend.redis_stream));
    try std.testing.expectEqual(@as(c_int, 0), queue_publish(slot));
    try std.testing.expectEqual(@as(c_int, 1), queue_msg_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_publish(slot));
    try std.testing.expectEqual(@as(c_int, 2), queue_msg_count(slot));
}

test "cannot disconnect while subscribed" {
    queue_reset();
    const slot = queue_connect(@intFromEnum(QueueBackend.rabbitmq));
    _ = queue_subscribe(slot);
    // Must unsubscribe before disconnect
    try std.testing.expectEqual(@as(c_int, -2), queue_disconnect(slot));
    // Unsubscribe then disconnect works
    try std.testing.expectEqual(@as(c_int, 0), queue_unsubscribe(slot));
    try std.testing.expectEqual(@as(c_int, 0), queue_disconnect(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(0, 1)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(1, 2)); // connected -> subscribed
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(2, 3)); // subscribed -> consuming
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(3, 2)); // consuming -> subscribed
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(2, 1)); // subscribed -> connected
    try std.testing.expectEqual(@as(c_int, 1), queue_can_transition(1, 0)); // connected -> disconnected
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), queue_can_transition(0, 2)); // disconnected -> subscribed
    try std.testing.expectEqual(@as(c_int, 0), queue_can_transition(0, 3)); // disconnected -> consuming
    try std.testing.expectEqual(@as(c_int, 0), queue_can_transition(3, 0)); // consuming -> disconnected
}
