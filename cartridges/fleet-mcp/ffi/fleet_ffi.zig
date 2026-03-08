// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Fleet-MCP Cartridge — Zig FFI bridge for gitbot fleet orchestration.
//
// Provides the native execution layer for the 6-bot gate policy.
// The Idris2 ABI (SafeFleet.idr) defines the gate types and proofs;
// this Zig layer runs the actual gate checks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match FleetMcp.SafeFleet encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const BotGate = enum(c_int) {
    rhodibot = 1,
    echidnabot = 2,
    sustainabot = 3,
    panicbot = 4,
    glambot = 5,
    seambot = 6,
};

pub const RepoStatus = enum(c_int) {
    unscanned = 0,
    scanning = 1,
    healthy = 2,
    degraded = 3,
    blocked = 4,
};

// ═══════════════════════════════════════════════════════════════════════
// Gate Results
// ═══════════════════════════════════════════════════════════════════════

const MAX_GATES: usize = 6;

var passed_gates: [MAX_GATES]bool = .{ false, false, false, false, false, false };
var gate_scores: [MAX_GATES]c_int = .{ 0, 0, 0, 0, 0, 0 };

/// Reset all gate results.
pub export fn fleet_reset() void {
    for (&passed_gates) |*g| g.* = false;
    for (&gate_scores) |*s| s.* = 0;
}

/// Record a gate scan result.
pub export fn fleet_record_gate(gate: c_int, passed: c_int, score: c_int) c_int {
    if (gate < 1 or gate > 6) return -1;
    const idx: usize = @intCast(gate - 1);
    passed_gates[idx] = passed != 0;
    gate_scores[idx] = score;
    return 0;
}

/// Check if mandatory gates (Rhodibot, Echidnabot, Panicbot) have passed.
pub export fn fleet_has_mandatory() c_int {
    // Rhodibot=0, Echidnabot=1, Panicbot=3
    return if (passed_gates[0] and passed_gates[1] and passed_gates[3]) 1 else 0;
}

/// Check if all six gates have passed.
pub export fn fleet_has_all() c_int {
    for (passed_gates) |g| {
        if (!g) return 0;
    }
    return 1;
}

/// Derive repository status from current gate results.
pub export fn fleet_status() c_int {
    if (fleet_has_all() == 1) return @intFromEnum(RepoStatus.healthy);
    if (fleet_has_mandatory() == 1) return @intFromEnum(RepoStatus.degraded);
    for (passed_gates) |g| {
        if (g) return @intFromEnum(RepoStatus.scanning);
    }
    return @intFromEnum(RepoStatus.unscanned);
}

/// Get the score for a specific gate.
pub export fn fleet_gate_score(gate: c_int) c_int {
    if (gate < 1 or gate > 6) return -1;
    return gate_scores[@intCast(gate - 1)];
}


// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the fleet-mcp cartridge. Resets all gate results.
pub export fn boj_cartridge_init() c_int {
    fleet_reset();
    return 0;
}

/// Deinitialise the fleet-mcp cartridge. Resets all gate results.
pub export fn boj_cartridge_deinit() void {
    fleet_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "fleet-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "initial state is unscanned" {
    fleet_reset();
    try std.testing.expectEqual(@as(c_int, 0), fleet_status());
}

test "mandatory gates required for release" {
    fleet_reset();
    // Pass only Rhodibot and Echidnabot — not enough
    _ = fleet_record_gate(1, 1, 95); // Rhodibot
    _ = fleet_record_gate(2, 1, 90); // Echidnabot
    try std.testing.expectEqual(@as(c_int, 0), fleet_has_mandatory());

    // Add Panicbot — now mandatory is met
    _ = fleet_record_gate(4, 1, 85); // Panicbot
    try std.testing.expectEqual(@as(c_int, 1), fleet_has_mandatory());
    try std.testing.expectEqual(@as(c_int, @intFromEnum(RepoStatus.degraded)), fleet_status());
}

test "all gates for healthy status" {
    fleet_reset();
    _ = fleet_record_gate(1, 1, 95);
    _ = fleet_record_gate(2, 1, 90);
    _ = fleet_record_gate(3, 1, 80);
    _ = fleet_record_gate(4, 1, 85);
    _ = fleet_record_gate(5, 1, 75);
    _ = fleet_record_gate(6, 1, 88);
    try std.testing.expectEqual(@as(c_int, 1), fleet_has_all());
    try std.testing.expectEqual(@as(c_int, @intFromEnum(RepoStatus.healthy)), fleet_status());
}

test "failed gate prevents healthy" {
    fleet_reset();
    _ = fleet_record_gate(1, 1, 95);
    _ = fleet_record_gate(2, 1, 90);
    _ = fleet_record_gate(3, 0, 30); // Sustainabot failed
    _ = fleet_record_gate(4, 1, 85);
    _ = fleet_record_gate(5, 1, 75);
    _ = fleet_record_gate(6, 1, 88);
    try std.testing.expectEqual(@as(c_int, 0), fleet_has_all());
    // But mandatory still met (Rhodibot, Echidnabot, Panicbot passed)
    try std.testing.expectEqual(@as(c_int, 1), fleet_has_mandatory());
    try std.testing.expectEqual(@as(c_int, @intFromEnum(RepoStatus.degraded)), fleet_status());
}
