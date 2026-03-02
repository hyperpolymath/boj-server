// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Catalogue FFI — C-compatible bridge between Idris2 proofs and runtime.
//
// This module provides the native execution layer for the catalogue.
// The Idris2 ABI defines WHAT is safe (via IsUnbreakable proofs);
// this Zig layer executes HOW to mount/unmount cartridges safely.
//
// Key invariant: A cartridge can only be mounted if its status
// integer is 1 (Ready), matching the Idris2 IsUnbreakable proof.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match src/abi/Catalogue.idr encodings)
// ═══════════════════════════════════════════════════════════════════════

/// Cartridge status (matches Idris2 statusToInt encoding).
pub const CartridgeStatus = enum(c_int) {
    development = 0,
    ready = 1,
    deprecated = 2,
    faulty = 3,
};

/// Protocol type (matches Idris2 protocolToInt encoding).
pub const ProtocolType = enum(c_int) {
    mcp = 1,
    lsp = 2,
    dap = 3,
    bsp = 4,
    nesy = 5,
    agentic = 6,
    fleet = 7,
    grpc = 8,
    rest = 9,
};

/// Capability domain (matches Idris2 domainToInt encoding).
pub const CapabilityDomain = enum(c_int) {
    cloud = 1,
    container = 2,
    database = 3,
    k8s = 4,
    git = 5,
    secrets = 6,
    queues = 7,
    iac = 8,
    observe = 9,
    ssg = 10,
    proof = 11,
    fleet_dom = 12,
    nesy_dom = 13,
};

/// Menu tier (Teranga/Shield/Ayo).
pub const MenuTier = enum(c_int) {
    teranga = 0,
    shield = 1,
    ayo = 2,
};

/// Maximum cartridges that can be registered.
const MAX_CARTRIDGES: usize = 128;

/// Maximum cartridges per order.
const MAX_ORDER_SIZE: usize = 16;

// ═══════════════════════════════════════════════════════════════════════
// Cartridge Registry
// ═══════════════════════════════════════════════════════════════════════

/// A registered cartridge in the catalogue.
const CartridgeEntry = struct {
    name: [64]u8,
    name_len: usize,
    version: [16]u8,
    version_len: usize,
    status: CartridgeStatus,
    tier: MenuTier,
    domain: CapabilityDomain,
    protocols: [9]bool, // indexed by ProtocolType int value - 1
    binary_hash: [64]u8,
    hash_len: usize,
    mounted: bool,
};

/// Global catalogue state.
var catalogue: [MAX_CARTRIDGES]CartridgeEntry = undefined;
var catalogue_count: usize = 0;
var initialised: bool = false;

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the catalogue. Must be called before any other function.
export fn boj_catalogue_init() c_int {
    catalogue_count = 0;
    for (&catalogue) |*entry| {
        entry.mounted = false;
        entry.name_len = 0;
        entry.version_len = 0;
        entry.hash_len = 0;
        entry.status = .development;
        entry.protocols = .{ false, false, false, false, false, false, false, false, false };
    }
    initialised = true;
    return 0;
}

/// Shut down the catalogue. Unmounts all cartridges.
export fn boj_catalogue_deinit() void {
    for (&catalogue) |*entry| {
        entry.mounted = false;
    }
    catalogue_count = 0;
    initialised = false;
}

// ═══════════════════════════════════════════════════════════════════════
// Registration
// ═══════════════════════════════════════════════════════════════════════

/// Register a cartridge in the catalogue.
/// Returns 0 on success, -1 on failure.
export fn boj_catalogue_register(
    name_ptr: [*]const u8,
    name_len: usize,
    version_ptr: [*]const u8,
    version_len: usize,
    status: c_int,
    tier: c_int,
    domain: c_int,
) c_int {
    if (!initialised) return -1;
    if (catalogue_count >= MAX_CARTRIDGES) return -1;
    if (name_len > 64 or version_len > 16) return -1;

    var entry = &catalogue[catalogue_count];
    @memcpy(entry.name[0..name_len], name_ptr[0..name_len]);
    entry.name_len = name_len;
    @memcpy(entry.version[0..version_len], version_ptr[0..version_len]);
    entry.version_len = version_len;
    entry.status = @enumFromInt(status);
    entry.tier = @enumFromInt(tier);
    entry.domain = @enumFromInt(domain);
    entry.mounted = false;
    entry.protocols = .{ false, false, false, false, false, false, false, false, false };
    entry.hash_len = 0;

    catalogue_count += 1;
    return 0;
}

/// Add a protocol to the last registered cartridge.
export fn boj_catalogue_add_protocol(protocol: c_int) c_int {
    if (!initialised or catalogue_count == 0) return -1;
    if (protocol < 1 or protocol > 9) return -1;
    catalogue[catalogue_count - 1].protocols[@as(usize, @intCast(protocol)) - 1] = true;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Mount / Unmount (the core safety gate)
// ═══════════════════════════════════════════════════════════════════════

/// Mount a cartridge by index.
/// SAFETY: Only mounts if status == Ready (matching IsUnbreakable proof).
/// Returns 0 on success, -1 if not ready, -2 if not found.
export fn boj_catalogue_mount(index: usize) c_int {
    if (!initialised or index >= catalogue_count) return -2;
    if (catalogue[index].status != .ready) return -1;
    catalogue[index].mounted = true;
    return 0;
}

/// Unmount a cartridge by index.
export fn boj_catalogue_unmount(index: usize) c_int {
    if (!initialised or index >= catalogue_count) return -2;
    catalogue[index].mounted = false;
    return 0;
}

/// Check if a cartridge is mounted.
export fn boj_catalogue_is_mounted(index: usize) c_int {
    if (!initialised or index >= catalogue_count) return -1;
    return if (catalogue[index].mounted) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════

/// Get the total number of registered cartridges.
export fn boj_catalogue_count() usize {
    return catalogue_count;
}

/// Get the number of ready cartridges.
export fn boj_catalogue_count_ready() usize {
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.status == .ready) count += 1;
    }
    return count;
}

/// Get the number of mounted cartridges.
export fn boj_catalogue_count_mounted() usize {
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.mounted) count += 1;
    }
    return count;
}

/// Get the status of a cartridge by index.
export fn boj_catalogue_status(index: usize) c_int {
    if (index >= catalogue_count) return -1;
    return @intFromEnum(catalogue[index].status);
}

/// Get the version string.
export fn boj_catalogue_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "lifecycle" {
    try std.testing.expectEqual(@as(c_int, 0), boj_catalogue_init());
    try std.testing.expectEqual(@as(usize, 0), boj_catalogue_count());
    boj_catalogue_deinit();
}

test "register and mount" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "test-cartridge";
    const ver = "1.0.0";
    const result = boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1, // ready
        0, // teranga
        3, // database
    );
    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expectEqual(@as(usize, 1), boj_catalogue_count());

    // Mount should succeed (status = ready)
    try std.testing.expectEqual(@as(c_int, 0), boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), boj_catalogue_is_mounted(0));
}

test "cannot mount development cartridge" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "dev-cartridge";
    const ver = "0.1.0";
    _ = boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 0, 0, 1);

    // Mount should fail (status = development, not ready)
    try std.testing.expectEqual(@as(c_int, -1), boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 0), boj_catalogue_is_mounted(0));
}

test "cannot mount faulty cartridge" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "bad-cartridge";
    const ver = "0.1.0";
    _ = boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 3, 0, 1);

    // Mount should fail (status = faulty)
    try std.testing.expectEqual(@as(c_int, -1), boj_catalogue_mount(0));
}
