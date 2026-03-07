// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Cartridge Loader — Dynamic loading of verified cartridge binaries.
//
// This module handles the runtime loading of cartridge shared libraries.
// Each cartridge is a .so/.dylib that implements a standard interface
// (init, deinit, name, version). Before loading, the loader verifies
// the binary's SHA-256 hash against the catalogue's recorded hash,
// matching the Idris2 Attested proof type.
//
// Phase 2 implementation.

const std = @import("std");
const crypto = std.crypto;
const fs = std.fs;

/// SHA-256 digest length in bytes.
pub const HASH_LEN: usize = 32;

/// SHA-256 digest as a hex string length.
pub const HASH_HEX_LEN: usize = 64;

/// Cartridge binary interface that loaded cartridges must implement.
/// Each cartridge .so/.dylib exports these four C-calling-convention symbols.
pub const CartridgeInterface = struct {
    /// Initialise the cartridge. Returns 0 on success.
    init: *const fn () callconv(.C) c_int,
    /// Shut down the cartridge.
    deinit: *const fn () callconv(.C) void,
    /// Get the cartridge name (null-terminated).
    name: *const fn () callconv(.C) [*:0]const u8,
    /// Get the cartridge version (null-terminated).
    version: *const fn () callconv(.C) [*:0]const u8,
    /// Handle to the loaded dynamic library (for cleanup).
    _lib: std.DynLib,
};

/// Errors specific to cartridge loading.
pub const LoadError = error{
    /// The binary hash does not match the expected hash.
    HashMismatch,
    /// A required symbol is missing from the shared library.
    MissingSymbol,
    /// The file could not be read for hash verification.
    CannotReadBinary,
};

/// Compute the SHA-256 hash of a file, returning the digest as raw bytes.
pub fn hashFile(path: []const u8) (LoadError || fs.File.OpenError || fs.File.ReadError)![HASH_LEN]u8 {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return LoadError.CannotReadBinary,
        else => return err,
    };
    defer file.close();

    var hasher = crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    return hasher.finalResult();
}

/// Format a SHA-256 digest as a lowercase hex string.
pub fn hashToHex(digest: [HASH_LEN]u8) [HASH_HEX_LEN]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [HASH_HEX_LEN]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

/// Verify a binary's SHA-256 hash against the expected hex hash string.
/// This is the runtime equivalent of the Idris2 Attested proof type —
/// it guarantees the loaded binary matches the attested artefact.
///
/// Returns true if the hashes match, false if they differ.
/// Returns an error if the file cannot be read.
pub fn verifyHash(binary_path: []const u8, expected_hex: []const u8) !bool {
    if (expected_hex.len != HASH_HEX_LEN) return false;

    const digest = try hashFile(binary_path);
    const actual_hex = hashToHex(digest);

    return std.mem.eql(u8, &actual_hex, expected_hex[0..HASH_HEX_LEN]);
}

/// Load a cartridge from a shared library path.
///
/// If `expected_hash` is non-null, the binary's SHA-256 hash is verified
/// before loading. This matches the Idris2 Attested proof type — a cartridge
/// can only be loaded if its binary matches the attested hash.
///
/// The caller must call `unloadCartridge` when done.
pub fn loadCartridge(
    path: []const u8,
    expected_hash: ?[]const u8,
) !CartridgeInterface {
    // Phase 2: Verify hash before loading (if hash provided)
    if (expected_hash) |hash| {
        const valid = try verifyHash(path, hash);
        if (!valid) return LoadError.HashMismatch;
    }

    // Open the dynamic library
    var lib = std.DynLib.open(path) catch return error.FileNotFound;
    errdefer lib.close();

    // Look up the four required symbols
    const init_fn = lib.lookup(*const fn () callconv(.C) c_int, "boj_cartridge_init") orelse
        return LoadError.MissingSymbol;
    const deinit_fn = lib.lookup(*const fn () callconv(.C) void, "boj_cartridge_deinit") orelse
        return LoadError.MissingSymbol;
    const name_fn = lib.lookup(*const fn () callconv(.C) [*:0]const u8, "boj_cartridge_name") orelse
        return LoadError.MissingSymbol;
    const version_fn = lib.lookup(*const fn () callconv(.C) [*:0]const u8, "boj_cartridge_version") orelse
        return LoadError.MissingSymbol;

    return CartridgeInterface{
        .init = init_fn,
        .deinit = deinit_fn,
        .name = name_fn,
        .version = version_fn,
        ._lib = lib,
    };
}

/// Unload a previously loaded cartridge, closing the dynamic library handle.
pub fn unloadCartridge(iface: *CartridgeInterface) void {
    iface._lib.close();
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports for catalogue integration
// ═══════════════════════════════════════════════════════════════════════

/// Set the binary hash for a catalogue entry.
/// Called by the V-lang adapter after computing or receiving the hash.
/// hash_ptr: pointer to 64-byte hex string. hash_len must be 64.
/// Returns 0 on success, -1 on failure.
export fn boj_loader_set_hash(
    catalogue_index: usize,
    hash_ptr: [*]const u8,
    hash_len: usize,
) c_int {
    if (hash_len != HASH_HEX_LEN) return -1;
    // Delegate to catalogue — import at comptime
    const catalogue = @import("catalogue.zig");
    return catalogue.boj_catalogue_set_hash(catalogue_index, hash_ptr, hash_len);
}

/// Verify a binary file's hash against the stored catalogue hash.
/// path_ptr/path_len: path to the .so/.dylib file.
/// expected_hex_ptr/expected_hex_len: 64-char hex SHA-256 hash.
/// Returns 1 if match, 0 if mismatch, -1 on error.
export fn boj_loader_verify(
    path_ptr: [*]const u8,
    path_len: usize,
    expected_hex_ptr: [*]const u8,
    expected_hex_len: usize,
) c_int {
    if (expected_hex_len != HASH_HEX_LEN) return -1;
    const result = verifyHash(
        path_ptr[0..path_len],
        expected_hex_ptr[0..expected_hex_len],
    ) catch return -1;
    return if (result) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "hashToHex produces correct hex string" {
    const digest = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    const hex = hashToHex(digest);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "hashFile on known content" {
    // Create a temp file with known content "abc" (SHA-256 is well-known)
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test_hash.bin", .{});
    try file.writeAll("abc");
    file.close();

    // Get the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test_hash.bin", &path_buf);

    const digest = try hashFile(path);
    const hex = hashToHex(digest);

    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "verifyHash returns true for matching hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("verify_match.bin", .{});
    try file.writeAll("abc");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("verify_match.bin", &path_buf);

    const result = try verifyHash(path, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expect(result);
}

test "verifyHash returns false for wrong hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("verify_mismatch.bin", .{});
    try file.writeAll("abc");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("verify_mismatch.bin", &path_buf);

    const result = try verifyHash(path, "0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expect(!result);
}

test "verifyHash returns false for wrong-length hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("verify_badlen.bin", .{});
    try file.writeAll("abc");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("verify_badlen.bin", &path_buf);

    const result = try verifyHash(path, "tooshort");
    try std.testing.expect(!result);
}

test "hashFile returns error for missing file" {
    const result = hashFile("/nonexistent/path/to/file.so");
    try std.testing.expectError(LoadError.CannotReadBinary, result);
}
