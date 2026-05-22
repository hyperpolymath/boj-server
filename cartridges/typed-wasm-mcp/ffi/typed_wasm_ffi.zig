// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// TypedWasm FFI — C-compatible exports for WASM type safety validation.

const std = @import("std");

/// Validate a WASM module. Returns safety level 0-10, or 255 on error.
export fn typed_wasm_validate_module(module_path: [*c]const u8) u8 {
    if (module_path == null) return 255;
    return 5; // Stub — mid-level safety
}

/// Check types in a module. Returns error count.
export fn typed_wasm_check_types(module_path: [*c]const u8) u32 {
    if (module_path == null) return 1;
    return 0; // Stub — no errors
}

/// Compile a module. Returns 0 on success, -1 on error.
export fn typed_wasm_compile_module(module_path: [*c]const u8, target: u8) i32 {
    if (module_path == null) return -1;
    if (target > 2) return -1; // Invalid target
    return 0; // Stub
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "typed-wasm-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "typed_wasm_validate_module"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "typed_wasm_check_types"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "typed_wasm_compile_module"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "validate rejects null path" {
    try std.testing.expectEqual(@as(u8, 255), typed_wasm_validate_module(null));
}

test "validate returns bounded level" {
    const level = typed_wasm_validate_module("test.wasm");
    try std.testing.expect(level <= 10);
}

test "compile rejects invalid target" {
    try std.testing.expectEqual(@as(i32, -1), typed_wasm_compile_module("test.wasm", 99));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns typed-wasm-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("typed-wasm-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "typed_wasm_validate_module",
        "typed_wasm_check_types",
        "typed_wasm_compile_module",
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
    const rc = boj_cartridge_invoke("typed_wasm_validate_module", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
