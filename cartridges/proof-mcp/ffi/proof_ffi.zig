// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Proof-MCP Cartridge — Zig FFI bridge for formal proof verification.
//
// Implements the verification state machine from SafeProof.idr.
// Ensures no verification can run without a loaded proof obligation,
// and no result can be retrieved from an incomplete verification.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match ProofMcp.SafeProof encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const ProofState = enum(c_int) {
    idle = 0,
    loading = 1,
    verifying = 2,
    verified = 3,
    failed = 4,
};

pub const ProofBackend = enum(c_int) {
    z3 = 1,
    cvc5 = 2,
    lean = 3,
    coq = 4,
    agda = 5,
    isabelle = 6,
    idris2 = 7,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Proof Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const SessionSlot = struct {
    active: bool,
    state: ProofState,
    backend: ProofBackend,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .idle,
    .backend = .z3,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: ProofState, to: ProofState) bool {
    return switch (from) {
        .idle => to == .loading,
        .loading => to == .verifying or to == .idle,
        .verifying => to == .verified or to == .failed,
        .verified => to == .idle,
        .failed => to == .idle,
    };
}

/// Initialise a new proof session. Returns slot index or -1 on failure.
pub export fn proof_init(backend: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .idle;
            slot.backend = @enumFromInt(backend);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Load a proof obligation (transition Idle -> Loading).
pub export fn proof_load(slot_idx: c_int, backend: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .loading)) return -2;

    sessions[idx].state = .loading;
    sessions[idx].backend = @enumFromInt(backend);
    return 0;
}

/// Start verification (transition Loading -> Verifying).
pub export fn proof_verify(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .verifying)) return -2;

    sessions[idx].state = .verifying;
    return 0;
}

/// Mark verification as successful (transition Verifying -> Verified).
pub export fn proof_succeed(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .verified)) return -2;

    sessions[idx].state = .verified;
    return 0;
}

/// Mark verification as failed (transition Verifying -> Failed).
pub export fn proof_fail(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .failed)) return -2;

    sessions[idx].state = .failed;
    return 0;
}

/// Get the result of a completed verification. Returns state or -1 on error.
pub export fn proof_get_result(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    return @intFromEnum(sessions[idx].state);
}

/// Reset a session to idle (from Verified, Failed, or Loading).
pub export fn proof_reset(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .idle)) return -2;

    sessions[idx].state = .idle;
    return 0;
}

/// Get the state of a session.
pub export fn proof_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(ProofState.idle);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn proof_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: ProofState = @enumFromInt(from);
    const t: ProofState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Release a session slot entirely.
pub export fn proof_release(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;

    sessions[idx].active = false;
    sessions[idx].state = .idle;
    return 0;
}

/// Reset all sessions (for testing).
pub export fn proof_reset_all() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.active = false;
        slot.state = .idle;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the proof-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    proof_reset_all();
    return 0;
}

/// Deinitialise the proof-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    proof_reset_all();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "proof-mcp";
}

/// Return the cartridge version as a null-terminated C string.
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "proof_init_session"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_load_obligation"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_verify"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_get_result"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_get_state"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_reset_session"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_release_session"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "proof_can_transition"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and release session" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.z3));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.idle)), proof_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), proof_release(slot));
}

test "full verification lifecycle" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.lean));
    try std.testing.expectEqual(@as(c_int, 0), proof_load(slot, @intFromEnum(ProofBackend.lean)));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.loading)), proof_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), proof_verify(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.verifying)), proof_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), proof_succeed(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.verified)), proof_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), proof_reset(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.idle)), proof_state(slot));
}

test "cannot verify without loading" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.coq));
    // Should fail — can't verify from idle state
    try std.testing.expectEqual(@as(c_int, -2), proof_verify(slot));
}

test "cannot get result during verification" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.agda));
    _ = proof_load(slot, @intFromEnum(ProofBackend.agda));
    _ = proof_verify(slot);
    // State should be verifying (not verified or failed)
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.verifying)), proof_get_result(slot));
}

test "failed verification lifecycle" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.isabelle));
    _ = proof_load(slot, @intFromEnum(ProofBackend.isabelle));
    _ = proof_verify(slot);
    try std.testing.expectEqual(@as(c_int, 0), proof_fail(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.failed)), proof_state(slot));
    // Can reset from failed
    try std.testing.expectEqual(@as(c_int, 0), proof_reset(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.idle)), proof_state(slot));
}

test "cancel load returns to idle" {
    proof_reset_all();
    const slot = proof_init(@intFromEnum(ProofBackend.cvc5));
    _ = proof_load(slot, @intFromEnum(ProofBackend.cvc5));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.loading)), proof_state(slot));
    // Cancel load (Loading -> Idle)
    try std.testing.expectEqual(@as(c_int, 0), proof_reset(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ProofState.idle)), proof_state(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(0, 1)); // idle -> loading
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(1, 2)); // loading -> verifying
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(2, 3)); // verifying -> verified
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(2, 4)); // verifying -> failed
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(3, 0)); // verified -> idle
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(4, 0)); // failed -> idle
    try std.testing.expectEqual(@as(c_int, 1), proof_can_transition(1, 0)); // loading -> idle (cancel)
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), proof_can_transition(0, 2)); // idle -> verifying
    try std.testing.expectEqual(@as(c_int, 0), proof_can_transition(0, 3)); // idle -> verified
    try std.testing.expectEqual(@as(c_int, 0), proof_can_transition(3, 1)); // verified -> loading
}

test "max sessions enforced" {
    proof_reset_all();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = proof_init(@intFromEnum(ProofBackend.idris2));
        try std.testing.expect(s.* >= 0);
    }
    // Next init should fail
    try std.testing.expectEqual(@as(c_int, -1), proof_init(@intFromEnum(ProofBackend.idris2)));
    // Free one and retry
    _ = proof_release(slots[0]);
    try std.testing.expect(proof_init(@intFromEnum(ProofBackend.idris2)) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "proof_init_session",
        "proof_load_obligation",
        "proof_verify",
        "proof_get_result",
        "proof_get_state",
        "proof_reset_session",
        "proof_release_session",
        "proof_can_transition",
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
    const rc = boj_cartridge_invoke("proof_init_session", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
