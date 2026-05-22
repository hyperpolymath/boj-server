// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Stapeln FFI — C-compatible exports for container orchestration.

const std = @import("std");

/// List active stack count.
export fn stapeln_list_stacks_count() u32 {
    return 0; // Stub
}

/// Deploy a stack by name. Returns 0 on success, -1 on error.
export fn stapeln_deploy(name: [*c]const u8, replicas: u32) i32 {
    if (name == null or replicas == 0) return -1;
    return 0; // Stub
}

/// Scale a stack. Returns 0 on success.
export fn stapeln_scale(name: [*c]const u8, replicas: u32) i32 {
    _ = replicas; // stub — parameter reserved for real implementation
    if (name == null) return -1;
    return 0; // Stub
}

/// Get health status: 0=healthy, 1=degraded, 2=unhealthy, 3=unknown.
export fn stapeln_get_health(name: [*c]const u8) u8 {
    if (name == null) return 3;
    return 0; // Stub
}

// ── Standard ABI (ADR-0005 four symbols + ADR-0006 invoke) ──────────

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "stapeln-mcp";
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

/// Dispatch the 4 cartridge.json MCP tools. Grade D Alpha stubs:
/// each arm returns JSON that reflects the tool's intended shape.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "stapeln_list_stacks"))
        "{\"result\":{\"stacks\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "stapeln_deploy"))
        "{\"result\":{\"deployed\":true,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "stapeln_scale"))
        "{\"result\":{\"scaled\":true,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "stapeln_get_health"))
        "{\"result\":{\"health\":\"healthy\",\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "deploy rejects null name" {
    try std.testing.expectEqual(@as(i32, -1), stapeln_deploy(null, 1));
}

test "deploy rejects zero replicas" {
    try std.testing.expectEqual(@as(i32, -1), stapeln_deploy("web", 0));
}

test "health returns unknown for null" {
    try std.testing.expectEqual(@as(u8, 3), stapeln_get_health(null));
}

test "boj_cartridge_name returns stapeln-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("stapeln-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "stapeln_list_stacks", "stapeln_deploy",
        "stapeln_scale",       "stapeln_get_health",
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
    const rc = boj_cartridge_invoke("stapeln_list_stacks", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
