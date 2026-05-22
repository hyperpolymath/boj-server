// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — Zig FFI bridge for OODA loop enforcement.
//
// Ensures agents follow Observe → Orient → Decide → Act and cannot
// skip steps. Emergency halt from any state, resume to Observe.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match AgentMcp.SafeOODA encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const AgentState = enum(c_int) {
    observe = 1,
    orient = 2,
    decide = 3,
    act = 4,
    halted = 5,
};

// ═══════════════════════════════════════════════════════════════════════
// Session Management
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 32;

const Session = struct {
    active: bool,
    state: AgentState,
    loop_count: u32,
    was_halted: bool,
};

var sessions: [MAX_SESSIONS]Session = [_]Session{.{
    .active = false,
    .state = .observe,
    .loop_count = 0,
    .was_halted = false,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition.
fn isValidTransition(from: AgentState, to: AgentState) bool {
    return switch (from) {
        .observe => to == .orient or to == .halted,
        .orient => to == .decide or to == .halted,
        .decide => to == .act or to == .halted,
        .act => to == .observe or to == .halted,
        .halted => to == .observe,
    };
}

/// Create a new agent session. Returns session index or -1.
pub export fn agent_new_session() c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*s, i| {
        if (!s.active) {
            s.active = true;
            s.state = .observe;
            s.loop_count = 0;
            s.was_halted = false;
            return @intCast(i);
        }
    }
    return -1;
}

/// End a session.
pub export fn agent_end_session(idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    sessions[@intCast(idx)].active = false;
    return 0;
}

/// Attempt a state transition. Returns 0 on success, -1 invalid, -2 not found.
pub export fn agent_transition(idx: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (idx < 0 or idx >= MAX_SESSIONS) return -2;
    const i: usize = @intCast(idx);
    if (!sessions[i].active) return -2;

    const target: AgentState = @enumFromInt(to);
    if (!isValidTransition(sessions[i].state, target)) return -1;

    // Track loop completion (Act -> Observe)
    if (sessions[i].state == .act and target == .observe) {
        sessions[i].loop_count += 1;
    }
    if (target == .halted) {
        sessions[i].was_halted = true;
    }

    sessions[i].state = target;
    return 0;
}

/// Get current state of a session.
pub export fn agent_state(idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    const i: usize = @intCast(idx);
    if (!sessions[i].active) return -1;
    return @intFromEnum(sessions[i].state);
}

/// Get loop count for a session.
pub export fn agent_loop_count(idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    const i: usize = @intCast(idx);
    if (!sessions[i].active) return -1;
    return @intCast(sessions[i].loop_count);
}

/// Validate a transition without executing it (C-ABI export).
pub export fn agent_validate_ooda(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: AgentState = @enumFromInt(from);
    const t: AgentState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Get next standard state in the OODA sequence.
pub export fn agent_next_state(current: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const s: AgentState = @enumFromInt(current);
    return @intFromEnum(switch (s) {
        .observe => AgentState.orient,
        .orient => AgentState.decide,
        .decide => AgentState.act,
        .act => AgentState.observe,
        .halted => AgentState.observe, // resume
    });
}

/// Reset all sessions (for testing).
pub export fn agent_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*s| {
        s.active = false;
        s.state = .observe;
        s.loop_count = 0;
        s.was_halted = false;
    }
}


// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the agent-mcp cartridge. Resets all sessions.
pub export fn boj_cartridge_init() c_int {
    agent_reset();
    return 0;
}

/// Deinitialise the agent-mcp cartridge. Resets all sessions.
pub export fn boj_cartridge_deinit() void {
    agent_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "agent-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.2.0";
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

    const body: []const u8 = if (shim.toolIs(tool_name, "agent_new_session"))
        "{\"result\":{\"session_id\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_end_session"))
        "{\"result\":{\"ended\":true,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_transition"))
        "{\"result\":{\"transitioned\":true,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_state"))
        "{\"result\":{\"state\":\"unknown\",\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_loop_count"))
        "{\"result\":{\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_validate_ooda"))
        "{\"result\":{\"valid\":true,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "agent_reset"))
        "{\"result\":{\"reset\":true,\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Protocol Types (from proven-agentic, added in v0.2.0)
// ═══════════════════════════════════════════════════════════════════════

pub const ToolCall = enum(c_int) {
    execute = 0,
    query = 1,
    transform = 2,
    communicate = 3,
    delegate = 4,
    escalate = 5,
};

pub const PlanStep = enum(c_int) {
    action = 0,
    condition = 1,
    loop = 2,
    branch = 3,
    parallel = 4,
    checkpoint = 5,
    rollback = 6,
};

pub const Coordination = enum(c_int) {
    solo = 0,
    collaborative = 1,
    competitive = 2,
    hierarchical = 3,
    swarm = 4,
    consensus = 5,
};

pub const SafetyCheck = enum(c_int) {
    approved = 0,
    denied = 1,
    escalated = 2,
    timeout = 3,
    sandboxed = 4,
    human_required = 5,
};

pub const MemoryType = enum(c_int) {
    working = 0,
    episodic = 1,
    semantic = 2,
    procedural = 3,
    shared = 4,
};

/// Whether a tool call has side effects.
pub export fn agent_tool_has_side_effects(tc: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const t: ToolCall = @enumFromInt(tc);
    return switch (t) {
        .execute, .communicate, .delegate, .escalate => 1,
        .query, .transform => 0,
    };
}

/// Whether a tool call requires a safety pre-check.
pub export fn agent_tool_requires_safety(tc: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const t: ToolCall = @enumFromInt(tc);
    return switch (t) {
        .execute, .delegate, .escalate => 1,
        else => 0,
    };
}

/// Whether a safety check outcome allows execution.
pub export fn agent_safety_allows_exec(sc: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const s: SafetyCheck = @enumFromInt(sc);
    return switch (s) {
        .approved, .sandboxed => 1,
        else => 0,
    };
}

/// Whether a safety check needs human intervention.
pub export fn agent_safety_needs_human(sc: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const s: SafetyCheck = @enumFromInt(sc);
    return switch (s) {
        .escalated, .human_required => 1,
        else => 0,
    };
}

/// Whether a coordination strategy involves multiple agents.
pub export fn agent_coordination_is_multi(c: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const coord: Coordination = @enumFromInt(c);
    return if (coord != .solo) 1 else 0;
}

/// Whether a memory type persists across sessions.
pub export fn agent_memory_is_persistent(m: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const mem: MemoryType = @enumFromInt(m);
    return if (mem != .working) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "full OODA loop" {
    agent_reset();
    const s = agent_new_session();
    try std.testing.expect(s >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AgentState.observe)), agent_state(s));

    // Observe -> Orient -> Decide -> Act -> Observe
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 2)); // Orient
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 3)); // Decide
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 4)); // Act
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 1)); // Observe (new loop)

    try std.testing.expectEqual(@as(c_int, 1), agent_loop_count(s));
    _ = agent_end_session(s);
}

test "cannot skip Orient" {
    agent_reset();
    const s = agent_new_session();
    // Observe -> Decide should fail (must go through Orient)
    try std.testing.expectEqual(@as(c_int, -1), agent_transition(s, 3));
    // Observe -> Act should fail
    try std.testing.expectEqual(@as(c_int, -1), agent_transition(s, 4));
    // State should still be Observe
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AgentState.observe)), agent_state(s));
    _ = agent_end_session(s);
}

test "emergency halt from any state" {
    agent_reset();
    const s = agent_new_session();
    // Halt from Observe
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 5));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AgentState.halted)), agent_state(s));
    // Resume to Observe
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AgentState.observe)), agent_state(s));
    _ = agent_end_session(s);
}

test "halt from Orient" {
    agent_reset();
    const s = agent_new_session();
    _ = agent_transition(s, 2); // Orient
    try std.testing.expectEqual(@as(c_int, 0), agent_transition(s, 5)); // Halt
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AgentState.halted)), agent_state(s));
    _ = agent_end_session(s);
}

test "cannot go backwards" {
    agent_reset();
    const s = agent_new_session();
    _ = agent_transition(s, 2); // Orient
    _ = agent_transition(s, 3); // Decide
    // Cannot go back to Orient
    try std.testing.expectEqual(@as(c_int, -1), agent_transition(s, 2));
    // Cannot go back to Observe
    try std.testing.expectEqual(@as(c_int, -1), agent_transition(s, 1));
    _ = agent_end_session(s);
}

test "next state sequence" {
    try std.testing.expectEqual(@as(c_int, 2), agent_next_state(1)); // Observe -> Orient
    try std.testing.expectEqual(@as(c_int, 3), agent_next_state(2)); // Orient -> Decide
    try std.testing.expectEqual(@as(c_int, 4), agent_next_state(3)); // Decide -> Act
    try std.testing.expectEqual(@as(c_int, 1), agent_next_state(4)); // Act -> Observe
    try std.testing.expectEqual(@as(c_int, 1), agent_next_state(5)); // Halted -> Observe
}

// Protocol tests (v0.2.0)

test "tool call side effects" {
    try std.testing.expectEqual(@as(c_int, 1), agent_tool_has_side_effects(0)); // execute
    try std.testing.expectEqual(@as(c_int, 0), agent_tool_has_side_effects(1)); // query
    try std.testing.expectEqual(@as(c_int, 0), agent_tool_has_side_effects(2)); // transform
    try std.testing.expectEqual(@as(c_int, 1), agent_tool_has_side_effects(4)); // delegate
}

test "safety check permissions" {
    try std.testing.expectEqual(@as(c_int, 1), agent_safety_allows_exec(0)); // approved
    try std.testing.expectEqual(@as(c_int, 0), agent_safety_allows_exec(1)); // denied
    try std.testing.expectEqual(@as(c_int, 1), agent_safety_allows_exec(4)); // sandboxed
    try std.testing.expectEqual(@as(c_int, 0), agent_safety_allows_exec(5)); // human_required
    try std.testing.expectEqual(@as(c_int, 1), agent_safety_needs_human(5)); // human_required
    try std.testing.expectEqual(@as(c_int, 0), agent_safety_needs_human(0)); // approved
}

test "coordination multi-agent" {
    try std.testing.expectEqual(@as(c_int, 0), agent_coordination_is_multi(0)); // solo
    try std.testing.expectEqual(@as(c_int, 1), agent_coordination_is_multi(1)); // collaborative
    try std.testing.expectEqual(@as(c_int, 1), agent_coordination_is_multi(4)); // swarm
}

test "validation matches transitions" {
    // Valid
    try std.testing.expectEqual(@as(c_int, 1), agent_validate_ooda(1, 2)); // Obs -> Ori
    try std.testing.expectEqual(@as(c_int, 1), agent_validate_ooda(2, 3)); // Ori -> Dec
    try std.testing.expectEqual(@as(c_int, 1), agent_validate_ooda(3, 4)); // Dec -> Act
    try std.testing.expectEqual(@as(c_int, 1), agent_validate_ooda(4, 1)); // Act -> Obs
    try std.testing.expectEqual(@as(c_int, 1), agent_validate_ooda(1, 5)); // Obs -> Halt
    // Invalid
    try std.testing.expectEqual(@as(c_int, 0), agent_validate_ooda(1, 3)); // Obs -> Dec
    try std.testing.expectEqual(@as(c_int, 0), agent_validate_ooda(1, 4)); // Obs -> Act
    try std.testing.expectEqual(@as(c_int, 0), agent_validate_ooda(3, 1)); // Dec -> Obs
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "agent_new_session", "agent_end_session",  "agent_transition",
        "agent_state",       "agent_loop_count",   "agent_validate_ooda",
        "agent_reset",
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
    const rc = boj_cartridge_invoke("agent_new_session", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
