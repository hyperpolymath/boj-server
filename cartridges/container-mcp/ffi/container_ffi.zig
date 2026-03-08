// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Container-MCP Cartridge — Zig FFI bridge for container management.
//
// Implements the container lifecycle state machine from SafeContainer.idr.
// Ensures containers follow the correct lifecycle ordering:
// None -> Built -> Created -> Running -> Stopped -> Removed

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match ContainerMcp.SafeContainer encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const CtrState = enum(c_int) {
    none = 0,
    built = 1,
    created = 2,
    running = 3,
    stopped = 4,
    removed = 5,
};

pub const ContainerRuntime = enum(c_int) {
    podman = 1,
    nerdctl = 2,
    docker = 3,
};

// ═══════════════════════════════════════════════════════════════════════
// Container Lifecycle State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_CONTAINERS: usize = 32;

const ContainerSlot = struct {
    active: bool,
    state: CtrState,
    runtime: ContainerRuntime,
    image_name_hash: u32,
};

var containers: [MAX_CONTAINERS]ContainerSlot = [_]ContainerSlot{.{
    .active = false,
    .state = .none,
    .runtime = .podman,
    .image_name_hash = 0,
}} ** MAX_CONTAINERS;

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: CtrState, to: CtrState) bool {
    return switch (from) {
        .none => to == .built,
        .built => to == .created,
        .created => to == .running or to == .removed,
        .running => to == .stopped,
        .stopped => to == .running or to == .removed,
        .removed => false,
    };
}

/// Simple hash for image name tracking.
fn hashName(name: [*:0]const u8) u32 {
    var h: u32 = 5381;
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        h = ((h << 5) +% h) +% @as(u32, name[i]);
    }
    return h;
}

/// Build a container image. Returns slot index or -1 on failure.
pub export fn ctr_build(runtime: c_int, image_name: [*:0]const u8) c_int {
    for (&containers, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .built;
            slot.runtime = @enumFromInt(runtime);
            slot.image_name_hash = hashName(image_name);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Create a container from a built image.
pub export fn ctr_create(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONTAINERS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!containers[idx].active) return -1;
    if (!isValidTransition(containers[idx].state, .created)) return -2;

    containers[idx].state = .created;
    return 0;
}

/// Start a created or stopped container.
pub export fn ctr_start(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONTAINERS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!containers[idx].active) return -1;
    if (!isValidTransition(containers[idx].state, .running)) return -2;

    containers[idx].state = .running;
    return 0;
}

/// Stop a running container.
pub export fn ctr_stop(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONTAINERS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!containers[idx].active) return -1;
    if (!isValidTransition(containers[idx].state, .stopped)) return -2;

    containers[idx].state = .stopped;
    return 0;
}

/// Remove a stopped or created container.
pub export fn ctr_remove(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONTAINERS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!containers[idx].active) return -1;
    if (!isValidTransition(containers[idx].state, .removed)) return -2;

    containers[idx].state = .removed;
    containers[idx].active = false;
    return 0;
}

/// Get the state of a container.
pub export fn ctr_state(slot_idx: c_int) c_int {
    if (slot_idx < 0 or slot_idx >= MAX_CONTAINERS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!containers[idx].active) return @intFromEnum(CtrState.none);
    return @intFromEnum(containers[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn ctr_can_transition(from: c_int, to: c_int) c_int {
    const f: CtrState = @enumFromInt(from);
    const t: CtrState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all containers (for testing).
pub export fn ctr_reset() void {
    for (&containers) |*slot| {
        slot.active = false;
        slot.state = .none;
        slot.image_name_hash = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the container-mcp cartridge. Resets all container slots.
pub export fn boj_cartridge_init() c_int {
    ctr_reset();
    return 0;
}

/// Deinitialise the container-mcp cartridge. Resets all container slots.
pub export fn boj_cartridge_deinit() void {
    ctr_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "container-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "full lifecycle: build -> create -> start -> stop -> remove" {
    ctr_reset();
    const slot = ctr_build(@intFromEnum(ContainerRuntime.podman), "myapp:latest");
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CtrState.built)), ctr_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ctr_create(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CtrState.created)), ctr_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ctr_start(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CtrState.running)), ctr_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ctr_stop(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CtrState.stopped)), ctr_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ctr_remove(slot));
}

test "cannot start unbuilt container" {
    ctr_reset();
    const slot = ctr_build(@intFromEnum(ContainerRuntime.nerdctl), "test:v1");
    // Cannot start directly from built — must create first
    try std.testing.expectEqual(@as(c_int, -2), ctr_start(slot));
}

test "cannot remove running container" {
    ctr_reset();
    const slot = ctr_build(@intFromEnum(ContainerRuntime.podman), "webapp:latest");
    _ = ctr_create(slot);
    _ = ctr_start(slot);
    // Cannot remove while running — must stop first
    try std.testing.expectEqual(@as(c_int, -2), ctr_remove(slot));
}

test "restart stopped container" {
    ctr_reset();
    const slot = ctr_build(@intFromEnum(ContainerRuntime.docker), "db:14");
    _ = ctr_create(slot);
    _ = ctr_start(slot);
    _ = ctr_stop(slot);
    // Can restart a stopped container
    try std.testing.expectEqual(@as(c_int, 0), ctr_start(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CtrState.running)), ctr_state(slot));
}

test "remove created but never started" {
    ctr_reset();
    const slot = ctr_build(@intFromEnum(ContainerRuntime.podman), "scratch:latest");
    _ = ctr_create(slot);
    // Can remove a created container without starting it
    try std.testing.expectEqual(@as(c_int, 0), ctr_remove(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(0, 1)); // none -> built
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(1, 2)); // built -> created
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(2, 3)); // created -> running
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(3, 4)); // running -> stopped
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(4, 3)); // stopped -> running (restart)
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(4, 5)); // stopped -> removed
    try std.testing.expectEqual(@as(c_int, 1), ctr_can_transition(2, 5)); // created -> removed
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), ctr_can_transition(0, 3)); // none -> running
    try std.testing.expectEqual(@as(c_int, 0), ctr_can_transition(3, 5)); // running -> removed
    try std.testing.expectEqual(@as(c_int, 0), ctr_can_transition(5, 0)); // removed -> none
}

test "max containers enforced" {
    ctr_reset();
    var i: usize = 0;
    while (i < MAX_CONTAINERS) : (i += 1) {
        const slot = ctr_build(@intFromEnum(ContainerRuntime.podman), "fill:latest");
        try std.testing.expect(slot >= 0);
    }
    // Next build should fail
    try std.testing.expectEqual(@as(c_int, -1), ctr_build(@intFromEnum(ContainerRuntime.podman), "overflow:latest"));
}
