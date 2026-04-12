// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Kategoria FFI — C-compatible exports for categorization.

const std = @import("std");

/// Classify an input. Returns confidence 0-100, or 255 on error.
export fn kategoria_classify(input: [*c]const u8) u8 {
    if (input == null) return 255;
    return 85; // Stub — high confidence
}

/// Get route count for a classification label.
export fn kategoria_get_routes(label: [*c]const u8) u32 {
    if (label == null) return 0;
    return 1; // Stub
}

/// Get available taxonomy levels.
export fn kategoria_get_levels() u32 {
    return 12; // Matches clade taxonomy
}

/// Evaluate a challenge at a given level. Returns score 0-100.
export fn kategoria_eval_challenge(level: u8, input: [*c]const u8) u8 {
    if (input == null or level > 12) return 0;
    return 70; // Stub
}

// ── Tests ──

test "classify rejects null input" {
    try std.testing.expectEqual(@as(u8, 255), kategoria_classify(null));
}

test "classify returns bounded confidence" {
    const conf = kategoria_classify("test input");
    try std.testing.expect(conf <= 100);
}

test "levels matches clade taxonomy" {
    try std.testing.expectEqual(@as(u32, 12), kategoria_get_levels());
}
