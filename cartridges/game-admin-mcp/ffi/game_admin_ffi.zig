// SPDX-License-Identifier: MPL-2.0
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

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "game-admin-mcp";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.1.0";

export fn boj_cartridge_init() callconv(.c) c_int {
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_NAME_PTR;
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_VERSION_PTR;
}

/// Dispatch the cartridge.json MCP tools. Grade D Alpha stubs.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "game_probe_server"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_list_servers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_get_config"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_set_config"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_server_action"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_drift_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "game_list_profiles"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns game-admin-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("game-admin-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "game_probe_server",
        "game_list_servers",
        "game_get_config",
        "game_set_config",
        "game_server_action",
        "game_drift_status",
        "game_list_profiles",
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
    const rc = boj_cartridge_invoke("game_probe_server", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
