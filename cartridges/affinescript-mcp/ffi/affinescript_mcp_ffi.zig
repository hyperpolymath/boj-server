// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// affinescript_mcp_ffi.zig — C-ABI FFI implementation for affinescript-mcp cartridge.
//
// Implements the state machine defined in AffinescriptMcp.SafeCompiler (Idris2 ABI).
// State machine: Ready | Busy | Error (local compiler, no auth)
// Actions: Check, Parse, Format, ExplainError, StdlibSearch, SyntaxRef, EvalSnippet
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session lifecycle state.
/// 0 = Ready, 1 = Busy, 2 = Error.
pub const SessionState = enum(c_int) {
    ready = 0,
    busy = 1,
    err = 2,
};

/// Compiler action identifiers matching Idris2 CompilerAction encoding.
pub const CompilerAction = enum(c_int) {
    check = 0,
    parse = 1,
    format = 2,
    explain_error = 3,
    stdlib_search = 4,
    syntax_ref = 5,
    eval_snippet = 6,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .ready => to == .busy,
        .busy => to == .ready or to == .err,
        .err => to == .ready,
    };
}

/// Check if an action requires the compiler subprocess.
fn actionNeedsCompiler(action: CompilerAction) bool {
    return switch (action) {
        .check, .parse, .eval_snippet => true,
        .format, .explain_error, .stdlib_search, .syntax_ref => false,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .ready,
    invocation_count: u64 = 0,
    last_action: c_int = -1,
    check_count: u32 = 0,
    parse_count: u32 = 0,
    format_count: u32 = 0,
    eval_count: u32 = 0,
    lookup_count: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn afs_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a session. Returns slot index (>= 0) or error (< 0).
pub export fn afs_mcp_open(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .ready;
            slot.invocation_count = 0;
            slot.last_action = -1;
            slot.check_count = 0;
            slot.parse_count = 0;
            slot.format_count = 0;
            slot.eval_count = 0;
            slot.lookup_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success.
pub export fn afs_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn afs_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Mark session as busy (compiler invocation started). Returns 0 on success.
pub export fn afs_mcp_start_invocation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .busy)) return -2;

    sessions[idx].state = .busy;
    return 0;
}

/// Mark invocation as complete (success). Returns 0 on success.
pub export fn afs_mcp_finish_success(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .ready)) return -2;

    sessions[idx].state = .ready;
    return 0;
}

/// Signal a compiler error. Returns 0 on success.
pub export fn afs_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Recover from error state. Returns 0 on success.
pub export fn afs_mcp_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .ready)) return -2;

    sessions[idx].state = .ready;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — action recording and metrics
// ---------------------------------------------------------------------------

/// Record a compiler action. Returns 0 on success.
pub export fn afs_mcp_record_action(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(CompilerAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx].invocation_count += 1;
    sessions[idx].last_action = action;

    switch (act) {
        .check => sessions[idx].check_count += 1,
        .parse => sessions[idx].parse_count += 1,
        .format => sessions[idx].format_count += 1,
        .eval_snippet => sessions[idx].eval_count += 1,
        .explain_error, .stdlib_search, .syntax_ref => sessions[idx].lookup_count += 1,
    }

    return 0;
}

/// Get total invocation count for a session.
pub export fn afs_mcp_invocation_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.invocation_count);
}

/// Get check count.
pub export fn afs_mcp_check_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.check_count);
}

/// Get parse count.
pub export fn afs_mcp_parse_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.parse_count);
}

/// Get format count.
pub export fn afs_mcp_format_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.format_count);
}

/// Get total action count. Always returns 7.
pub export fn afs_mcp_action_count() c_int {
    return 7;
}

/// Reset all sessions (test/debug use only).
pub export fn afs_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    afs_mcp_reset();

    const slot = afs_mcp_open(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_record_action(slot, 0)); // Check
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_invocation_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_check_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_close(slot));
}

test "busy/ready transitions" {
    afs_mcp_reset();

    const slot = afs_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_start_invocation(slot));
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_session_state(slot)); // busy

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_finish_success(slot));
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_session_state(slot)); // ready
}

test "error and recovery" {
    afs_mcp_reset();

    const slot = afs_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_start_invocation(slot));
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 2), afs_mcp_session_state(slot)); // error

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_recover(slot));
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_session_state(slot)); // ready
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_can_transition(0, 1)); // Ready -> Busy
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_can_transition(1, 0)); // Busy -> Ready
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_can_transition(1, 2)); // Busy -> Error
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_can_transition(2, 0)); // Error -> Ready
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_can_transition(0, 2)); // Ready -> Error (invalid)
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_can_transition(2, 1)); // Error -> Busy (invalid)
}

test "action category counting" {
    afs_mcp_reset();

    const slot = afs_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_record_action(slot, 0)); // Check
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_record_action(slot, 1)); // Parse
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_record_action(slot, 2)); // Format
    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_record_action(slot, 6)); // EvalSnippet

    try std.testing.expectEqual(@as(c_int, 4), afs_mcp_invocation_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_check_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_parse_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), afs_mcp_format_count(slot));
}

test "slot exhaustion" {
    afs_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = afs_mcp_open(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), afs_mcp_open(0));

    try std.testing.expectEqual(@as(c_int, 0), afs_mcp_close(slots[0]));
    const new_slot = afs_mcp_open(0);
    try std.testing.expect(new_slot >= 0);
}
