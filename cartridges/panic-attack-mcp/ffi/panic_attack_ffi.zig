// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// PanicAttack FFI — C-compatible exports for security scanning.

const std = @import("std");

/// Severity levels matching the ABI definition.
pub const Severity = enum(u8) { info = 0, low = 1, medium = 2, high = 3, critical = 4 };

/// Initiate a scan on a target path. Returns scan ID or 0 on error.
export fn panic_attack_scan(target: [*c]const u8) callconv(.C) u32 {
    if (target == null) return 0;
    // Stub: real impl delegates to panic-attacker binary
    return 1;
}

/// Get number of findings for a completed scan.
export fn panic_attack_get_findings_count(scan_id: u32) callconv(.C) u32 {
    if (scan_id == 0) return 0;
    return 0; // Stub
}

/// Get the highest severity found in a scan.
export fn panic_attack_get_severity(scan_id: u32) callconv(.C) u8 {
    if (scan_id == 0) return @intFromEnum(Severity.info);
    return @intFromEnum(Severity.info); // Stub
}

// ── Tests ──

test "scan rejects null target" {
    try std.testing.expectEqual(@as(u32, 0), panic_attack_scan(null));
}

test "scan accepts valid target" {
    try std.testing.expect(panic_attack_scan("/tmp/repo") != 0);
}

test "findings count zero for invalid scan" {
    try std.testing.expectEqual(@as(u32, 0), panic_attack_get_findings_count(0));
}
