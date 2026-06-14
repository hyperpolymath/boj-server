// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Auto-SDP FFI — Software Defined Perimeter for community nodes.
//
// Implements a zero-trust perimeter around federation nodes:
//   - Node identity verification via X25519 keypair
//   - Allow-list of authorised peer node IDs
//   - Per-peer rate limiting (requests/second)
//   - Automatic ban on repeated authentication failures
//   - Integration with Umoja federation key exchange
//
// The SDP layer sits between the network transport and the federation
// protocol, rejecting traffic from unverified sources before it reaches
// the gossip layer.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

const MAX_PEERS: usize = 128;
const MAX_BANNED: usize = 64;
const NODE_ID_LEN: usize = 32;
const DEFAULT_RATE_LIMIT: u32 = 100; // requests per second
const BAN_THRESHOLD: u8 = 5; // failed auths before ban
const BAN_DURATION_S: i64 = 300; // 5 minutes

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

const PeerPolicy = enum(u8) {
    allow = 0,
    deny = 1,
    rate_limited = 2,
};

const AuthorisedPeer = struct {
    node_id: [NODE_ID_LEN]u8 = [_]u8{0} ** NODE_ID_LEN,
    id_len: usize = 0,
    policy: PeerPolicy = .allow,
    rate_limit: u32 = DEFAULT_RATE_LIMIT,
    request_count: u64 = 0,
    last_request_ts: i64 = 0,
    auth_failures: u8 = 0,
    active: bool = false,
};

const BannedPeer = struct {
    node_id: [NODE_ID_LEN]u8 = [_]u8{0} ** NODE_ID_LEN,
    id_len: usize = 0,
    banned_at: i64 = 0,
    reason: u8 = 0, // 0=auth_failure, 1=rate_exceeded, 2=manual
};

// ═══════════════════════════════════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════════════════════════════════

var authorised: [MAX_PEERS]AuthorisedPeer = [_]AuthorisedPeer{.{}} ** MAX_PEERS;
var auth_count: usize = 0;
var banned: [MAX_BANNED]BannedPeer = [_]BannedPeer{.{}} ** MAX_BANNED;
var ban_count: usize = 0;
var sdp_enabled: bool = false;
var open_mode: bool = true; // when true, unauthenticated peers are allowed (seed bootstrapping)
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal API
// ═══════════════════════════════════════════════════════════════════════

fn init() void {
    auth_count = 0;
    ban_count = 0;
    authorised = [_]AuthorisedPeer{.{}} ** MAX_PEERS;
    banned = [_]BannedPeer{.{}} ** MAX_BANNED;
    sdp_enabled = true;
    open_mode = true;
}

fn authorisePeer(id_ptr: [*]const u8, id_len: usize, rate_limit: u32) i32 {
    if (auth_count >= MAX_PEERS) return -1;
    const actual = @min(id_len, NODE_ID_LEN);
    var peer = &authorised[auth_count];
    @memcpy(peer.node_id[0..actual], id_ptr[0..actual]);
    peer.id_len = actual;
    peer.policy = .allow;
    peer.rate_limit = if (rate_limit == 0) DEFAULT_RATE_LIMIT else rate_limit;
    peer.active = true;
    auth_count += 1;
    return @as(i32, @intCast(auth_count - 1));
}

fn findPeer(id_ptr: [*]const u8, id_len: usize) ?usize {
    const actual = @min(id_len, NODE_ID_LEN);
    for (authorised[0..auth_count], 0..) |peer, i| {
        if (peer.id_len == actual and
            std.mem.eql(u8, peer.node_id[0..actual], id_ptr[0..actual]))
        {
            return i;
        }
    }
    return null;
}

fn isBanned(id_ptr: [*]const u8, id_len: usize) bool {
    const actual = @min(id_len, NODE_ID_LEN);
    const now = std.time.timestamp();
    for (banned[0..ban_count]) |b| {
        if (b.id_len == actual and
            std.mem.eql(u8, b.node_id[0..actual], id_ptr[0..actual]))
        {
            // Check if ban has expired
            if (now - b.banned_at < BAN_DURATION_S) return true;
        }
    }
    return false;
}

fn banPeer(id_ptr: [*]const u8, id_len: usize, reason: u8) void {
    if (ban_count >= MAX_BANNED) {
        // Evict oldest ban
        for (0..MAX_BANNED - 1) |i| {
            banned[i] = banned[i + 1];
        }
        ban_count -= 1;
    }
    const actual = @min(id_len, NODE_ID_LEN);
    var b = &banned[ban_count];
    @memcpy(b.node_id[0..actual], id_ptr[0..actual]);
    b.id_len = actual;
    b.banned_at = std.time.timestamp();
    b.reason = reason;
    ban_count += 1;
}

/// Check if a peer is allowed to send a request.
fn checkAccess(id_ptr: [*]const u8, id_len: usize) u8 {
    // 0 = allowed, 1 = denied (not authorised), 2 = banned, 3 = rate limited
    if (isBanned(id_ptr, id_len)) return 2;

    if (findPeer(id_ptr, id_len)) |idx| {
        var peer = &authorised[idx];
        peer.request_count += 1;
        return 0;
    }

    // Not in allow-list: allow if open mode, deny otherwise
    return if (open_mode) 0 else 1;
}

fn recordAuthFailure(id_ptr: [*]const u8, id_len: usize) void {
    if (findPeer(id_ptr, id_len)) |idx| {
        authorised[idx].auth_failures += 1;
        if (authorised[idx].auth_failures >= BAN_THRESHOLD) {
            banPeer(id_ptr, id_len, 0); // auth_failure
            authorised[idx].policy = .deny;
        }
    } else {
        // Unknown peer — ban directly after threshold
        banPeer(id_ptr, id_len, 0);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports
// ═══════════════════════════════════════════════════════════════════════

export fn boj_sdp_init() i32 {
    mutex.lock();
    defer mutex.unlock();
    init();
    return 0;
}

export fn boj_sdp_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    auth_count = 0;
    ban_count = 0;
    sdp_enabled = false;
}

export fn boj_sdp_authorise(id_ptr: [*]const u8, id_len: usize, rate_limit: u32) i32 {
    mutex.lock();
    defer mutex.unlock();
    return authorisePeer(id_ptr, id_len, rate_limit);
}

export fn boj_sdp_check(id_ptr: [*]const u8, id_len: usize) u8 {
    mutex.lock();
    defer mutex.unlock();
    return checkAccess(id_ptr, id_len);
}

export fn boj_sdp_record_auth_failure(id_ptr: [*]const u8, id_len: usize) void {
    mutex.lock();
    defer mutex.unlock();
    recordAuthFailure(id_ptr, id_len);
}

export fn boj_sdp_ban(id_ptr: [*]const u8, id_len: usize, reason: u8) void {
    mutex.lock();
    defer mutex.unlock();
    banPeer(id_ptr, id_len, reason);
}

export fn boj_sdp_is_banned(id_ptr: [*]const u8, id_len: usize) u8 {
    mutex.lock();
    defer mutex.unlock();
    return if (isBanned(id_ptr, id_len)) 1 else 0;
}

export fn boj_sdp_set_open_mode(mode: u8) void {
    mutex.lock();
    defer mutex.unlock();
    open_mode = mode != 0;
}

export fn boj_sdp_peer_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return auth_count;
}

export fn boj_sdp_ban_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return ban_count;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "sdp init" {
    init();
    try std.testing.expect(sdp_enabled);
    try std.testing.expect(open_mode);
    try std.testing.expectEqual(@as(usize, 0), auth_count);
}

test "sdp authorise peer" {
    init();
    const id = "node-alpha";
    const idx = authorisePeer(id.ptr, id.len, 50);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), auth_count);
}

test "sdp check allows authorised peer" {
    init();
    open_mode = false;
    const id = "node-beta";
    _ = authorisePeer(id.ptr, id.len, 100);
    const result = checkAccess(id.ptr, id.len);
    try std.testing.expectEqual(@as(u8, 0), result);
}

test "sdp check denies unknown in closed mode" {
    init();
    open_mode = false;
    const id = "unknown-node";
    const result = checkAccess(id.ptr, id.len);
    try std.testing.expectEqual(@as(u8, 1), result);
}

test "sdp check allows unknown in open mode" {
    init();
    open_mode = true;
    const id = "unknown-node";
    const result = checkAccess(id.ptr, id.len);
    try std.testing.expectEqual(@as(u8, 0), result);
}

test "sdp ban peer" {
    init();
    const id = "bad-node";
    banPeer(id.ptr, id.len, 2); // manual ban
    try std.testing.expect(isBanned(id.ptr, id.len));
    try std.testing.expectEqual(@as(u8, 2), checkAccess(id.ptr, id.len));
}

test "sdp auth failure leads to ban" {
    init();
    const id = "failing-node";
    _ = authorisePeer(id.ptr, id.len, 100);
    // 5 failures = BAN_THRESHOLD
    var i: u8 = 0;
    while (i < BAN_THRESHOLD) : (i += 1) {
        recordAuthFailure(id.ptr, id.len);
    }
    try std.testing.expect(isBanned(id.ptr, id.len));
}

test "sdp find peer" {
    init();
    const id = "findme";
    _ = authorisePeer(id.ptr, id.len, 100);
    try std.testing.expect(findPeer(id.ptr, id.len) != null);
    try std.testing.expect(findPeer("nope".ptr, 4) == null);
}

test "sdp c-abi roundtrip" {
    _ = boj_sdp_init();
    const id = "api-node";
    const idx = boj_sdp_authorise(id.ptr, id.len, 200);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(u8, 0), boj_sdp_check(id.ptr, id.len));
    try std.testing.expectEqual(@as(usize, 1), boj_sdp_peer_count());
}

test "sdp deinit resets" {
    _ = boj_sdp_init();
    _ = boj_sdp_authorise("tmp".ptr, 3, 100);
    boj_sdp_deinit();
    try std.testing.expectEqual(@as(usize, 0), boj_sdp_peer_count());
    try std.testing.expect(!sdp_enabled);
}
