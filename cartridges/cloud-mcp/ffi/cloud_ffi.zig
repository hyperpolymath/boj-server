// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Cloud-MCP Cartridge — Zig FFI bridge for multi-cloud provider operations.
//
// Implements the provider session state machine from SafeCloud.idr.
// Ensures no operation can execute on an unauthenticated provider,
// and tracks credential lifecycle to prevent leaks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match CloudMcp.SafeCloud encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    auth_error = 3,
};

pub const CloudProvider = enum(c_int) {
    aws = 1,
    gcloud = 2,
    azure = 3,
    digital_ocean = 4,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const SessionSlot = struct {
    active: bool,
    state: SessionState,
    provider: CloudProvider,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .unauthenticated,
    .provider = .aws,
}} ** MAX_SESSIONS;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .operating or to == .unauthenticated,
        .operating => to == .authenticated or to == .auth_error,
        .auth_error => to == .unauthenticated,
    };
}

/// Authenticate with a provider. Returns slot index or -1 on failure.
pub export fn cloud_authenticate(provider: c_int) c_int {
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.provider = @enumFromInt(provider);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Logout from a provider session by slot index.
pub export fn cloud_logout(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .unauthenticated)) return -2;

    sessions[idx].active = false;
    sessions[idx].state = .unauthenticated;
    return 0;
}

/// Begin an operation (transition Authenticated -> Operating).
pub export fn cloud_begin_operation(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .operating)) return -2;

    sessions[idx].state = .operating;
    return 0;
}

/// End an operation (transition Operating -> Authenticated).
pub export fn cloud_end_operation(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Get the state of a session.
pub export fn cloud_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(SessionState.unauthenticated);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn cloud_can_transition(from: c_int, to: c_int) c_int {
    const f: SessionState = @enumFromInt(from);
    const t: SessionState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn cloud_reset() void {
    for (&sessions) |*slot| {
        slot.active = false;
        slot.state = .unauthenticated;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the cloud-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    cloud_reset();
    return 0;
}

/// Deinitialise the cloud-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    cloud_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "cloud-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "authenticate and logout" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "cannot operate on unauthenticated" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.gcloud));
    _ = cloud_logout(slot);
    // Should fail — can't begin operation on unauthenticated session
    try std.testing.expectEqual(@as(c_int, -1), cloud_begin_operation(slot));
}

test "operation lifecycle" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.azure));
    try std.testing.expectEqual(@as(c_int, 0), cloud_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.operating)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "cannot double-logout" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.digital_ocean));
    _ = cloud_logout(slot);
    // Second logout should fail — already unauthenticated
    try std.testing.expectEqual(@as(c_int, -1), cloud_logout(slot));
}

test "cannot logout while operating" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    _ = cloud_begin_operation(slot);
    // Cannot logout directly from operating — must end operation first
    try std.testing.expectEqual(@as(c_int, -2), cloud_logout(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(1, 2)); // auth -> operating
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(2, 1)); // operating -> auth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(1, 0)); // auth -> unauth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(2, 3)); // operating -> error
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(3, 0)); // error -> unauth
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), cloud_can_transition(0, 2)); // unauth -> operating
    try std.testing.expectEqual(@as(c_int, 0), cloud_can_transition(2, 0)); // operating -> unauth
}

test "max sessions enforced" {
    cloud_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = cloud_authenticate(@intFromEnum(CloudProvider.aws));
        try std.testing.expect(s.* >= 0);
    }
    // Next authenticate should fail
    try std.testing.expectEqual(@as(c_int, -1), cloud_authenticate(@intFromEnum(CloudProvider.aws)));
    // Free one and retry
    _ = cloud_logout(slots[0]);
    try std.testing.expect(cloud_authenticate(@intFromEnum(CloudProvider.aws)) >= 0);
}
