// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Reposystem FFI — C-compatible exports for repository management.

const std = @import("std");

/// List repository count.
export fn reposystem_list_repos_count() callconv(.C) u32 {
    return 0; // Stub
}

/// Check health of a repo. Returns 0=green, 1=yellow, 2=red, 3=unknown.
export fn reposystem_check_health(repo_name: [*c]const u8) callconv(.C) u8 {
    if (repo_name == null) return 3;
    return 0; // Stub — green
}

/// Sync mirrors for a repo. Returns 0 on success, -1 on error.
export fn reposystem_sync_mirrors(repo_name: [*c]const u8) callconv(.C) i32 {
    if (repo_name == null) return -1;
    return 0; // Stub
}

/// Run audit. Returns number of checks passed.
export fn reposystem_run_audit(repo_name: [*c]const u8) callconv(.C) u32 {
    if (repo_name == null) return 0;
    return 17; // Stub — all RSR checks pass
}

// ── Tests ──

test "health returns unknown for null" {
    try std.testing.expectEqual(@as(u8, 3), reposystem_check_health(null));
}

test "sync rejects null repo" {
    try std.testing.expectEqual(@as(i32, -1), reposystem_sync_mirrors(null));
}

test "audit returns zero for null" {
    try std.testing.expectEqual(@as(u32, 0), reposystem_run_audit(null));
}
