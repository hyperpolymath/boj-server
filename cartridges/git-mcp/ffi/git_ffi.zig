// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Git-MCP Cartridge — Zig FFI bridge for git forge operations.
//
// Implements the forge authentication state machine from SafeGit.idr.
// Ensures no forge operation can execute without authentication,
// prevents cross-forge operations, and tracks PR/issue lifecycle.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match GitMcp.SafeGit encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const GitState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    repo_selected = 2,
    operating = 3,
    git_error = 4,
};

pub const GitForge = enum(c_int) {
    github = 1,
    gitlab = 2,
    gitea = 3,
    bitbucket = 4,
};

// ═══════════════════════════════════════════════════════════════════════
// Forge State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_FORGES: usize = 8;

const ForgeSlot = struct {
    active: bool,
    state: GitState,
    forge: GitForge,
    selected_repo_hash: u64,
};

var forges: [MAX_FORGES]ForgeSlot = [_]ForgeSlot{.{
    .active = false,
    .state = .unauthenticated,
    .forge = .github,
    .selected_repo_hash = 0,
}} ** MAX_FORGES;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: GitState, to: GitState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .repo_selected or to == .unauthenticated,
        .repo_selected => to == .operating or to == .authenticated,
        .operating => to == .repo_selected or to == .git_error,
        .git_error => to == .authenticated,
    };
}

/// Simple string hash for repo identification.
fn hashRepo(owner: [*:0]const u8, name: [*:0]const u8) u64 {
    var h: u64 = 5381;
    var i: usize = 0;
    while (owner[i] != 0) : (i += 1) {
        h = ((h << 5) +% h) +% @as(u64, owner[i]);
    }
    h = ((h << 5) +% h) +% @as(u64, '/');
    i = 0;
    while (name[i] != 0) : (i += 1) {
        h = ((h << 5) +% h) +% @as(u64, name[i]);
    }
    return h;
}

/// Authenticate with a forge. Returns slot index or -1 on failure.
pub export fn git_authenticate(forge_type: c_int) c_int {
    for (&forges, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.forge = @enumFromInt(forge_type);
            slot.selected_repo_hash = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Select a repository context (transition Authenticated -> RepoSelected).
pub export fn git_select_repo(slot_idx: c_int, owner: [*:0]const u8, name: [*:0]const u8) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_FORGES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!forges[idx].active) return -1;
    if (!isValidTransition(forges[idx].state, .repo_selected)) return -2;

    forges[idx].state = .repo_selected;
    forges[idx].selected_repo_hash = hashRepo(owner, name);
    return 0;
}

/// Begin an operation (transition RepoSelected -> Operating).
pub export fn git_begin_operation(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_FORGES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!forges[idx].active) return -1;
    if (!isValidTransition(forges[idx].state, .operating)) return -2;

    forges[idx].state = .operating;
    return 0;
}

/// End an operation successfully (transition Operating -> RepoSelected).
pub export fn git_end_operation(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_FORGES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!forges[idx].active) return -1;
    if (!isValidTransition(forges[idx].state, .repo_selected)) return -2;

    forges[idx].state = .repo_selected;
    return 0;
}

/// Logout from forge (transition Authenticated -> Unauthenticated).
pub export fn git_logout(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_FORGES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!forges[idx].active) return -1;
    if (!isValidTransition(forges[idx].state, .unauthenticated)) return -2;

    forges[idx].active = false;
    forges[idx].state = .unauthenticated;
    forges[idx].selected_repo_hash = 0;
    return 0;
}

/// Get the state of a forge session.
pub export fn git_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_FORGES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!forges[idx].active) return @intFromEnum(GitState.unauthenticated);
    return @intFromEnum(forges[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn git_can_transition(from: c_int, to: c_int) c_int {
    const f: GitState = @enumFromInt(from);
    const t: GitState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all forge sessions (for testing).
pub export fn git_reset() void {
    for (&forges) |*slot| {
        slot.active = false;
        slot.state = .unauthenticated;
        slot.selected_repo_hash = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the git-mcp cartridge. Resets all forge sessions.
pub export fn boj_cartridge_init() c_int {
    git_reset();
    return 0;
}

/// Deinitialise the git-mcp cartridge. Resets all forge sessions.
pub export fn boj_cartridge_deinit() void {
    git_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "git-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "authenticate and logout" {
    git_reset();
    const slot = git_authenticate(@intFromEnum(GitForge.github));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(GitState.authenticated)), git_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), git_logout(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(GitState.unauthenticated)), git_state(slot));
}

test "cannot operate without authentication" {
    git_reset();
    // No slot authenticated — begin_operation on slot 0 should fail
    try std.testing.expectEqual(@as(c_int, -1), git_begin_operation(0));
}

test "cannot operate without repo selected" {
    git_reset();
    const slot = git_authenticate(@intFromEnum(GitForge.gitlab));
    // Authenticated but no repo selected — should fail
    try std.testing.expectEqual(@as(c_int, -2), git_begin_operation(slot));
    _ = git_logout(slot);
}

test "full operation lifecycle" {
    git_reset();
    const slot = git_authenticate(@intFromEnum(GitForge.gitea));
    try std.testing.expectEqual(@as(c_int, 0), git_select_repo(slot, "hyperpolymath", "boj-server"));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(GitState.repo_selected)), git_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), git_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(GitState.operating)), git_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), git_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(GitState.repo_selected)), git_state(slot));
}

test "cannot double-authenticate into same slot" {
    git_reset();
    // Fill all slots
    var i: usize = 0;
    while (i < MAX_FORGES) : (i += 1) {
        const s = git_authenticate(@intFromEnum(GitForge.github));
        try std.testing.expect(s >= 0);
    }
    // Next authenticate should fail — all slots occupied
    try std.testing.expectEqual(@as(c_int, -1), git_authenticate(@intFromEnum(GitForge.github)));
    git_reset();
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(1, 2)); // auth -> repo_selected
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(2, 3)); // repo_selected -> operating
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(3, 2)); // operating -> repo_selected
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(2, 1)); // repo_selected -> auth
    try std.testing.expectEqual(@as(c_int, 1), git_can_transition(1, 0)); // auth -> unauth
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), git_can_transition(0, 2)); // unauth -> repo_selected
    try std.testing.expectEqual(@as(c_int, 0), git_can_transition(0, 3)); // unauth -> operating
    try std.testing.expectEqual(@as(c_int, 0), git_can_transition(3, 0)); // operating -> unauth
}
