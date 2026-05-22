// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// DAP-MCP Cartridge — Zig FFI bridge for Debug Adapter Protocol management.
//
// Implements the DAP session lifecycle from SafeDap.idr with breakpoint
// management and step-control state tracking.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match DapMcp.SafeDap encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const DapState = enum(c_int) {
    not_started = 0,
    launched = 1,
    configured = 2,
    running = 3,
    stopped = 4,
    terminated = 5,
    disconnected = 6,
};

pub const BreakpointKind = enum(c_int) {
    source = 1,
    function = 2,
    data = 3,
    instruction = 4,
    exception = 5,
};

pub const StopReason = enum(c_int) {
    breakpoint = 1,
    step = 2,
    exception = 3,
    pause = 4,
    entry = 5,
    goto_target = 6,
};

pub const StepGranularity = enum(c_int) {
    statement = 1,
    line = 2,
    instruction = 3,
};

// ═══════════════════════════════════════════════════════════════════════
// DAP Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;
const MAX_BREAKPOINTS: usize = 32;

const Breakpoint = struct {
    active: bool = false,
    kind: BreakpointKind = .source,
    verified: bool = false,
};

const SessionSlot = struct {
    active: bool = false,
    state: DapState = .not_started,
    stop_reason: StopReason = .breakpoint,
    breakpoints: [MAX_BREAKPOINTS]Breakpoint = [_]Breakpoint{.{}} ** MAX_BREAKPOINTS,
    breakpoint_count: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: DapState, to: DapState) bool {
    return switch (from) {
        .not_started => to == .launched,
        .launched => to == .configured or to == .disconnected,
        .configured => to == .running,
        .running => to == .stopped or to == .terminated or to == .disconnected,
        .stopped => to == .running or to == .terminated,
        .terminated => to == .disconnected,
        .disconnected => false,
    };
}

/// Initialise a new DAP session. Returns slot index or -1 on failure.
pub export fn dap_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.* = SessionSlot{};
            slot.active = true;
            return @intCast(i);
        }
    }
    return -1;
}

/// Launch the debug adapter (NotStarted -> Launched).
pub export fn dap_launch(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .launched)) return -2;
    sessions[idx].state = .launched;
    return 0;
}

/// Send ConfigurationDone (Launched -> Configured).
pub export fn dap_configure(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .configured)) return -2;
    sessions[idx].state = .configured;
    return 0;
}

/// Start execution (Configured -> Running or Stopped -> Running for continue/step).
pub export fn dap_continue(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .running)) return -2;
    sessions[idx].state = .running;
    return 0;
}

/// Target stopped (Running -> Stopped).
pub export fn dap_stopped(slot_idx: c_int, reason: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .stopped)) return -2;
    sessions[idx].state = .stopped;
    sessions[idx].stop_reason = @enumFromInt(reason);
    return 0;
}

/// Target terminated (Running/Stopped -> Terminated).
pub export fn dap_terminate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .terminated)) return -2;
    sessions[idx].state = .terminated;
    return 0;
}

/// Disconnect adapter.
pub export fn dap_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .disconnected)) return -2;
    sessions[idx].state = .disconnected;
    return 0;
}

/// Get the state of a session.
pub export fn dap_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(DapState.not_started);
    return @intFromEnum(sessions[idx].state);
}

/// Can we inspect variables/stack? (only in stopped state)
pub export fn dap_can_inspect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    return if (sessions[idx].active and sessions[idx].state == .stopped) 1 else 0;
}

/// Can we set breakpoints? (in launched, configured, or stopped states)
pub export fn dap_can_set_breakpoints(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return 0;
    return switch (sessions[idx].state) {
        .launched, .configured, .stopped => 1,
        else => 0,
    };
}

/// Add a breakpoint. Returns breakpoint index or -1 on failure.
pub export fn dap_add_breakpoint(slot_idx: c_int, kind: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    // Inline breakpoint check to avoid deadlock (dap_can_set_breakpoints also locks)
    const can_set = switch (sessions[idx].state) {
        .launched, .configured, .stopped => true,
        else => false,
    };
    if (!can_set) return -2;
    if (sessions[idx].breakpoint_count >= MAX_BREAKPOINTS) return -3;

    for (&sessions[idx].breakpoints, 0..) |*bp, bi| {
        if (!bp.active) {
            bp.active = true;
            bp.kind = @enumFromInt(kind);
            bp.verified = true;
            sessions[idx].breakpoint_count += 1;
            return @intCast(bi);
        }
    }
    return -1;
}

/// Validate a state transition (C-ABI export).
pub export fn dap_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: DapState = @enumFromInt(from);
    const t: DapState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Release a session slot.
pub export fn dap_release(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    sessions[idx] = SessionSlot{};
    return 0;
}

/// Reset all sessions.
pub export fn dap_reset_all() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.* = SessionSlot{};
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface
// ═══════════════════════════════════════════════════════════════════════

pub export fn boj_cartridge_init() c_int {
    dap_reset_all();
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    dap_reset_all();
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "dap-mcp";
}

pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "dap_start"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_initialize"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_launch"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_attach"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_set_breakpoints"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_continue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_step_over"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_step_in"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_step_out"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_stack_trace"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_variables"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dap_stop"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and release DAP session" {
    dap_reset_all();
    const slot = dap_init();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(DapState.not_started)), dap_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), dap_release(slot));
}

test "full DAP debug lifecycle" {
    dap_reset_all();
    const slot = dap_init();
    try std.testing.expectEqual(@as(c_int, 0), dap_launch(slot));
    // Set a breakpoint while launched
    try std.testing.expect(dap_add_breakpoint(slot, @intFromEnum(BreakpointKind.source)) >= 0);
    try std.testing.expectEqual(@as(c_int, 0), dap_configure(slot));
    try std.testing.expectEqual(@as(c_int, 0), dap_continue(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(DapState.running)), dap_state(slot));
    // Hit breakpoint
    try std.testing.expectEqual(@as(c_int, 0), dap_stopped(slot, @intFromEnum(StopReason.breakpoint)));
    try std.testing.expectEqual(@as(c_int, 1), dap_can_inspect(slot));
    // Continue
    try std.testing.expectEqual(@as(c_int, 0), dap_continue(slot));
    try std.testing.expectEqual(@as(c_int, 0), dap_can_inspect(slot));
    // Terminate
    try std.testing.expectEqual(@as(c_int, 0), dap_terminate(slot));
    try std.testing.expectEqual(@as(c_int, 0), dap_disconnect(slot));
}

test "cannot inspect while running" {
    dap_reset_all();
    const slot = dap_init();
    _ = dap_launch(slot);
    _ = dap_configure(slot);
    _ = dap_continue(slot);
    try std.testing.expectEqual(@as(c_int, 0), dap_can_inspect(slot));
}

test "DAP state transitions" {
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(0, 1)); // not_started -> launched
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(1, 2)); // launched -> configured
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(2, 3)); // configured -> running
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(3, 4)); // running -> stopped
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(4, 3)); // stopped -> running
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(3, 5)); // running -> terminated
    try std.testing.expectEqual(@as(c_int, 1), dap_can_transition(5, 6)); // terminated -> disconnected
    try std.testing.expectEqual(@as(c_int, 0), dap_can_transition(0, 3)); // not_started -> running (invalid)
    try std.testing.expectEqual(@as(c_int, 0), dap_can_transition(6, 0)); // disconnected -> not_started (invalid)
}

test "breakpoint management" {
    dap_reset_all();
    const slot = dap_init();
    // Can't set breakpoints before launch
    try std.testing.expectEqual(@as(c_int, 0), dap_can_set_breakpoints(slot));
    _ = dap_launch(slot);
    try std.testing.expectEqual(@as(c_int, 1), dap_can_set_breakpoints(slot));
    const bp = dap_add_breakpoint(slot, @intFromEnum(BreakpointKind.function));
    try std.testing.expect(bp >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "dap_start",
        "dap_initialize",
        "dap_launch",
        "dap_attach",
        "dap_set_breakpoints",
        "dap_continue",
        "dap_step_over",
        "dap_step_in",
        "dap_step_out",
        "dap_stack_trace",
        "dap_variables",
        "dap_stop",
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
    const rc = boj_cartridge_invoke("dap_start", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
