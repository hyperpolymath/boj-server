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
    agent = 14,
    lsp = 15,
    dap = 16,
    bsp = 17,
    code_intel = 18,
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
///
/// The `backend` field is the optional third axis of the capability matrix.
/// It defaults to "universal" for cartridges that are provider-agnostic.
/// Community extensions can specialise it (e.g. "postgresql", "podman", "aws")
/// to target a specific backend without modifying core infrastructure.
/// See docs/EXTENSIBILITY.md for the rationale and extension mechanism.
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
    backend: [32]u8,    // "universal" or provider-specific label
    backend_len: usize,
};

/// Global catalogue state.
var catalogue: [MAX_CARTRIDGES]CartridgeEntry = undefined;
var catalogue_count: usize = 0;
var initialised: bool = false;

/// Thread-safety mutex — protects all global state in this module.
/// Every C-ABI export acquires this before touching globals.
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the catalogue. Must be called before any other function.
pub export fn boj_catalogue_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    catalogue_count = 0;
    const universal = "universal";
    for (&catalogue) |*entry| {
        entry.mounted = false;
        entry.name_len = 0;
        entry.version_len = 0;
        entry.hash_len = 0;
        entry.status = .development;
        entry.protocols = .{ false, false, false, false, false, false, false, false, false };
        @memcpy(entry.backend[0..universal.len], universal);
        entry.backend_len = universal.len;
    }
    initialised = true;
    return 0;
}

/// Shut down the catalogue. Unmounts all cartridges.
pub export fn boj_catalogue_deinit() void {
    mutex.lock();
    defer mutex.unlock();
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
pub export fn boj_catalogue_register(
    name_ptr: [*]const u8,
    name_len: usize,
    version_ptr: [*]const u8,
    version_len: usize,
    status: c_int,
    tier: c_int,
    domain: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
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
    const universal = "universal";
    @memcpy(entry.backend[0..universal.len], universal);
    entry.backend_len = universal.len;

    catalogue_count += 1;
    return 0;
}

/// Add a protocol to the last registered cartridge.
pub export fn boj_catalogue_add_protocol(protocol: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or catalogue_count == 0) return -1;
    if (protocol < 1 or protocol > 9) return -1;
    catalogue[catalogue_count - 1].protocols[@as(usize, @intCast(protocol)) - 1] = true;
    return 0;
}

/// Set the backend for the last registered cartridge.
/// Defaults to "universal" if never called.
/// This is the third-axis extension point (see docs/EXTENSIBILITY.md).
pub export fn boj_catalogue_set_backend(backend_ptr: [*]const u8, backend_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or catalogue_count == 0) return -1;
    if (backend_len > 32) return -1;
    @memcpy(catalogue[catalogue_count - 1].backend[0..backend_len], backend_ptr[0..backend_len]);
    catalogue[catalogue_count - 1].backend_len = backend_len;
    return 0;
}

/// Get the backend label for a cartridge by index.
/// Copies into out_ptr, returns length (or 0 on error).
pub export fn boj_menu_backend(index: usize, out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return 0;
    const len = @min(catalogue[index].backend_len, out_len);
    @memcpy(out_ptr[0..len], catalogue[index].backend[0..len]);
    return len;
}

// ═══════════════════════════════════════════════════════════════════════
// Mount / Unmount (the core safety gate)
// ═══════════════════════════════════════════════════════════════════════

/// Mount a cartridge by index.
/// SAFETY: Only mounts if status == Ready (matching IsUnbreakable proof).
/// Returns 0 on success, -1 if not ready, -2 if not found.
pub export fn boj_catalogue_mount(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -2;
    if (catalogue[index].status != .ready) return -1;
    catalogue[index].mounted = true;
    return 0;
}

/// Unmount a cartridge by index.
pub export fn boj_catalogue_unmount(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -2;
    catalogue[index].mounted = false;
    return 0;
}

/// Check if a cartridge is mounted.
pub export fn boj_catalogue_is_mounted(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    return if (catalogue[index].mounted) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════

/// Get the total number of registered cartridges.
pub export fn boj_catalogue_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return catalogue_count;
}

/// Get the number of ready cartridges.
pub export fn boj_catalogue_count_ready() usize {
    mutex.lock();
    defer mutex.unlock();
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.status == .ready) count += 1;
    }
    return count;
}

/// Get the number of mounted cartridges.
pub export fn boj_catalogue_count_mounted() usize {
    mutex.lock();
    defer mutex.unlock();
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.mounted) count += 1;
    }
    return count;
}

/// Get the status of a cartridge by index.
pub export fn boj_catalogue_status(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (index >= catalogue_count) return -1;
    return @intFromEnum(catalogue[index].status);
}

/// Set the binary hash for a cartridge by index.
/// hash_ptr: pointer to hex string. hash_len: must be <= 64.
/// Returns 0 on success, -1 on failure.
pub export fn boj_catalogue_set_hash(index: usize, hash_ptr: [*]const u8, hash_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    if (hash_len > 64) return -1;
    @memcpy(catalogue[index].binary_hash[0..hash_len], hash_ptr[0..hash_len]);
    catalogue[index].hash_len = hash_len;
    return 0;
}

/// Get the binary hash for a cartridge by index.
/// Writes the hash into out_ptr, returns the hash length (0 if no hash set).
pub export fn boj_catalogue_get_hash(index: usize, out_ptr: [*]u8) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return 0;
    const len = catalogue[index].hash_len;
    if (len > 0) {
        @memcpy(out_ptr[0..len], catalogue[index].binary_hash[0..len]);
    }
    return len;
}

/// Get the version string.
pub export fn boj_catalogue_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Teranga Menu Discovery
// ═══════════════════════════════════════════════════════════════════════
//
// These exports implement the Teranga menu discovery protocol (matching
// the Idris2 Boj.Menu ABI). AI agents use these to discover what
// cartridges are available, their capabilities, and whether they can
// be mounted.

/// Get the name of a cartridge by index. Copies into out_ptr.
/// Returns the name length, or 0 if index is invalid.
pub export fn boj_menu_name(index: usize, out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return 0;
    const len = @min(catalogue[index].name_len, out_len);
    @memcpy(out_ptr[0..len], catalogue[index].name[0..len]);
    return len;
}

/// Get the version of a cartridge by index. Copies into out_ptr.
/// Returns the version length, or 0 if index is invalid.
pub export fn boj_menu_version(index: usize, out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return 0;
    const len = @min(catalogue[index].version_len, out_len);
    @memcpy(out_ptr[0..len], catalogue[index].version[0..len]);
    return len;
}

/// Get the tier of a cartridge by index.
/// Returns 0=Teranga, 1=Shield, 2=Ayo, or -1 on error.
pub export fn boj_menu_tier(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    return @intFromEnum(catalogue[index].tier);
}

/// Get the domain of a cartridge by index.
/// Returns the domain integer (1-18), or -1 on error.
pub export fn boj_menu_domain(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    return @intFromEnum(catalogue[index].domain);
}

/// Check if a cartridge supports a given protocol.
/// Returns 1 if supported, 0 if not, -1 on error.
pub export fn boj_menu_has_protocol(index: usize, protocol: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    if (protocol < 1 or protocol > 9) return -1;
    return if (catalogue[index].protocols[@as(usize, @intCast(protocol)) - 1]) 1 else 0;
}

/// Check if a cartridge is available (status == Ready).
/// Returns 1 if available, 0 if not, -1 on error.
pub export fn boj_menu_available(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= catalogue_count) return -1;
    return if (catalogue[index].status == .ready) 1 else 0;
}

/// Count cartridges by tier.
pub export fn boj_menu_count_by_tier(tier_int: c_int) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;
    const tier: MenuTier = @enumFromInt(tier_int);
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.tier == tier) count += 1;
    }
    return count;
}

/// Count available (Ready) cartridges by tier.
pub export fn boj_menu_count_available_by_tier(tier_int: c_int) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;
    const tier: MenuTier = @enumFromInt(tier_int);
    var count: usize = 0;
    for (catalogue[0..catalogue_count]) |entry| {
        if (entry.tier == tier and entry.status == .ready) count += 1;
    }
    return count;
}

/// Validate an order ticket — given an array of cartridge names, returns
/// how many can be mounted (status == Ready). This matches the Idris2
/// validateOrder function.
pub export fn boj_menu_validate_order(
    name_ptrs: [*]const [*]const u8,
    name_lens: [*]const usize,
    count: usize,
) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;
    if (count > MAX_ORDER_SIZE) return 0;

    var satisfied: usize = 0;
    for (0..count) |i| {
        const req_name = name_ptrs[i][0..name_lens[i]];
        for (catalogue[0..catalogue_count]) |entry| {
            if (entry.name_len == req_name.len and
                std.mem.eql(u8, entry.name[0..entry.name_len], req_name) and
                entry.status == .ready)
            {
                satisfied += 1;
                break;
            }
        }
    }
    return satisfied;
}

/// Generate a JSON-formatted menu string into out_buf.
/// Returns the number of bytes written, or 0 on error.
/// This is the primary discovery endpoint for AI agents.
pub export fn boj_menu_json(out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;

    const tier_labels = [_][]const u8{ "teranga", "shield", "ayo" };
    const proto_labels = [_][]const u8{ "mcp", "lsp", "dap", "bsp", "nesy", "agentic", "fleet", "grpc", "rest" };
    const status_labels = [_][]const u8{ "development", "ready", "deprecated", "faulty" };

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    // Opening.
    const header = "{\"menu\":\"teranga\",\"version\":\"0.1.0\",\"cartridges\":[";
    if (pos + header.len > buf.len) return 0;
    @memcpy(buf[pos..][0..header.len], header);
    pos += header.len;

    for (catalogue[0..catalogue_count], 0..) |entry, idx| {
        if (idx > 0) {
            buf[pos] = ',';
            pos += 1;
        }

        // Build entry JSON manually (no allocator needed).
        // {"name":"...","version":"...","tier":"...","status":"...","available":true/false,"protocols":["..."]}
        const prefix = "{\"name\":\"";
        @memcpy(buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;

        @memcpy(buf[pos..][0..entry.name_len], entry.name[0..entry.name_len]);
        pos += entry.name_len;

        const mid1 = "\",\"version\":\"";
        @memcpy(buf[pos..][0..mid1.len], mid1);
        pos += mid1.len;

        @memcpy(buf[pos..][0..entry.version_len], entry.version[0..entry.version_len]);
        pos += entry.version_len;

        const mid2 = "\",\"tier\":\"";
        @memcpy(buf[pos..][0..mid2.len], mid2);
        pos += mid2.len;

        const tier_label = tier_labels[@as(usize, @intCast(@intFromEnum(entry.tier)))];
        @memcpy(buf[pos..][0..tier_label.len], tier_label);
        pos += tier_label.len;

        const mid3 = "\",\"status\":\"";
        @memcpy(buf[pos..][0..mid3.len], mid3);
        pos += mid3.len;

        const status_label = status_labels[@as(usize, @intCast(@intFromEnum(entry.status)))];
        @memcpy(buf[pos..][0..status_label.len], status_label);
        pos += status_label.len;

        const mid_backend = "\",\"backend\":\"";
        @memcpy(buf[pos..][0..mid_backend.len], mid_backend);
        pos += mid_backend.len;

        @memcpy(buf[pos..][0..entry.backend_len], entry.backend[0..entry.backend_len]);
        pos += entry.backend_len;

        const mid4 = if (entry.status == .ready)
            "\",\"available\":true,\"protocols\":["
        else
            "\",\"available\":false,\"protocols\":[";
        @memcpy(buf[pos..][0..mid4.len], mid4);
        pos += mid4.len;

        // Protocols array.
        var first_proto = true;
        for (entry.protocols, 0..) |has, pi| {
            if (has) {
                if (!first_proto) {
                    buf[pos] = ',';
                    pos += 1;
                }
                buf[pos] = '"';
                pos += 1;
                const pl = proto_labels[pi];
                @memcpy(buf[pos..][0..pl.len], pl);
                pos += pl.len;
                buf[pos] = '"';
                pos += 1;
                first_proto = false;
            }
        }

        const suffix = "]}";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }

    // Closing.
    const footer = "]}";
    @memcpy(buf[pos..][0..footer.len], footer);
    pos += footer.len;

    // Copy to output buffer.
    const write_len = @min(pos, out_len);
    @memcpy(out_ptr[0..write_len], buf[0..write_len]);
    return write_len;
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

// ═══════════════════════════════════════════════════════════════════════
// Teranga Menu Discovery Tests
// ═══════════════════════════════════════════════════════════════════════

test "menu name and version query" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "database-mcp";
    const ver = "0.2.0";
    _ = boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    var name_buf: [64]u8 = undefined;
    const nlen = boj_menu_name(0, &name_buf, 64);
    try std.testing.expectEqual(name.len, nlen);
    try std.testing.expectEqualSlices(u8, name, name_buf[0..nlen]);

    var ver_buf: [16]u8 = undefined;
    const vlen = boj_menu_version(0, &ver_buf, 16);
    try std.testing.expectEqual(ver.len, vlen);
    try std.testing.expectEqualSlices(u8, ver, ver_buf[0..vlen]);
}

test "menu tier and domain query" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "fleet-mcp";
    const ver = "0.1.0";
    _ = boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 12); // teranga, fleet domain

    try std.testing.expectEqual(@as(c_int, 0), boj_menu_tier(0));   // teranga
    try std.testing.expectEqual(@as(c_int, 12), boj_menu_domain(0)); // fleet
}

test "menu protocol check" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "nesy-mcp";
    const ver = "0.2.0";
    _ = boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 13);
    _ = boj_catalogue_add_protocol(1); // MCP
    _ = boj_catalogue_add_protocol(5); // NeSy
    _ = boj_catalogue_add_protocol(8); // gRPC

    try std.testing.expectEqual(@as(c_int, 1), boj_menu_has_protocol(0, 1)); // MCP
    try std.testing.expectEqual(@as(c_int, 1), boj_menu_has_protocol(0, 5)); // NeSy
    try std.testing.expectEqual(@as(c_int, 1), boj_menu_has_protocol(0, 8)); // gRPC
    try std.testing.expectEqual(@as(c_int, 0), boj_menu_has_protocol(0, 2)); // LSP - not set
}

test "menu availability check" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const ready = "ready-cart";
    _ = boj_catalogue_register(ready.ptr, ready.len, "1.0".ptr, 3, 1, 0, 1); // ready
    const dev = "dev-cart";
    _ = boj_catalogue_register(dev.ptr, dev.len, "0.1".ptr, 3, 0, 0, 2); // development

    try std.testing.expectEqual(@as(c_int, 1), boj_menu_available(0)); // ready
    try std.testing.expectEqual(@as(c_int, 0), boj_menu_available(1)); // development
}

test "menu count by tier" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    // 2 teranga, 1 shield
    _ = boj_catalogue_register("t1".ptr, 2, "1.0".ptr, 3, 1, 0, 1);
    _ = boj_catalogue_register("t2".ptr, 2, "1.0".ptr, 3, 0, 0, 2);
    _ = boj_catalogue_register("s1".ptr, 2, "1.0".ptr, 3, 1, 1, 6);

    try std.testing.expectEqual(@as(usize, 2), boj_menu_count_by_tier(0)); // teranga
    try std.testing.expectEqual(@as(usize, 1), boj_menu_count_by_tier(1)); // shield
    try std.testing.expectEqual(@as(usize, 0), boj_menu_count_by_tier(2)); // ayo

    // Available by tier
    try std.testing.expectEqual(@as(usize, 1), boj_menu_count_available_by_tier(0)); // 1 of 2 teranga ready
    try std.testing.expectEqual(@as(usize, 1), boj_menu_count_available_by_tier(1)); // shield ready
}

test "menu validate order" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    _ = boj_catalogue_register("database-mcp".ptr, 12, "0.1.0".ptr, 5, 1, 0, 3); // ready
    _ = boj_catalogue_register("fleet-mcp".ptr, 9, "0.1.0".ptr, 5, 1, 0, 12);    // ready
    _ = boj_catalogue_register("nesy-mcp".ptr, 8, "0.1.0".ptr, 5, 0, 0, 13);     // development

    // Order for database-mcp and fleet-mcp (both ready)
    const names = [_][*]const u8{ "database-mcp", "fleet-mcp" };
    const lens = [_]usize{ 12, 9 };
    try std.testing.expectEqual(@as(usize, 2), boj_menu_validate_order(&names, &lens, 2));

    // Order including nesy-mcp (not ready)
    const names2 = [_][*]const u8{ "database-mcp", "nesy-mcp" };
    const lens2 = [_]usize{ 12, 8 };
    try std.testing.expectEqual(@as(usize, 1), boj_menu_validate_order(&names2, &lens2, 2));

    // Order for nonexistent cartridge
    const names3 = [_][*]const u8{"phantom-mcp"};
    const lens3 = [_]usize{11};
    try std.testing.expectEqual(@as(usize, 0), boj_menu_validate_order(&names3, &lens3, 1));
}

test "backend defaults to universal" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "db-universal";
    _ = boj_catalogue_register(name.ptr, name.len, "1.0".ptr, 3, 1, 0, 3);

    var buf: [32]u8 = undefined;
    const len = boj_menu_backend(0, &buf, 32);
    try std.testing.expectEqualSlices(u8, "universal", buf[0..len]);
}

test "backend can be specialised" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    const name = "db-postgres";
    _ = boj_catalogue_register(name.ptr, name.len, "1.0".ptr, 3, 2, 0, 3); // ayo tier
    const pg = "postgresql";
    _ = boj_catalogue_set_backend(pg.ptr, pg.len);

    var buf: [32]u8 = undefined;
    const len = boj_menu_backend(0, &buf, 32);
    try std.testing.expectEqualSlices(u8, "postgresql", buf[0..len]);
}

test "menu JSON generation" {
    _ = boj_catalogue_init();
    defer boj_catalogue_deinit();

    _ = boj_catalogue_register("database-mcp".ptr, 12, "0.1.0".ptr, 5, 1, 0, 3);
    _ = boj_catalogue_add_protocol(1); // MCP
    _ = boj_catalogue_add_protocol(9); // REST

    var buf: [4096]u8 = undefined;
    const len = boj_menu_json(&buf, 4096);
    try std.testing.expect(len > 0);

    const json = buf[0..len];
    // Verify structural elements are present.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"menu\":\"teranga\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"database-mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"backend\":\"universal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rest\"") != null);
}
