// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Gossamer FFI — C-compatible exports for the Gossamer webview shell.

const std = @import("std");

/// Window handle (0 = invalid).
pub const WindowHandle = u32;

/// Create a new webview window. Returns handle or 0 on failure.
export fn gossamer_create_window(width: u32, height: u32) WindowHandle {
    if (width == 0 or height == 0) return 0;
    // Stub: real impl delegates to libgossamer
    return 1;
}

/// Load a panel by URI into a window. Returns 0 on success, -1 on error.
export fn gossamer_load_panel(handle: WindowHandle, uri: [*c]const u8) i32 {
    if (handle == 0 or uri == null) return -1;
    return 0;
}

/// Evaluate JavaScript in a window context. Returns 0 on success.
export fn gossamer_eval_js(handle: WindowHandle, script: [*c]const u8) i32 {
    if (handle == 0 or script == null) return -1;
    return 0;
}

/// Get runtime version. Returns packed major.minor.patch.
export fn gossamer_get_version() u32 {
    return (0 << 16) | (1 << 8) | 0; // 0.1.0
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "gossamer-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "gossamer_create_window"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gossamer_load_panel"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gossamer_eval_js"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gossamer_get_version"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "create window rejects zero dimensions" {
    try std.testing.expectEqual(@as(WindowHandle, 0), gossamer_create_window(0, 600));
    try std.testing.expectEqual(@as(WindowHandle, 0), gossamer_create_window(800, 0));
}

test "create window succeeds with valid dimensions" {
    try std.testing.expect(gossamer_create_window(800, 600) != 0);
}

test "load panel rejects null handle" {
    try std.testing.expectEqual(@as(i32, -1), gossamer_load_panel(0, "panel://home"));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns gossamer-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("gossamer-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "gossamer_create_window",
        "gossamer_load_panel",
        "gossamer_eval_js",
        "gossamer_get_version",
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
    const rc = boj_cartridge_invoke("gossamer_create_window", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
