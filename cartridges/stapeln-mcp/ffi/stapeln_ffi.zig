// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Stapeln FFI — C-compatible exports for container orchestration.

const std = @import("std");

/// List active stack count.
export fn stapeln_list_stacks_count() callconv(.C) u32 {
    return 0; // Stub
}

/// Deploy a stack by name. Returns 0 on success, -1 on error.
export fn stapeln_deploy(name: [*c]const u8, replicas: u32) callconv(.C) i32 {
    if (name == null or replicas == 0) return -1;
    return 0; // Stub
}

/// Scale a stack. Returns 0 on success.
export fn stapeln_scale(name: [*c]const u8, replicas: u32) callconv(.C) i32 {
    if (name == null) return -1;
    return 0; // Stub
}

/// Get health status: 0=healthy, 1=degraded, 2=unhealthy, 3=unknown.
export fn stapeln_get_health(name: [*c]const u8) callconv(.C) u8 {
    if (name == null) return 3;
    return 0; // Stub
}

// ── Tests ──

test "deploy rejects null name" {
    try std.testing.expectEqual(@as(i32, -1), stapeln_deploy(null, 1));
}

test "deploy rejects zero replicas" {
    try std.testing.expectEqual(@as(i32, -1), stapeln_deploy("web", 0));
}

test "health returns unknown for null" {
    try std.testing.expectEqual(@as(u8, 3), stapeln_get_health(null));
}
