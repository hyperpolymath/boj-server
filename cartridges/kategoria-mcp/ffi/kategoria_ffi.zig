// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Kategoria FFI — C-compatible exports for categorization.

const std = @import("std");

/// Classify an input. Returns confidence 0-100, or 255 on error.
export fn kategoria_classify(input: [*c]const u8) u8 {
    if (input == null) return 255;
    return 85; // Stub — high confidence
}

/// Get route count for a classification label.
export fn kategoria_get_routes(label: [*c]const u8) u32 {
    if (label == null) return 0;
    return 1; // Stub
}

/// Get available taxonomy levels.
export fn kategoria_get_levels() u32 {
    return 12; // Matches clade taxonomy
}

/// Evaluate a challenge at a given level. Returns score 0-100.
export fn kategoria_eval_challenge(level: u8, input: [*c]const u8) u8 {
    if (input == null or level > 12) return 0;
    return 70; // Stub
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "kategoria-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "kategoria_classify"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "kategoria_get_levels"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "kategoria_eval_challenge"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "classify rejects null input" {
    try std.testing.expectEqual(@as(u8, 255), kategoria_classify(null));
}

test "classify returns bounded confidence" {
    const conf = kategoria_classify("test input");
    try std.testing.expect(conf <= 100);
}

test "levels matches clade taxonomy" {
    try std.testing.expectEqual(@as(u32, 12), kategoria_get_levels());
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns kategoria-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("kategoria-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "kategoria_classify",
        "kategoria_get_levels",
        "kategoria_eval_challenge",
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
    const rc = boj_cartridge_invoke("kategoria_classify", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
