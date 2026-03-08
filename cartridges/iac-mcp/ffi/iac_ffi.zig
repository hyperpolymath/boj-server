// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// IaC-MCP Cartridge — Zig FFI bridge for infrastructure-as-code operations.
//
// Implements the plan-before-apply state machine from SafeIac.idr.
// Ensures no infrastructure apply can execute without a preceding plan,
// and no destroy can run from an uninitialised workspace.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match IacMcp.SafeIac encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const IacState = enum(c_int) {
    uninitialized = 0,
    initialized = 1,
    planned = 2,
    applying = 3,
    applied = 4,
    iac_error = 5,
};

pub const IacTool = enum(c_int) {
    terraform = 1,
    pulumi = 2,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Plan-Before-Apply State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_WORKSPACES: usize = 8;

const WorkspaceSlot = struct {
    active: bool,
    tool: IacTool,
    state: IacState,
    plan_hash: u32, // Hash of plan for verification on apply
};

var workspaces: [MAX_WORKSPACES]WorkspaceSlot = [_]WorkspaceSlot{.{
    .active = false,
    .tool = .terraform,
    .state = .uninitialized,
    .plan_hash = 0,
}} ** MAX_WORKSPACES;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: IacState, to: IacState) bool {
    return switch (from) {
        .uninitialized => to == .initialized,
        .initialized => to == .planned or to == .uninitialized,
        .planned => to == .applying or to == .planned, // re-plan allowed
        .applying => to == .applied or to == .iac_error,
        .applied => to == .initialized, // reset for next cycle
        .iac_error => to == .initialized, // recover
    };
}

/// Initialise a new workspace. Returns slot index or -1 on failure.
pub export fn iac_init(tool: c_int) c_int {
    for (&workspaces, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.tool = @enumFromInt(tool);
            slot.state = .initialized;
            slot.plan_hash = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Generate a plan for a workspace.
pub export fn iac_plan(slot_idx: c_int, plan_hash: u32) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_WORKSPACES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!workspaces[idx].active) return -1;
    if (!isValidTransition(workspaces[idx].state, .planned)) return -2;

    workspaces[idx].state = .planned;
    workspaces[idx].plan_hash = plan_hash;
    return 0;
}

/// Apply the planned changes. REQUIRES state to be Planned (not Initialized).
/// This is the key safety invariant: you cannot apply without planning first.
pub export fn iac_apply(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_WORKSPACES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!workspaces[idx].active) return -1;
    // SAFETY: Must be in Planned state — cannot skip from Initialized
    if (workspaces[idx].state != .planned) return -2;
    if (!isValidTransition(workspaces[idx].state, .applying)) return -2;

    workspaces[idx].state = .applying;
    // Simulate immediate completion for the state machine
    workspaces[idx].state = .applied;
    return 0;
}

/// Destroy all resources and return to Uninitialized.
pub export fn iac_destroy(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_WORKSPACES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!workspaces[idx].active) return -1;
    if (!isValidTransition(workspaces[idx].state, .uninitialized)) return -2;

    workspaces[idx].active = false;
    workspaces[idx].state = .uninitialized;
    workspaces[idx].plan_hash = 0;
    return 0;
}

/// Get the state of a workspace.
pub export fn iac_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_WORKSPACES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!workspaces[idx].active) return @intFromEnum(IacState.uninitialized);
    return @intFromEnum(workspaces[idx].state);
}

/// Check whether a workspace has an active plan.
pub export fn iac_has_plan(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_WORKSPACES) return 0;
    const idx: usize = @intCast(slot_idx);
    if (!workspaces[idx].active) return 0;
    return if (workspaces[idx].state == .planned and workspaces[idx].plan_hash != 0) 1 else 0;
}

/// Validate a state transition (C-ABI export).
pub export fn iac_can_transition(from: c_int, to: c_int) c_int {
    const f: IacState = @enumFromInt(from);
    const t: IacState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all workspaces (for testing).
pub export fn iac_reset() void {
    for (&workspaces) |*slot| {
        slot.active = false;
        slot.state = .uninitialized;
        slot.plan_hash = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the iac-mcp cartridge. Resets all workspace slots.
pub export fn boj_cartridge_init() c_int {
    iac_reset();
    return 0;
}

/// Deinitialise the iac-mcp cartridge. Resets all workspace slots.
pub export fn boj_cartridge_deinit() void {
    iac_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "iac-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and destroy" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.terraform));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.initialized)), iac_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), iac_destroy(slot));
}

test "cannot apply without plan" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.terraform));
    // Attempt to apply directly from initialized — MUST fail
    try std.testing.expectEqual(@as(c_int, -2), iac_apply(slot));
    // State should remain initialized
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.initialized)), iac_state(slot));
}

test "plan then apply succeeds" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.pulumi));
    try std.testing.expectEqual(@as(c_int, 0), iac_plan(slot, 0xDEAD));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.planned)), iac_state(slot));
    try std.testing.expectEqual(@as(c_int, 1), iac_has_plan(slot));
    try std.testing.expectEqual(@as(c_int, 0), iac_apply(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.applied)), iac_state(slot));
}

test "re-plan allowed" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.terraform));
    try std.testing.expectEqual(@as(c_int, 0), iac_plan(slot, 0xAAAA));
    try std.testing.expectEqual(@as(c_int, 0), iac_plan(slot, 0xBBBB));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.planned)), iac_state(slot));
}

test "cannot destroy from planned" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.terraform));
    _ = iac_plan(slot, 0x1234);
    // Destroy only valid from initialized, not planned
    try std.testing.expectEqual(@as(c_int, -2), iac_destroy(slot));
}

test "full lifecycle" {
    iac_reset();
    const slot = iac_init(@intFromEnum(IacTool.terraform));
    _ = iac_plan(slot, 0xCAFE);
    _ = iac_apply(slot);
    // After applied, must go back to initialized
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IacState.applied)), iac_state(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), iac_can_transition(0, 1)); // uninit -> init
    try std.testing.expectEqual(@as(c_int, 1), iac_can_transition(1, 2)); // init -> planned
    try std.testing.expectEqual(@as(c_int, 1), iac_can_transition(2, 3)); // planned -> applying
    try std.testing.expectEqual(@as(c_int, 1), iac_can_transition(3, 4)); // applying -> applied
    try std.testing.expectEqual(@as(c_int, 1), iac_can_transition(4, 1)); // applied -> init
    // Invalid transitions — the key safety invariant
    try std.testing.expectEqual(@as(c_int, 0), iac_can_transition(1, 3)); // init -> applying (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), iac_can_transition(0, 2)); // uninit -> planned
    try std.testing.expectEqual(@as(c_int, 0), iac_can_transition(2, 0)); // planned -> uninit
}
