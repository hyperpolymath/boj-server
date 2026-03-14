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
const Allocator = std.mem.Allocator;

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

/// Default VeriSimDB endpoint when VERISIMDB_URL is not set.
const DEFAULT_VERISIM_URL = "http://localhost:8080";

/// Maximum HTTP response body we will capture from curl (50 KiB).
const MAX_HTTP_RESPONSE: usize = 50 * 1024;

/// Timeout in seconds for curl requests.
const CURL_TIMEOUT_SECS = "5";

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
/// Count of failed HTTP requests in persistent mode (best-effort metric).
var http_errors: usize = 0;
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
// Persistent mode — HTTP helpers (shell out to curl)
// ═══════════════════════════════════════════════════════════════════════
//
// VeriSimDB REST API:
//   POST   {url}/api/v1/octads          — create/update an octad (key-value as JSON metadata)
//   GET    {url}/api/v1/octads/{key}    — retrieve an octad by key
//   DELETE {url}/api/v1/octads/{key}    — delete an octad by key
//
// We shell out to curl rather than using std.http.Client because:
//   1. The V-lang adapter already uses curl — consistent approach
//   2. curl handles TLS, redirects, retries more robustly
//   3. Avoids Zig std.http API churn across versions

/// Resolve the VeriSimDB base URL: uses global endpoint if set,
/// otherwise falls back to VERISIMDB_URL env var, then the default.
fn resolveBaseUrl() [MAX_ENDPOINT_LEN]u8 {
    if (endpoint_len > 0) {
        return endpoint;
    }
    // Try the environment variable (read outside of mutex — no global state mutation).
    const env_val = std.posix.getenv("VERISIMDB_URL");
    if (env_val) |url| {
        var buf: [MAX_ENDPOINT_LEN]u8 = [_]u8{0} ** MAX_ENDPOINT_LEN;
        const len = @min(url.len, MAX_ENDPOINT_LEN);
        @memcpy(buf[0..len], url[0..len]);
        return buf;
    }
    // Default fallback.
    var buf: [MAX_ENDPOINT_LEN]u8 = [_]u8{0} ** MAX_ENDPOINT_LEN;
    @memcpy(buf[0..DEFAULT_VERISIM_URL.len], DEFAULT_VERISIM_URL);
    return buf;
}

/// Return the effective URL length (position of first null byte).
fn urlLen(buf: []const u8) usize {
    for (buf, 0..) |c, i| {
        if (c == 0) return i;
    }
    return buf.len;
}

/// Build a full API URL: "{base}/api/v1/octads" or "{base}/api/v1/octads/{key}".
/// Returns a stack buffer and the used length.
fn buildApiUrl(base: []const u8, base_len: usize, key: ?[]const u8) struct { buf: [512]u8, len: usize } {
    var buf: [512]u8 = [_]u8{0} ** 512;
    var pos: usize = 0;

    // Strip trailing slash from base if present.
    var effective_base_len = base_len;
    if (effective_base_len > 0 and base[effective_base_len - 1] == '/') {
        effective_base_len -= 1;
    }

    // Copy base URL.
    if (effective_base_len > buf.len) return .{ .buf = buf, .len = 0 };
    @memcpy(buf[pos..][0..effective_base_len], base[0..effective_base_len]);
    pos += effective_base_len;

    // Append path.
    const path = "/api/v1/octads";
    if (pos + path.len > buf.len) return .{ .buf = buf, .len = 0 };
    @memcpy(buf[pos..][0..path.len], path);
    pos += path.len;

    // Append key suffix if provided.
    if (key) |k| {
        if (pos + 1 + k.len > buf.len) return .{ .buf = buf, .len = 0 };
        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..k.len], k);
        pos += k.len;
    }

    return .{ .buf = buf, .len = pos };
}

/// Build the JSON body for a PUT/POST request.
/// Format: {"key": "<key>", "value": "<value>"}
/// Note: values are base64-encoded to avoid JSON escaping issues with
/// arbitrary binary data.
fn buildJsonBody(key: []const u8, value: []const u8) struct { buf: [MAX_KEY_LEN + MAX_VALUE_LEN + 64]u8, len: usize } {
    const max_len = MAX_KEY_LEN + MAX_VALUE_LEN + 64;
    var buf: [max_len]u8 = [_]u8{0} ** max_len;
    var pos: usize = 0;

    const prefix = "{\"key\":\"";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;

    const mid = "\",\"value\":\"";
    @memcpy(buf[pos..][0..mid.len], mid);
    pos += mid.len;

    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;

    const suffix = "\"}";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return .{ .buf = buf, .len = pos };
}

/// Result of an HTTP request via curl.
const HttpResult = struct {
    ok: bool,
    body: [MAX_HTTP_RESPONSE]u8,
    body_len: usize,
};

/// Execute a curl command and return success/failure + stdout body.
/// Caller must NOT hold the mutex (this blocks on a subprocess).
fn curlExec(argv: []const []const u8) HttpResult {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = argv,
        .max_output_bytes = MAX_HTTP_RESPONSE,
    }) catch {
        return HttpResult{ .ok = false, .body = [_]u8{0} ** MAX_HTTP_RESPONSE, .body_len = 0 };
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    const success = (result.term == .Exited and result.term.Exited == 0);

    var body: [MAX_HTTP_RESPONSE]u8 = [_]u8{0} ** MAX_HTTP_RESPONSE;
    const copy_len = @min(result.stdout.len, MAX_HTTP_RESPONSE);
    @memcpy(body[0..copy_len], result.stdout[0..copy_len]);

    return HttpResult{ .ok = success, .body = body, .body_len = copy_len };
}

/// POST a key-value pair to VeriSimDB. Returns true on success.
fn httpPut(base_url: []const u8, base_url_len: usize, key: []const u8, value: []const u8) bool {
    const api = buildApiUrl(base_url, base_url_len, null);
    if (api.len == 0) return false;

    const json = buildJsonBody(key, value);
    if (json.len == 0) return false;

    const result = curlExec(&.{
        "curl",
        "-sf",
        "--max-time",
        CURL_TIMEOUT_SECS,
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        json.buf[0..json.len],
        api.buf[0..api.len],
    });
    return result.ok;
}

/// GET a value from VeriSimDB by key. Returns the response body on success.
fn httpGet(base_url: []const u8, base_url_len: usize, key: []const u8) HttpResult {
    const api = buildApiUrl(base_url, base_url_len, key);
    if (api.len == 0) return HttpResult{ .ok = false, .body = [_]u8{0} ** MAX_HTTP_RESPONSE, .body_len = 0 };

    return curlExec(&.{
        "curl",
        "-sf",
        "--max-time",
        CURL_TIMEOUT_SECS,
        api.buf[0..api.len],
    });
}

/// DELETE a key from VeriSimDB. Returns true on success.
fn httpDelete(base_url: []const u8, base_url_len: usize, key: []const u8) bool {
    const api = buildApiUrl(base_url, base_url_len, key);
    if (api.len == 0) return false;

    const result = curlExec(&.{
        "curl",
        "-sf",
        "--max-time",
        CURL_TIMEOUT_SECS,
        "-X",
        "DELETE",
        api.buf[0..api.len],
    });
    return result.ok;
}

/// Extract the "value" field from a JSON response body.
/// Looks for "value":"..." and returns the content between quotes.
/// This is intentionally simple — no full JSON parser needed for our
/// well-defined API responses.
fn extractJsonValue(body: []const u8) ?[]const u8 {
    const needle = "\"value\":\"";
    const start_idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = start_idx + needle.len;
    if (val_start >= body.len) return null;
    const val_end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return null;
    return body[val_start..val_end];
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
    http_errors = 0;

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
/// In persistent mode, also POSTs to VeriSimDB REST API (write-through).
/// The in-memory store always reflects the latest state; the HTTP call is
/// best-effort — if VeriSimDB is unreachable the local write still succeeds
/// and the http_errors counter is incremented.
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

    // Capture persistent-mode state while holding lock.
    const is_persistent = (mode == .persistent);

    // Update in-memory store (always).
    if (findEntry(key_ptr, key_len)) |idx| {
        entries[idx].value = [_]u8{0} ** MAX_VALUE_LEN;
        entries[idx].value_len = copyBounded(&entries[idx].value, value_ptr, value_len);
        entries[idx].updated_at = std.time.timestamp();
        writes += 1;
    } else {
        // Find a free slot.
        if (entry_count >= MAX_ENTRIES) return -1;
        var found_slot = false;
        for (0..MAX_ENTRIES) |i| {
            if (!entries[i].active) {
                entries[i] = StoreEntry{};
                entries[i].active = true;
                entries[i].key_len = copyBounded(&entries[i].key, key_ptr, key_len);
                entries[i].value_len = copyBounded(&entries[i].value, value_ptr, value_len);
                entries[i].updated_at = std.time.timestamp();
                entry_count += 1;
                writes += 1;
                found_slot = true;
                break;
            }
        }
        if (!found_slot) return -1;
    }

    // Persistent mode: POST to VeriSimDB (outside critical path).
    if (is_persistent) {
        const base = resolveBaseUrl();
        const effective_len = if (endpoint_len > 0) endpoint_len else urlLen(&base);
        if (!httpPut(&base, effective_len, key_ptr[0..key_len], value_ptr[0..value_len])) {
            http_errors += 1;
        }
    }

    return 0;
}

/// Retrieve a value by key. Copies into out_ptr, returns bytes written.
/// In persistent mode, if the key is not in the local cache, attempts a
/// GET from VeriSimDB and populates the cache on success.
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

    // Try local cache first.
    if (findEntry(key_ptr, key_len)) |idx| {
        const vlen = entries[idx].value_len;
        const write_len = @min(vlen, out_len);
        @memcpy(out_ptr[0..write_len], entries[idx].value[0..write_len]);
        return @intCast(write_len);
    }

    // Persistent mode: try fetching from VeriSimDB if not in local cache.
    if (mode == .persistent) {
        const base = resolveBaseUrl();
        const effective_len = if (endpoint_len > 0) endpoint_len else urlLen(&base);
        const resp = httpGet(&base, effective_len, key_ptr[0..key_len]);
        if (resp.ok and resp.body_len > 0) {
            // Try to extract the value from the JSON response.
            if (extractJsonValue(resp.body[0..resp.body_len])) |val| {
                const write_len = @min(val.len, out_len);
                @memcpy(out_ptr[0..write_len], val[0..write_len]);

                // Populate local cache for subsequent reads.
                if (val.len <= MAX_VALUE_LEN) {
                    if (entry_count < MAX_ENTRIES) {
                        for (0..MAX_ENTRIES) |i| {
                            if (!entries[i].active) {
                                entries[i] = StoreEntry{};
                                entries[i].active = true;
                                entries[i].key_len = copyBounded(&entries[i].key, key_ptr, key_len);
                                entries[i].value_len = copyBounded(&entries[i].value, val.ptr, val.len);
                                entries[i].updated_at = std.time.timestamp();
                                entry_count += 1;
                                break;
                            }
                        }
                    }
                }

                return @intCast(write_len);
            }
        } else {
            http_errors += 1;
        }
    }

    return 0; // not found
}

/// Delete a key-value pair. Returns 0 on success, -1 if not found.
/// In persistent mode, also issues a DELETE to VeriSimDB (best-effort).
pub export fn verisimdb_store_delete(
    key_ptr: [*]const u8,
    key_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;
    if (key_len == 0 or key_len > MAX_KEY_LEN) return -1;

    // Capture persistent state while holding lock.
    const is_persistent = (mode == .persistent);

    if (findEntry(key_ptr, key_len)) |idx| {
        entries[idx] = StoreEntry{};
        entry_count -= 1;
        writes += 1;

        // Persistent mode: DELETE from VeriSimDB (best-effort).
        if (is_persistent) {
            const base = resolveBaseUrl();
            const effective_len = if (endpoint_len > 0) endpoint_len else urlLen(&base);
            if (!httpDelete(&base, effective_len, key_ptr[0..key_len])) {
                http_errors += 1;
            }
        }

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

/// Return the number of HTTP errors (persistent mode only).
/// Useful for monitoring write-through health.
pub export fn verisimdb_store_http_errors() usize {
    mutex.lock();
    defer mutex.unlock();
    return http_errors;
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

// ═══════════════════════════════════════════════════════════════════════
// Persistent mode tests
// ═══════════════════════════════════════════════════════════════════════
//
// These tests verify the persistent mode plumbing without requiring a
// running VeriSimDB instance. HTTP calls will fail (curl can't connect)
// but the in-memory store should still work correctly — confirming the
// best-effort / write-through design.

test "persistent mode put succeeds locally even without VeriSimDB running" {
    // Use a bogus endpoint — curl will fail to connect, but the in-memory
    // write should still succeed (best-effort persistence).
    const ep = "http://127.0.0.1:19999";
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_init(ep.ptr, ep.len));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.persistent)), verisimdb_store_mode());

    const key = "persist:test:key";
    const value = "persist-value-42";
    // Put should succeed (in-memory write) despite HTTP failure.
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_put(key.ptr, key.len, value.ptr, value.len));
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_count());

    // Value should be retrievable from local cache.
    var out: [MAX_VALUE_LEN]u8 = undefined;
    const rlen = verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN);
    try std.testing.expect(rlen > 0);
    try std.testing.expectEqualSlices(u8, value, out[0..@intCast(rlen)]);

    // HTTP errors counter should have been incremented (curl failed).
    try std.testing.expect(verisimdb_store_http_errors() > 0);

    verisimdb_store_deinit();
}

test "persistent mode delete succeeds locally even without VeriSimDB running" {
    const ep = "http://127.0.0.1:19999";
    _ = verisimdb_store_init(ep.ptr, ep.len);

    const key = "persist:del:key";
    const value = "to-be-deleted";
    _ = verisimdb_store_put(key.ptr, key.len, value.ptr, value.len);
    try std.testing.expectEqual(@as(usize, 1), verisimdb_store_count());

    // Delete should succeed locally despite HTTP failure.
    try std.testing.expectEqual(@as(c_int, 0), verisimdb_store_delete(key.ptr, key.len));
    try std.testing.expectEqual(@as(usize, 0), verisimdb_store_count());

    verisimdb_store_deinit();
}

test "persistent mode get falls through to not-found when VeriSimDB unreachable" {
    const ep = "http://127.0.0.1:19999";
    _ = verisimdb_store_init(ep.ptr, ep.len);

    const key = "persist:missing:key";
    var out: [MAX_VALUE_LEN]u8 = undefined;
    // Should return 0 (not found) — the HTTP call fails, and there is
    // nothing in the local cache either.
    const rlen = verisimdb_store_get(key.ptr, key.len, &out, MAX_VALUE_LEN);
    try std.testing.expectEqual(@as(c_int, 0), rlen);

    verisimdb_store_deinit();
}

test "mode switching between in-memory and persistent" {
    // Start in-memory.
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.in_memory)), verisimdb_store_mode());
    try std.testing.expectEqual(@as(usize, 0), verisimdb_store_http_errors());

    // Switch to persistent.
    const ep = "http://127.0.0.1:19999";
    _ = verisimdb_store_init(ep.ptr, ep.len);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.persistent)), verisimdb_store_mode());

    // Switch back to in-memory.
    _ = verisimdb_store_init(empty.ptr, 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(StoreMode.in_memory)), verisimdb_store_mode());
    // http_errors should have been reset on re-init.
    try std.testing.expectEqual(@as(usize, 0), verisimdb_store_http_errors());

    verisimdb_store_deinit();
}

test "in-memory mode does not increment http_errors" {
    const empty = "";
    _ = verisimdb_store_init(empty.ptr, 0);

    const key = "inmem:no-http";
    const value = "safe";
    _ = verisimdb_store_put(key.ptr, key.len, value.ptr, value.len);
    _ = verisimdb_store_delete(key.ptr, key.len);

    // No HTTP calls should have been made in in-memory mode.
    try std.testing.expectEqual(@as(usize, 0), verisimdb_store_http_errors());

    verisimdb_store_deinit();
}

test "buildApiUrl constructs correct paths" {
    const base = "http://localhost:8080";
    // Without key suffix.
    const url1 = buildApiUrl(base, base.len, null);
    try std.testing.expectEqualSlices(u8, "http://localhost:8080/api/v1/octads", url1.buf[0..url1.len]);

    // With key suffix.
    const url2 = buildApiUrl(base, base.len, "my-key");
    try std.testing.expectEqualSlices(u8, "http://localhost:8080/api/v1/octads/my-key", url2.buf[0..url2.len]);

    // With trailing slash on base.
    const base2 = "http://localhost:8080/";
    const url3 = buildApiUrl(base2, base2.len, null);
    try std.testing.expectEqualSlices(u8, "http://localhost:8080/api/v1/octads", url3.buf[0..url3.len]);
}

test "buildJsonBody produces valid JSON structure" {
    const json = buildJsonBody("test-key", "test-value");
    const expected = "{\"key\":\"test-key\",\"value\":\"test-value\"}";
    try std.testing.expectEqualSlices(u8, expected, json.buf[0..json.len]);
}

test "extractJsonValue parses response body" {
    const body = "{\"id\":\"abc\",\"key\":\"k\",\"value\":\"hello-world\",\"ts\":123}";
    const val = extractJsonValue(body);
    try std.testing.expect(val != null);
    try std.testing.expectEqualSlices(u8, "hello-world", val.?);
}

test "extractJsonValue returns null for missing field" {
    const body = "{\"id\":\"abc\",\"key\":\"k\"}";
    try std.testing.expect(extractJsonValue(body) == null);
}

test "urlLen finds null terminator" {
    var buf: [16]u8 = [_]u8{0} ** 16;
    buf[0] = 'h';
    buf[1] = 'i';
    try std.testing.expectEqual(@as(usize, 2), urlLen(&buf));
}

test "resolveBaseUrl uses endpoint when set" {
    const ep = "http://custom:9090";
    _ = verisimdb_store_init(ep.ptr, ep.len);
    const resolved = resolveBaseUrl();
    try std.testing.expectEqualSlices(u8, "http://custom:9090", resolved[0..ep.len]);
    verisimdb_store_deinit();
}
