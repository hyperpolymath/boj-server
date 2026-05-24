// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// coord_identity.zig — Phase 1 (ADR-0016) ed25519 identity foundation.
//
// Realises the C-ABI contract documented in
// `cartridges/local-coord-mcp/abi/LocalCoord/Identity.idr`:
//
//   * boj_coord_identity_init(key_path)            -> int  (0 ok)
//   * boj_coord_identity_get_pubkey(out, out_len)  -> int  (bytes written, -1 err)
//   * boj_coord_identity_load_known_peers(path)    -> int  (count, -1 err)
//   * boj_coord_identity_known_peer_count()        -> int
//
// Phase 1 scope: keypair generation, on-disk persistence (0600), pubkey
// export, and a minimal TOML-shaped parser for the trust list. NO
// signing, NO verification, NO network — those are Phase 2 / 3.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const crypto = std.crypto;
const Ed25519 = crypto.sign.Ed25519;

const PUBKEY_BYTES: usize = 32;
const SEED_BYTES: usize = 32;
const SIG_BYTES: usize = 64;
const MAX_KNOWN_PEERS: usize = 64;
const PEER_ID_MAX: usize = 32;
const HOST_MAX: usize = 256;

// ═══════════════════════════════════════════════════════════════════
// Global identity state (Phase 1 — singleton per process)
// ═══════════════════════════════════════════════════════════════════

const KnownPeer = struct {
    peer_id: [PEER_ID_MAX]u8,
    peer_id_len: u8,
    pubkey: [PUBKEY_BYTES]u8,
    host: [HOST_MAX]u8,
    host_len: u16,
    port: u16,
};

const IdentityState = struct {
    initialised: bool = false,
    key_pair: ?Ed25519.KeyPair = null,
    known_peers: [MAX_KNOWN_PEERS]KnownPeer = undefined,
    known_peer_count: usize = 0,
};

var state: IdentityState = .{};
var state_mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════

fn cStrToSlice(ptr: [*:0]const u8) []const u8 {
    return mem.span(ptr);
}

fn ensureParentDir(path: []const u8) !void {
    if (fs.path.dirname(path)) |dir| {
        fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
}

fn writeSeedFile(path: []const u8, seed: [SEED_BYTES]u8) !void {
    try ensureParentDir(path);
    const file = try fs.createFileAbsolute(path, .{ .mode = 0o600, .truncate = true });
    defer file.close();
    try file.writeAll(&seed);
}

fn readSeedFile(path: []const u8) !?[SEED_BYTES]u8 {
    const file = fs.openFileAbsolute(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close();
    var buf: [SEED_BYTES]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n != SEED_BYTES) return error.InvalidKeyFile;
    return buf;
}

// ═══════════════════════════════════════════════════════════════════
// Public FFI surface — matches Identity.idr contract
// ═══════════════════════════════════════════════════════════════════

/// Initialise the identity store. Loads the keypair from `key_path` if
/// present; otherwise generates a fresh keypair and persists the seed
/// at that path (mode 0600). Idempotent: subsequent calls with the
/// same path are no-ops.
pub export fn boj_coord_identity_init(key_path: [*:0]const u8) c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (state.initialised) return 0;

    const path = cStrToSlice(key_path);

    var seed: [SEED_BYTES]u8 = undefined;
    if (readSeedFile(path) catch return -1) |existing| {
        seed = existing;
    } else {
        crypto.random.bytes(&seed);
        writeSeedFile(path, seed) catch return -2;
    }

    // Ed25519.KeyPair.generateDeterministic is the Zig 0.15.x API for
    // seed → keypair derivation. It can theoretically fail with
    // IdentityElementError for adversarial seeds; not reachable for a
    // CSPRNG-derived 32-byte input, but propagate the error code for
    // honesty rather than `unreachable`.
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return -3;
    state.key_pair = kp;
    state.initialised = true;
    return 0;
}

/// Copy the local ed25519 public key (32 bytes) into the caller's
/// buffer. Returns bytes written on success (== 32), -1 if not yet
/// initialised, -2 if buffer too small.
pub export fn boj_coord_identity_get_pubkey(out: [*]u8, out_len: usize) c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (!state.initialised) return -1;
    if (out_len < PUBKEY_BYTES) return -2;
    const kp = state.key_pair orelse return -1;
    // Ed25519.PublicKey holds a `.bytes: [32]u8` field directly.
    @memcpy(out[0..PUBKEY_BYTES], &kp.public_key.bytes);
    return @intCast(PUBKEY_BYTES);
}

/// Load the known-peers trust list from `toml_path`. Replaces any
/// previously-loaded set on each call. Returns the number of entries
/// loaded (>= 0) or -1 on parse error. A missing file is treated as
/// zero entries (not an error) so the bus starts cleanly on first run.
pub export fn boj_coord_identity_load_known_peers(toml_path: [*:0]const u8) c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    const path = cStrToSlice(toml_path);
    const file = fs.openFileAbsolute(path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            state.known_peer_count = 0;
            return 0;
        },
        else => return -1,
    };
    defer file.close();

    var buf: [16384]u8 = undefined;
    const n = file.readAll(&buf) catch return -1;
    const text = buf[0..n];

    state.known_peer_count = 0;
    parseTomlPeers(text, &state.known_peers, &state.known_peer_count) catch return -1;
    return @intCast(state.known_peer_count);
}

/// Current number of loaded known peers.
pub export fn boj_coord_identity_known_peer_count() c_int {
    state_mutex.lock();
    defer state_mutex.unlock();
    return @intCast(state.known_peer_count);
}

// ═══════════════════════════════════════════════════════════════════
// Minimal TOML-shaped parser
// ═══════════════════════════════════════════════════════════════════
//
// Accepts the following shape, one or more times:
//
//   [[peer]]
//   id = "claude-7f3a"
//   pubkey = "abcdef..."   # 64 hex chars (32 bytes)
//   host = "192.168.1.42"
//   port = 7746
//
// Comments start with '#'. Blank lines and unknown keys are ignored.
// All four fields are required per `[[peer]]` block; a block missing
// any required field is rejected at the end of that block.

const ParseError = error{ Malformed, BadHex, TooManyPeers, MissingField };

const FieldFlags = packed struct {
    id: bool = false,
    pubkey: bool = false,
    host: bool = false,
    port: bool = false,
};

fn parseTomlPeers(
    text: []const u8,
    out: *[MAX_KNOWN_PEERS]KnownPeer,
    out_count: *usize,
) ParseError!void {
    var in_block = false;
    var current: KnownPeer = std.mem.zeroes(KnownPeer);
    var flags = FieldFlags{};

    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (mem.eql(u8, line, "[[peer]]")) {
            if (in_block) {
                try commitBlock(out, out_count, &current, &flags);
            }
            in_block = true;
            current = std.mem.zeroes(KnownPeer);
            flags = .{};
            continue;
        }

        if (!in_block) return error.Malformed; // stray key=value before any [[peer]]

        const eq_idx = mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = trim(line[0..eq_idx]);
        const value = trim(line[eq_idx + 1 ..]);

        if (mem.eql(u8, key, "id")) {
            const s = stripQuotes(value) orelse return error.Malformed;
            if (s.len == 0 or s.len > PEER_ID_MAX) return error.Malformed;
            @memcpy(current.peer_id[0..s.len], s);
            current.peer_id_len = @intCast(s.len);
            flags.id = true;
        } else if (mem.eql(u8, key, "pubkey")) {
            const s = stripQuotes(value) orelse return error.Malformed;
            try hexDecode(s, current.pubkey[0..]);
            flags.pubkey = true;
        } else if (mem.eql(u8, key, "host")) {
            const s = stripQuotes(value) orelse return error.Malformed;
            if (s.len == 0 or s.len > HOST_MAX) return error.Malformed;
            @memcpy(current.host[0..s.len], s);
            current.host_len = @intCast(s.len);
            flags.host = true;
        } else if (mem.eql(u8, key, "port")) {
            current.port = std.fmt.parseInt(u16, value, 10) catch return error.Malformed;
            flags.port = true;
        }
        // Unknown keys: silently ignored (forward-compat).
    }
    if (in_block) {
        try commitBlock(out, out_count, &current, &flags);
    }
}

fn commitBlock(
    out: *[MAX_KNOWN_PEERS]KnownPeer,
    out_count: *usize,
    current: *const KnownPeer,
    flags: *const FieldFlags,
) ParseError!void {
    if (!(flags.id and flags.pubkey and flags.host and flags.port)) {
        return error.MissingField;
    }
    if (out_count.* >= MAX_KNOWN_PEERS) return error.TooManyPeers;
    out[out_count.*] = current.*;
    out_count.* += 1;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSpace(s[start])) start += 1;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn stripQuotes(s: []const u8) ?[]const u8 {
    if (s.len < 2) return null;
    if (s[0] != '"' or s[s.len - 1] != '"') return null;
    return s[1 .. s.len - 1];
}

fn hexDecode(hex: []const u8, out: []u8) ParseError!void {
    if (hex.len != out.len * 2) return error.BadHex;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = hexNibble(hex[2 * i]) orelse return error.BadHex;
        const lo = hexNibble(hex[2 * i + 1]) orelse return error.BadHex;
        out[i] = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ═══════════════════════════════════════════════════════════════════
// Test-only helpers — allow Zig unit tests to inspect internal state
// without going through the C-ABI surface.
// ═══════════════════════════════════════════════════════════════════

pub fn testResetState() void {
    state_mutex.lock();
    defer state_mutex.unlock();
    state = .{};
}

pub fn testKnownPeerAt(index: usize) ?KnownPeer {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (index >= state.known_peer_count) return null;
    return state.known_peers[index];
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

test "hexDecode roundtrip on a known pubkey-shaped value" {
    var out: [PUBKEY_BYTES]u8 = undefined;
    try hexDecode("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &out);
    try std.testing.expectEqual(@as(u8, 0x01), out[0]);
    try std.testing.expectEqual(@as(u8, 0xef), out[31]);
}

test "hexDecode rejects wrong-length input" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.BadHex, hexDecode("aabbcc", &out)); // 6 chars, need 8
}

test "hexDecode rejects non-hex characters" {
    var out: [2]u8 = undefined;
    try std.testing.expectError(error.BadHex, hexDecode("ZZAA", &out));
}

test "parseTomlPeers handles a single complete block" {
    testResetState();
    const toml =
        \\[[peer]]
        \\id = "claude-7f3a"
        \\pubkey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\host = "192.168.1.42"
        \\port = 7746
    ;
    var peers: [MAX_KNOWN_PEERS]KnownPeer = undefined;
    var count: usize = 0;
    try parseTomlPeers(toml, &peers, &count);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 7746), peers[0].port);
    try std.testing.expectEqualStrings("claude-7f3a", peers[0].peer_id[0..peers[0].peer_id_len]);
}

test "parseTomlPeers handles multiple blocks and comments" {
    testResetState();
    const toml =
        \\# trust list
        \\[[peer]]
        \\id = "alice"
        \\pubkey = "0000000000000000000000000000000000000000000000000000000000000001"
        \\host = "alice.local"
        \\port = 7746
        \\
        \\[[peer]]
        \\id = "bob"
        \\pubkey = "0000000000000000000000000000000000000000000000000000000000000002"
        \\host = "bob.local"
        \\port = 7747
    ;
    var peers: [MAX_KNOWN_PEERS]KnownPeer = undefined;
    var count: usize = 0;
    try parseTomlPeers(toml, &peers, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 7747), peers[1].port);
}

test "parseTomlPeers rejects a block missing fields" {
    const toml =
        \\[[peer]]
        \\id = "incomplete"
        \\host = "x"
    ;
    var peers: [MAX_KNOWN_PEERS]KnownPeer = undefined;
    var count: usize = 0;
    try std.testing.expectError(error.MissingField, parseTomlPeers(toml, &peers, &count));
}

test "FFI: identity init generates and persists, second init no-ops" {
    testResetState();
    const tmp_path = "/tmp/boj-coord-test-identity.key";
    // Clean any previous state
    fs.deleteFileAbsolute(tmp_path) catch {};
    defer fs.deleteFileAbsolute(tmp_path) catch {};

    // Zig string literals already carry a `:0` sentinel, so `.ptr`
    // coerces directly to `[*:0]const u8`. No @ptrCast needed.
    const path_z: [:0]const u8 = tmp_path;
    const rc1 = boj_coord_identity_init(path_z.ptr);
    try std.testing.expectEqual(@as(c_int, 0), rc1);

    var pubkey1: [PUBKEY_BYTES]u8 = undefined;
    const n1 = boj_coord_identity_get_pubkey(&pubkey1, PUBKEY_BYTES);
    try std.testing.expectEqual(@as(c_int, @intCast(PUBKEY_BYTES)), n1);

    // Re-init: idempotent on the same process state.
    const rc2 = boj_coord_identity_init(path_z.ptr);
    try std.testing.expectEqual(@as(c_int, 0), rc2);

    var pubkey2: [PUBKEY_BYTES]u8 = undefined;
    _ = boj_coord_identity_get_pubkey(&pubkey2, PUBKEY_BYTES);
    try std.testing.expectEqualSlices(u8, &pubkey1, &pubkey2);
}

test "FFI: get_pubkey before init returns -1" {
    testResetState();
    var pubkey: [PUBKEY_BYTES]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), boj_coord_identity_get_pubkey(&pubkey, PUBKEY_BYTES));
}

test "FFI: load_known_peers on missing file returns 0" {
    testResetState();
    const missing_z: [:0]const u8 = "/tmp/boj-coord-test-no-such-known-peers.toml";
    const rc = boj_coord_identity_load_known_peers(missing_z.ptr);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqual(@as(c_int, 0), boj_coord_identity_known_peer_count());
}

// RFC 8032 §7.1 TEST 1 — the canonical ed25519 reference vector.
// The matching test in coord-tui/src/main.rs pins the same vector,
// so if both this test and that test pass, the Rust and Zig
// derivations agree with the spec — and therefore with each other
// — across the shared 32-byte seed-file format.
//
// SEED:   9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
// PUBKEY: d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a

test "RFC 8032 §7.1 TEST 1 — seed derives the canonical pubkey" {
    testResetState();
    const seed_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const expect_hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

    var seed: [SEED_BYTES]u8 = undefined;
    try hexDecode(seed_hex, &seed);

    const tmp_path = "/tmp/boj-coord-test-rfc8032.key";
    fs.deleteFileAbsolute(tmp_path) catch {};
    defer fs.deleteFileAbsolute(tmp_path) catch {};
    try writeSeedFile(tmp_path, seed);

    const path_z: [:0]const u8 = tmp_path;
    try std.testing.expectEqual(@as(c_int, 0), boj_coord_identity_init(path_z.ptr));

    var pubkey: [PUBKEY_BYTES]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, @intCast(PUBKEY_BYTES)),
        boj_coord_identity_get_pubkey(&pubkey, PUBKEY_BYTES),
    );

    var expect_bytes: [PUBKEY_BYTES]u8 = undefined;
    try hexDecode(expect_hex, &expect_bytes);
    try std.testing.expectEqualSlices(u8, &expect_bytes, &pubkey);
}
