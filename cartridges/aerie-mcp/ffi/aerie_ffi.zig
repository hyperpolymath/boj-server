// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Aerie FFI — C-compatible exports for environment management.

const std = @import("std");

/// List active environment count.
export fn aerie_list_envs_count() u32 {
    return 0; // Stub
}

/// Create an environment. Returns env ID or 0 on failure.
export fn aerie_create_env(name: [*c]const u8, mem_mb: u32) u32 {
    if (name == null or mem_mb == 0) return 0;
    return 1; // Stub
}

/// Destroy an environment. Returns 0 on success.
export fn aerie_destroy_env(env_id: u32) i32 {
    if (env_id == 0) return -1;
    return 0; // Stub
}

/// Get env status: 0=provisioning, 1=ready, 2=destroying, 3=destroyed, 4=error.
export fn aerie_get_status(env_id: u32) u8 {
    if (env_id == 0) return 4; // Error
    return 1; // Stub — ready
}

// ── Tests ──

test "create rejects null name" {
    try std.testing.expectEqual(@as(u32, 0), aerie_create_env(null, 512));
}

test "create rejects zero memory" {
    try std.testing.expectEqual(@as(u32, 0), aerie_create_env("dev", 0));
}

test "destroy rejects zero id" {
    try std.testing.expectEqual(@as(i32, -1), aerie_destroy_env(0));
}
