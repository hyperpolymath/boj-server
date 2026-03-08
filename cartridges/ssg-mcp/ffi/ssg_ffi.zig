// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// SSG-MCP Cartridge — Zig FFI bridge for static site generation operations.
//
// Implements the build pipeline state machine from SafeSsg.idr.
// Ensures no deployment can execute without a preceding build and preview,
// and no preview can run without a successful build.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match SsgMcp.SafeSsg encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SsgState = enum(c_int) {
    empty = 0,
    content_loaded = 1,
    built = 2,
    previewing = 3,
    ready_to_deploy = 4,
    deployed = 5,
    ssg_error = 6,
};

pub const SsgEngine = enum(c_int) {
    hugo = 1,
    zola = 2,
    astro = 3,
    casket = 4,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Build Pipeline State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SITES: usize = 8;

const SiteSlot = struct {
    active: bool,
    engine: SsgEngine,
    state: SsgState,
    content_hash: u32, // Hash of content for cache invalidation
};

var sites: [MAX_SITES]SiteSlot = [_]SiteSlot{.{
    .active = false,
    .engine = .hugo,
    .state = .empty,
    .content_hash = 0,
}} ** MAX_SITES;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: SsgState, to: SsgState) bool {
    return switch (from) {
        .empty => to == .content_loaded,
        .content_loaded => to == .built or to == .ssg_error,
        .built => to == .previewing or to == .built, // rebuild allowed
        .previewing => to == .ready_to_deploy,
        .ready_to_deploy => to == .deployed or to == .empty or to == .ssg_error,
        .deployed => to == .empty,
        .ssg_error => to == .empty,
    };
}

/// Load content into a new site. Returns slot index or -1 on failure.
pub export fn ssg_load_content(engine: c_int, content_hash: u32) c_int {
    for (&sites, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.engine = @enumFromInt(engine);
            slot.state = .content_loaded;
            slot.content_hash = content_hash;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Build the static site.
pub export fn ssg_build(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return -1;
    if (!isValidTransition(sites[idx].state, .built)) return -2;

    sites[idx].state = .built;
    return 0;
}

/// Start preview server. REQUIRES state to be Built (not ContentLoaded).
pub export fn ssg_preview(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return -1;
    // SAFETY: Must be in Built state — cannot preview unbuilt content
    if (sites[idx].state != .built) return -2;
    if (!isValidTransition(sites[idx].state, .previewing)) return -2;

    sites[idx].state = .previewing;
    return 0;
}

/// Mark preview as complete, transition to ReadyToDeploy.
pub export fn ssg_ready_deploy(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return -1;
    if (!isValidTransition(sites[idx].state, .ready_to_deploy)) return -2;

    sites[idx].state = .ready_to_deploy;
    return 0;
}

/// Deploy the site. REQUIRES state to be ReadyToDeploy (not Built).
/// This is the key safety invariant: you cannot deploy without previewing first.
pub export fn ssg_deploy(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return -1;
    // SAFETY: Must be in ReadyToDeploy state — cannot skip preview
    if (sites[idx].state != .ready_to_deploy) return -2;
    if (!isValidTransition(sites[idx].state, .deployed)) return -2;

    sites[idx].state = .deployed;
    return 0;
}

/// Clean build artifacts and reset to Empty.
pub export fn ssg_clean(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return -1;
    if (!isValidTransition(sites[idx].state, .empty)) return -2;

    sites[idx].active = false;
    sites[idx].state = .empty;
    sites[idx].content_hash = 0;
    return 0;
}

/// Get the state of a site.
pub export fn ssg_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_SITES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sites[idx].active) return @intFromEnum(SsgState.empty);
    return @intFromEnum(sites[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn ssg_can_transition(from: c_int, to: c_int) c_int {
    const f: SsgState = @enumFromInt(from);
    const t: SsgState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sites (for testing).
pub export fn ssg_reset() void {
    for (&sites) |*slot| {
        slot.active = false;
        slot.state = .empty;
        slot.content_hash = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the ssg-mcp cartridge. Resets all site slots.
pub export fn boj_cartridge_init() c_int {
    ssg_reset();
    return 0;
}

/// Deinitialise the ssg-mcp cartridge. Resets all site slots.
pub export fn boj_cartridge_deinit() void {
    ssg_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "ssg-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "load content and clean" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.hugo), 0xABCD);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.content_loaded)), ssg_state(slot));
    // Cannot clean from content_loaded (must build first)
    try std.testing.expectEqual(@as(c_int, -2), ssg_clean(slot));
}

test "cannot deploy without preview" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.zola), 0x1234);
    _ = ssg_build(slot);
    // Attempt to deploy directly from built — MUST fail
    try std.testing.expectEqual(@as(c_int, -2), ssg_deploy(slot));
    // State should remain built
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.built)), ssg_state(slot));
}

test "cannot preview without build" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.astro), 0x5678);
    // Attempt to preview from content_loaded — MUST fail
    try std.testing.expectEqual(@as(c_int, -2), ssg_preview(slot));
}

test "full pipeline: load -> build -> preview -> ready -> deploy" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.casket), 0xCAFE);
    try std.testing.expectEqual(@as(c_int, 0), ssg_build(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.built)), ssg_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ssg_preview(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.previewing)), ssg_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ssg_ready_deploy(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.ready_to_deploy)), ssg_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ssg_deploy(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.deployed)), ssg_state(slot));
}

test "rebuild allowed" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.hugo), 0xAAAA);
    try std.testing.expectEqual(@as(c_int, 0), ssg_build(slot));
    try std.testing.expectEqual(@as(c_int, 0), ssg_build(slot)); // rebuild
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.built)), ssg_state(slot));
}

test "clean after deploy" {
    ssg_reset();
    const slot = ssg_load_content(@intFromEnum(SsgEngine.zola), 0xBBBB);
    _ = ssg_build(slot);
    _ = ssg_preview(slot);
    _ = ssg_ready_deploy(slot);
    _ = ssg_deploy(slot);
    try std.testing.expectEqual(@as(c_int, 0), ssg_clean(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SsgState.empty)), ssg_state(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(0, 1)); // empty -> content_loaded
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(1, 2)); // content_loaded -> built
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(2, 3)); // built -> previewing
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(3, 4)); // previewing -> ready_to_deploy
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(4, 5)); // ready_to_deploy -> deployed
    try std.testing.expectEqual(@as(c_int, 1), ssg_can_transition(5, 0)); // deployed -> empty
    // Invalid transitions — the key safety invariants
    try std.testing.expectEqual(@as(c_int, 0), ssg_can_transition(1, 3)); // content_loaded -> previewing (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), ssg_can_transition(2, 5)); // built -> deployed (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), ssg_can_transition(0, 5)); // empty -> deployed
}
