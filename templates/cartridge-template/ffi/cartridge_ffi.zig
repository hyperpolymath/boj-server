// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Your Name <your.email@example.com>

const std = @import("std");
const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "my-new-cartridge";
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

export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;

    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "tool_name"))
        "{\"result\":{}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
test "boj_cartridge_name returns my-new-cartridge" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("my-new-cartridge", n);
}

test "boj_cartridge_version returns semver" {
    const v = std.mem.span(boj_cartridge_version());
    try std.testing.expectEqualStrings("0.1.0", v);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke unknown tool returns -1" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke known tool writes JSON and returns 0" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("tool_name", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
}

test "invoke with too-small buffer returns -3 and sets required length" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("tool_name", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
