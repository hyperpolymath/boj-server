// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Cartridge Loader — Dynamic loading of verified cartridge binaries.
//
// This module handles the runtime loading of cartridge shared libraries.
// Each cartridge is a .so/.dylib that implements a standard interface.
// Before loading, the loader verifies the binary hash against the
// catalogue's recorded hash (matching the Idris2 Attested proof type).
//
// Phase 2 implementation — stub for now, will be filled in future sessions.

const std = @import("std");

/// Cartridge binary interface that loaded cartridges must implement.
pub const CartridgeInterface = struct {
    /// Initialise the cartridge. Returns 0 on success.
    init: *const fn () callconv(.C) c_int,
    /// Shut down the cartridge.
    deinit: *const fn () callconv(.C) void,
    /// Get the cartridge name.
    name: *const fn () callconv(.C) [*:0]const u8,
    /// Get the cartridge version.
    version: *const fn () callconv(.C) [*:0]const u8,
};

/// Load a cartridge from a shared library path.
/// Phase 2: Will verify binary hash before loading.
/// Phase 5: Will also verify against Umoja network attestation.
pub fn loadCartridge(allocator: std.mem.Allocator, path: []const u8) !CartridgeInterface {
    _ = allocator;
    _ = path;
    // TODO: Phase 2 — implement dynamic library loading with hash verification
    return error.NotImplemented;
}

/// Verify a binary's SHA-256 hash against the expected hash.
/// This is the runtime equivalent of the Idris2 Attested proof type.
pub fn verifyHash(binary_path: []const u8, expected_hash: []const u8) !bool {
    _ = binary_path;
    _ = expected_hash;
    // TODO: Phase 2 — implement SHA-256 hash verification
    return error.NotImplemented;
}

test "loader stub" {
    // Phase 2 will add real tests
    try std.testing.expect(true);
}
