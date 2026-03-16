// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gcp_mcp_ffi.zig — C-ABI FFI implementation for gcp-mcp cartridge.
//
// Implements the state machine defined in GcpMcp.SafeCloud (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Service account JSON key or OAuth2 token, REST API (googleapis.com).
// Services: Compute, Storage, Functions, Pub/Sub, BigQuery, IAM with
// configurable project_id and multi-service routing.
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

/// GCP service identifiers matching Idris2 GcpService encoding.
pub const GcpService = enum(c_int) {
    compute = 0,
    storage = 1,
    functions = 2,
    pubsub = 3,
    bigquery = 4,
    iam = 5,
};

/// GCP action identifiers matching Idris2 GcpAction encoding.
pub const GcpAction = enum(c_int) {
    list_projects = 0,
    list_instances = 1,
    start_instance = 2,
    stop_instance = 3,
    list_buckets = 4,
    get_object = 5,
    put_object = 6,
    list_functions = 7,
    invoke_function = 8,
    list_pubsub_topics = 9,
    publish_message = 10,
    list_subscriptions = 11,
    run_query = 12,
    list_datasets = 13,
    create_dataset = 14,
    get_iam_policy = 15,
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
    const a = std.meta.intToEnum(GcpAction, action) catch return -1;
    return switch (a) {
        .list_projects, .list_instances, .start_instance, .stop_instance => 0,
        .list_buckets, .get_object, .put_object => 1,
        .list_functions, .invoke_function => 2,
        .list_pubsub_topics, .publish_message, .list_subscriptions => 3,
        .run_query, .list_datasets, .create_dataset => 4,
        .get_iam_policy => 5,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const PROJECT_BUF_SIZE: usize = 128;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    project_buf: [PROJECT_BUF_SIZE]u8 = .{0} ** PROJECT_BUF_SIZE,
    project_len: usize = 0,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    quota_remaining: u32 = 10000,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn gcp_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session with project_id. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots, -2 = project_id too long.
pub export fn gcp_mcp_authenticate(project_ptr: [*]const u8, project_len: c_int) c_int {
    const plen: usize = std.math.cast(usize, project_len) orelse return -2;
    if (plen > PROJECT_BUF_SIZE) return -2;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            @memcpy(slot.project_buf[0..plen], project_ptr[0..plen]);
            slot.project_len = plen;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.quota_remaining = 10000;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Deauthenticate (close) a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = invalid state transition.
pub export fn gcp_mcp_deauthenticate(slot_idx: c_int) c_int {
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
pub export fn gcp_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting (quota exceeded) on a session. Returns 0 on success.
pub export fn gcp_mcp_throttle(slot_idx: c_int) c_int {
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
pub export fn gcp_mcp_unthrottle(slot_idx: c_int) c_int {
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
pub export fn gcp_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Get the service for an action. Returns service int (0-5) or -1 for invalid.
pub export fn gcp_mcp_action_service(action: c_int) c_int {
    return actionToService(action);
}

/// Record an API call on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = not authenticated, -3 = invalid action.
pub export fn gcp_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    _ = std.meta.intToEnum(GcpAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;
    if (sessions[idx].quota_remaining > 0) {
        sessions[idx].quota_remaining -= 1;
    }
    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn gcp_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get remaining quota for a session. Returns quota or -1 if invalid.
pub export fn gcp_mcp_quota_remaining(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.quota_remaining);
}

/// Get total service count. Always returns 6.
pub export fn gcp_mcp_service_count() c_int {
    return 6;
}

/// Get total action count. Always returns 16.
pub export fn gcp_mcp_action_count() c_int {
    return 16;
}

/// Reset all sessions (test/debug use only).
pub export fn gcp_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    gcp_mcp_reset();

    const project = "my-gcp-project";
    const slot = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_session_state(slot));

    // Record an API call
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_call_count(slot));

    // Deauthenticate
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_deauthenticate(slot));
}

test "rate limiting and quota" {
    gcp_mcp_reset();

    const project = "quota-test";
    const slot = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
    try std.testing.expect(slot >= 0);

    // Check initial quota
    try std.testing.expectEqual(@as(c_int, 10000), gcp_mcp_quota_remaining(slot));

    // Record a call, quota should decrease
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_record_call(slot, 4));
    try std.testing.expectEqual(@as(c_int, 9999), gcp_mcp_quota_remaining(slot));

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), gcp_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), gcp_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_session_state(slot));
}

test "error and recovery" {
    gcp_mcp_reset();

    const project = "error-test";
    const slot = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), gcp_mcp_session_state(slot));

    // Recover to unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_deauthenticate(slot));
}

test "invalid transitions rejected" {
    gcp_mcp_reset();

    const project = "transition-test";
    const slot = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
    try std.testing.expect(slot >= 0);

    // Cannot throttle twice
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), gcp_mcp_throttle(slot));

    // Cannot error from rate_limited
    try std.testing.expectEqual(@as(c_int, -2), gcp_mcp_signal_error(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_can_transition(3, 0));

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_can_transition(0, 3));
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_can_transition(2, 0));
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_can_transition(3, 1));
}

test "action service routing" {
    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_action_service(0)); // ListProjects -> Compute
    try std.testing.expectEqual(@as(c_int, 1), gcp_mcp_action_service(4)); // ListBuckets -> Storage
    try std.testing.expectEqual(@as(c_int, 2), gcp_mcp_action_service(7)); // ListFunctions -> Functions
    try std.testing.expectEqual(@as(c_int, 3), gcp_mcp_action_service(9)); // ListPubSubTopics -> PubSub
    try std.testing.expectEqual(@as(c_int, 4), gcp_mcp_action_service(12)); // RunQuery -> BigQuery
    try std.testing.expectEqual(@as(c_int, 5), gcp_mcp_action_service(15)); // GetIamPolicy -> IAM
    try std.testing.expectEqual(@as(c_int, -1), gcp_mcp_action_service(99)); // invalid
}

test "slot exhaustion" {
    gcp_mcp_reset();

    const project = "exhaust-test";
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), gcp_mcp_authenticate(project.ptr, @intCast(project.len)));

    try std.testing.expectEqual(@as(c_int, 0), gcp_mcp_deauthenticate(slots[0]));
    const new_slot = gcp_mcp_authenticate(project.ptr, @intCast(project.len));
    try std.testing.expect(new_slot >= 0);
}
