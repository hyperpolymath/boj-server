// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Readiness Tests — Component Readiness Grade verification.
//
// Grade D (Alpha): Component runs without crashing.
// Grade C (Beta):  Component produces correct output.
// Grade B (RC):    Edge cases and multi-input support.

const std = @import("std");
const catalogue = @import("catalogue");

// ═══════════════════════════════════════════════════════════════════════
// Grade D — Component runs without crashing
// ═══════════════════════════════════════════════════════════════════════

test "readiness_d_catalogue_lifecycle" {
    // Init and deinit without crashing
    const result = catalogue.boj_catalogue_init();
    try std.testing.expectEqual(@as(c_int, 0), result);
    catalogue.boj_catalogue_deinit();
}

test "readiness_d_register_cartridge" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "readiness-test";
    const ver = "1.0.0";
    const result = catalogue.boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1,
        0,
        3,
    );
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "readiness_d_mount_unmount" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "mount-test";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
    _ = catalogue.boj_catalogue_mount(0);
    _ = catalogue.boj_catalogue_unmount(0);
}

test "readiness_d_query_operations" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = catalogue.boj_catalogue_count();
    _ = catalogue.boj_catalogue_count_ready();
    _ = catalogue.boj_catalogue_count_mounted();
    _ = catalogue.boj_catalogue_status(0);
    _ = catalogue.boj_catalogue_is_mounted(0);
    _ = catalogue.boj_catalogue_version();
}

test "readiness_d_hash_operations" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "hash-test";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    _ = catalogue.boj_catalogue_set_hash(0, hash.ptr, hash.len);

    var buf: [64]u8 = undefined;
    _ = catalogue.boj_catalogue_get_hash(0, &buf);
}

// ═══════════════════════════════════════════════════════════════════════
// Grade C — Component produces correct output
// ═══════════════════════════════════════════════════════════════════════

test "readiness_c_mount_requires_ready" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Development cartridge should NOT mount
    const name = "dev-cart";
    const ver = "0.1.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 0, 0, 1);
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(0));
}

test "readiness_c_faulty_cartridge_rejected" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "faulty-cart";
    const ver = "0.1.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 3, 0, 1);
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_mount(0));
}

test "readiness_c_deprecated_cartridge_rejected" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "deprecated-cart";
    const ver = "0.1.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 2, 0, 1);
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_mount(0));
}

test "readiness_c_ready_cartridge_mounts" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "ready-cart";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
}

test "readiness_c_counts_are_accurate" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());

    // Register 3 cartridges: 2 ready, 1 development
    const names = [_][]const u8{ "cart-a", "cart-b", "cart-c" };
    const statuses = [_]c_int{ 1, 1, 0 };
    const ver = "1.0.0";
    for (names, statuses) |name, status| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, status, 0, 3);
    }

    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 2), catalogue.boj_catalogue_count_ready());
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());

    _ = catalogue.boj_catalogue_mount(0);
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count_mounted());
}

test "readiness_c_hash_roundtrip" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "hash-rt";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_set_hash(0, hash.ptr, hash.len));

    var buf: [64]u8 = undefined;
    const len = catalogue.boj_catalogue_get_hash(0, &buf);
    try std.testing.expectEqual(@as(usize, 64), len);
    try std.testing.expectEqualStrings(hash, buf[0..64]);
}

test "readiness_c_protocol_addition" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "proto-cart";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    // Valid protocols (1-9)
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(1));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(9));

    // Invalid protocol
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_add_protocol(0));
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_add_protocol(10));
}

// ═══════════════════════════════════════════════════════════════════════
// Grade B — Edge cases and multi-input support
// ═══════════════════════════════════════════════════════════════════════

test "readiness_b_register_max_name" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Max name length is 64
    const name = "a" ** 64;
    const ver = "1.0.0";
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1,
        0,
        3,
    ));
}

test "readiness_b_reject_oversized_name" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Name longer than 64 should be rejected
    const name = "a" ** 65;
    const ver = "1.0.0";
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1,
        0,
        3,
    ));
}

test "readiness_b_multiple_mounts" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register 4 ready cartridges
    const names = [_][]const u8{ "cart-1", "cart-2", "cart-3", "cart-4" };
    const ver = "1.0.0";
    for (names) |name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
    }

    // Mount all 4
    for (0..4) |i| {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(i));
    }
    try std.testing.expectEqual(@as(usize, 4), catalogue.boj_catalogue_count_mounted());

    // Unmount 2
    _ = catalogue.boj_catalogue_unmount(0);
    _ = catalogue.boj_catalogue_unmount(2);
    try std.testing.expectEqual(@as(usize, 2), catalogue.boj_catalogue_count_mounted());
}

test "readiness_b_out_of_bounds_index" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Operations on nonexistent indices
    try std.testing.expectEqual(@as(c_int, -2), catalogue.boj_catalogue_mount(999));
    try std.testing.expectEqual(@as(c_int, -2), catalogue.boj_catalogue_unmount(999));
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_is_mounted(999));
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_status(999));
}

test "readiness_b_double_mount_idempotent" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "double-mount";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    // Mount twice — should succeed both times (idempotent)
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count_mounted());
}

test "readiness_b_uninitialised_operations" {
    // Ensure deinit state rejects operations
    catalogue.boj_catalogue_deinit();

    const name = "should-fail";
    const ver = "1.0.0";
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_register(
        name.ptr,
        name.len,
        ver.ptr,
        ver.len,
        1,
        0,
        3,
    ));
}

test "readiness_b_hash_wrong_length" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "hash-badlen";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    // Hash longer than 64 should be rejected
    const long_hash = "a" ** 65;
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_set_hash(0, long_hash.ptr, long_hash.len));
}

test "readiness_b_all_menu_tiers" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";
    // Teranga (0), Shield (1), Ayo (2)
    const tiers = [_]c_int{ 0, 1, 2 };
    const names = [_][]const u8{ "teranga-cart", "shield-cart", "ayo-cart" };
    for (names, tiers) |name, tier| {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name.ptr,
            name.len,
            ver.ptr,
            ver.len,
            1,
            tier,
            3,
        ));
    }
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count());
}

test "readiness_b_all_domains" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";
    // All 13 domains
    var i: c_int = 1;
    while (i <= 13) : (i += 1) {
        const name = "domain-cart";
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, i);
    }
    try std.testing.expectEqual(@as(usize, 13), catalogue.boj_catalogue_count());
}

// ═══════════════════════════════════════════════════════════════════════
// Grade A — Production (stress, capacity, integrity under load)
// ═══════════════════════════════════════════════════════════════════════

test "readiness_a_concurrent_mount_unmount_alternation" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";
    const names = [_][]const u8{ "alt-a", "alt-b", "alt-c", "alt-d", "alt-e", "alt-f" };
    for (names) |name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
    }

    // Rapid mount/unmount alternation across all cartridges
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        for (0..6) |i| {
            try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(i));
        }
        try std.testing.expectEqual(@as(usize, 6), catalogue.boj_catalogue_count_mounted());

        // Unmount odd indices
        var j: usize = 1;
        while (j < 6) : (j += 2) {
            _ = catalogue.boj_catalogue_unmount(j);
        }
        try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

        // Unmount remaining
        var k: usize = 0;
        while (k < 6) : (k += 2) {
            _ = catalogue.boj_catalogue_unmount(k);
        }
        try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());
    }
}

test "readiness_a_stress_max_cartridges" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";

    // Register MAX_CARTRIDGES (128) cartridges — all ready
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        // Build a unique 3-char name from index (zero-padded via fixed buffer)
        var name_buf: [8]u8 = undefined;
        const name_slice = std.fmt.bufPrint(&name_buf, "s-{d:0>4}", .{i}) catch unreachable;
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_register(
            name_slice.ptr,
            name_slice.len,
            ver.ptr,
            ver.len,
            1,
            0,
            3,
        ));
    }

    try std.testing.expectEqual(@as(usize, 128), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 128), catalogue.boj_catalogue_count_ready());

    // Mount all 128
    var m: usize = 0;
    while (m < 128) : (m += 1) {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(m));
    }
    try std.testing.expectEqual(@as(usize, 128), catalogue.boj_catalogue_count_mounted());
}

test "readiness_a_full_lifecycle_stress" {
    // Run init → register → mount → unmount → deinit → reinit cycle multiple times
    var cycle: usize = 0;
    while (cycle < 5) : (cycle += 1) {
        _ = catalogue.boj_catalogue_init();

        const ver = "1.0.0";
        const names = [_][]const u8{ "lc-x", "lc-y", "lc-z" };
        for (names) |name| {
            _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
        }
        try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count());

        // Mount all
        for (0..3) |i| {
            try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(i));
        }
        try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

        // Unmount all
        for (0..3) |i| {
            _ = catalogue.boj_catalogue_unmount(i);
        }
        try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());

        catalogue.boj_catalogue_deinit();

        // After deinit, counts should reflect uninitialised state
        try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
    }
}

test "readiness_a_protocol_saturation" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const name = "proto-sat";
    const ver = "1.0.0";
    _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);

    // Add all 9 valid protocols (1 through 9)
    var p: c_int = 1;
    while (p <= 9) : (p += 1) {
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_add_protocol(p));
    }

    // Cartridge should still mount fine with all protocols registered
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_mount(0));
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(0));
}

test "readiness_a_hash_integrity_under_load" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";

    // Pre-computed distinct 64-char hex hashes (SHA-256 style)
    const hashes = [_][]const u8{
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34",
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
        "ef2d127de37b942baad06145e54b0c619a1f22327b2ebbcfbec78f5564afe39d",
        "4e07408562bedb8b60ce05c1decfe3ad16b72230967de01f640b7e4729b49fce",
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    };

    // Register 8 cartridges and set a unique hash on each
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var name_buf: [8]u8 = undefined;
        const name_slice = std.fmt.bufPrint(&name_buf, "hsh-{d:0>3}", .{i}) catch unreachable;
        _ = catalogue.boj_catalogue_register(name_slice.ptr, name_slice.len, ver.ptr, ver.len, 1, 0, 3);
        try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_set_hash(i, hashes[i].ptr, hashes[i].len));
    }

    // Verify all hashes roundtrip correctly
    var j: usize = 0;
    while (j < 8) : (j += 1) {
        var buf: [64]u8 = undefined;
        const len = catalogue.boj_catalogue_get_hash(j, &buf);
        try std.testing.expectEqual(@as(usize, 64), len);
        try std.testing.expectEqualStrings(hashes[j], buf[0..64]);
    }
}

test "readiness_a_mixed_status_registration" {
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver = "1.0.0";

    // Status 0 = Development, 1 = Ready, 2 = Deprecated, 3 = Faulty
    const names = [_][]const u8{ "ms-dev", "ms-rdy1", "ms-depr", "ms-flt", "ms-rdy2", "ms-dev2", "ms-rdy3", "ms-flt2" };
    const statuses = [_]c_int{ 0, 1, 2, 3, 1, 0, 1, 3 };

    for (names, statuses) |name, status| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, status, 0, 3);
    }

    try std.testing.expectEqual(@as(usize, 8), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_ready());

    // Attempt to mount all — only ready ones (indices 1, 4, 6) should succeed
    for (0..8) |i| {
        _ = catalogue.boj_catalogue_mount(i);
    }
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

    // Verify exactly the right ones are mounted
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(0)); // dev
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(1)); // ready
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(2)); // deprecated
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(3)); // faulty
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(4)); // ready
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(5)); // dev
    try std.testing.expectEqual(@as(c_int, 1), catalogue.boj_catalogue_is_mounted(6)); // ready
    try std.testing.expectEqual(@as(c_int, 0), catalogue.boj_catalogue_is_mounted(7)); // faulty
}

test "readiness_a_reinit_clears_everything" {
    _ = catalogue.boj_catalogue_init();

    const ver = "1.0.0";
    const names = [_][]const u8{ "ri-a", "ri-b", "ri-c", "ri-d", "ri-e" };
    for (names) |name| {
        _ = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 1, 0, 3);
    }

    // Mount 3 of them
    _ = catalogue.boj_catalogue_mount(0);
    _ = catalogue.boj_catalogue_mount(2);
    _ = catalogue.boj_catalogue_mount(4);
    try std.testing.expectEqual(@as(usize, 5), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 3), catalogue.boj_catalogue_count_mounted());

    // Set a hash on one
    const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    _ = catalogue.boj_catalogue_set_hash(0, hash.ptr, hash.len);

    // Deinit and reinit — everything should be cleared
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_ready());
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count_mounted());

    // Old indices should be invalid
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_status(0));
    try std.testing.expectEqual(@as(c_int, -1), catalogue.boj_catalogue_is_mounted(0));

    // Hash retrieval on cleared slot should return 0 length
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_get_hash(0, &buf));
}
