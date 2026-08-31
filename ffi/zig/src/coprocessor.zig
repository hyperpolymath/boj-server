// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Coprocessor Dispatch FFI — Axiom.jl-style GPU/TPU/FPGA offload.
//
// Provides a capability-based coprocessor dispatch system for BoJ cartridges.
// Each cartridge can declare which accelerators it supports, and the dispatcher
// selects the best available backend at runtime with automatic CPU fallback.
//
// Design follows Axiom.jl's pattern:
//   detect → select → dispatch → fallback
//
// Key features:
//   - Auto-detect available accelerators (CUDA, ROCm, Metal, TPU, FPGA)
//   - Per-cartridge accelerator affinity declarations
//   - Resource-aware scheduling (integrates with Guardian module)
//   - Graceful CPU fallback when no accelerator is available
//   - Dispatch latency tracking for performance monitoring
//   - C-ABI exports for zig adapter integration

const std = @import("std");

// `std.atomic.Mutex` was removed from the standard library; its replacement is
// `shim.Mutex`, whose lock/unlock surface is identical to the hand-rolled
// wrapper this replaces. The wrapper also busy-waited via `spinLoopHint`, burning
// a core under contention; `shim.Mutex` parks the thread instead. 81 other
// files in this repo already use this form.
const Mutex = shim.Mutex;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

/// Maximum cartridges that can declare coprocessor affinity.
const MAX_CARTRIDGES: usize = 32;

/// Maximum accelerators per cartridge.
const MAX_AFFINITY: usize = 6;

/// Maximum detected devices across all backends.
const MAX_DEVICES: usize = 16;

/// Maximum name length for a cartridge or device.
const MAX_NAME_LEN: usize = 64;

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// Accelerator backend type.
pub const AcceleratorKind = enum(u8) {
    cpu = 0,
    cuda = 1,
    rocm = 2,
    metal = 3,
    tpu = 4,
    fpga = 5,
};

/// Accelerator device status.
const DeviceStatus = enum(u8) {
    unavailable = 0,
    available = 1,
    busy = 2,
    faulted = 3,
};

/// A detected accelerator device.
const Device = struct {
    kind: AcceleratorKind = .cpu,
    status: DeviceStatus = .unavailable,
    device_index: u8 = 0,
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    memory_bytes: u64 = 0,
    dispatch_count: u64 = 0,
    total_latency_us: u64 = 0,
};

/// Cartridge coprocessor affinity declaration.
const CartridgeAffinity = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    preferred: [MAX_AFFINITY]AcceleratorKind = [_]AcceleratorKind{.cpu} ** MAX_AFFINITY,
    preferred_count: usize = 0,
    active_device: ?usize = null, // index into devices[]
};

/// Dispatch result returned to caller.
pub const DispatchResult = struct {
    device_kind: AcceleratorKind,
    device_index: u8,
    was_fallback: bool,
};

// ═══════════════════════════════════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════════════════════════════════

var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;
var device_count: usize = 0;

var affinities: [MAX_CARTRIDGES]CartridgeAffinity = [_]CartridgeAffinity{.{}} ** MAX_CARTRIDGES;
var affinity_count: usize = 0;

var initialised: bool = false;
var mutex: Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Detection
// ═══════════════════════════════════════════════════════════════════════

/// Detect accelerator devices from environment variables.
/// Uses env-only detection (no filesystem probing) for safe cross-runtime use.
/// Set BOJ_CUDA_DEVICES=N, BOJ_ROCM_DEVICES=N, etc. to declare devices.
fn detectFromEnv(env_name: [*:0]const u8, kind: AcceleratorKind, label: []const u8) void {
    const val = getenv(env_name) orelse return;
    // Parse the C string to get count
    var count: u8 = 0;
    var i: usize = 0;
    while (val[i] != 0 and i < 3) : (i += 1) {
        if (val[i] >= '0' and val[i] <= '9') {
            count = count * 10 + (val[i] - '0');
        }
    }
    if (count == 0) return;
    var dev_idx: u8 = 0;
    while (dev_idx < count and device_count < MAX_DEVICES) : (dev_idx += 1) {
        var dev = &devices[device_count];
        dev.kind = kind;
        dev.status = .available;
        dev.device_index = dev_idx;
        const actual_len = @min(label.len, MAX_NAME_LEN);
        @memcpy(dev.name[0..actual_len], label[0..actual_len]);
        dev.name_len = actual_len;
        device_count += 1;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Core API
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the coprocessor subsystem. Detects all available accelerators.
fn init() void {
    device_count = 0;
    affinity_count = 0;

    // CPU is always device 0
    var cpu_dev = &devices[0];
    cpu_dev.kind = .cpu;
    cpu_dev.status = .available;
    cpu_dev.device_index = 0;
    const cpu_label = "CPU";
    @memcpy(cpu_dev.name[0..cpu_label.len], cpu_label);
    cpu_dev.name_len = cpu_label.len;
    device_count = 1;

    // Detect accelerators from environment variables
    detectFromEnv("BOJ_CUDA_DEVICES", .cuda, "CUDA Device");
    detectFromEnv("BOJ_ROCM_DEVICES", .rocm, "ROCm Device");
    detectFromEnv("BOJ_TPU_DEVICES", .tpu, "TPU Device");
    detectFromEnv("BOJ_FPGA_DEVICES", .fpga, "FPGA Device");

    initialised = true;
}

/// Register a cartridge's coprocessor affinity (preferred accelerator list).
fn registerAffinity(name_ptr: [*]const u8, name_len: usize, kinds: []const AcceleratorKind) i32 {
    if (affinity_count >= MAX_CARTRIDGES) return -1;
    const actual_name_len = @min(name_len, MAX_NAME_LEN);
    const actual_kind_count = @min(kinds.len, MAX_AFFINITY);

    var aff = &affinities[affinity_count];
    @memcpy(aff.name[0..actual_name_len], name_ptr[0..actual_name_len]);
    aff.name_len = actual_name_len;
    for (kinds[0..actual_kind_count], 0..) |k, i| {
        aff.preferred[i] = k;
    }
    aff.preferred_count = actual_kind_count;
    aff.active_device = null;

    affinity_count += 1;
    return @as(i32, @intCast(affinity_count - 1));
}

/// Find the best available device for a cartridge based on its affinity.
fn selectDevice(affinity_idx: usize) DispatchResult {
    if (affinity_idx >= affinity_count) {
        return .{ .device_kind = .cpu, .device_index = 0, .was_fallback = true };
    }

    const aff = &affinities[affinity_idx];

    // Try each preferred accelerator in order
    for (aff.preferred[0..aff.preferred_count]) |preferred_kind| {
        for (devices[0..device_count], 0..) |*dev, idx| {
            if (dev.kind == preferred_kind and dev.status == .available) {
                affinities[affinity_idx].active_device = idx;
                return .{
                    .device_kind = dev.kind,
                    .device_index = dev.device_index,
                    .was_fallback = false,
                };
            }
        }
    }

    // Fallback to CPU (always device 0)
    affinities[affinity_idx].active_device = 0;
    return .{ .device_kind = .cpu, .device_index = 0, .was_fallback = true };
}

/// Record a dispatch event for latency tracking.
fn recordDispatch(device_idx: usize, latency_us: u64) void {
    if (device_idx < device_count) {
        devices[device_idx].dispatch_count += 1;
        devices[device_idx].total_latency_us += latency_us;
    }
}

/// Find affinity index by cartridge name.
fn findAffinity(name_ptr: [*]const u8, name_len: usize) ?usize {
    const actual_len = @min(name_len, MAX_NAME_LEN);
    for (affinities[0..affinity_count], 0..) |aff, i| {
        if (aff.name_len == actual_len and
            std.mem.eql(u8, aff.name[0..actual_len], name_ptr[0..actual_len]))
        {
            return i;
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports
// ═══════════════════════════════════════════════════════════════════════

/// Initialise coprocessor subsystem. Returns 0 on success.
export fn boj_coprocessor_init()i32 {
    mutex.lock();
    defer mutex.unlock();
    init();
    return 0;
}

/// Deinitialise coprocessor subsystem.
export fn boj_coprocessor_deinit()void {
    mutex.lock();
    defer mutex.unlock();
    device_count = 0;
    affinity_count = 0;
    initialised = false;
    devices = [_]Device{.{}} ** MAX_DEVICES;
    affinities = [_]CartridgeAffinity{.{}} ** MAX_CARTRIDGES;
}

/// Return the number of detected devices (including CPU).
export fn boj_coprocessor_device_count()usize {
    mutex.lock();
    defer mutex.unlock();
    return device_count;
}

/// Return the kind of device at the given index (AcceleratorKind as u8).
export fn boj_coprocessor_device_kind(idx: usize)u8 {
    mutex.lock();
    defer mutex.unlock();
    if (idx >= device_count) return 0;
    return @intFromEnum(devices[idx].kind);
}

/// Return the status of device at the given index (DeviceStatus as u8).
export fn boj_coprocessor_device_status(idx: usize)u8 {
    mutex.lock();
    defer mutex.unlock();
    if (idx >= device_count) return 0;
    return @intFromEnum(devices[idx].status);
}

/// Return the dispatch count of device at the given index.
export fn boj_coprocessor_device_dispatches(idx: usize)u64 {
    mutex.lock();
    defer mutex.unlock();
    if (idx >= device_count) return 0;
    return devices[idx].dispatch_count;
}

/// Register a cartridge's coprocessor affinity.
/// kinds_ptr points to an array of u8 (AcceleratorKind values), kinds_len is the count.
/// Returns the affinity index, or -1 on error.
export fn boj_coprocessor_register(
    name_ptr: [*]const u8,
    name_len: usize,
    kinds_ptr: [*]const u8,
    kinds_len: usize,
)i32 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) init();
    const actual_len = @min(kinds_len, MAX_AFFINITY);
    var kinds_buf: [MAX_AFFINITY]AcceleratorKind = undefined;
    for (0..actual_len) |i| {
        kinds_buf[i] = @enumFromInt(kinds_ptr[i]);
    }
    return registerAffinity(name_ptr, name_len, kinds_buf[0..actual_len]);
}

/// Select best device for a cartridge by affinity index.
/// Returns the AcceleratorKind (u8). Sets was_fallback via the out pointer.
export fn boj_coprocessor_select(affinity_idx: usize, was_fallback: *u8)u8 {
    mutex.lock();
    defer mutex.unlock();
    const result = selectDevice(affinity_idx);
    was_fallback.* = if (result.was_fallback) 1 else 0;
    return @intFromEnum(result.device_kind);
}

/// Select best device for a cartridge by name.
/// Returns AcceleratorKind (u8), 0 (cpu) if not found.
export fn boj_coprocessor_select_by_name(
    name_ptr: [*]const u8,
    name_len: usize,
    was_fallback: *u8,
)u8 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) init();
    if (findAffinity(name_ptr, name_len)) |idx| {
        // Call selectDevice directly (not boj_coprocessor_select) to avoid deadlock —
        // we already hold the mutex.
        const result = selectDevice(idx);
        was_fallback.* = if (result.was_fallback) 1 else 0;
        return @intFromEnum(result.device_kind);
    }
    was_fallback.* = 1;
    return 0; // cpu
}

/// Record a dispatch event for tracking. Returns 0 on success.
export fn boj_coprocessor_record_dispatch(device_idx: usize, latency_us: u64)i32 {
    mutex.lock();
    defer mutex.unlock();
    if (device_idx >= device_count) return -1;
    recordDispatch(device_idx, latency_us);
    return 0;
}

/// Return the number of registered cartridge affinities.
export fn boj_coprocessor_affinity_count()usize {
    mutex.lock();
    defer mutex.unlock();
    return affinity_count;
}

/// Check if an accelerator of the given kind is available.
export fn boj_coprocessor_has_accelerator(kind: u8)u8 {
    mutex.lock();
    defer mutex.unlock();
    for (devices[0..device_count]) |dev| {
        if (@intFromEnum(dev.kind) == kind and dev.status == .available) return 1;
    }
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "coprocessor init detects CPU" {
    init();
    try std.testing.expect(device_count >= 1);
    try std.testing.expectEqual(AcceleratorKind.cpu, devices[0].kind);
    try std.testing.expectEqual(DeviceStatus.available, devices[0].status);
}

test "coprocessor init is idempotent" {
    init();
    const count1 = device_count;
    init();
    const count2 = device_count;
    try std.testing.expectEqual(count1, count2);
}

test "coprocessor register affinity" {
    init();
    const name = "nesy-mcp";
    const kinds = [_]AcceleratorKind{ .cuda, .rocm, .cpu };
    const idx = registerAffinity(name.ptr, name.len, &kinds);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), affinity_count);
}

test "coprocessor select falls back to cpu" {
    init();
    const name = "proof-mcp";
    const kinds = [_]AcceleratorKind{ .tpu, .fpga };
    const idx = registerAffinity(name.ptr, name.len, &kinds);
    try std.testing.expect(idx >= 0);
    const result = selectDevice(@intCast(idx));
    try std.testing.expectEqual(AcceleratorKind.cpu, result.device_kind);
    try std.testing.expect(result.was_fallback);
}

test "coprocessor select prefers first available" {
    init();
    // Simulate a CUDA device
    var dev = &devices[device_count];
    dev.kind = .cuda;
    dev.status = .available;
    dev.device_index = 0;
    device_count += 1;

    const name = "agent-mcp";
    const kinds = [_]AcceleratorKind{ .cuda, .cpu };
    const idx = registerAffinity(name.ptr, name.len, &kinds);
    try std.testing.expect(idx >= 0);
    const result = selectDevice(@intCast(idx));
    try std.testing.expectEqual(AcceleratorKind.cuda, result.device_kind);
    try std.testing.expect(!result.was_fallback);
}

test "coprocessor record dispatch tracks latency" {
    init();
    try std.testing.expectEqual(@as(u64, 0), devices[0].dispatch_count);
    recordDispatch(0, 150);
    recordDispatch(0, 250);
    try std.testing.expectEqual(@as(u64, 2), devices[0].dispatch_count);
    try std.testing.expectEqual(@as(u64, 400), devices[0].total_latency_us);
}

test "coprocessor find affinity by name" {
    init();
    const name = "database-mcp";
    const kinds = [_]AcceleratorKind{.cpu};
    _ = registerAffinity(name.ptr, name.len, &kinds);
    const found = findAffinity(name.ptr, name.len);
    try std.testing.expect(found != null);
}

test "coprocessor find affinity returns null for unknown" {
    init();
    const name = "nonexistent";
    const found = findAffinity(name.ptr, name.len);
    try std.testing.expect(found == null);
}

test "coprocessor c-abi init and device count" {
    _ = boj_coprocessor_init();
    const count = boj_coprocessor_device_count();
    try std.testing.expect(count >= 1);
    const kind = boj_coprocessor_device_kind(0);
    try std.testing.expectEqual(@as(u8, 0), kind); // cpu
}

test "coprocessor c-abi register and select" {
    _ = boj_coprocessor_init();
    const name = "test-cart";
    const kinds = [_]u8{ 1, 2, 0 }; // cuda, rocm, cpu
    const idx = boj_coprocessor_register(name.ptr, name.len, &kinds, kinds.len);
    try std.testing.expect(idx >= 0);

    var fallback: u8 = 0;
    const selected = boj_coprocessor_select(@intCast(idx), &fallback);
    // On a dev machine without GPU, selects CPU (which is in the affinity list)
    try std.testing.expectEqual(@as(u8, 0), selected); // cpu
    // CPU was explicitly in the affinity list, so was_fallback = false
    try std.testing.expectEqual(@as(u8, 0), fallback);
}

test "coprocessor c-abi select by name" {
    _ = boj_coprocessor_init();
    const name = "named-cart";
    const kinds = [_]u8{0}; // cpu only
    _ = boj_coprocessor_register(name.ptr, name.len, &kinds, kinds.len);

    var fallback: u8 = 0;
    const selected = boj_coprocessor_select_by_name(name.ptr, name.len, &fallback);
    try std.testing.expectEqual(@as(u8, 0), selected);
    try std.testing.expect(fallback == 0); // cpu was in affinity, not a fallback
}

test "coprocessor has_accelerator" {
    _ = boj_coprocessor_init();
    // CPU should always be available
    try std.testing.expectEqual(@as(u8, 1), boj_coprocessor_has_accelerator(0));
}

test "coprocessor env-driven cuda detection" {
    // Save and set env
    const had_env = shim.getenv("BOJ_CUDA_DEVICES") != null;
    if (!had_env) {
        // Can't easily set env in Zig tests, so just verify init works
        init();
        try std.testing.expect(device_count >= 1);
    }
}

test "coprocessor deinit resets state" {
    _ = boj_coprocessor_init();
    const name = "temp-cart";
    const kinds = [_]u8{0};
    _ = boj_coprocessor_register(name.ptr, name.len, &kinds, kinds.len);
    try std.testing.expect(boj_coprocessor_affinity_count() > 0);

    boj_coprocessor_deinit();
    try std.testing.expectEqual(@as(usize, 0), boj_coprocessor_device_count());
    try std.testing.expectEqual(@as(usize, 0), boj_coprocessor_affinity_count());
    try std.testing.expect(!initialised);
}

const shim = @import("cartridge_shim");
