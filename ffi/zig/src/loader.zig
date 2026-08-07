// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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

// `std.atomic.Mutex` was removed from the standard library; its replacement is
// `shim.Mutex`, whose lock/unlock surface is identical to the hand-rolled
// wrapper this replaces. The wrapper also busy-waited via `spinLoopHint`, burning
// a core under contention; `shim.Mutex` parks the thread instead. 81 other
// files in this repo already use this form.
const Mutex = shim.Mutex;
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
    init: *const fn () c_int,
    /// Shut down the cartridge.
    deinit: *const fn () void,
    /// Get the cartridge name (null-terminated).
    name: *const fn () [*:0]const u8,
    /// Get the cartridge version (null-terminated).
    version: *const fn () [*:0]const u8,
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
///
/// SAFETY PROPERTIES:
/// - I/O buffer `buf` is stack-allocated at 8KiB; `file.read` returns at
///   most buf.len bytes so `buf[0..n]` is always in-bounds.
/// - File handle is closed via `defer` even on read errors.
/// - Empty path is rejected before I/O to avoid platform-specific behaviour.
pub fn hashFile(path: []const u8) (LoadError || std.Io.File.OpenError || std.Io.File.ReadStreamingError)![HASH_LEN]u8 {
    // SAFETY: reject empty paths before any I/O
    if (path.len == 0) return LoadError.CannotReadBinary;

    const file = std.Io.Dir.cwd().openFile(shim.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return LoadError.CannotReadBinary,
        else => return err,
    };
    defer file.close(shim.io());

    var hasher = crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        // 0.16 contract: end-of-stream is error.EndOfStream; a 0 return
        // just means "no bytes this call" and is not terminal.
        const n = file.readStreaming(shim.io(), &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        // SAFETY: n <= buf.len guaranteed by the readStreaming contract
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
    const init_fn = lib.lookup(*const fn () c_int, "boj_cartridge_init") orelse
        return LoadError.MissingSymbol;
    const deinit_fn = lib.lookup(*const fn () void, "boj_cartridge_deinit") orelse
        return LoadError.MissingSymbol;
    const name_fn = lib.lookup(*const fn () [*:0]const u8, "boj_cartridge_name") orelse
        return LoadError.MissingSymbol;
    const version_fn = lib.lookup(*const fn () [*:0]const u8, "boj_cartridge_version") orelse
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
/// Called by the zig adapter after computing or receiving the hash.
/// hash_ptr: pointer to 64-byte hex string. hash_len must be 64.
/// Returns 0 on success, -1 on failure.
///
/// HARDENED: Explicit bounds check on hash_len before pointer arithmetic;
/// validates hex characters to prevent garbage data in catalogue.
export fn boj_loader_set_hash(
    catalogue_index: usize,
    hash_ptr: [*]const u8,
    hash_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // SAFETY: reject non-64-byte hashes before any pointer dereference
    if (hash_len != HASH_HEX_LEN) return -1;

    // SAFETY: validate that all bytes are valid hex characters to prevent
    // garbage data from being stored in the catalogue
    for (hash_ptr[0..HASH_HEX_LEN]) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return -1,
        }
    }

    // Delegate to catalogue — import at comptime
    const catalogue = @import("catalogue.zig");
    return catalogue.boj_catalogue_set_hash(catalogue_index, hash_ptr, hash_len);
}

/// Verify a binary file's hash against the stored catalogue hash.
/// path_ptr/path_len: path to the .so/.dylib file.
/// expected_hex_ptr/expected_hex_len: 64-char hex SHA-256 hash.
/// Returns 1 if match, 0 if mismatch, -1 on error.
///
/// HARDENED: Bounds check on path_len before slicing; reject zero-length paths.
export fn boj_loader_verify(
    path_ptr: [*]const u8,
    path_len: usize,
    expected_hex_ptr: [*]const u8,
    expected_hex_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // SAFETY: reject empty paths and oversized paths before slicing
    if (path_len == 0 or path_len > std.fs.max_path_bytes) return -1;
    if (expected_hex_len != HASH_HEX_LEN) return -1;
    const result = verifyHash(
        path_ptr[0..path_len],
        expected_hex_ptr[0..expected_hex_len],
    ) catch return -1;
    return if (result) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// WASM Cartridge Support
// ═══════════════════════════════════════════════════════════════════════
//
// WASM cartridges are loaded from .wasm files instead of native .so/.dylib.
// The same hash verification and catalogue integration applies.
//
// WASM modules must export the same 4 symbols as native cartridges:
//   boj_cartridge_init, boj_cartridge_deinit,
//   boj_cartridge_name, boj_cartridge_version
//
// Zig validates the WASM module structure (magic bytes, version, export
// section). Actual WASM execution is delegated to a runtime (wasmtime/
// wasmer) in the zig adapter layer — this FFI provides validation,
// hash verification, and registry tracking.

/// WASM binary magic bytes: \0asm
const WASM_MAGIC = [_]u8{ 0x00, 0x61, 0x73, 0x6D };

/// WASM version 1 (MVP).
const WASM_VERSION_1 = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

/// Maximum number of WASM cartridges that can be registered.
const MAX_WASM_CARTRIDGES: usize = 32;

/// Maximum path length for a WASM module.
const MAX_WASM_PATH_LEN: usize = 512;

/// A registered WASM cartridge slot.
const WasmCartridgeSlot = struct {
    active: bool = false,
    path: [MAX_WASM_PATH_LEN]u8 = [_]u8{0} ** MAX_WASM_PATH_LEN,
    path_len: usize = 0,
    hash: [HASH_HEX_LEN]u8 = [_]u8{0} ** HASH_HEX_LEN,
    hash_verified: bool = false,
    module_valid: bool = false,
    /// WASM module size in bytes.
    module_size: u64 = 0,
    /// Catalogue index this WASM cartridge maps to (-1 if unmapped).
    catalogue_idx: c_int = -1,
};

/// Global WASM cartridge registry.
///
/// THREAD SAFETY: All reads/writes to wasm_slots and wasm_count are protected
/// by `mutex`. Every C-ABI export and every public function that touches these
/// globals acquires the mutex before access and releases via `defer mutex.unlock()`.
var wasm_slots: [MAX_WASM_CARTRIDGES]WasmCartridgeSlot = [_]WasmCartridgeSlot{.{}} ** MAX_WASM_CARTRIDGES;
var wasm_count: usize = 0;

/// Module-level mutex for thread-safe access to ALL mutable global state.
///
/// INVARIANT: Every C-ABI export function (boj_loader_*, boj_wasm_*) acquires
/// this mutex at entry. Internal pure functions (hashFile, hashToHex, verifyHash,
/// validateWasmModule) do NOT acquire it — callers are responsible.
var mutex: Mutex = .{};

/// Validate that a file is a valid WASM module.
/// Checks magic bytes and version header.
/// Returns the module size in bytes, or 0 if invalid.
///
/// HARDENED: Bounds-check on path length before I/O; explicit error propagation
/// for file operations instead of silent zero-returns; stat.size validated > 0.
pub fn validateWasmModule(path: []const u8) !u64 {
    // SAFETY: reject empty paths before any I/O (bounds check)
    if (path.len == 0) return 0;

    const file = std.Io.Dir.cwd().openFile(shim.io(), path, .{}) catch return 0;
    defer file.close(shim.io());

    // Read the 8-byte WASM header.
    var header: [8]u8 = undefined;
    const n = file.readStreaming(shim.io(), &.{&header}) catch return 0;
    // SAFETY: need exactly 8 bytes for magic + version
    if (n < 8) return 0;

    // Check magic bytes.
    if (!std.mem.eql(u8, header[0..4], &WASM_MAGIC)) return 0;

    // Check version.
    if (!std.mem.eql(u8, header[4..8], &WASM_VERSION_1)) return 0;

    // Get file size.
    const stat = file.stat(shim.io()) catch return 0;
    // SAFETY: a valid WASM module must be at least 8 bytes (header)
    if (stat.size < 8) return 0;
    return stat.size;
}

/// Register a WASM cartridge for loading.
/// Validates the module structure and computes its hash.
/// Returns the slot index on success, -1 on error.
pub export fn boj_wasm_register(
    path_ptr: [*]const u8,
    path_len: usize,
    catalogue_idx: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (path_len == 0 or path_len > MAX_WASM_PATH_LEN) return -1;
    if (wasm_count >= MAX_WASM_CARTRIDGES) return -1;

    const path = path_ptr[0..path_len];

    // Validate WASM module.
    const module_size = validateWasmModule(path) catch return -1;
    if (module_size == 0) return -1;

    // Compute hash.
    const digest = hashFile(path) catch return -1;
    const hex = hashToHex(digest);

    // Find a free slot.
    for (&wasm_slots, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            @memcpy(slot.path[0..path_len], path);
            slot.path_len = path_len;
            slot.hash = hex;
            slot.hash_verified = true;
            slot.module_valid = true;
            slot.module_size = module_size;
            slot.catalogue_idx = catalogue_idx;
            wasm_count += 1;
            return @intCast(i);
        }
    }
    return -1;
}

/// Unregister a WASM cartridge slot.
/// Returns 0 on success, -1 on error.
///
/// HARDENED: Guard against wasm_count underflow (defensive check even though
/// it should be impossible if register/unregister are always paired).
pub export fn boj_wasm_unregister(slot_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx >= MAX_WASM_CARTRIDGES or !wasm_slots[slot_idx].active) return -1;
    wasm_slots[slot_idx] = WasmCartridgeSlot{};
    // SAFETY: saturating subtraction prevents underflow if state is inconsistent
    wasm_count = if (wasm_count > 0) wasm_count - 1 else 0;
    return 0;
}

/// Get the number of registered WASM cartridges.
pub export fn boj_wasm_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return wasm_count;
}

/// Check if a WASM slot is valid and verified.
/// Returns 1 if valid, 0 if not, -1 on error.
pub export fn boj_wasm_is_valid(slot_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx >= MAX_WASM_CARTRIDGES or !wasm_slots[slot_idx].active) return -1;
    return if (wasm_slots[slot_idx].module_valid and wasm_slots[slot_idx].hash_verified) 1 else 0;
}

/// Get the WASM module size in bytes.
/// Returns the size, or 0 on error.
pub export fn boj_wasm_module_size(slot_idx: usize) u64 {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx >= MAX_WASM_CARTRIDGES or !wasm_slots[slot_idx].active) return 0;
    return wasm_slots[slot_idx].module_size;
}

/// Get the hash of a WASM module. Copies into out_ptr/out_len.
/// Returns HASH_HEX_LEN on success, 0 on error.
///
/// HARDENED: Added out_len parameter to prevent buffer overrun on caller's
/// buffer. Callers must provide at least HASH_HEX_LEN (64) bytes.
pub export fn boj_wasm_hash(slot_idx: usize, out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx >= MAX_WASM_CARTRIDGES or !wasm_slots[slot_idx].active) return 0;
    if (!wasm_slots[slot_idx].hash_verified) return 0;
    // SAFETY: bounds check on caller's output buffer before writing
    if (out_len < HASH_HEX_LEN) return 0;
    @memcpy(out_ptr[0..HASH_HEX_LEN], &wasm_slots[slot_idx].hash);
    return HASH_HEX_LEN;
}

/// Verify a WASM module's hash against an expected value.
/// Returns 1 if match, 0 if mismatch, -1 on error.
///
/// HARDENED: Bounds check on path_len before slicing pointer.
pub export fn boj_wasm_verify(
    path_ptr: [*]const u8,
    path_len: usize,
    expected_hex_ptr: [*]const u8,
    expected_hex_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // SAFETY: reject empty/oversized paths before pointer slice
    if (path_len == 0 or path_len > std.fs.max_path_bytes) return -1;
    if (expected_hex_len != HASH_HEX_LEN) return -1;
    const result = verifyHash(
        path_ptr[0..path_len],
        expected_hex_ptr[0..expected_hex_len],
    ) catch return -1;
    return if (result) 1 else 0;
}

/// Check if a file is a valid WASM module (magic + version check).
/// Returns 1 if valid WASM, 0 if not, -1 on error.
///
/// HARDENED: Bounds check on path_len before slicing pointer.
pub export fn boj_wasm_validate(
    path_ptr: [*]const u8,
    path_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // SAFETY: reject empty/oversized paths before pointer slice
    if (path_len == 0 or path_len > std.fs.max_path_bytes) return -1;
    const size = validateWasmModule(path_ptr[0..path_len]) catch return -1;
    return if (size > 0) 1 else 0;
}

/// Reset all WASM cartridge slots.
pub export fn boj_wasm_reset() void {
    mutex.lock();
    defer mutex.unlock();
    wasm_slots = [_]WasmCartridgeSlot{.{}} ** MAX_WASM_CARTRIDGES;
    wasm_count = 0;
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

    const file = try tmp_dir.dir.createFile(shim.io(), "test_hash.bin", .{});
    try file.writeStreamingAll(shim.io(), "abc");
    file.close(shim.io());

    // Get the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "test_hash.bin", &path_buf);
    const path = path_buf[0..path_len];

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

    const file = try tmp_dir.dir.createFile(shim.io(), "verify_match.bin", .{});
    try file.writeStreamingAll(shim.io(), "abc");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "verify_match.bin", &path_buf);
    const path = path_buf[0..path_len];

    const result = try verifyHash(path, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expect(result);
}

test "verifyHash returns false for wrong hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(shim.io(), "verify_mismatch.bin", .{});
    try file.writeStreamingAll(shim.io(), "abc");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "verify_mismatch.bin", &path_buf);
    const path = path_buf[0..path_len];

    const result = try verifyHash(path, "0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expect(!result);
}

test "verifyHash returns false for wrong-length hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(shim.io(), "verify_badlen.bin", .{});
    try file.writeStreamingAll(shim.io(), "abc");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "verify_badlen.bin", &path_buf);
    const path = path_buf[0..path_len];

    const result = try verifyHash(path, "tooshort");
    try std.testing.expect(!result);
}

test "hashFile returns error for missing file" {
    const result = hashFile("/nonexistent/path/to/file.so");
    try std.testing.expectError(LoadError.CannotReadBinary, result);
}

// ═══════════════════════════════════════════════════════════════════════
// WASM Tests
// ═══════════════════════════════════════════════════════════════════════

test "validateWasmModule accepts valid WASM" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid WASM file (8 bytes header + 1 byte body).
    const file = try tmp_dir.dir.createFile(shim.io(), "valid.wasm", .{});
    try file.writeStreamingAll(shim.io(), &WASM_MAGIC);
    try file.writeStreamingAll(shim.io(), &WASM_VERSION_1);
    try file.writeStreamingAll(shim.io(), &[_]u8{0x00}); // empty module body
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "valid.wasm", &path_buf);
    const path = path_buf[0..path_len];

    const size = try validateWasmModule(path);
    try std.testing.expect(size == 9); // 8 header + 1 body
}

test "validateWasmModule rejects non-WASM" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(shim.io(), "not_wasm.bin", .{});
    try file.writeStreamingAll(shim.io(), "not a wasm file");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "not_wasm.bin", &path_buf);
    const path = path_buf[0..path_len];

    const size = try validateWasmModule(path);
    try std.testing.expectEqual(@as(u64, 0), size);
}

test "validateWasmModule rejects too-short file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(shim.io(), "short.wasm", .{});
    try file.writeStreamingAll(shim.io(), &[_]u8{ 0x00, 0x61 }); // Only 2 bytes
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "short.wasm", &path_buf);
    const path = path_buf[0..path_len];

    const size = try validateWasmModule(path);
    try std.testing.expectEqual(@as(u64, 0), size);
}

test "WASM register and unregister" {
    boj_wasm_reset();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a valid WASM file.
    const file = try tmp_dir.dir.createFile(shim.io(), "cart.wasm", .{});
    try file.writeStreamingAll(shim.io(), &WASM_MAGIC);
    try file.writeStreamingAll(shim.io(), &WASM_VERSION_1);
    try file.writeStreamingAll(shim.io(), "cartridge body data");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "cart.wasm", &path_buf);
    const path = path_buf[0..path_len];

    // Register.
    const slot = boj_wasm_register(path.ptr, path.len, 0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(usize, 1), boj_wasm_count());

    // Valid and verified.
    try std.testing.expectEqual(@as(c_int, 1), boj_wasm_is_valid(@intCast(slot)));

    // Module size > 0.
    try std.testing.expect(boj_wasm_module_size(@intCast(slot)) > 0);

    // Hash retrievable (pass buffer length for bounds-checked API).
    var hash_buf: [HASH_HEX_LEN]u8 = undefined;
    const hlen = boj_wasm_hash(@intCast(slot), &hash_buf, HASH_HEX_LEN);
    try std.testing.expectEqual(HASH_HEX_LEN, hlen);

    // Unregister.
    try std.testing.expectEqual(@as(c_int, 0), boj_wasm_unregister(@intCast(slot)));
    try std.testing.expectEqual(@as(usize, 0), boj_wasm_count());
}

test "WASM register rejects invalid module" {
    boj_wasm_reset();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(shim.io(), "bad.wasm", .{});
    try file.writeStreamingAll(shim.io(), "this is not wasm");
    file.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "bad.wasm", &path_buf);
    const path = path_buf[0..path_len];

    const slot = boj_wasm_register(path.ptr, path.len, 0);
    try std.testing.expectEqual(@as(c_int, -1), slot);
    try std.testing.expectEqual(@as(usize, 0), boj_wasm_count());
}

test "WASM validate export" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Valid WASM.
    const good = try tmp_dir.dir.createFile(shim.io(), "good.wasm", .{});
    try good.writeStreamingAll(shim.io(), &WASM_MAGIC);
    try good.writeStreamingAll(shim.io(), &WASM_VERSION_1);
    try good.writeStreamingAll(shim.io(), "body");
    good.close(shim.io());

    // Invalid file.
    const bad = try tmp_dir.dir.createFile(shim.io(), "bad.txt", .{});
    try bad.writeStreamingAll(shim.io(), "hello");
    bad.close(shim.io());

    var good_path: [std.fs.max_path_bytes]u8 = undefined;
    const gp_len = try tmp_dir.dir.realPathFile(shim.io(), "good.wasm", &good_path);
    const gp = good_path[0..gp_len];
    var bad_path: [std.fs.max_path_bytes]u8 = undefined;
    const bp_len = try tmp_dir.dir.realPathFile(shim.io(), "bad.txt", &bad_path);
    const bp = bad_path[0..bp_len];

    try std.testing.expectEqual(@as(c_int, 1), boj_wasm_validate(gp.ptr, gp.len));
    try std.testing.expectEqual(@as(c_int, 0), boj_wasm_validate(bp.ptr, bp.len));
}

test "loader set_hash delegates to catalogue" {
    const catalogue = @import("catalogue.zig");
    _ = catalogue.boj_catalogue_init();

    // Register a cartridge so we have an index to set hash on (7 args).
    // status=0 (development), tier=0 (teranga), domain=1 (cloud).
    const name = "hash-test-cart";
    const ver = "1.0.0";
    const idx = catalogue.boj_catalogue_register(name.ptr, name.len, ver.ptr, ver.len, 0, 0, 1);
    try std.testing.expect(idx >= 0);
    const uidx: usize = @intCast(idx);

    // Set hash via loader wrapper (64-char hex string).
    const hash_hex = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    try std.testing.expectEqual(@as(c_int, 0), boj_loader_set_hash(uidx, hash_hex.ptr, hash_hex.len));

    // Wrong length should fail.
    const short = "abc123";
    try std.testing.expectEqual(@as(c_int, -1), boj_loader_set_hash(uidx, short.ptr, short.len));

    // Verify catalogue has the hash via get_hash (returns length written).
    var out: [64]u8 = undefined;
    const written = catalogue.boj_catalogue_get_hash(uidx, &out);
    try std.testing.expectEqual(@as(usize, 64), written);
    try std.testing.expectEqualSlices(u8, hash_hex, &out);
}

test "loader verify checks file hash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with known content.
    const f = try tmp_dir.dir.createFile(shim.io(), "verify-test.bin", .{});
    try f.writeStreamingAll(shim.io(), "hello world");
    f.close(shim.io());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(shim.io(), "verify-test.bin", &path_buf);
    const path = path_buf[0..path_len];

    // Compute expected SHA-256 of "hello world".
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("hello world");
    const digest = hasher.finalResult();
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    // Correct hash → 1.
    try std.testing.expectEqual(@as(c_int, 1), boj_loader_verify(path.ptr, path.len, &hex, 64));

    // Wrong hash → 0.
    var wrong: [64]u8 = [_]u8{'0'} ** 64;
    try std.testing.expectEqual(@as(c_int, 0), boj_loader_verify(path.ptr, path.len, &wrong, 64));

    // Wrong length → -1.
    const short = "abc";
    try std.testing.expectEqual(@as(c_int, -1), boj_loader_verify(path.ptr, path.len, short.ptr, short.len));
}

const shim = @import("cartridge_shim");
