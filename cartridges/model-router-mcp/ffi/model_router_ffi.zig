// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Model Router FFI — LLM tier routing for BoJ MCP cartridge.

const std = @import("std");

pub const ModelTier = enum(i32) {
    haiku = 0,
    sonnet = 1,
    opus = 2,
};

/// Select model based on cost preference (0=cheapest, 100=best quality).
pub export fn router_select(cost_pref: i32) callconv(.C) i32 {
    if (cost_pref < 30) return 0; // Haiku
    if (cost_pref < 70) return 1; // Sonnet
    return 2; // Opus
}

/// Fallback: Opus→Sonnet, Sonnet→Haiku, Haiku→-1 (no fallback).
pub export fn router_fallback(tier: i32) callconv(.C) i32 {
    return switch (@as(ModelTier, @enumFromInt(tier))) {
        .opus => 1,
        .sonnet => 0,
        .haiku => -1,
    };
}

test "model selection" {
    try std.testing.expectEqual(@as(i32, 0), router_select(0));
    try std.testing.expectEqual(@as(i32, 1), router_select(50));
    try std.testing.expectEqual(@as(i32, 2), router_select(100));
}

test "fallback chain terminates" {
    try std.testing.expectEqual(@as(i32, 1), router_fallback(2));
    try std.testing.expectEqual(@as(i32, 0), router_fallback(1));
    try std.testing.expectEqual(@as(i32, -1), router_fallback(0));
}
