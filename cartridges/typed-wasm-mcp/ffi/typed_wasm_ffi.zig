// SPDX-License-Identifier: PMPL-1.0-or-later
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
