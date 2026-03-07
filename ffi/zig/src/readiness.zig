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
