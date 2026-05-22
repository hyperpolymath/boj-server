// SPDX-License-Identifier: MPL-2.0
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
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "github-actions-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "gha_list_workflows"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_runs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_get_run"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_jobs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_get_logs"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_artifacts"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_dispatch_workflow"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_rerun_workflow"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_cancel_run"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_secrets"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_runners"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gha_list_caches"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns github-actions-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("github-actions-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "gha_list_workflows",
        "gha_list_runs",
        "gha_get_run",
        "gha_list_jobs",
        "gha_get_logs",
        "gha_list_artifacts",
        "gha_dispatch_workflow",
        "gha_rerun_workflow",
        "gha_cancel_run",
        "gha_list_secrets",
        "gha_list_runners",
        "gha_list_caches",
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
    const rc = boj_cartridge_invoke("gha_list_workflows", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
