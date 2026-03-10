// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ VeriSimDB Integration — backing store interface for cartridge state.
//
// Provides a C-ABI layer for persisting cartridge catalogue state, federation
// peer registries, and proof session data to a VeriSimDB instance via its
// HTTP/VQL API.
//
// The interface is designed to work in two modes:
//   1. In-memory (default) — all state in module globals, no network required
//   2. Persistent — syncs with VeriSimDB endpoint for durable storage
//
// This allows BoJ to work standalone (in-memory) or with VeriSimDB when
// available, without changing the cartridge code.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

/// Maximum length of the VeriSimDB endpoint URL.
const MAX_ENDPOINT_LEN: usize = 256;

/// Maximum number of key-value pairs in the store.
const MAX_ENTRIES: usize = 256;

/// Maximum key length.
const MAX_KEY_LEN: usize = 128;

/// Maximum value length.
const MAX_VALUE_LEN: usize = 1024;

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// Storage mode.
pub const StoreMode = enum(c_int) {
    in_memory = 0,
    persistent = 1,
};

/// A key-value entry in the store.
const StoreEntry = struct {
    active: bool = false,
    key: [MAX_KEY_LEN]u8 = [_]u8{0} ** MAX_KEY_LEN,
    key_len: usize = 0,
    value: [MAX_VALUE_LEN]u8 = [_]u8{0} ** MAX_VALUE_LEN,
    value_len: usize = 0,
    /// Unix timestamp of last update.
    updated_at: i64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════
// Global state
// ═══════════════════════════════════════════════════════════════════════

/// VeriSimDB endpoint (e.g. "http://localhost:8080").
var endpoint: [MAX_ENDPOINT_LEN]u8 = [_]u8{0} ** MAX_ENDPOINT_LEN;
var endpoint_len: usize = 0;

/// Current storage mode.
var mode: StoreMode = .in_memory;

/// Whether the backing store has been initialised.
var initialised: bool = false;

/// In-memory key-value store.
var entries: [MAX_ENTRIES]StoreEntry = [_]StoreEntry{.{}} ** MAX_ENTRIES;
var entry_count: usize = 0;

/// Statistics.
var reads: usize = 0;
var writes: usize = 0;
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════

/// Copy bounded bytes into a fixed buffer.
fn copyBounded(dst: []u8, src_ptr: [*]const u8, src_len: usize) usize {
    const len = @min(src_len, dst.len);
    @memcpy(dst[0..len], src_ptr[0..len]);
    return len;
}

/// Find an entry by key. Returns index or null.
fn findEntry(key_ptr: [*]const u8, key_len: usize) ?usize {
    for (0..MAX_ENTRIES) |i| {
        if (entries[i].active and entries[i].key_len == key_len) {
            if (std.mem.eql(u8, entries[i].key[0..key_len], key_ptr[0..key_len])) {
                return i;
            }
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the VeriSimDB backing store.
/// If endpoint is provided (len > 0), switches to persistent mode.
/// If no endpoint, uses in-memory mode.
/// Returns 0 on success.
pub export fn verisimdb_store_init(
    endpoint_ptr: [*]const u8,
    ep_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // Reset state.
    entries = [_]StoreEntry{.{}} ** MAX_ENTRIES;
    entry_count = 0;
    reads = 0;
    writes = 0;

    if (ep_len > 0 and ep_len <= MAX_ENDPOINT_LEN) {
        endpoint_len = copyBounded(&endpoint, endpoint_ptr, ep_len);
        mode = .persistent;
    } else {
        endpoint_len = 0;
        mode = .in_memory;
    }
    initialised = true;
    return 0;
}

/// Deinitialise the store.
pub export fn verisimdb_store_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    entries = [_]StoreEntry{.{}} ** MAX_ENTRIES;
    entry_count = 0;
    initialised = false;
    mode = .in_memory;
}

/// Get the current storage mode. Returns 0 (in_memory) or 1 (persistent).
pub export fn verisimdb_store_mode() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intFromEnum(mode);
}

/// Check if the store is initialised.
pub export fn verisimdb_store_ready() c_int {
    mutex.lock();
    defer mutex.unlock();
    return if (initialised) 1 else 0;
}

/// Store a key-value pair. Overwrites existing entries with the same key.
/// Returns 0 on success, -1 on error.
pub export fn verisimdb_store_put(
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;
    if (key_len == 0 or key_len > MAX_KEY_LEN) return -1;
    if (value_len > MAX_VALUE_LEN) return -1;

    // Check for existing entry.
    if (findEntry(key_ptr, key_len)) |idx| {
        entries[idx].value = [_]u8{0} ** MAX_VALUE_LEN;
        entries[idx].value_len = copyBounded(&entries[idx].value, value_ptr, value_len);
        entries[idx].updated_at = std.time.timestamp();
        writes += 1;
        return 0;
    }

    // Find a free slot.
    if (entry_count >= MAX_ENTRIES) return -1;
    for (0..MAX_ENTRIES) |i| {
        if (!entries[i].active) {
            entries[i] = StoreEntry{};
            entries[i].active = true;
            entries[i].key_len = copyBounded(&entries[i].key, key_ptr, key_len);
            entries[i].value_len = copyBounded(&entries[i].value, value_ptr, value_len);
            entries[i].updated_at = std.time.timestamp();
            entry_count += 1;
            writes += 1;
            return 0;
        }
    }
    return -1;
}

/// Retrieve a value by key. Copies into out_ptr, returns bytes written.
/// Returns 0 if key not found, -1 on error.
pub export fn verisimdb_store_get(
    key_ptr: [*]const u8,
    key_len: usize,
    out_ptr: [*]u8,
    out_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;
    if (key_len == 0 or key_len > MAX_KEY_LEN) return -1;

    reads += 1;

    if (findEntry(key_ptr, key_len)) |idx| {
        const vlen = entries[idx].value_len;
        const write_len = @min(vlen, out_len);
        @memcpy(out_ptr[0..write_len], entries[idx].value[0..write_len]);
        return @intCast(write_len);
    }
    return 0; // not found
}

/// Delete a key-value pair. Returns 0 on success, -1 if not found.
pub export fn verisimdb_store_delete(
    key_ptr: [*]const u8,
    key_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;
    if (key_len == 0 or key_len > MAX_KEY_LEN) return -1;

    if (findEntry(key_ptr, key_len)) |idx| {
        entries[idx] = StoreEntry{};
        entry_count -= 1;
        writes += 1;
        return 0;
    }
    return -1; // not found
}

/// Return the number of entries in the store.
pub export fn verisimdb_store_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return entry_count;
}

/// Return the total number of reads since init.
pub export fn verisimdb_store_reads() usize {
    mutex.lock();
    defer mutex.unlock();
    return reads;
}

/// Return the total number of writes since init.
pub export fn verisimdb_store_writes() usize {
    mutex.lock();
    defer mutex.unlock();
    return writes;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and deinit store" {
    const empty = "";
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_init(empty.ptr, 0));
    try std.testing.expectEqual(@as(c_int, 1), verisimdb_store_ready());
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.in_memory)), verisimdb_store_mode());
    verisimdb_store_deinit();
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_ready());
}

test "init with endpoint sets persistent mode" {
    const ep = "http://localhost:8080";
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_init(ep.ptr, ep.len));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.persistent)), verisimdb_store_mode());
    verisimdb_store_deinit();
}

test "put and get key-value" {
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);

    const key = "cartridge:database-mcp:version";
    const value = "0.1.0";
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_put(key.ptr, key.len, value.ptr, value.len));
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_count());

    var out: [MAX_VALUE_LEN]u8 = undefined;
    const rlen = verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN);
    try std.testing.expect(rlen > 0);
    try std.testing.expectEqualSlices(u8, value, out[0..@intCast(rlen)]);

    verisimdb_store_deinit();
}

test "overwrite existing key" {
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);

    const key = "state:federation";
    const v1 = "initialising";
    const v2 = "running";
    _ = verisimdb_store_put(key.ptr, key.len, v1.ptr, v1.len);
    _ = verisimdb_store_put(key.ptr, key.len, v2.ptr, v2.len);

    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_count());

    var out: [MAX_VALUE_LEN]u8 = undefined;
    const rlen = verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN);
    try std.testing.expectEqualSlices(u8, v2, out[0..@intCast(rlen)]);

    verisimdb_store_deinit();
}

test "delete key" {
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);

    const key = "temp:session";
    const value = "abc123";
    _ = verisimdb_store_put(key.ptr, key.len, value.ptr, value.len);
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_count());

    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_delete(key.ptr, key.len));
    try std.testing.expectEqual(@as(usize, 0), verisimdb_store_count());

    // Get should return 0 (not found).
    var out: [MAX_VALUE_LEN]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN));

    verisimdb_store_deinit();
}

test "stats tracking" {
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);

    const key = "stats:test";
    const value = "data";
    _ = verisimdb_store_put(key.ptr, key.len, value.ptr, value.len);
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_writes());

    var out: [MAX_VALUE_LEN]u8 = undefined;
    _ = verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN);
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_reads());

    verisimdb_store_deinit();
}

test "operations on uninitialised store fail" {
    verisimdb_store_deinit();
    const key = "test";
    const value = "data";
    try std.testing.expectEqual(@as(c_int, -1), verisimdb_store_put(key.ptr, key.len, value.ptr, value.len));
    var out: [MAX_VALUE_LEN]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN));
}
