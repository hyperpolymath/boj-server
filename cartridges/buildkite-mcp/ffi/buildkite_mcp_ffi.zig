// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// buildkite_mcp_ffi.zig — C-ABI FFI implementation for buildkite-mcp cartridge.
//
// Implements the state machine defined in BuildkiteMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Bearer token required for all Buildkite API operations.
// Actions: ListPipelines, GetPipeline, ListBuilds, GetBuild, CreateBuild,
//          CancelBuild, ListJobs, GetJobLog, ListArtifacts, ListAgents
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

pub const BuildkiteAction = enum(c_int) {
    list_pipelines = 0,
    get_pipeline = 1,
    list_builds = 2,
    get_build = 3,
    create_build = 4,
    cancel_build = 5,
    list_jobs = 6,
    get_job_log = 7,
    list_artifacts = 8,
    list_agents = 9,
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
    build_ops: u32 = 0,
    agent_ops: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

pub export fn buildkite_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn buildkite_mcp_authenticate(dummy: c_int) c_int {
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
            slot.build_ops = 0;
            slot.agent_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn buildkite_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn buildkite_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn buildkite_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn buildkite_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn buildkite_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn buildkite_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(BuildkiteAction, action) catch return -3;

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
        .list_pipelines, .get_pipeline => sessions[idx].pipeline_ops += 1,
        .list_builds, .get_build, .create_build, .cancel_build, .list_jobs, .get_job_log, .list_artifacts => sessions[idx].build_ops += 1,
        .list_agents => sessions[idx].agent_ops += 1,
    }

    return 0;
}

pub export fn buildkite_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].api_call_count);
}

pub export fn buildkite_mcp_pipeline_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].pipeline_ops);
}

pub export fn buildkite_mcp_build_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].build_ops);
}

pub export fn buildkite_mcp_agent_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    if (!sessions[idx].active) return -1;
    return @intCast(sessions[idx].agent_ops);
}

pub export fn buildkite_mcp_action_count() c_int {
    return 10;
}

pub export fn buildkite_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "buildkite-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "buildkite_list_pipelines"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_get_pipeline"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_list_builds"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_get_build"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_create_build"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_cancel_build"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_list_jobs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_get_job_log"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_list_artifacts"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "buildkite_list_agents"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "authenticated session lifecycle" {
    buildkite_mcp_reset();
    const slot = buildkite_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_pipeline_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_close(slot));
}

test "rate limiting flow" {
    buildkite_mcp_reset();
    const slot = buildkite_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), buildkite_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_session_state(slot));
}

test "category counting" {
    buildkite_mcp_reset();
    const slot = buildkite_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_record_call(slot, 2));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_record_call(slot, 9));
    try std.testing.expectEqual(@as(c_int, 3), buildkite_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_pipeline_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_build_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_agent_op_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), buildkite_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    buildkite_mcp_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = buildkite_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), buildkite_mcp_authenticate(0));
    try std.testing.expectEqual(@as(c_int, 0), buildkite_mcp_close(slots[0]));
    try std.testing.expect(buildkite_mcp_authenticate(0) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns buildkite-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("buildkite-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "buildkite_list_pipelines",
        "buildkite_get_pipeline",
        "buildkite_list_builds",
        "buildkite_get_build",
        "buildkite_create_build",
        "buildkite_cancel_build",
        "buildkite_list_jobs",
        "buildkite_get_job_log",
        "buildkite_list_artifacts",
        "buildkite_list_agents",
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
    const rc = boj_cartridge_invoke("buildkite_list_pipelines", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
