// SPDX-License-Identifier: PMPL-1.0-or-later
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
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    sessions[@intCast(idx)].active = false;
    return 0;
}

/// Attempt a state transition. Returns 0 on success, -1 invalid, -2 not found.
pub export fn agent_transition(idx: c_int, to: c_int) c_int {
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
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    const i: usize = @intCast(idx);
    if (!sessions[i].active) return -1;
    return @intFromEnum(sessions[i].state);
}

/// Get loop count for a session.
pub export fn agent_loop_count(idx: c_int) c_int {
    if (idx < 0 or idx >= MAX_SESSIONS) return -1;
    const i: usize = @intCast(idx);
    if (!sessions[i].active) return -1;
    return @intCast(sessions[i].loop_count);
}

/// Validate a transition without executing it (C-ABI export).
pub export fn agent_validate_ooda(from: c_int, to: c_int) c_int {
    const f: AgentState = @enumFromInt(from);
    const t: AgentState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Get next standard state in the OODA sequence.
pub export fn agent_next_state(current: c_int) c_int {
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
    return "agent-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
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
