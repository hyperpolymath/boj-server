// SPDX-License-Identifier: MPL-2.0
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

var mutex: std.Thread.Mutex = .{};

/// Reset all gate results.
pub export fn fleet_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&passed_gates) |*g| g.* = false;
    for (&gate_scores) |*s| s.* = 0;
}

/// Record a gate scan result.
pub export fn fleet_record_gate(gate: c_int, passed: c_int, score: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (gate < 1 or gate > 6) return -1;
    const idx: usize = @intCast(gate - 1);
    passed_gates[idx] = passed != 0;
    gate_scores[idx] = score;
    return 0;
}

/// Check if mandatory gates (Rhodibot, Echidnabot, Panicbot) have passed.
pub export fn fleet_has_mandatory() c_int {
    mutex.lock();
    defer mutex.unlock();
    // Rhodibot=0, Echidnabot=1, Panicbot=3
    return if (passed_gates[0] and passed_gates[1] and passed_gates[3]) 1 else 0;
}

/// Check if all six gates have passed.
pub export fn fleet_has_all() c_int {
    mutex.lock();
    defer mutex.unlock();
    for (passed_gates) |g| {
        if (!g) return 0;
    }
    return 1;
}

/// Derive repository status from current gate results.
pub export fn fleet_status() c_int {
    mutex.lock();
    defer mutex.unlock();
    // Inline checks to avoid deadlock (fleet_has_all/fleet_has_mandatory also lock)
    const all_passed = blk: {
        for (passed_gates) |g| {
            if (!g) break :blk false;
        }
        break :blk true;
    };
    if (all_passed) return @intFromEnum(RepoStatus.healthy);
    // Mandatory: Rhodibot=0, Echidnabot=1, Panicbot=3
    if (passed_gates[0] and passed_gates[1] and passed_gates[3]) return @intFromEnum(RepoStatus.degraded);
    for (passed_gates) |g| {
        if (g) return @intFromEnum(RepoStatus.scanning);
    }
    return @intFromEnum(RepoStatus.unscanned);
}

/// Get the score for a specific gate.
pub export fn fleet_gate_score(gate: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
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
    mutex.lock();
    defer mutex.unlock();
    return "fleet-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "fleet_record_gate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fleet_bot_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fleet_gate_score"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fleet_has_mandatory"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fleet_fleet_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "fleet_record_gate",
        "fleet_bot_status",
        "fleet_gate_score",
        "fleet_has_mandatory",
        "fleet_fleet_status",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
    }
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("fleet_record_gate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
