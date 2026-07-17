// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// bug-filing-mcp FFI — ADR-0006 five-symbol cartridge ABI.
//
// This cartridge is a thin HTTP client over the feedback-o-tron engine's
// localhost intake (mod.js is the live dispatch path). The FFI layer is
// standard-layout scaffolding: invoke answers every declared tool with a
// structured delegation notice pointing at the HTTP backend, because a
// network round-trip does not belong in a synchronous C-ABI call. It is
// NOT the real engine and no .so is declared in cartridge.json.

const std = @import("std");

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "bug-filing-mcp";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.2.0";

const DELEGATION_BODY =
    "{\"result\":{\"status\":\"delegated\",\"transport\":\"http\"," ++
    "\"backend\":\"http://127.0.0.1:7722\"," ++
    "\"hint\":\"invoke via mod.js (Deno worker); start the engine with FEEDBACK_A_TRON_HTTP=1\"}}";

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

    const known = shim.toolIs(tool_name, "research_feedback") or
        shim.toolIs(tool_name, "synthesize_feedback") or
        shim.toolIs(tool_name, "submit_feedback");
    if (!known) return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, DELEGATION_BODY);
}

// ── Tests ──

test "boj_cartridge_name returns bug-filing-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("bug-filing-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool answers with a delegation notice" {
    var buf: [512]u8 = undefined;
    const tools = [_][]const u8{
        "research_feedback",
        "synthesize_feedback",
        "submit_feedback",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "delegated") != null);
    }
}

test "invoke: unknown tool returns RC_UNKNOWN_TOOL" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(shim.RC_UNKNOWN_TOOL, rc);
}

test "invoke: buffer too small reports needed length" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("submit_feedback", "{}", &buf, &len);
    try std.testing.expectEqual(shim.RC_BUFFER_TOO_SMALL, rc);
    try std.testing.expect(len > 4);
}
