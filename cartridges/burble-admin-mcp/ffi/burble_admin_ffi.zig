// SPDX-License-Identifier: MPL-2.0
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
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "burble-admin-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "burble_check_health"))
        "{\"result\":{\"health\":\"healthy\",\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_list_rooms"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_create_room"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_close_room"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_kick_user"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_get_config"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_update_config"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_voice_stats"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_toggle_recording"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "burble_node_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns burble-admin-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("burble-admin-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "burble_check_health",
        "burble_list_rooms",
        "burble_create_room",
        "burble_close_room",
        "burble_kick_user",
        "burble_get_config",
        "burble_update_config",
        "burble_voice_stats",
        "burble_toggle_recording",
        "burble_node_status",
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
    const rc = boj_cartridge_invoke("burble_check_health", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
