// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// circleci_mcp_ffi.zig — C-ABI FFI implementation for circleci-mcp cartridge.
//
// Implements the state machine defined in CircleciMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Circle-Token required for all CircleCI API operations.
// Actions: ListPipelines, GetPipeline, ListWorkflows, GetWorkflow, ListJobs,
//          ListArtifacts, TriggerPipeline, CancelWorkflow, ListEnvVars
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

pub const CircleciAction = enum(c_int) {
    list_pipelines = 0,
    get_pipeline = 1,
    list_workflows = 2,
    get_workflow = 3,
    list_jobs = 4,
    list_artifacts = 5,
    trigger_pipeline = 6,
    cancel_workflow = 7,
    list_envvars = 8,
};

fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
        .err => to == .authenticated or to == .unauthenticated,
    };
}

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    pipeline_ops: u32 = 0,
    workflow_ops: u32 = 0,
    config_ops: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

pub export fn circleci_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn circleci_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.pipeline_ops = 0;
            slot.workflow_ops = 0;
            slot.config_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn circleci_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn circleci_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn circleci_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn circleci_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn circleci_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn circleci_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(CircleciAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .rate_limited) return -2;
    if (slot.state == .err) return -2;
    if (slot.state == .unauthenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    switch (act) {
        .list_pipelines, .get_pipeline, .trigger_pipeline => sessions[idx].pipeline_ops += 1,
        .list_workflows, .get_workflow, .list_jobs, .list_artifacts, .cancel_workflow => sessions[idx].workflow_ops += 1,
        .list_envvars => sessions[idx].config_ops += 1,
    }

    return 0;
}

pub export fn circleci_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].api_call_count);
}

pub export fn circleci_mcp_pipeline_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].pipeline_ops);
}

pub export fn circleci_mcp_workflow_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].workflow_ops);
}

pub export fn circleci_mcp_config_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].config_ops);
}

pub export fn circleci_mcp_action_count() c_int {
    return 9;
}

pub export fn circleci_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

test "authenticated session lifecycle" {
    circleci_mcp_reset();
    const slot = circleci_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_pipeline_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_close(slot));
}

test "rate limiting flow" {
    circleci_mcp_reset();
    const slot = circleci_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), circleci_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_session_state(slot));
}

test "category counting" {
    circleci_mcp_reset();
    const slot = circleci_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    // ListPipelines (0)
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_record_call(slot, 0));
    // ListWorkflows (2)
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_record_call(slot, 2));
    // ListEnvVars (8)
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_record_call(slot, 8));
    try std.testing.expectEqual(@as(c_int, 3), circleci_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_pipeline_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_workflow_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_config_op_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), circleci_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    circleci_mcp_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = circleci_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), circleci_mcp_authenticate(0));
    try std.testing.expectEqual(@as(c_int, 0), circleci_mcp_close(slots[0]));
    try std.testing.expect(circleci_mcp_authenticate(0) >= 0);
}
