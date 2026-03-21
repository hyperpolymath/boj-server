// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// prometheus_mcp_ffi.zig — C-ABI FFI implementation for prometheus-mcp cartridge.
//
// Implements the state machine defined in PrometheusMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Optional Bearer token — Prometheus reads are typically public.
// Actions: InstantQuery, RangeQuery, ListTargets, ListAlerts, ListLabels,
//          LabelValues, GetMetadata, ListSeries
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Prometheus action identifiers matching Idris2 PrometheusAction encoding.
pub const PrometheusAction = enum(c_int) {
    instant_query = 0,
    range_query = 1,
    list_targets = 2,
    list_alerts = 3,
    list_labels = 4,
    label_values = 5,
    get_metadata = 6,
    list_series = 7,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .rate_limited or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated or to == .unauthenticated,
        .err => to == .authenticated or to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    instant_queries: u32 = 0,
    range_queries: u32 = 0,
    discovery_ops: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn prometheus_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn prometheus_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.instant_queries = 0;
            slot.range_queries = 0;
            slot.discovery_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn prometheus_mcp_open_anonymous(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unauthenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.instant_queries = 0;
            slot.range_queries = 0;
            slot.discovery_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn prometheus_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn prometheus_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn prometheus_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn prometheus_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated) and !isValidTransition(slot.state, .unauthenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

pub export fn prometheus_mcp_signal_error(slot_idx: c_int) c_int {
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
// C-ABI exports — action recording and metrics
// ---------------------------------------------------------------------------

pub export fn prometheus_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(PrometheusAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .rate_limited) return -2;
    if (slot.state == .err) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    switch (act) {
        .instant_query => sessions[idx].instant_queries += 1,
        .range_query => sessions[idx].range_queries += 1,
        .list_targets, .list_alerts, .list_labels, .label_values, .get_metadata, .list_series => sessions[idx].discovery_ops += 1,
    }

    return 0;
}

pub export fn prometheus_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

pub export fn prometheus_mcp_instant_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.instant_queries);
}

pub export fn prometheus_mcp_range_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.range_queries);
}

pub export fn prometheus_mcp_discovery_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.discovery_ops);
}

pub export fn prometheus_mcp_action_count() c_int {
    return 8;
}

pub export fn prometheus_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_instant_query_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slot));
}

test "anonymous session lifecycle" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_open_anonymous(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 1));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_range_query_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slot));
}

test "rate limiting flow" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), prometheus_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), prometheus_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_session_state(slot));
}

test "category counting" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // InstantQuery (0)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 0));
    // RangeQuery (1)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 1));
    // ListTargets (2)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 2));
    // ListLabels (4)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 4));

    try std.testing.expectEqual(@as(c_int, 4), prometheus_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_instant_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_range_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), prometheus_mcp_discovery_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_can_transition(2, 3));
}

test "slot exhaustion" {
    prometheus_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = prometheus_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), prometheus_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slots[0]));
    const new_slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}
