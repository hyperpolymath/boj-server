// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Local-Coord MCP Cartridge — Zig FFI bridge for localhost multi-instance
// coordination.
//
// Manages a peer registry, session tokens, message fan-out, and task
// claiming (mutex). Binds ONLY to 127.0.0.1:7745 — the Idris2 ABI
// proves loopback-only at compile time; this FFI honours that constraint
// at runtime.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Constants (must match SafeLocalCoord.idr)
// ═══════════════════════════════════════════════════════════════════════

/// CRITICAL: Loopback only. Never change to 0.0.0.0 or any LAN address.
const BIND_ADDR = [4]u8{ 127, 0, 0, 1 };
const BIND_PORT: u16 = 7745;
const MAX_PEERS: usize = 16;
const MAX_CLAIMS: usize = 64;
const TOKEN_LEN: usize = 16; // 16 bytes = 32 hex chars
const MAX_MESSAGES: usize = 256; // ring buffer size per peer

// ═══════════════════════════════════════════════════════════════════════
// Types (must match Protocol.idr encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const ClientKind = enum(c_int) {
    claude = 0,
    gemini = 1,
    copilot = 2,
    custom = 3,
};

pub const PeerState = enum(c_int) {
    registering = 0,
    active = 1,
    departing = 2,
    gone = 3,
};

pub const MsgKind = enum(c_int) {
    direct_msg = 0,
    broadcast = 1,
    status_update = 2,
    claim_request = 3,
    claim_release = 4,
    ping = 5,
};

pub const ClaimResult = enum(c_int) {
    granted = 0,
    held = 1,
    not_found = 2,
};

// ═══════════════════════════════════════════════════════════════════════
// Peer Registry
// ═══════════════════════════════════════════════════════════════════════

const Peer = struct {
    active: bool,
    kind: ClientKind,
    suffix: [4]u8, // 4-char hex suffix
    state: PeerState,
    token: [TOKEN_LEN]u8,
    // Per-peer message inbox (ring buffer)
    inbox: [MAX_MESSAGES][512]u8,
    inbox_lens: [MAX_MESSAGES]u16,
    inbox_head: u16, // next write position
    inbox_tail: u16, // next read position
    inbox_count: u16,
    // Status string
    status: [256]u8,
    status_len: u16,
};

const empty_peer = Peer{
    .active = false,
    .kind = .claude,
    .suffix = [_]u8{ '0', '0', '0', '0' },
    .state = .gone,
    .token = [_]u8{0} ** TOKEN_LEN,
    .inbox = [_][512]u8{[_]u8{0} ** 512} ** MAX_MESSAGES,
    .inbox_lens = [_]u16{0} ** MAX_MESSAGES,
    .inbox_head = 0,
    .inbox_tail = 0,
    .inbox_count = 0,
    .status = [_]u8{0} ** 256,
    .status_len = 0,
};

var peers: [MAX_PEERS]Peer = [_]Peer{empty_peer} ** MAX_PEERS;
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Task Claim Registry
// ═══════════════════════════════════════════════════════════════════════

const Claim = struct {
    active: bool,
    task_name: [128]u8,
    task_name_len: u8,
    holder_idx: u8, // index into peers[]
};

const empty_claim = Claim{
    .active = false,
    .task_name = [_]u8{0} ** 128,
    .task_name_len = 0,
    .holder_idx = 0,
};

var claims: [MAX_CLAIMS]Claim = [_]Claim{empty_claim} ** MAX_CLAIMS;

// ��══════════════════════════════════════════════════════════════════════
// Token Generation (CSPRNG from OS)
// ═══════════════════════════════════════════════════════════════════════

fn generateToken() [TOKEN_LEN]u8 {
    var buf: [TOKEN_LEN]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return buf;
}

fn generateSuffix() [4]u8 {
    var raw: [2]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = "0123456789abcdef";
    return [4]u8{
        hex[raw[0] >> 4],
        hex[raw[0] & 0x0f],
        hex[raw[1] >> 4],
        hex[raw[1] & 0x0f],
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Peer Operations
// ═══════════════════════════════════════════════════════════════════════

fn findPeerByToken(token_ptr: [*]const u8, token_len: usize) ?usize {
    if (token_len != TOKEN_LEN) return null;
    for (&peers, 0..) |*p, i| {
        if (p.active and std.mem.eql(u8, &p.token, token_ptr[0..TOKEN_LEN])) {
            return i;
        }
    }
    return null;
}

/// Register a new peer. Returns peer index, or -1 if full.
/// Writes token into token_out (must be TOKEN_LEN bytes).
/// Writes suffix into suffix_out (must be 4 bytes).
pub export fn coord_register(kind: c_int, token_out: [*]u8, suffix_out: [*]u8) c_int {
    mutex.lock();
    defer mutex.unlock();

    const client_kind: ClientKind = @enumFromInt(kind);

    for (&peers, 0..) |*p, i| {
        if (!p.active) {
            p.active = true;
            p.kind = client_kind;
            p.suffix = generateSuffix();
            p.state = .active;
            p.token = generateToken();
            p.inbox_head = 0;
            p.inbox_tail = 0;
            p.inbox_count = 0;
            p.status_len = 0;

            // Copy token and suffix to caller
            @memcpy(token_out[0..TOKEN_LEN], &p.token);
            @memcpy(suffix_out[0..4], &p.suffix);

            return @intCast(i);
        }
    }
    return -1; // registry full
}

/// Deregister a peer. Releases any claims it holds.
pub export fn coord_deregister(token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;

    // Release all claims held by this peer
    for (&claims) |*c| {
        if (c.active and c.holder_idx == @as(u8, @intCast(idx))) {
            c.active = false;
        }
    }

    peers[idx].active = false;
    peers[idx].state = .gone;
    return 0;
}

/// List active peers. Writes peer info into out buffer as a series of
/// (kind: i32, suffix: [4]u8, state: i32) = 12 bytes per peer.
/// Returns number of active peers written.
pub export fn coord_list_peers(token_ptr: [*]const u8, token_len: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    // Validate caller token
    if (findPeerByToken(token_ptr, @intCast(token_len)) == null) return -1;

    var written: usize = 0;
    const cap: usize = @intCast(out_cap);

    for (&peers) |*p| {
        if (p.active and (written + 12) <= cap) {
            const offset = written;
            // kind (4 bytes, little-endian i32)
            const kind_bytes: [4]u8 = @bitCast(@intFromEnum(p.kind));
            @memcpy(out[offset .. offset + 4], &kind_bytes);
            // suffix (4 bytes)
            @memcpy(out[offset + 4 .. offset + 8], &p.suffix);
            // state (4 bytes, little-endian i32)
            const state_bytes: [4]u8 = @bitCast(@intFromEnum(p.state));
            @memcpy(out[offset + 8 .. offset + 12], &state_bytes);
            written += 12;
        }
    }
    return @intCast(written / 12);
}

/// Send a message to a specific peer (by index) or broadcast (target = -1).
pub export fn coord_send(
    token_ptr: [*]const u8,
    token_len: c_int,
    target_idx: c_int,
    msg_ptr: [*]const u8,
    msg_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const sender_idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const mlen: usize = @intCast(@min(msg_len, 512));

    if (target_idx == -1) {
        // Broadcast to all active peers except sender
        var sent: c_int = 0;
        for (&peers, 0..) |*p, i| {
            if (p.active and i != sender_idx and p.inbox_count < MAX_MESSAGES) {
                const head: usize = p.inbox_head;
                @memcpy(p.inbox[head][0..mlen], msg_ptr[0..mlen]);
                p.inbox_lens[head] = @intCast(mlen);
                p.inbox_head = @intCast((@as(u32, p.inbox_head) + 1) % MAX_MESSAGES);
                p.inbox_count += 1;
                sent += 1;
            }
        }
        return sent;
    } else {
        // Direct message
        if (target_idx < 0 or target_idx >= MAX_PEERS) return -2;
        const tidx: usize = @intCast(target_idx);
        const target = &peers[tidx];
        if (!target.active) return -2;
        if (target.inbox_count >= MAX_MESSAGES) return -3; // inbox full

        const head: usize = target.inbox_head;
        @memcpy(target.inbox[head][0..mlen], msg_ptr[0..mlen]);
        target.inbox_lens[head] = @intCast(mlen);
        target.inbox_head = @intCast((@as(u32, target.inbox_head) + 1) % MAX_MESSAGES);
        target.inbox_count += 1;
        return 1;
    }
}

/// Receive the next message from this peer's inbox.
/// Writes message into msg_out, returns message length, or 0 if empty, -1 if bad token.
pub export fn coord_receive(
    token_ptr: [*]const u8,
    token_len: c_int,
    msg_out: [*]u8,
    msg_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const peer = &peers[idx];

    if (peer.inbox_count == 0) return 0;

    const tail: usize = peer.inbox_tail;
    const mlen: usize = @min(@as(usize, peer.inbox_lens[tail]), @as(usize, @intCast(msg_cap)));
    @memcpy(msg_out[0..mlen], peer.inbox[tail][0..mlen]);
    peer.inbox_tail = @intCast((@as(u32, peer.inbox_tail) + 1) % MAX_MESSAGES);
    peer.inbox_count -= 1;
    return @intCast(mlen);
}

/// Attempt to claim a task. Returns ClaimResult encoding.
pub export fn coord_claim_task(
    token_ptr: [*]const u8,
    token_len: c_int,
    task_ptr: [*]const u8,
    task_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const tlen: usize = @intCast(@min(task_len, 128));

    // Check if already claimed
    for (&claims) |*c| {
        if (c.active and c.task_name_len == @as(u8, @intCast(tlen)) and
            std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen]))
        {
            if (c.holder_idx == @as(u8, @intCast(idx))) {
                return 0; // Already held by caller — idempotent grant
            }
            return 1; // Held by another peer
        }
    }

    // Find an empty claim slot
    for (&claims) |*c| {
        if (!c.active) {
            c.active = true;
            @memcpy(c.task_name[0..tlen], task_ptr[0..tlen]);
            c.task_name_len = @intCast(tlen);
            c.holder_idx = @intCast(idx);
            return 0; // Granted
        }
    }
    return 2; // No slots available (treated as NotFound)
}

/// Release a task claim.
pub export fn coord_release_task(
    token_ptr: [*]const u8,
    token_len: c_int,
    task_ptr: [*]const u8,
    task_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const tlen: usize = @intCast(@min(task_len, 128));

    for (&claims) |*c| {
        if (c.active and c.task_name_len == @as(u8, @intCast(tlen)) and
            std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen]) and
            c.holder_idx == @as(u8, @intCast(idx)))
        {
            c.active = false;
            return 0;
        }
    }
    return -2; // Not held by this peer
}

/// Set this peer's status string.
pub export fn coord_set_status(
    token_ptr: [*]const u8,
    token_len: c_int,
    status_ptr: [*]const u8,
    status_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const slen: usize = @intCast(@min(status_len, 256));
    @memcpy(peers[idx].status[0..slen], status_ptr[0..slen]);
    peers[idx].status_len = @intCast(slen);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

pub export fn boj_cartridge_init() c_int {
    coord_reset();
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    coord_reset();
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    return "local-coord-mcp";
}

pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Reset (for testing)
// ═══════════════════════════════════════════════════════════════════════

pub export fn coord_reset() void {
    mutex.lock();
    defer mutex.unlock();
    peers = [_]Peer{empty_peer} ** MAX_PEERS;
    claims = [_]Claim{empty_claim} ** MAX_CLAIMS;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "register and deregister peer" {
    coord_reset();
    var token: [TOKEN_LEN]u8 = undefined;
    var suffix: [4]u8 = undefined;
    const idx = coord_register(0, &token, &suffix); // claude
    try std.testing.expect(idx >= 0);

    // Deregister with correct token
    const result = coord_deregister(&token, TOKEN_LEN);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "register fills up" {
    coord_reset();
    var tokens: [MAX_PEERS][TOKEN_LEN]u8 = undefined;
    var suffix: [4]u8 = undefined;

    // Fill all slots
    for (0..MAX_PEERS) |i| {
        const idx = coord_register(0, &tokens[i], &suffix);
        try std.testing.expectEqual(@as(c_int, @intCast(i)), idx);
    }

    // Next should fail
    var extra_token: [TOKEN_LEN]u8 = undefined;
    const overflow = coord_register(0, &extra_token, &suffix);
    try std.testing.expectEqual(@as(c_int, -1), overflow);

    coord_reset();
}

test "bad token rejected" {
    coord_reset();
    var token: [TOKEN_LEN]u8 = undefined;
    var suffix: [4]u8 = undefined;
    _ = coord_register(0, &token, &suffix);

    var bad_token = [_]u8{0xFF} ** TOKEN_LEN;
    var out: [256]u8 = undefined;
    const result = coord_list_peers(&bad_token, TOKEN_LEN, &out, 256);
    try std.testing.expectEqual(@as(c_int, -1), result);
    coord_reset();
}

test "claim mutex semantics" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, &tok1, &suf); // claude
    _ = coord_register(1, &tok2, &suf); // gemini

    const task = "audit-boj-server";

    // Peer 1 claims
    const r1 = coord_claim_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r1); // Granted

    // Peer 2 tries to claim same task — should be denied
    const r2 = coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 1), r2); // Held

    // Peer 1 releases
    const r3 = coord_release_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r3);

    // Now peer 2 can claim
    const r4 = coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r4); // Granted

    coord_reset();
}

test "idempotent claim" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, &tok, &suf);

    const task = "fix-ci";
    const r1 = coord_claim_task(&tok, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r1);

    // Same peer claims again — should be idempotent grant
    const r2 = coord_claim_task(&tok, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r2);

    coord_reset();
}

test "send and receive direct message" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx1 = coord_register(0, &tok1, &suf);
    _ = coord_register(1, &tok2, &suf);

    const msg = "hello from claude";
    // idx1 sends to idx2 (idx2 = 1)
    _ = idx1;
    const sent = coord_send(&tok1, TOKEN_LEN, 1, msg.ptr, @intCast(msg.len));
    try std.testing.expectEqual(@as(c_int, 1), sent);

    // idx2 receives
    var buf: [512]u8 = undefined;
    const received = coord_receive(&tok2, TOKEN_LEN, &buf, 512);
    try std.testing.expectEqual(@as(c_int, @intCast(msg.len)), received);
    try std.testing.expect(std.mem.eql(u8, buf[0..msg.len], msg));

    // No more messages
    const empty = coord_receive(&tok2, TOKEN_LEN, &buf, 512);
    try std.testing.expectEqual(@as(c_int, 0), empty);

    coord_reset();
}

test "broadcast message" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var tok3: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, &tok1, &suf);
    _ = coord_register(1, &tok2, &suf);
    _ = coord_register(2, &tok3, &suf);

    const msg = "starting audit";
    const sent = coord_send(&tok1, TOKEN_LEN, -1, msg.ptr, @intCast(msg.len));
    try std.testing.expectEqual(@as(c_int, 2), sent); // 2 recipients (not sender)

    // Both tok2 and tok3 should have the message
    var buf: [512]u8 = undefined;
    const r2 = coord_receive(&tok2, TOKEN_LEN, &buf, 512);
    try std.testing.expect(r2 > 0);
    const r3 = coord_receive(&tok3, TOKEN_LEN, &buf, 512);
    try std.testing.expect(r3 > 0);

    // Sender should NOT have the message
    const r1 = coord_receive(&tok1, TOKEN_LEN, &buf, 512);
    try std.testing.expectEqual(@as(c_int, 0), r1);

    coord_reset();
}

test "deregister releases claims" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, &tok1, &suf);
    _ = coord_register(1, &tok2, &suf);

    const task = "fix-pipeline";
    _ = coord_claim_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len));

    // Deregister peer 1
    _ = coord_deregister(&tok1, TOKEN_LEN);

    // Peer 2 should now be able to claim
    const r = coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r); // Granted

    coord_reset();
}
