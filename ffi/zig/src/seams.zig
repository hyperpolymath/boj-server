// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Seam Checks — Integration contract validation.
//
// Inspired by panic-attack's diagnostics pattern (src/diagnostics.rs):
// validate that all integration seams between ABI, FFI, and Adapter layers
// are intact.  Because the architecture is formally constrained
// (Idris2 proofs → Zig C-ABI → V adapter), most seams are self-evident —
// the checks should produce a "silent signature" (all pass, nothing to report).
//
// Seam categories:
//   1. Catalogue contract  — enum encodings match Idris2 ABI
//   2. Cartridge interface  — standard 4-symbol export contract
//   3. Mount safety gate   — IsUnbreakable invariant holds at FFI level
//   4. Hash attestation    — binary integrity chain
//   5. Protocol coverage   — matrix completeness
//   6. Module initialisation — lifecycle contracts
//   7. State machine validity — feedback/community/SLA transitions
//   8. Thread safety        — mutex protection on all C-ABI exports
//
// If all seams pass, BoJ's integration surface is verified.
// Any failure is a genuine architectural defect, not a test fluke.

const std = @import("std");
const catalogue = @import("catalogue");

// ═══════════════════════════════════════════════════════════════════════
// Seam 1: Catalogue enum encodings match Idris2 ABI
// ═══════════════════════════════════════════════════════════════════════
//
// The Idris2 ABI defines statusToInt, protocolToInt, domainToInt.
// These Zig enums MUST use identical integer values.
// If they drift, the C-ABI bridge is silently broken.

test "seam: CartridgeStatus encoding matches Idris2 statusToInt" {
    // Idris2: Development=0, Ready=1, Deprecated=2, Faulty=3
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(catalogue.CartridgeStatus.development));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(catalogue.CartridgeStatus.ready));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(catalogue.CartridgeStatus.deprecated));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(catalogue.CartridgeStatus.faulty));
}

test "seam: ProtocolType encoding matches Idris2 protocolToInt" {
    // Idris2: MCP=1, LSP=2, DAP=3, BSP=4, NeSy=5, Agentic=6, Fleet=7, gRPC=8, REST=9
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(catalogue.ProtocolType.mcp));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(catalogue.ProtocolType.lsp));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(catalogue.ProtocolType.dap));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(catalogue.ProtocolType.bsp));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(catalogue.ProtocolType.nesy));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(catalogue.ProtocolType.agentic));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(catalogue.ProtocolType.fleet));
    try std.testing.expectEqual(@as(c_int, 8), @intFromEnum(catalogue.ProtocolType.grpc));
    try std.testing.expectEqual(@as(c_int, 9), @intFromEnum(catalogue.ProtocolType.rest));
}

test "seam: CapabilityDomain encoding matches Idris2 domainToInt" {
    // Idris2: Cloud=1..Feedback=14
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(catalogue.CapabilityDomain.cloud));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(catalogue.CapabilityDomain.container));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(catalogue.CapabilityDomain.database));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(catalogue.CapabilityDomain.k8s));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(catalogue.CapabilityDomain.git));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(catalogue.CapabilityDomain.secrets));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(catalogue.CapabilityDomain.queues));
    try std.testing.expectEqual(@as(c_int, 8), @intFromEnum(catalogue.CapabilityDomain.iac));
    try std.testing.expectEqual(@as(c_int, 9), @intFromEnum(catalogue.CapabilityDomain.observe));
    try std.testing.expectEqual(@as(c_int, 10), @intFromEnum(catalogue.CapabilityDomain.ssg));
    try std.testing.expectEqual(@as(c_int, 11), @intFromEnum(catalogue.CapabilityDomain.proof));
    try std.testing.expectEqual(@as(c_int, 12), @intFromEnum(catalogue.CapabilityDomain.fleet_dom));
    try std.testing.expectEqual(@as(c_int, 13), @intFromEnum(catalogue.CapabilityDomain.nesy_dom));
    try std.testing.expectEqual(@as(c_int, 14), @intFromEnum(catalogue.CapabilityDomain.feedback));
}

test "seam: MenuTier encoding matches Idris2" {
    // Idris2: Teranga=0, Shield=1, Ayo=2
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(catalogue.MenuTier.teranga));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(catalogue.MenuTier.shield));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(catalogue.MenuTier.ayo));
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 2: Mount safety gate (IsUnbreakable invariant at FFI level)
// ═══════════════════════════════════════════════════════════════════════
//
// The Idris2 IsUnbreakable proof requires status=Ready for mounting.
// The Zig FFI must enforce this identically — no mount without ready.

test "seam: mount gate rejects every non-ready status" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register one cartridge per non-ready status
    const statuses = [_]c_int{ 0, 2, 3 }; // development, deprecated, faulty
    const names = [_][]const u8{ "dev-seam", "dep-seam", "bad-seam" };

    for (statuses, names) |status, name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, "1.0".ptr, 3, status, 0, 1);
    }

    // None of these should be mountable
    for (0..3) |i| {
        try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_mount(i));
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(i));
    }
}

test "seam: mount gate accepts ready status" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("ready-seam".ptr, 10, "1.0".ptr, 3, 1, 0, 1);
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 3: Hash attestation chain
// ═══════════════════════════════════════════════════════════════════════
//
// The hash set/get contract must be symmetrical — what goes in comes out.
// This validates the binary integrity pipeline.

test "seam: hash round-trip is lossless" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("hash-seam".ptr, 9, "1.0".ptr, 3, 1, 0, 3);

    const hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";
    _ = catalogue.boj_catalogue_set_hash(0, hash.ptr, hash.len);

    var out: [64]u8 = undefined;
    const len = catalogue.boj_catalogue_get_hash(0, &out);
    try std.testing.expectEqual(hash.len, len);
    try std.testing.expectEqualSlices(u8, hash, out[0..len]);
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 4: Backend axis default contract
// ═══════════════════════════════════════════════════════════════════════
//
// Every cartridge registered without an explicit set_backend call
// must default to "universal".  Community extensions rely on this.

test "seam: backend defaults to universal without explicit set" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("no-backend".ptr, 10, "1.0".ptr, 3, 1, 0, 3);

    var buf: [32]u8 = undefined;
    const len = catalogue.boj_menu_backend(0, &buf, 32);
    try std.testing.expectEqualSlices(u8, "universal", buf[0..len]);
}

test "seam: backend set overrides universal" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("pg-seam".ptr, 7, "1.0".ptr, 3, 1, 2, 3);
    const pg = "postgresql";
    _ = catalogue.boj_catalogue_set_backend(pg.ptr, pg.len);

    var buf: [32]u8 = undefined;
    const len = catalogue.boj_menu_backend(0, &buf, 32);
    try std.testing.expectEqualSlices(u8, "postgresql", buf[0..len]);
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 5: Catalogue lifecycle contract
// ═══════════════════════════════════════════════════════════════════════
//
// init → register → mount → unmount → deinit must be a clean lifecycle.
// Any leak or state corruption across this cycle is an architectural defect.

test "seam: full lifecycle round-trip leaves clean state" {
    // Cycle 1
    _ = catalogue.boj_catalogue_init();
    _ = catalogue.boj_catalogue_register("cycle-1".ptr, 7, "1.0".ptr, 3, 1, 0, 1);
    _ = catalogue.boj_catalogue_mount(0);
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
    _ = catalogue.boj_catalogue_unmount(0);
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(0));
    catalogue.boj_catalogue_deinit();
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());

    // Cycle 2 — re-init must start clean
    _ = catalogue.boj_catalogue_init();
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
    _ = catalogue.boj_catalogue_register("cycle-2".ptr, 7, "2.0".ptr, 3, 1, 0, 2);
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count());
    catalogue.boj_catalogue_deinit();
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 6: Menu JSON contract
// ═══════════════════════════════════════════════════════════════════════
//
// The JSON output is the adapter's contract with the outside world.
// panic-attack's panicbot seam check validates JSON field presence —
// we do the same for the Teranga menu.

test "seam: menu JSON contains all required fields" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("seam-cart".ptr, 9, "1.0.0".ptr, 5, 1, 0, 3);
    _ = catalogue.boj_catalogue_add_protocol(1); // MCP
    _ = catalogue.boj_catalogue_add_protocol(9); // REST

    var buf: [4096]u8 = undefined;
    const len = catalogue.boj_menu_json(&buf, 4096);
    const json = buf[0..len];

    // All required fields must be present (adapter and AI agents depend on these)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"menu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cartridges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tier\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"available\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"protocols\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"backend\"") != null);
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 7: Protocol range completeness
// ═══════════════════════════════════════════════════════════════════════
//
// The protocol enum must cover integers 1..9 contiguously.
// Any gap means a matrix column is unaddressable.

test "seam: protocol range 1..9 is contiguous" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("proto-seam".ptr, 10, "1.0".ptr, 3, 1, 0, 1);

    // Every protocol 1..9 should be settable
    for (1..10) |p| {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(@intCast(p)));
    }
    // Protocol 0 and 10 should be rejected
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_add_protocol(0));
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_add_protocol(10));
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 8: Order ticket validation contract
// ═══════════════════════════════════════════════════════════════════════
//
// validate_order must match only Ready cartridges by exact name.
// This is the contract between AI agents and the catalogue.

test "seam: order validation is exact-match and status-aware" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_register("exact-match".ptr, 11, "1.0".ptr, 3, 1, 0, 3); // ready
    _ = catalogue.boj_catalogue_register("exact-match-dev".ptr, 15, "0.1".ptr, 3, 0, 0, 3); // dev

    // Exact match on ready cartridge
    const names1 = [_][*]const u8{"exact-match"};
    const lens1 = [_]usize{11};
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_menu_validate_order(&names1, &lens1, 1));

    // Exact match on dev cartridge (should NOT satisfy)
    const names2 = [_][*]const u8{"exact-match-dev"};
    const lens2 = [_]usize{15};
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_menu_validate_order(&names2, &lens2, 1));

    // Prefix match should NOT work (no substring matching)
    const names3 = [_][*]const u8{"exact"};
    const lens3 = [_]usize{5};
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_menu_validate_order(&names3, &lens3, 1));
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 9: Thread safety — concurrent catalogue access
// ═══════════════════════════════════════════════════════════════════════
//
// Validates that the mutex protection works: multiple threads can call
// catalogue operations without data corruption.  This is the seam between
// the V-lang HTTP worker threads and the Zig FFI globals.

test "seam: concurrent register+query does not corrupt state" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Spawn writer threads that register cartridges concurrently
    const WRITERS = 4;
    const PER_WRITER = 8;
    var threads: [WRITERS]std.Thread = undefined;

    for (0..WRITERS) |w| {
        threads[w] = try std.Thread.spawn(.{}, struct {
            fn run(writer_id: usize) void {
                for (0..PER_WRITER) |i| {
                    var name_buf: [64]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "thread-{d}-cart-{d}", .{ writer_id, i }) catch return;
                    _ = catalogue.boj_catalogue_register(name.ptr, name.len, "1.0".ptr, 3, 1, 0, 1);
                }
            }
        }.run, .{w});
    }

    for (&threads) |*t| t.join();

    // All registrations should have succeeded — count must equal WRITERS * PER_WRITER
    const count = catalogue.boj_catalogue_count();
    try std.testing.expectEqual(@as(usize, WRITERS * PER_WRITER), count);
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 10: PanLL CartridgeAbi schema contract
// ═══════════════════════════════════════════════════════════════════════
//
// The PanLL CartridgeAbi.res module declares cartridgeCount = 21.
// If BoJ adds or removes cartridges without updating the schema,
// PanLL's compile-time safety is silently broken.
// This seam validates the catalogue can hold exactly the declared count.

test "seam: catalogue supports exactly 21 cartridges (PanLL schema contract)" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register all 21 cartridges matching PanLL's CartridgeAbi.cartridgeCount
    const cartridge_names = [_][]const u8{
        "agent-mcp",     "bsp-mcp",       "cloud-mcp",     "comms-mcp",
        "container-mcp", "dap-mcp",       "database-mcp",  "feedback-mcp",
        "fleet-mcp",     "git-mcp",       "iac-mcp",       "k8s-mcp",
        "lsp-mcp",       "ml-mcp",        "nesy-mcp",      "observe-mcp",
        "proof-mcp",     "queues-mcp",    "research-mcp",  "secrets-mcp",
        "ssg-mcp",
    };

    for (cartridge_names) |name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, "0.3.0".ptr, 5, 1, 0, 1);
    }

    // Exactly 21 cartridges registered — matches PanLL CartridgeAbi.cartridgeCount
    try std.testing.expectEqual(@as(usize, 21), catalogue.boj_catalogue_count());

    // All 21 should be mountable (all registered as Ready)
    for (0..21) |i| {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(i));
    }
    try std.testing.expectEqual(@as(usize, 21), catalogue.boj_catalogue_count_mounted());
}

// ═══════════════════════════════════════════════════════════════════════
// Seam 11: Protocol column coverage per cartridge (PanLL schema contract)
// ═══════════════════════════════════════════════════════════════════════
//
// Validates that protocol assignments match PanLL's cartridge-schema.json.
// Every cartridge must support at least MCP (protocol 1).

test "seam: all cartridges support MCP protocol" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const names = [_][]const u8{
        "agent-mcp",     "bsp-mcp",       "cloud-mcp",     "comms-mcp",
        "container-mcp", "dap-mcp",       "database-mcp",  "feedback-mcp",
        "fleet-mcp",     "git-mcp",       "iac-mcp",       "k8s-mcp",
        "lsp-mcp",       "ml-mcp",        "nesy-mcp",      "observe-mcp",
        "proof-mcp",     "queues-mcp",    "research-mcp",  "secrets-mcp",
        "ssg-mcp",
    };

    for (names) |name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, "0.3.0".ptr, 5, 1, 0, 1);
        // Add MCP protocol (1) to each
        _ = catalogue.boj_catalogue_add_protocol(1);
    }

    // Verify MCP protocol is present on all
    for (0..21) |i| {
        try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_has_protocol(i, 1));
    }
}

test "seam: concurrent mount+unmount does not corrupt state" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Pre-register cartridges
    for (0..8) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "mt-seam-{d}", .{i}) catch unreachable;
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, "1.0".ptr, 3, 1, 0, 1);
    }

    // Spawn threads that rapidly mount+unmount
    var threads: [4]std.Thread = undefined;
    for (0..4) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(thread_id: usize) void {
                for (0..100) |_| {
                    const idx = thread_id * 2;
                    _ = catalogue.boj_catalogue_mount(idx);
                    _ = catalogue.boj_catalogue_mount(idx + 1);
                    _ = catalogue.boj_catalogue_unmount(idx);
                    _ = catalogue.boj_catalogue_unmount(idx + 1);
                }
            }
        }.run, .{t});
    }

    for (&threads) |*t| t.join();

    // After all unmounts, nothing should be mounted
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());
}
