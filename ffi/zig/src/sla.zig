// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ SLA & Monitoring FFI — Service Level Agreement tracking and metrics.
//
// Tracks per-cartridge and system-level SLA metrics:
//   - Uptime percentage (availability)
//   - Request latency percentiles (p50, p95, p99)
//   - Error rate (failed invocations / total)
//   - Circuit breaker state history
//
// Produces structured SLA reports queryable via the REST API.
// Integrates with vordr for external monitoring and Guardian for
// resource-aware thresholds.

const std = @import("std");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    pub fn lock(m: *Mutex) void {
        while (!m.state.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(m: *Mutex) void {
        m.state.unlock();
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

const MAX_CARTRIDGES: usize = 32;
const MAX_NAME_LEN: usize = 64;
const LATENCY_WINDOW: usize = 1000; // rolling window for percentile calculation
const UPTIME_CHECK_INTERVAL_S: i64 = 60;

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// SLA tier defines the service level target.
const SlaTier = enum(u8) {
    community = 0, // 95% uptime, best-effort latency
    standard = 1, // 99% uptime, p95 < 500ms
    premium = 2, // 99.9% uptime, p95 < 100ms
};

/// Per-cartridge SLA metrics.
const CartridgeSla = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    tier: SlaTier = .community,

    // Availability
    total_checks: u64 = 0,
    successful_checks: u64 = 0,
    mounted_at: i64 = 0, // timestamp when last mounted
    unmounted_at: i64 = 0,

    // Latency tracking (rolling window)
    latencies_us: [LATENCY_WINDOW]u32 = [_]u32{0} ** LATENCY_WINDOW,
    latency_idx: usize = 0,
    latency_count: usize = 0,

    // Error tracking
    total_invocations: u64 = 0,
    failed_invocations: u64 = 0,

    // Active
    active: bool = false,
};

/// System-level SLA summary.
const SystemSla = struct {
    start_time: i64 = 0,
    total_requests: u64 = 0,
    total_errors: u64 = 0,
    cartridges_tracked: usize = 0,
};

// ═══════════════════════════════════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════════════════════════════════

var cartridge_slas: [MAX_CARTRIDGES]CartridgeSla = [_]CartridgeSla{.{}} ** MAX_CARTRIDGES;
var sla_count: usize = 0;
var system_sla: SystemSla = .{};
var initialised: bool = false;
var mutex: Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal API
// ═══════════════════════════════════════════════════════════════════════

fn init() void {
    sla_count = 0;
    system_sla = .{};
    system_sla.start_time = std.time.timestamp();
    cartridge_slas = [_]CartridgeSla{.{}} ** MAX_CARTRIDGES;
    initialised = true;
}

fn findCartridge(name_ptr: [*]const u8, name_len: usize) ?usize {
    const actual = @min(name_len, MAX_NAME_LEN);
    for (cartridge_slas[0..sla_count], 0..) |sla, i| {
        if (sla.name_len == actual and
            std.mem.eql(u8, sla.name[0..actual], name_ptr[0..actual]))
        {
            return i;
        }
    }
    return null;
}

fn registerCartridge(name_ptr: [*]const u8, name_len: usize, tier: SlaTier) i32 {
    if (sla_count >= MAX_CARTRIDGES) return -1;
    const actual = @min(name_len, MAX_NAME_LEN);
    var sla = &cartridge_slas[sla_count];
    @memcpy(sla.name[0..actual], name_ptr[0..actual]);
    sla.name_len = actual;
    sla.tier = tier;
    sla.active = true;
    sla.mounted_at = std.time.timestamp();
    sla_count += 1;
    system_sla.cartridges_tracked = sla_count;
    return @as(i32, @intCast(sla_count - 1));
}

fn recordInvocation(idx: usize, latency_us: u32, success: bool) void {
    if (idx >= sla_count) return;
    var sla = &cartridge_slas[idx];
    sla.total_invocations += 1;
    system_sla.total_requests += 1;
    if (!success) {
        sla.failed_invocations += 1;
        system_sla.total_errors += 1;
    }
    // Rolling latency window
    sla.latencies_us[sla.latency_idx] = latency_us;
    sla.latency_idx = (sla.latency_idx + 1) % LATENCY_WINDOW;
    if (sla.latency_count < LATENCY_WINDOW) sla.latency_count += 1;
}

fn recordHealthCheck(idx: usize, healthy: bool) void {
    if (idx >= sla_count) return;
    var sla = &cartridge_slas[idx];
    sla.total_checks += 1;
    if (healthy) sla.successful_checks += 1;
}

/// Calculate percentile from the rolling latency window.
fn percentile(idx: usize, pct: u8) u32 {
    if (idx >= sla_count) return 0;
    const sla = &cartridge_slas[idx];
    if (sla.latency_count == 0) return 0;

    // Copy and sort the active window
    var buf: [LATENCY_WINDOW]u32 = undefined;
    const count = sla.latency_count;
    @memcpy(buf[0..count], sla.latencies_us[0..count]);
    std.mem.sort(u32, buf[0..count], {}, std.sort.asc(u32));

    const rank = (@as(usize, pct) * count) / 100;
    return buf[@min(rank, count - 1)];
}

/// Calculate uptime percentage (0-10000 = 0.00%-100.00%).
fn uptimePercent(idx: usize) u32 {
    if (idx >= sla_count) return 0;
    const sla = &cartridge_slas[idx];
    if (sla.total_checks == 0) return 10000; // no checks = assume healthy
    return @intCast((sla.successful_checks * 10000) / sla.total_checks);
}

/// Calculate error rate (0-10000 = 0.00%-100.00%).
fn errorRate(idx: usize) u32 {
    if (idx >= sla_count) return 0;
    const sla = &cartridge_slas[idx];
    if (sla.total_invocations == 0) return 0;
    return @intCast((sla.failed_invocations * 10000) / sla.total_invocations);
}

/// Check if a cartridge is meeting its SLA tier targets.
fn meetsSla(idx: usize) bool {
    if (idx >= sla_count) return false;
    const sla = &cartridge_slas[idx];
    const uptime = uptimePercent(idx);
    const p95 = percentile(idx, 95);

    return switch (sla.tier) {
        .community => uptime >= 9500, // 95%
        .standard => uptime >= 9900 and p95 <= 500_000, // 99%, p95 < 500ms
        .premium => uptime >= 9990 and p95 <= 100_000, // 99.9%, p95 < 100ms
    };
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports
// ═══════════════════════════════════════════════════════════════════════

export fn boj_sla_init() i32 {
    mutex.lock();
    defer mutex.unlock();
    init();
    return 0;
}

export fn boj_sla_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    sla_count = 0;
    system_sla = .{};
    initialised = false;
}

export fn boj_sla_register(name_ptr: [*]const u8, name_len: usize, tier: u8) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) init();
    const sla_tier: SlaTier = @enumFromInt(@min(tier, 2));
    return registerCartridge(name_ptr, name_len, sla_tier);
}

export fn boj_sla_record_invocation(idx: usize, latency_us: u32, success: u8) void {
    mutex.lock();
    defer mutex.unlock();
    recordInvocation(idx, latency_us, success != 0);
}

export fn boj_sla_record_health(idx: usize, healthy: u8) void {
    mutex.lock();
    defer mutex.unlock();
    recordHealthCheck(idx, healthy != 0);
}

export fn boj_sla_uptime(idx: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    return uptimePercent(idx);
}

export fn boj_sla_error_rate(idx: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    return errorRate(idx);
}

export fn boj_sla_p50(idx: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    return percentile(idx, 50);
}

export fn boj_sla_p95(idx: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    return percentile(idx, 95);
}

export fn boj_sla_p99(idx: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    return percentile(idx, 99);
}

export fn boj_sla_meets_target(idx: usize) u8 {
    mutex.lock();
    defer mutex.unlock();
    return if (meetsSla(idx)) 1 else 0;
}

export fn boj_sla_total_requests() u64 {
    mutex.lock();
    defer mutex.unlock();
    return system_sla.total_requests;
}

export fn boj_sla_total_errors() u64 {
    mutex.lock();
    defer mutex.unlock();
    return system_sla.total_errors;
}

export fn boj_sla_cartridge_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return sla_count;
}

export fn boj_sla_cartridge_invocations(idx: usize) u64 {
    mutex.lock();
    defer mutex.unlock();
    if (idx >= sla_count) return 0;
    return cartridge_slas[idx].total_invocations;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "sla init and register" {
    init();
    const name = "database-mcp";
    const idx = registerCartridge(name.ptr, name.len, .standard);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), sla_count);
}

test "sla record invocation tracks latency" {
    init();
    const name = "test-cart";
    const idx = registerCartridge(name.ptr, name.len, .community);
    try std.testing.expect(idx >= 0);
    recordInvocation(@intCast(idx), 150, true);
    recordInvocation(@intCast(idx), 250, true);
    recordInvocation(@intCast(idx), 350, false);
    try std.testing.expectEqual(@as(u64, 3), cartridge_slas[0].total_invocations);
    try std.testing.expectEqual(@as(u64, 1), cartridge_slas[0].failed_invocations);
}

test "sla uptime 100% when all checks pass" {
    init();
    const name = "healthy-cart";
    const idx = registerCartridge(name.ptr, name.len, .community);
    const uidx: usize = @intCast(idx);
    recordHealthCheck(uidx, true);
    recordHealthCheck(uidx, true);
    recordHealthCheck(uidx, true);
    try std.testing.expectEqual(@as(u32, 10000), uptimePercent(uidx));
}

test "sla uptime degrades with failures" {
    init();
    const name = "flaky-cart";
    const idx = registerCartridge(name.ptr, name.len, .standard);
    const uidx: usize = @intCast(idx);
    // 9 pass, 1 fail = 90%
    var i: usize = 0;
    while (i < 9) : (i += 1) recordHealthCheck(uidx, true);
    recordHealthCheck(uidx, false);
    try std.testing.expectEqual(@as(u32, 9000), uptimePercent(uidx));
}

test "sla percentile calculation" {
    init();
    const name = "latency-cart";
    const idx = registerCartridge(name.ptr, name.len, .community);
    const uidx: usize = @intCast(idx);
    // Add 100 latency samples: 1000, 2000, ..., 100000 us
    var i: u32 = 1;
    while (i <= 100) : (i += 1) {
        recordInvocation(uidx, i * 1000, true);
    }
    const p50 = percentile(uidx, 50);
    const p95 = percentile(uidx, 95);
    const p99 = percentile(uidx, 99);
    try std.testing.expect(p50 >= 49000 and p50 <= 51000);
    try std.testing.expect(p95 >= 94000 and p95 <= 96000);
    try std.testing.expect(p99 >= 98000 and p99 <= 100000);
}

test "sla error rate calculation" {
    init();
    const name = "error-cart";
    const idx = registerCartridge(name.ptr, name.len, .community);
    const uidx: usize = @intCast(idx);
    recordInvocation(uidx, 100, true);
    recordInvocation(uidx, 100, true);
    recordInvocation(uidx, 100, false);
    recordInvocation(uidx, 100, false);
    // 2/4 = 50%
    try std.testing.expectEqual(@as(u32, 5000), errorRate(uidx));
}

test "sla meets target community tier" {
    init();
    const name = "comm-cart";
    const idx = registerCartridge(name.ptr, name.len, .community);
    const uidx: usize = @intCast(idx);
    // 96/100 checks pass = 96% > 95% target
    var i: usize = 0;
    while (i < 96) : (i += 1) recordHealthCheck(uidx, true);
    while (i < 100) : (i += 1) recordHealthCheck(uidx, false);
    try std.testing.expect(meetsSla(uidx));
}

test "sla fails target standard tier" {
    init();
    const name = "std-cart";
    const idx = registerCartridge(name.ptr, name.len, .standard);
    const uidx: usize = @intCast(idx);
    // 95/100 = 95% < 99% target
    var i: usize = 0;
    while (i < 95) : (i += 1) recordHealthCheck(uidx, true);
    while (i < 100) : (i += 1) recordHealthCheck(uidx, false);
    try std.testing.expect(!meetsSla(uidx));
}

test "sla c-abi register and query" {
    _ = boj_sla_init();
    const name = "api-test";
    const idx = boj_sla_register(name.ptr, name.len, 0); // community
    try std.testing.expect(idx >= 0);
    boj_sla_record_invocation(@intCast(idx), 200, 1);
    try std.testing.expectEqual(@as(u64, 1), boj_sla_total_requests());
    try std.testing.expectEqual(@as(u64, 0), boj_sla_total_errors());
}

test "sla system totals aggregate" {
    _ = boj_sla_init();
    const n1 = "cart-a";
    const n2 = "cart-b";
    const idx_a = boj_sla_register(n1.ptr, n1.len, 0);
    const idx_b = boj_sla_register(n2.ptr, n2.len, 1);
    boj_sla_record_invocation(@intCast(idx_a), 100, 1);
    boj_sla_record_invocation(@intCast(idx_b), 200, 0); // error
    boj_sla_record_invocation(@intCast(idx_b), 300, 1);
    try std.testing.expectEqual(@as(u64, 3), boj_sla_total_requests());
    try std.testing.expectEqual(@as(u64, 1), boj_sla_total_errors());
}

test "sla deinit resets state" {
    _ = boj_sla_init();
    const name = "tmp";
    _ = boj_sla_register(name.ptr, name.len, 0);
    boj_sla_deinit();
    try std.testing.expectEqual(@as(usize, 0), boj_sla_cartridge_count());
    try std.testing.expectEqual(@as(u64, 0), boj_sla_total_requests());
}
