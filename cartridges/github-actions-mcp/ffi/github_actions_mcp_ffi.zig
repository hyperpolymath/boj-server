// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github_actions_mcp_ffi.zig — C-ABI FFI implementation for github-actions-mcp cartridge.
//
// Implements the state machine defined in GithubActionsMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Bearer token required for all GitHub Actions API operations.
// Actions: ListWorkflows, ListRuns, GetRun, ListJobs, GetLogs, ListArtifacts,
//          DispatchWorkflow, RerunWorkflow, CancelRun, ListSecrets, ListRunners, ListCaches
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

pub const GhaAction = enum(c_int) {
    list_workflows = 0,
    list_runs = 1,
    get_run = 2,
    list_jobs = 3,
    get_logs = 4,
    list_artifacts = 5,
    dispatch_workflow = 6,
    rerun_workflow = 7,
    cancel_run = 8,
    list_secrets = 9,
    list_runners = 10,
    list_caches = 11,
};

fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
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
    workflow_ops: u32 = 0,
    run_ops: u32 = 0,
    infra_ops: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn gha_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn gha_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.workflow_ops = 0;
            slot.run_ops = 0;
            slot.infra_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn gha_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn gha_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn gha_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn gha_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn gha_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn gha_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(GhaAction, action) catch return -3;

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
        .list_workflows, .dispatch_workflow => sessions[idx].workflow_ops += 1,
        .list_runs, .get_run, .list_jobs, .get_logs, .list_artifacts, .rerun_workflow, .cancel_run => sessions[idx].run_ops += 1,
        .list_secrets, .list_runners, .list_caches => sessions[idx].infra_ops += 1,
    }

    return 0;
}

pub export fn gha_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

pub export fn gha_mcp_workflow_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.workflow_ops);
}

pub export fn gha_mcp_run_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.run_ops);
}

pub export fn gha_mcp_infra_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.infra_ops);
}

pub export fn gha_mcp_action_count() c_int {
    return 12;
}

pub export fn gha_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    gha_mcp_reset();

    const slot = gha_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_session_state(slot));

    // ListWorkflows (0)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_workflow_op_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_close(slot));
}

test "rate limiting flow" {
    gha_mcp_reset();

    const slot = gha_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), gha_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), gha_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_session_state(slot));
}

test "category counting" {
    gha_mcp_reset();

    const slot = gha_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // ListWorkflows (0)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 0));
    // ListRuns (1)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 1));
    // GetRun (2)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 2));
    // ListSecrets (9)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 9));
    // DispatchWorkflow (6)
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_record_call(slot, 6));

    try std.testing.expectEqual(@as(c_int, 5), gha_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), gha_mcp_workflow_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), gha_mcp_run_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_infra_op_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), gha_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    gha_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = gha_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), gha_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), gha_mcp_close(slots[0]));
    const new_slot = gha_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}
