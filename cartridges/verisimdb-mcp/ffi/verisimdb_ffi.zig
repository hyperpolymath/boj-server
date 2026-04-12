// SPDX-License-Identifier: PMPL-1.0-or-later
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
