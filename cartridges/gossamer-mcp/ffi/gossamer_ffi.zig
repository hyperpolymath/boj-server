// SPDX-License-Identifier: PMPL-1.0-or-later
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
