// SPDX-License-Identifier: MPL-2.0
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

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "idaptik-admin-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "idaptik_server_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_list_sessions"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_create_session"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_end_session"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_get_config"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_update_config"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_list_level_packs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_toggle_training"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_player_stats"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "idaptik_server_action"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns idaptik-admin-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("idaptik-admin-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "idaptik_server_status",
        "idaptik_list_sessions",
        "idaptik_create_session",
        "idaptik_end_session",
        "idaptik_get_config",
        "idaptik_update_config",
        "idaptik_list_level_packs",
        "idaptik_toggle_training",
        "idaptik_player_stats",
        "idaptik_server_action",
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
    const rc = boj_cartridge_invoke("idaptik_server_status", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
