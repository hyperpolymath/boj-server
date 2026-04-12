// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Burble Admin FFI — C-compatible bridge for BoJ MCP cartridge.
// Implements the operations defined in BurbleAdmin.Protocol (Idris2 ABI).

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (mirrors Idris2 ABI)
// ═══════════════════════════════════════════════════════════════════════

pub const Operation = enum(i32) {
    list_rooms = 0,
    create_room = 1,
    delete_room = 2,
    list_users = 3,
    kick_user = 4,
    get_metrics = 5,
    manage_recordings = 6,
};

pub const PermLevel = enum(i32) {
    read_only = 0,
    moderator = 1,
    admin = 2,
};

// ═══════════════════════════════════════════════════════════════════════
// Permission checking (matches Idris2 proof)
// ═══════════════════════════════════════════════════════════════════════

/// Returns the minimum permission level for an operation.
/// Matches burble_min_perm in Protocol.idr exactly.
pub export fn burble_admin_min_perm(op: i32) i32 {
    return switch (@as(Operation, @enumFromInt(op))) {
        .list_rooms => 0,
        .create_room => 1,
        .delete_room => 2,
        .list_users => 0,
        .kick_user => 1,
        .get_metrics => 0,
        .manage_recordings => 2,
    };
}

/// Check if a user with the given permission level can perform the operation.
/// Returns 1 if allowed, 0 if denied.
pub export fn burble_admin_check_perm(op: i32, user_perm: i32) i32 {
    const required = burble_admin_min_perm(op);
    return if (user_perm >= required) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Room capacity validation
// ═══════════════════════════════════════════════════════════════════════

/// Validate room capacity (1-500). Returns clamped value.
pub export fn burble_admin_clamp_capacity(requested: i32) i32 {
    if (requested < 1) return 1;
    if (requested > 500) return 500;
    return requested;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "permission levels match ABI" {
    // ReadOnly ops
    try std.testing.expectEqual(@as(i32, 0), burble_admin_min_perm(0)); // list_rooms
    try std.testing.expectEqual(@as(i32, 0), burble_admin_min_perm(3)); // list_users
    try std.testing.expectEqual(@as(i32, 0), burble_admin_min_perm(5)); // get_metrics

    // Moderator ops
    try std.testing.expectEqual(@as(i32, 1), burble_admin_min_perm(1)); // create_room
    try std.testing.expectEqual(@as(i32, 1), burble_admin_min_perm(4)); // kick_user

    // Admin ops
    try std.testing.expectEqual(@as(i32, 2), burble_admin_min_perm(2)); // delete_room
    try std.testing.expectEqual(@as(i32, 2), burble_admin_min_perm(6)); // manage_recordings
}

test "permission check" {
    // Admin can do everything
    try std.testing.expectEqual(@as(i32, 1), burble_admin_check_perm(0, 2));
    try std.testing.expectEqual(@as(i32, 1), burble_admin_check_perm(2, 2));

    // ReadOnly can't delete
    try std.testing.expectEqual(@as(i32, 0), burble_admin_check_perm(2, 0));
}

test "capacity clamping" {
    try std.testing.expectEqual(@as(i32, 1), burble_admin_clamp_capacity(0));
    try std.testing.expectEqual(@as(i32, 50), burble_admin_clamp_capacity(50));
    try std.testing.expectEqual(@as(i32, 500), burble_admin_clamp_capacity(999));
}
