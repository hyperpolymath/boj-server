// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Secrets-MCP Cartridge — Zig FFI bridge for secret management operations.
//
// Implements the vault seal/unseal state machine from SafeSecrets.idr.
// Ensures no secret can be read from a sealed vault, authentication
// is required before access, and all accesses are counted for audit.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match SecretsMcp.SafeSecrets encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const VaultState = enum(c_int) {
    sealed = 0,
    unsealed = 1,
    authenticated = 2,
    accessing = 3,
    secret_error = 4,
};

pub const SecretBackend = enum(c_int) {
    vault = 1,
    sops = 2,
    env_vault = 3,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Vault State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_VAULTS: usize = 4;

const VaultSlot = struct {
    active: bool,
    state: VaultState,
    backend: SecretBackend,
    access_count: u64,
};

var vaults: [MAX_VAULTS]VaultSlot = [_]VaultSlot{.{
    .active = false,
    .state = .sealed,
    .backend = .vault,
    .access_count = 0,
}} ** MAX_VAULTS;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: VaultState, to: VaultState) bool {
    return switch (from) {
        .sealed => to == .unsealed,
        .unsealed => to == .authenticated or to == .sealed,
        .authenticated => to == .accessing or to == .unsealed,
        .accessing => to == .authenticated or to == .secret_error,
        .secret_error => to == .authenticated,
    };
}

/// Unseal a vault. Returns slot index or -1 on failure.
pub export fn sec_unseal(backend: c_int) c_int {
    for (&vaults, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unsealed;
            slot.backend = @enumFromInt(backend);
            slot.access_count = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Authenticate with an unsealed vault (transition Unsealed -> Authenticated).
pub export fn sec_authenticate(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return -1;
    if (!isValidTransition(vaults[idx].state, .authenticated)) return -2;

    vaults[idx].state = .authenticated;
    return 0;
}

/// Begin a secret access (transition Authenticated -> Accessing).
pub export fn sec_begin_access(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return -1;
    if (!isValidTransition(vaults[idx].state, .accessing)) return -2;

    vaults[idx].state = .accessing;
    return 0;
}

/// End a secret access (transition Accessing -> Authenticated).
/// Increments the audit access count.
pub export fn sec_end_access(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return -1;
    if (!isValidTransition(vaults[idx].state, .authenticated)) return -2;

    vaults[idx].state = .authenticated;
    vaults[idx].access_count += 1;
    return 0;
}

/// Seal the vault (transition Unsealed -> Sealed).
pub export fn sec_seal(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return -1;
    if (!isValidTransition(vaults[idx].state, .sealed)) return -2;

    vaults[idx].active = false;
    vaults[idx].state = .sealed;
    vaults[idx].access_count = 0;
    return 0;
}

/// Get the state of a vault.
pub export fn sec_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return @intFromEnum(VaultState.sealed);
    return @intFromEnum(vaults[idx].state);
}

/// Get the access count for audit purposes.
pub export fn sec_access_count(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_VAULTS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!vaults[idx].active) return 0;
    return @intCast(vaults[idx].access_count);
}

/// Validate a state transition (C-ABI export).
pub export fn sec_can_transition(from: c_int, to: c_int) c_int {
    const f: VaultState = @enumFromInt(from);
    const t: VaultState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all vaults (for testing).
pub export fn sec_reset() void {
    for (&vaults) |*slot| {
        slot.active = false;
        slot.state = .sealed;
        slot.access_count = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the secrets-mcp cartridge. Resets all vault slots.
pub export fn boj_cartridge_init() c_int {
    sec_reset();
    return 0;
}

/// Deinitialise the secrets-mcp cartridge. Resets all vault slots.
pub export fn boj_cartridge_deinit() void {
    sec_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "secrets-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "unseal and seal" {
    sec_reset();
    const slot = sec_unseal(@intFromEnum(SecretBackend.vault));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(VaultState.unsealed)), sec_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), sec_seal(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(VaultState.sealed)), sec_state(slot));
}

test "cannot read from sealed vault" {
    sec_reset();
    // No vault unsealed — begin_access on slot 0 should fail
    try std.testing.expectEqual(@as(c_int, -1), sec_begin_access(0));
}

test "cannot access without authentication" {
    sec_reset();
    const slot = sec_unseal(@intFromEnum(SecretBackend.sops));
    // Unsealed but not authenticated — should fail
    try std.testing.expectEqual(@as(c_int, -2), sec_begin_access(slot));
    _ = sec_seal(slot);
}

test "full access lifecycle with audit count" {
    sec_reset();
    const slot = sec_unseal(@intFromEnum(SecretBackend.vault));
    try std.testing.expectEqual(@as(c_int, 0), sec_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, 0), sec_access_count(slot));

    // First access
    try std.testing.expectEqual(@as(c_int, 0), sec_begin_access(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(VaultState.accessing)), sec_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), sec_end_access(slot));
    try std.testing.expectEqual(@as(c_int, 1), sec_access_count(slot));

    // Second access
    try std.testing.expectEqual(@as(c_int, 0), sec_begin_access(slot));
    try std.testing.expectEqual(@as(c_int, 0), sec_end_access(slot));
    try std.testing.expectEqual(@as(c_int, 2), sec_access_count(slot));
}

test "cannot seal while authenticated" {
    sec_reset();
    const slot = sec_unseal(@intFromEnum(SecretBackend.env_vault));
    _ = sec_authenticate(slot);
    // Must deauth (go to unsealed) before sealing
    try std.testing.expectEqual(@as(c_int, -2), sec_seal(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(0, 1)); // sealed -> unsealed
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(1, 2)); // unsealed -> authenticated
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(2, 3)); // authenticated -> accessing
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(3, 2)); // accessing -> authenticated
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(2, 1)); // authenticated -> unsealed
    try std.testing.expectEqual(@as(c_int, 1), sec_can_transition(1, 0)); // unsealed -> sealed
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), sec_can_transition(0, 2)); // sealed -> authenticated
    try std.testing.expectEqual(@as(c_int, 0), sec_can_transition(0, 3)); // sealed -> accessing
    try std.testing.expectEqual(@as(c_int, 0), sec_can_transition(3, 0)); // accessing -> sealed
}
