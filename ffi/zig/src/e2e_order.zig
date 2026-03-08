// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — End-to-end order-ticket test at the Zig FFI layer.
//
// Simulates the full order-ticket flow without needing the V-lang server:
//   1. Init catalogue
//   2. Register 4 cartridges (database-mcp, fleet-mcp, nesy-mcp, agent-mcp)
//   3. Add protocols to each cartridge
//   4. Set hash attestation on one cartridge
//   5. Mount 3 cartridges (simulate an order)
//   6. Verify mount state and counts
//   7. Unmount one, verify count drops
//   8. Negative paths: development cartridge mount, out-of-bounds mount
//   9. Deinit

const std = @import("std");
const catalogue = @import("catalogue");

// ═══════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════

/// Register a cartridge by name with status=ready, tier=teranga, and
/// a given domain. Returns the index of the newly registered cartridge.
fn registerReady(name: []const u8, domain: c_int) usize {
    const ver = "1.0.0";
    const rc = catalogue.boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1, // status = ready
        0, // tier   = teranga
        domain,
    );
    std.debug.assert(rc == 0);
    // Index is count-before-register, i.e. current count minus one.
    return catalogue.boj_catalogue_count() - 1;
}

// ═══════════════════════════════════════════════════════════════════════
// Happy-path: full order-ticket flow
// ═══════════════════════════════════════════════════════════════════════

test "e2e order-ticket: register, protocol, hash, mount, query, unmount" {
    // --- Step 1: Init ---
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_init());

    // --- Step 2: Register 4 cartridges with status=ready ---
    //   database-mcp  domain=database(3)
    //   fleet-mcp     domain=fleet_dom(12)
    //   nesy-mcp      domain=nesy_dom(13)
    //   agent-mcp     domain=cloud(1)
    const idx_database = registerReady("database-mcp", 3);
    const idx_fleet = registerReady("fleet-mcp", 12);
    const idx_nesy = registerReady("nesy-mcp", 13);
    const idx_agent = registerReady("agent-mcp", 1);

    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count_ready());

    // --- Step 3: Add protocols matching V adapter builtins ---
    //   database-mcp: mcp(1)
    //   fleet-mcp:    mcp(1), fleet(7)
    //   nesy-mcp:     mcp(1), nesy(5)
    //   agent-mcp:    mcp(1), agentic(6)
    //
    // boj_catalogue_add_protocol applies to the *last* registered cartridge,
    // so we re-register in order and add protocols right after each.
    // Since we already registered above, we re-init and redo to keep the
    // add_protocol calls adjacent to registration.
    catalogue.boj_catalogue_deinit();
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_init());

    // database-mcp
    {
        const name = "database-mcp";
        const ver = "1.0.0";
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3,
        ));
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(1)); // mcp
    }

    // fleet-mcp
    {
        const name = "fleet-mcp";
        const ver = "1.0.0";
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name.ptr, name.len, ver.ptr, ver.len, 1, 0, 12,
        ));
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(1)); // mcp
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(7)); // fleet
    }

    // nesy-mcp
    {
        const name = "nesy-mcp";
        const ver = "1.0.0";
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name.ptr, name.len, ver.ptr, ver.len, 1, 0, 13,
        ));
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(1)); // mcp
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(5)); // nesy
    }

    // agent-mcp
    {
        const name = "agent-mcp";
        const ver = "1.0.0";
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name.ptr, name.len, ver.ptr, ver.len, 1, 0, 1,
        ));
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(1)); // mcp
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(6)); // agentic
    }

    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count_ready());

    // Indices after fresh registration sequence:
    const db_idx: usize = 0; // database-mcp
    const fl_idx: usize = 1; // fleet-mcp
    const ne_idx: usize = 2; // nesy-mcp
    const ag_idx: usize = 3; // agent-mcp

    // Suppress unused variable warnings from the first registration pass.
    _ = idx_database;
    _ = idx_fleet;
    _ = idx_nesy;
    _ = idx_agent;

    // --- Step 4: Set hash attestation on database-mcp ---
    const fake_hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    try std.testing.expectEqual(
        @as(c_int, 0),
        catalogue.boj_catalogue_set_hash(db_idx, fake_hash.ptr, fake_hash.len),
    );

    // Verify hash round-trips.
    var hash_buf: [64]u8 = undefined;
    const hash_len = catalogue.boj_catalogue_get_hash(db_idx, &hash_buf);
    try std.testing.expectEqual(fake_hash.len, hash_len);
    try std.testing.expectEqualSlices(u8, fake_hash, hash_buf[0..hash_len]);

    // --- Step 5: Mount 3 cartridges (simulate an order) ---
    //   Mount database-mcp, fleet-mcp, nesy-mcp (leave agent-mcp unmounted).
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(db_idx));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(fl_idx));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(ne_idx));

    // --- Step 6: Verify mounted count is 3 ---
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

    // --- Step 7: Verify each mounted cartridge via is_mounted ---
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(db_idx));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(fl_idx));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(ne_idx));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(ag_idx)); // not mounted

    // --- Step 8: Query catalogue to verify counts ---
    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count_ready());
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

    // Verify statuses by index.
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_status(db_idx)); // ready
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_status(fl_idx)); // ready
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_status(ne_idx)); // ready
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_status(ag_idx)); // ready

    // --- Step 9: Unmount one cartridge ---
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_unmount(fl_idx));

    // --- Step 10: Verify mounted count drops to 2 ---
    try std.testing.expectEqual(@as(usize, 2), catalogue.boj_catalogue_count_mounted());
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(fl_idx));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(db_idx)); // still up
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(ne_idx)); // still up

    // --- Step 11: Deinit ---
    catalogue.boj_catalogue_deinit();
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
}

// ═══════════════════════════════════════════════════════════════════════
// Negative paths
// ═══════════════════════════════════════════════════════════════════════

test "e2e negative: cannot mount development cartridge" {
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_init());
    defer catalogue.boj_catalogue_deinit();

    // Register a development (status=0) cartridge.
    const name = "dev-experiment";
    const ver = "0.0.1";
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
        name.ptr, name.len, ver.ptr, ver.len,
        0, // status = development
        0, // tier   = teranga
        3, // domain = database
    ));
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_ready());

    // Mount MUST fail with -1 (not ready).
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(0));
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());
}

test "e2e negative: out-of-bounds mount returns error" {
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_init());
    defer catalogue.boj_catalogue_deinit();

    // Register one cartridge so count=1.
    const name = "solo";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 1);

    // Index 0 is valid; index 1 and beyond are out of bounds.
    try std.testing.expectEqual(@as(c_int, -2), catalogue.boj_catalogue_mount(1));
    try std.testing.expectEqual(@as(c_int, -2), catalogue.boj_catalogue_mount(99));
    try std.testing.expectEqual(@as(c_int, -2), catalogue.boj_catalogue_mount(128));

    // is_mounted on out-of-bounds also returns error.
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_is_mounted(1));

    // The valid cartridge should still be mountable.
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
}
