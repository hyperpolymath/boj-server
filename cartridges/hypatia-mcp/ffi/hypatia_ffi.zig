// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Hypatia FFI — C-compatible exports for neurosymbolic CI scanning.

const std = @import("std");

/// Scan a repository path. Returns scan ID or 0 on failure.
export fn hypatia_scan_repo(path: [*c]const u8) u32 {
    if (path == null) return 0;
    return 1; // Stub
}

/// Begin model training. Returns 0 on success.
export fn hypatia_train_model(model_name: [*c]const u8) i32 {
    if (model_name == null) return -1;
    return 0; // Stub
}

/// Get the score for a completed scan (0-100).
export fn hypatia_get_score(scan_id: u32) u8 {
    if (scan_id == 0) return 0;
    return 85; // Stub
}

/// Get active rule count.
export fn hypatia_get_rule_count() u32 {
    return 17; // Stub — matches standard workflow set
}

// ── Standard ABI (ADR-0005 four symbols + ADR-0006 invoke) ──────────

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "hypatia-mcp";
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

/// Dispatch the 4 cartridge.json MCP tools. Grade D Alpha stubs.
/// Note: `hypatia_get_rule_set` is the declared tool name; the bespoke
/// FFI symbol is `hypatia_get_rule_count` — the invoke dispatch uses
/// the cartridge.json-declared name as its canonical surface.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "hypatia_scan_repo"))
        "{\"result\":{\"scan_id\":1,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hypatia_get_score"))
        "{\"result\":{\"score\":85,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hypatia_get_rule_set"))
        "{\"result\":{\"rules\":[],\"count\":17,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hypatia_train_model"))
        "{\"result\":{\"training\":true,\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "scan rejects null path" {
    try std.testing.expectEqual(@as(u32, 0), hypatia_scan_repo(null));
}

test "score within bounds" {
    const score = hypatia_get_score(1);
    try std.testing.expect(score <= 100);
}

test "rule count is positive" {
    try std.testing.expect(hypatia_get_rule_count() > 0);
}

test "boj_cartridge_name returns hypatia-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("hypatia-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "hypatia_scan_repo",    "hypatia_get_score",
        "hypatia_get_rule_set", "hypatia_train_model",
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
    const rc = boj_cartridge_invoke("hypatia_scan_repo", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
