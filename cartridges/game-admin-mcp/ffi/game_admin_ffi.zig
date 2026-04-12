// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Admin FFI — C-compatible bridge for BoJ MCP cartridge.

const std = @import("std");

pub const Operation = enum(i32) {
    list_servers = 0,
    get_server_status = 1,
    start_server = 2,
    stop_server = 3,
    restart_server = 4,
    update_config = 5,
    get_logs = 6,
    probe_health = 7,
};

pub const PermLevel = enum(i32) {
    viewer = 0,
    operator_ = 1,
    admin = 2,
};

pub export fn game_admin_min_perm(op: i32) i32 {
    return switch (@as(Operation, @enumFromInt(op))) {
        .list_servers => 0,
        .get_server_status => 0,
        .start_server => 1,
        .stop_server => 1,
        .restart_server => 1,
        .update_config => 2,
        .get_logs => 0,
        .probe_health => 0,
    };
}

pub export fn game_admin_check_perm(op: i32, user_perm: i32) i32 {
    const required = game_admin_min_perm(op);
    return if (user_perm >= required) 1 else 0;
}

pub export fn game_admin_is_readonly(op: i32) i32 {
    return switch (@as(Operation, @enumFromInt(op))) {
        .list_servers, .get_server_status, .get_logs, .probe_health => 1,
        else => 0,
    };
}

test "permission levels match ABI" {
    try std.testing.expectEqual(@as(i32, 0), game_admin_min_perm(0));
    try std.testing.expectEqual(@as(i32, 1), game_admin_min_perm(2));
    try std.testing.expectEqual(@as(i32, 2), game_admin_min_perm(5));
}

test "readonly operations" {
    try std.testing.expectEqual(@as(i32, 1), game_admin_is_readonly(0));
    try std.testing.expectEqual(@as(i32, 1), game_admin_is_readonly(1));
    try std.testing.expectEqual(@as(i32, 0), game_admin_is_readonly(2));
    try std.testing.expectEqual(@as(i32, 0), game_admin_is_readonly(5));
    try std.testing.expectEqual(@as(i32, 1), game_admin_is_readonly(7));
}
