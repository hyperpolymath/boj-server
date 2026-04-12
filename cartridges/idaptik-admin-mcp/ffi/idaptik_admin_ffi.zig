// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// IDApTIK Admin FFI — C-compatible bridge for BoJ MCP cartridge.

const std = @import("std");

pub const Operation = enum(i32) {
    list_levels = 0,
    get_level_state = 1,
    update_level = 2,
    list_players = 3,
    get_player_progress = 4,
    sync_server = 5,
    get_diagnostics = 6,
};

pub const PermLevel = enum(i32) {
    observer = 0,
    level_designer = 1,
    game_admin = 2,
};

pub export fn idaptik_admin_min_perm(op: i32) i32 {
    return switch (@as(Operation, @enumFromInt(op))) {
        .list_levels => 0,
        .get_level_state => 0,
        .update_level => 1,
        .list_players => 0,
        .get_player_progress => 0,
        .sync_server => 2,
        .get_diagnostics => 0,
    };
}

pub export fn idaptik_admin_check_perm(op: i32, user_perm: i32) i32 {
    const required = idaptik_admin_min_perm(op);
    return if (user_perm >= required) 1 else 0;
}

test "permission levels match ABI" {
    try std.testing.expectEqual(@as(i32, 0), idaptik_admin_min_perm(0));
    try std.testing.expectEqual(@as(i32, 1), idaptik_admin_min_perm(2));
    try std.testing.expectEqual(@as(i32, 2), idaptik_admin_min_perm(5));
}

test "permission check" {
    try std.testing.expectEqual(@as(i32, 1), idaptik_admin_check_perm(0, 0));
    try std.testing.expectEqual(@as(i32, 0), idaptik_admin_check_perm(5, 0));
    try std.testing.expectEqual(@as(i32, 1), idaptik_admin_check_perm(5, 2));
}
