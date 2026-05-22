// SPDX-License-Identifier: MPL-2.0
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

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "circleci-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "circleci_list_pipelines"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_get_pipeline"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_list_workflows"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_get_workflow"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_list_jobs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_list_artifacts"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_trigger_pipeline"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_cancel_workflow"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "circleci_list_envvars"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns circleci-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("circleci-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "circleci_list_pipelines",
        "circleci_get_pipeline",
        "circleci_list_workflows",
        "circleci_get_workflow",
        "circleci_list_jobs",
        "circleci_list_artifacts",
        "circleci_trigger_pipeline",
        "circleci_cancel_workflow",
        "circleci_list_envvars",
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
    const rc = boj_cartridge_invoke("circleci_list_pipelines", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
