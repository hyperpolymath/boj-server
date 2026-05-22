// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Model Router FFI — LLM tier routing for BoJ MCP cartridge.

const std = @import("std");

pub const ModelTier = enum(i32) {
    haiku = 0,
    sonnet = 1,
    opus = 2,
};

/// Select model based on cost preference (0=cheapest, 100=best quality).
pub export fn router_select(cost_pref: i32) i32 {
    if (cost_pref < 30) return 0; // Haiku
    if (cost_pref < 70) return 1; // Sonnet
    return 2; // Opus
}

/// Fallback: Opus→Sonnet, Sonnet→Haiku, Haiku→-1 (no fallback).
pub export fn router_fallback(tier: i32) i32 {
    return switch (@as(ModelTier, @enumFromInt(tier))) {
        .opus => 1,
        .sonnet => 0,
        .haiku => -1,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════
//
// Note: model-router-mcp has no cartridge.json; the 4 MCP tool names
// below come from README.adoc.

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "model-router-mcp";
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

/// Dispatch the 4 MCP tools declared in README.adoc. Grade D Alpha.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "classify_task"))
        "{\"result\":{\"tier\":\"haiku\",\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "plan_delegation"))
        "{\"result\":{\"plan\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "review_output"))
        "{\"result\":{\"approved\":false,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "estimate_cost"))
        "{\"result\":{\"usd\":0.0,\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "model selection" {
    try std.testing.expectEqual(@as(i32, 0), router_select(0));
    try std.testing.expectEqual(@as(i32, 1), router_select(50));
    try std.testing.expectEqual(@as(i32, 2), router_select(100));
}

test "fallback chain terminates" {
    try std.testing.expectEqual(@as(i32, 1), router_fallback(2));
    try std.testing.expectEqual(@as(i32, 0), router_fallback(1));
    try std.testing.expectEqual(@as(i32, -1), router_fallback(0));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns model-router-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("model-router-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "classify_task", "plan_delegation", "review_output", "estimate_cost",
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
    const rc = boj_cartridge_invoke("classify_task", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
