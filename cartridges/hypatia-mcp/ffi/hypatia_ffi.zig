// SPDX-License-Identifier: PMPL-1.0-or-later
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
