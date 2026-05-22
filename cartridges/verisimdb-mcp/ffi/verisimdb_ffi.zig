// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// VeriSimDB FFI — C-compatible exports for provenance database operations.

const std = @import("std");

/// Store an octad. Returns 0 on success, -1 on error.
export fn verisimdb_store_octad(key: [*c]const u8, data: [*c]const u8) i32 {
    if (key == null or data == null) return -1;
    return 0; // Stub
}

/// Get an octad by key. Returns 0 on found, -1 on not found.
export fn verisimdb_get_octad(key: [*c]const u8) i32 {
    if (key == null) return -1;
    return 0; // Stub
}

/// Detect drift. Returns number of drifted fields (0 = no drift).
export fn verisimdb_detect_drift(key: [*c]const u8) u32 {
    if (key == null) return 0;
    return 0; // Stub
}

/// Query audit log. Returns number of matching entries.
export fn verisimdb_query_audit(from_ts: u64, to_ts: u64) u32 {
    if (to_ts < from_ts) return 0;
    return 0; // Stub
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "verisimdb-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "verisimdb_store_octad"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "verisimdb_get_octad"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "verisimdb_detect_drift"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "verisimdb_query_audit"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "store rejects null key" {
    try std.testing.expectEqual(@as(i32, -1), verisimdb_store_octad(null, "data"));
}

test "get rejects null key" {
    try std.testing.expectEqual(@as(i32, -1), verisimdb_get_octad(null));
}

test "audit rejects inverted range" {
    try std.testing.expectEqual(@as(u32, 0), verisimdb_query_audit(100, 50));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns verisimdb-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("verisimdb-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "verisimdb_store_octad",
        "verisimdb_get_octad",
        "verisimdb_detect_drift",
        "verisimdb_query_audit",
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
    const rc = boj_cartridge_invoke("verisimdb_store_octad", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
