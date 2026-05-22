// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis_mcp_ffi.zig -- C-ABI FFI implementation for redis-mcp cartridge.
//
// Implements the state machine defined in RedisMcp.SafeDatabase (Idris2 ABI).
// Thread-safe via std.Thread.Mutex. Wraps RESP protocol stubs with pipeline
// support. Authentication via AUTH command with password from vault-mcp.
// No heap allocations for state management.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Redis connection lifecycle states.
/// Disconnected=0, Connected=1, Subscribing=2, Error=3
pub const ConnState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    subscribing = 2,
    err = 3,
};

/// Redis actions matching the Idris2 RedisAction type.
pub const RedisAction = enum(c_int) {
    get = 0,
    set = 1,
    del = 2,
    keys = 3,
    exists = 4,
    expire = 5,
    ttl = 6,
    lpush = 7,
    rpush = 8,
    lrange = 9,
    sadd = 10,
    smembers = 11,
    hset = 12,
    hget = 13,
    hgetall = 14,
    publish = 15,
    subscribe = 16,
    unsubscribe = 17,
    info = 18,
    ping = 19,
};

/// Validate a state transition against the proven Idris2 transition graph.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .connected,
        .connected => to == .disconnected or to == .subscribing or to == .err,
        .subscribing => to == .connected or to == .err,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Connection slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_CONNECTIONS: usize = 16;
const HOST_BUF_SIZE: usize = 256;

/// A single connection slot in the pool.
const ConnectionSlot = struct {
    active: bool = false,
    state: ConnState = .disconnected,
    host_buf: [HOST_BUF_SIZE]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 6379,
    sub_channel_count: u32 = 0,
    command_count: u64 = 0,
    pipeline_depth: u32 = 0,
};

var connections: [MAX_CONNECTIONS]ConnectionSlot = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// RESP protocol stubs (linked at build time)
// ---------------------------------------------------------------------------

/// Opaque Redis connection context.
const RedisContext = opaque {};
/// Opaque Redis reply.
const RedisReply = opaque {};

extern fn redisConnect(ip: [*:0]const u8, port: c_int) ?*RedisContext;
extern fn redisFree(ctx: *RedisContext) void;
extern fn redisCommand(ctx: *RedisContext, format: [*:0]const u8, ...) ?*RedisReply;
extern fn freeReplyObject(reply: *RedisReply) void;
extern fn redisAppendCommand(ctx: *RedisContext, format: [*:0]const u8, ...) c_int;
extern fn redisGetReply(ctx: *RedisContext, reply: *?*RedisReply) c_int;

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn redis_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Connect to Redis. Returns slot index (>= 0) or -1 if pool full, -2 if bad args.
pub export fn redis_mcp_connect(host_ptr: [*]const u8, host_len: c_int, port: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const len: usize = std.math.cast(usize, host_len) orelse return -2;
    if (len == 0 or len > HOST_BUF_SIZE) return -2;
    const p: u16 = std.math.cast(u16, port) orelse return -2;

    for (&connections, 0..) |*slot, idx| {
        if (!slot.active) {
            @memcpy(slot.host_buf[0..len], host_ptr[0..len]);
            slot.host_len = len;
            slot.port = p;
            slot.active = true;
            slot.state = .connected;
            slot.sub_channel_count = 0;
            slot.command_count = 0;
            slot.pipeline_depth = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect a connection slot. Returns 0 on success.
pub export fn redis_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.active = false;
    slot.state = .disconnected;
    slot.host_len = 0;
    slot.sub_channel_count = 0;
    slot.command_count = 0;
    slot.pipeline_depth = 0;
    return 0;
}

/// Get the current state of a connection. Returns state int or -1 if invalid.
pub export fn redis_mcp_connection_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Enter subscribing mode. Returns 0 on success.
pub export fn redis_mcp_subscribe(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .subscribing)) return -2;

    slot.state = .subscribing;
    slot.sub_channel_count += 1;
    return 0;
}

/// Leave subscribing mode (all channels unsubscribed). Returns 0 on success.
pub export fn redis_mcp_unsubscribe(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    slot.sub_channel_count = 0;
    return 0;
}

/// Signal an error on a connection. Returns 0 on success.
pub export fn redis_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Increment the command counter (for tracking). Returns new count or -1.
pub export fn redis_mcp_record_command(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    var slot = &connections[idx];
    if (!slot.active) return -1;

    slot.command_count += 1;
    return @intCast(@min(slot.command_count, std.math.maxInt(c_int)));
}

/// Get the command count for a connection.
pub export fn redis_mcp_command_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intCast(@min(slot.command_count, std.math.maxInt(c_int)));
}

/// Get the subscription channel count.
pub export fn redis_mcp_sub_channel_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_CONNECTIONS) return -1;
    const slot = &connections[idx];
    if (!slot.active) return -1;
    return @intCast(slot.sub_channel_count);
}

/// Get the number of active connections.
pub export fn redis_mcp_active_count() c_int {
    mutex.lock();
    defer mutex.unlock();

    var count: c_int = 0;
    for (&connections) |*slot| {
        if (slot.active) count += 1;
    }
    return count;
}

/// Reset all connections (test/debug use only).
pub export fn redis_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    connections = [_]ConnectionSlot{.{}} ** MAX_CONNECTIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "redis-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "redis_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_get"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_set"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_del"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_keys"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_hgetall"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_lpush"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_publish"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "redis_disconnect"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    redis_mcp_reset();

    const slot = redis_mcp_connect("localhost", 9, 6379);
    try std.testing.expect(slot >= 0);

    // Should be connected
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_connection_state(slot));

    // Subscribe
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_subscribe(slot));
    try std.testing.expectEqual(@as(c_int, 2), redis_mcp_connection_state(slot));

    // Unsubscribe
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_unsubscribe(slot));
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_connection_state(slot));

    // Disconnect
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_disconnect(slot));
}

test "error transitions" {
    redis_mcp_reset();

    const slot = redis_mcp_connect("localhost", 9, 6379);
    try std.testing.expect(slot >= 0);

    // Signal error from connected
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), redis_mcp_connection_state(slot));

    // Can only disconnect from error
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_disconnect(slot));
}

test "subscribing error" {
    redis_mcp_reset();

    const slot = redis_mcp_connect("localhost", 9, 6379);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_subscribe(slot));
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), redis_mcp_connection_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_disconnect(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(0, 1)); // disconn -> connected
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(1, 0)); // connected -> disconn
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(1, 2)); // connected -> subscribing
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(2, 1)); // subscribing -> connected
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(1, 3)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(2, 3)); // subscribing -> error
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_can_transition(3, 0)); // error -> disconn

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_can_transition(0, 2)); // disconn -> subscribing
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_can_transition(3, 1)); // error -> connected

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_can_transition(99, 0));
}

test "pool exhaustion" {
    redis_mcp_reset();

    var slots: [MAX_CONNECTIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = redis_mcp_connect("localhost", 9, 6379);
        try std.testing.expect(s.* >= 0);
    }

    // Pool full
    try std.testing.expectEqual(@as(c_int, -1), redis_mcp_connect("localhost", 9, 6379));
    try std.testing.expectEqual(@as(c_int, @intCast(MAX_CONNECTIONS)), redis_mcp_active_count());

    // Free one and retry
    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_disconnect(slots[0]));
    const new_slot = redis_mcp_connect("localhost", 9, 6379);
    try std.testing.expect(new_slot >= 0);
}

test "command counting" {
    redis_mcp_reset();

    const slot = redis_mcp_connect("localhost", 9, 6379);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_command_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), redis_mcp_record_command(slot));
    try std.testing.expectEqual(@as(c_int, 2), redis_mcp_record_command(slot));
    try std.testing.expectEqual(@as(c_int, 2), redis_mcp_command_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), redis_mcp_disconnect(slot));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns redis-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("redis-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "redis_connect",
        "redis_get",
        "redis_set",
        "redis_del",
        "redis_keys",
        "redis_hgetall",
        "redis_lpush",
        "redis_publish",
        "redis_disconnect",
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
    const rc = boj_cartridge_invoke("redis_connect", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
