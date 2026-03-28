// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Conflow FFI — C-compatible exports for configuration orchestration.

const std = @import("std");

/// Get a config value by key. Returns 0 if found, -1 if missing.
export fn conflow_get_config(key: [*c]const u8) callconv(.C) i32 {
    if (key == null) return -1;
    return 0; // Stub
}

/// Apply a config blob. Returns number of entries applied, or -1 on error.
export fn conflow_apply_config(blob: [*c]const u8) callconv(.C) i32 {
    if (blob == null) return -1;
    return 0; // Stub
}

/// Validate a config blob. Returns 0 if valid, error count otherwise.
export fn conflow_validate_config(blob: [*c]const u8) callconv(.C) i32 {
    if (blob == null) return -1;
    return 0; // Stub — valid
}

/// Diff two config blobs. Returns number of differences.
export fn conflow_diff_config(a: [*c]const u8, b: [*c]const u8) callconv(.C) u32 {
    if (a == null or b == null) return 0;
    return 0; // Stub
}

// ── Tests ──

test "get rejects null key" {
    try std.testing.expectEqual(@as(i32, -1), conflow_get_config(null));
}

test "validate rejects null blob" {
    try std.testing.expectEqual(@as(i32, -1), conflow_validate_config(null));
}

test "diff of identical configs is zero" {
    try std.testing.expectEqual(@as(u32, 0), conflow_diff_config("a=1", "a=1"));
}
