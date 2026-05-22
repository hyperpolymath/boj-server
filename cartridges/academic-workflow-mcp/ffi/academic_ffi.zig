// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// academic-workflow-mcp FFI — ADR-0006 five-symbol cartridge ABI implementation.

const std = @import("std");
const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "academic-workflow-mcp";
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
    const body: []const u8 = if (shim.toolIs(tool_name, "search_zotero"))
        "{\"result\":{}}"
    else if (shim.toolIs(tool_name, "get_paper_metadata"))
        "{\"result\":{}}"
    else if (shim.toolIs(tool_name, "generate_citation"))
        "{\"result\":{}}"
    else if (shim.toolIs(tool_name, "extract_bibkeys"))
        "{\"result\":{}}"
    else if (shim.toolIs(tool_name, "export_collection"))
        "{\"result\":{}}"
    else if (shim.toolIs(tool_name, "add_review_note"))
        "{\"result\":{}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "boj_cartridge_name returns academic-workflow-mcp" {
    try std.testing.expectEqualStrings("academic-workflow-mcp", std.mem.span(boj_cartridge_name()));
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke unknown tool returns RC_UNKNOWN_TOOL" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    try std.testing.expectEqual(@as(i32, shim.RC_UNKNOWN_TOOL), boj_cartridge_invoke("unknown_xyz", "{}", &buf, &len));
}

test "invoke search_zotero returns 0" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    try std.testing.expectEqual(@as(i32, 0), boj_cartridge_invoke("search_zotero", "{}", &buf, &len));
}
