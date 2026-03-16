// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aws_mcp_ffi.zig — C-ABI FFI implementation for aws-mcp cartridge.
//
// Implements the state machine defined in AwsMcp.SafeCloud (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: AWS Signature V4 (access_key_id + secret_access_key + region) via vault-mcp.
// Services: S3, EC2, Lambda, SQS, DynamoDB with configurable region and endpoint routing.
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
/// 0 = Unauthenticated, 1 = Authenticated, 2 = RateLimited, 3 = Error.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// AWS service identifiers matching Idris2 AwsService encoding.
pub const AwsService = enum(c_int) {
    s3 = 0,
    ec2 = 1,
    lambda = 2,
    sqs = 3,
    dynamodb = 4,
};

/// AWS action identifiers matching Idris2 AwsAction encoding.
pub const AwsAction = enum(c_int) {
    list_buckets = 0,
    get_object = 1,
    put_object = 2,
    delete_object = 3,
    list_instances = 4,
    start_instance = 5,
    stop_instance = 6,
    list_functions = 7,
    invoke_function = 8,
    list_queues = 9,
    send_message = 10,
    receive_message = 11,
    list_tables = 12,
    put_item = 13,
    get_item = 14,
    query_table = 15,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
        .err => to == .unauthenticated,
    };
}

/// Map action integer to its service integer. Returns -1 for invalid action.
fn actionToService(action: c_int) c_int {
    const a = std.meta.intToEnum(AwsAction, action) catch return -1;
    return switch (a) {
        .list_buckets, .get_object, .put_object, .delete_object => 0,
        .list_instances, .start_instance, .stop_instance => 1,
        .list_functions, .invoke_function => 2,
        .list_queues, .send_message, .receive_message => 3,
        .list_tables, .put_item, .get_item, .query_table => 4,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const REGION_BUF_SIZE: usize = 64;
const KEY_BUF_SIZE: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    region_buf: [REGION_BUF_SIZE]u8 = .{0} ** REGION_BUF_SIZE,
    region_len: usize = 0,
    access_key_buf: [KEY_BUF_SIZE]u8 = .{0} ** KEY_BUF_SIZE,
    access_key_len: usize = 0,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn aws_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session with region. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots, -2 = region too long.
pub export fn aws_mcp_authenticate(region_ptr: [*]const u8, region_len: c_int) c_int {
    const rlen: usize = std.math.cast(usize, region_len) orelse return -2;
    if (rlen > REGION_BUF_SIZE) return -2;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            @memcpy(slot.region_buf[0..rlen], region_ptr[0..rlen]);
            slot.region_len = rlen;
            slot.access_key_len = 0;
            slot.api_call_count = 0;
            slot.last_action = -1;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Deauthenticate (close) a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = invalid state transition.
pub export fn aws_mcp_deauthenticate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn aws_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn aws_mcp_throttle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    sessions[idx].state = .rate_limited;
    return 0;
}

/// Clear rate limiting (resume authenticated). Returns 0 on success.
pub export fn aws_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn aws_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    sessions[idx].state = .err;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — service routing and actions
// ---------------------------------------------------------------------------

/// Get the service for an action. Returns service int (0-4) or -1 for invalid.
pub export fn aws_mcp_action_service(action: c_int) c_int {
    return actionToService(action);
}

/// Record an API call on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = not authenticated, -3 = invalid action.
pub export fn aws_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    _ = std.meta.intToEnum(AwsAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;
    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn aws_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get total service count. Always returns 5.
pub export fn aws_mcp_service_count() c_int {
    return 5;
}

/// Get total action count. Always returns 16.
pub export fn aws_mcp_action_count() c_int {
    return 16;
}

/// Reset all sessions (test/debug use only).
pub export fn aws_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    aws_mcp_reset();

    const region = "us-east-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_session_state(slot));

    // Record an API call
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_call_count(slot));

    // Deauthenticate
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slot));
}

test "rate limiting flow" {
    aws_mcp_reset();

    const region = "eu-west-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), aws_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_session_state(slot));
}

test "error and recovery" {
    aws_mcp_reset();

    const region = "ap-south-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), aws_mcp_session_state(slot));

    // Recover to unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slot));
}

test "invalid transitions rejected" {
    aws_mcp_reset();

    const region = "us-west-2";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Cannot throttle from rate_limited (must be authenticated)
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_throttle(slot));

    // Cannot signal error from rate_limited
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_signal_error(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 0)); // auth -> unauth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(3, 0)); // error -> unauth

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(2, 0)); // rate_limited -> unauth
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(3, 1)); // error -> auth
}

test "action service routing" {
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_service(0)); // ListBuckets -> S3
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_service(4)); // ListInstances -> EC2
    try std.testing.expectEqual(@as(c_int, 2), aws_mcp_action_service(7)); // ListFunctions -> Lambda
    try std.testing.expectEqual(@as(c_int, 3), aws_mcp_action_service(9)); // ListQueues -> SQS
    try std.testing.expectEqual(@as(c_int, 4), aws_mcp_action_service(12)); // ListTables -> DynamoDB
    try std.testing.expectEqual(@as(c_int, -1), aws_mcp_action_service(99)); // invalid
}

test "slot exhaustion" {
    aws_mcp_reset();

    const region = "us-east-1";
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = aws_mcp_authenticate(region.ptr, @intCast(region.len));
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), aws_mcp_authenticate(region.ptr, @intCast(region.len)));

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slots[0]));
    const new_slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(new_slot >= 0);
}
