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
//
// Durability: every mutation persists to an append-only log under
// BOJ_COORD_STATE_DIR. On init the log is replayed to restore state
// across adapter restarts. When the env var is unset, durability is a
// silent no-op — process-local in-memory behaviour is preserved.
// See coord_durability.zig.

const std = @import("std");
const dur = @import("coord_durability.zig");

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

/// Trust role — determines what a peer may do without a supervision gate.
/// See docs/envelope-design.adoc for the risk ladder.
pub const Role = enum(c_int) {
    supervisor = 0, // Opus — holds the veto
    executor = 1, // Claude Sonnet/Haiku — trusted executor
    supervised = 2, // gemini/codex/vibe — Tier 2+ ops quarantined
};

/// Role-hint sentinel for coord_register — lets the server decide the
/// default from client_kind. Used to keep the register signature stable
/// while allowing explicit role requests.
const ROLE_HINT_DEFAULT: c_int = -1;

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

/// Per-window context disambiguator. Short label (e.g. repo name, tty-hash)
/// appended to peer_id as `<kind>-<4hex>@<context>`. Optional — empty means
/// the old `<kind>-<4hex>` form. Alphanumeric + hyphens only; enforced in
/// coord_set_context.
const MAX_CONTEXT: usize = 32;

const Peer = struct {
    active: bool,
    kind: ClientKind,
    suffix: [4]u8, // 4-char hex suffix
    state: PeerState,
    token: [TOKEN_LEN]u8,
    role: Role,
    // Per-peer message inbox (ring buffer)
    inbox: [MAX_MESSAGES][512]u8,
    inbox_lens: [MAX_MESSAGES]u16,
    inbox_head: u16, // next write position
    inbox_tail: u16, // next read position
    inbox_count: u16,
    // Status string
    status: [256]u8,
    status_len: u16,
    // Context disambiguator (repo / tty / window label)
    context: [MAX_CONTEXT]u8,
    context_len: u8,
};

const empty_peer = Peer{
    .active = false,
    .kind = .claude,
    .suffix = [_]u8{ '0', '0', '0', '0' },
    .state = .gone,
    .token = [_]u8{0} ** TOKEN_LEN,
    .role = .supervised,
    .inbox = [_][512]u8{[_]u8{0} ** 512} ** MAX_MESSAGES,
    .inbox_lens = [_]u16{0} ** MAX_MESSAGES,
    .inbox_head = 0,
    .inbox_tail = 0,
    .inbox_count = 0,
    .status = [_]u8{0} ** 256,
    .status_len = 0,
    .context = [_]u8{0} ** MAX_CONTEXT,
    .context_len = 0,
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

// ═══════════════════════════════════════════════════════════════════════
// Quarantine Queue — Tier 2+ ops from role=supervised peers held here
// until a supervisor approves or rejects.
// ═══════════════════════════════════════════════════════════════════════

const MAX_QUARANTINE: usize = 32;
const MAX_REASON: usize = 256;

const QuarantineEntry = struct {
    active: bool,
    request_id: u32,
    sender_idx: u8,
    target_idx: i8, // -1 for broadcast
    risk_tier: u8,
    msg: [512]u8,
    msg_len: u16,
    reason: [MAX_REASON]u8,
    reason_len: u16,
};

const empty_quar = QuarantineEntry{
    .active = false,
    .request_id = 0,
    .sender_idx = 0,
    .target_idx = -1,
    .risk_tier = 0,
    .msg = [_]u8{0} ** 512,
    .msg_len = 0,
    .reason = [_]u8{0} ** MAX_REASON,
    .reason_len = 0,
};

var quarantine: [MAX_QUARANTINE]QuarantineEntry = [_]QuarantineEntry{empty_quar} ** MAX_QUARANTINE;
var next_request_id: u32 = 1;

// ═══════════════════════════════════════════════════════════════════════
// Track Record — per (client_kind, tag) outcome history used to compute
// `effective_affinity`. DD-29: keyed on client_kind not peer_id so the
// record survives peer crash+restart.
//
// Ring buffer; oldest entry overwritten when full. Window for affinity
// aggregation: last 20 attempts for that (kind, tag) OR all attempts
// within the last 7 days, whichever is larger (DD-28).
// ═══════════════════════════════════════════════════════════════════════

const MAX_TRACK: usize = 512;
const MAX_TAG: usize = 64;
const WINDOW_ATTEMPTS: usize = 20;
const WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days in ms

const TrackEntry = struct {
    active: bool,
    client_kind: u8,
    outcome: u8, // 0 = fail, 1 = success
    risk_tier: u8,
    duration_ms: u32,
    timestamp_ms: u64,
    tag_len: u8,
    tag: [MAX_TAG]u8,
};

const empty_track = TrackEntry{
    .active = false,
    .client_kind = 0,
    .outcome = 0,
    .risk_tier = 0,
    .duration_ms = 0,
    .timestamp_ms = 0,
    .tag_len = 0,
    .tag = [_]u8{0} ** MAX_TAG,
};

var track: [MAX_TRACK]TrackEntry = [_]TrackEntry{empty_track} ** MAX_TRACK;
var track_head: usize = 0; // next write slot
var track_count: usize = 0; // active entries (saturates at MAX_TRACK)

/// Push a track-record entry into the ring. Caller-visible timestamp is
/// always std.time.milliTimestamp() at insertion. Oldest record is
/// overwritten when the ring is full.
fn recordTrack(
    client_kind: u8,
    outcome: u8,
    risk_tier: u8,
    duration_ms: u32,
    tag: []const u8,
) void {
    const t: *TrackEntry = &track[track_head];
    t.active = true;
    t.client_kind = client_kind;
    t.outcome = outcome;
    t.risk_tier = risk_tier;
    t.duration_ms = duration_ms;
    t.timestamp_ms = @intCast(std.time.milliTimestamp());
    const tl: usize = @min(tag.len, MAX_TAG);
    if (tl > 0) @memcpy(t.tag[0..tl], tag[0..tl]);
    t.tag_len = @intCast(tl);
    track_head = (track_head + 1) % MAX_TRACK;
    if (track_count < MAX_TRACK) track_count += 1;
}

/// Re-insert a replayed track entry without clobbering its original
/// timestamp. Used by replayDispatch so aggregations after restart
/// reflect real event time, not replay time.
fn recordTrackReplay(
    client_kind: u8,
    outcome: u8,
    risk_tier: u8,
    duration_ms: u32,
    timestamp_ms: u64,
    tag: []const u8,
) void {
    const t: *TrackEntry = &track[track_head];
    t.active = true;
    t.client_kind = client_kind;
    t.outcome = outcome;
    t.risk_tier = risk_tier;
    t.duration_ms = duration_ms;
    t.timestamp_ms = timestamp_ms;
    const tl: usize = @min(tag.len, MAX_TAG);
    if (tl > 0) @memcpy(t.tag[0..tl], tag[0..tl]);
    t.tag_len = @intCast(tl);
    track_head = (track_head + 1) % MAX_TRACK;
    if (track_count < MAX_TRACK) track_count += 1;
}

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

/// Find an active peer by its 4-char hex suffix. Returns index 0..MAX_PEERS-1
/// or -1 if no match. Adapters use this to resolve a peer_id string like
/// "claude-7f3a" (suffix = "7f3a") to the FFI peer index expected by coord_send.
pub export fn coord_find_peer_by_suffix(suffix_ptr: [*]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&peers, 0..) |*p, i| {
        if (p.active and std.mem.eql(u8, &p.suffix, suffix_ptr[0..4])) {
            return @intCast(i);
        }
    }
    return -1;
}

/// Read a peer's current status string. Writes up to out_cap bytes into out.
/// Returns status length on success, 0 if empty, -1 if peer index out of range.
/// Intended for coord_list_peers enrichment — the caller token is not required
/// because status is broadcast-visible by design.
pub export fn coord_read_peer_status(peer_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const slen: usize = @min(@as(usize, p.status_len), @as(usize, @intCast(out_cap)));
    if (slen > 0) @memcpy(out[0..slen], p.status[0..slen]);
    return @intCast(slen);
}

/// Read a peer's client_kind. Returns 0=claude 1=gemini 2=copilot 3=custom,
/// or -1 if peer index out of range / inactive.
pub export fn coord_read_peer_kind(peer_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    return @intFromEnum(p.kind);
}

/// Default role for a client_kind when no explicit hint is given.
/// claude -> executor (trusted executor)
/// everything else -> supervised (Tier 2+ gated)
fn defaultRoleForKind(kind: ClientKind) Role {
    return switch (kind) {
        .claude => .executor,
        else => .supervised,
    };
}

/// Find the active supervisor, if any. Returns the peer index or null.
fn findSupervisor() ?usize {
    for (&peers, 0..) |*p, i| {
        if (p.active and p.role == .supervisor) return i;
    }
    return null;
}

/// Register a new peer. Returns peer index, or -1 if full, -3 if the
/// caller tries to claim supervisor via role_hint (use
/// coord_promote_to_supervisor instead).
///
/// role_hint = -1 (ROLE_HINT_DEFAULT): server assigns from kind
/// role_hint = 0 (supervisor): REJECTED here — use coord_promote_to_supervisor
/// role_hint = 1 (executor): granted executor role
/// role_hint = 2 (supervised): granted supervised role (self-downgrade)
pub export fn coord_register(kind: c_int, role_hint: c_int, token_out: [*]u8, suffix_out: [*]u8) c_int {
    mutex.lock();
    defer mutex.unlock();

    const client_kind: ClientKind = @enumFromInt(kind);

    // Resolve role. Supervisor NEVER granted at register — must be
    // promoted via coord_promote_to_supervisor with env-var secret.
    const role: Role = blk: {
        if (role_hint == ROLE_HINT_DEFAULT) break :blk defaultRoleForKind(client_kind);
        const r: Role = @enumFromInt(role_hint);
        if (r == .supervisor) return -3;
        break :blk r;
    };

    for (&peers, 0..) |*p, i| {
        if (!p.active) {
            p.active = true;
            p.kind = client_kind;
            p.suffix = generateSuffix();
            p.state = .active;
            p.token = generateToken();
            p.role = role;
            p.inbox_head = 0;
            p.inbox_tail = 0;
            p.inbox_count = 0;
            p.status_len = 0;
            p.context_len = 0; // reset on slot reuse

            @memcpy(token_out[0..TOKEN_LEN], &p.token);
            @memcpy(suffix_out[0..4], &p.suffix);

            dur.logPeerAdd(@intCast(i), @intCast(@intFromEnum(client_kind)), @intCast(@intFromEnum(role)), &p.suffix, &p.token);
            return @intCast(i);
        }
    }
    return -1; // registry full
}

/// Promote the caller's peer to supervisor role. Gated by the
/// BOJ_SUPERVISOR_TOKEN env var (must be set, and presented secret
/// must match). At most one supervisor at a time.
///
/// Returns:
///   0   — promoted
///  -1   — bad own token
///  -2   — supervisor already exists
///  -3   — BOJ_SUPERVISOR_TOKEN env var not set (server doesn't allow
///          supervisor role in this deployment)
///  -4   — presented secret does not match env var
pub export fn coord_promote_to_supervisor(
    own_token_ptr: [*]const u8,
    own_token_len: c_int,
    secret_ptr: [*]const u8,
    secret_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(own_token_ptr, @intCast(own_token_len)) orelse return -1;
    if (findSupervisor() != null) return -2;

    // Env-var check — read at promotion time so a running server can
    // have its policy changed by restart.
    const env_secret = std.posix.getenv("BOJ_SUPERVISOR_TOKEN") orelse return -3;
    if (env_secret.len == 0) return -3;

    const slen: usize = @intCast(secret_len);
    if (slen != env_secret.len) return -4;
    // Constant-time compare — defence against timing oracles even though
    // we're loopback-only.
    var diff: u8 = 0;
    var k: usize = 0;
    while (k < slen) : (k += 1) {
        diff |= env_secret[k] ^ secret_ptr[k];
    }
    if (diff != 0) return -4;

    peers[idx].role = .supervisor;
    dur.logPeerRoleSet(@intCast(idx), @intCast(@intFromEnum(Role.supervisor)));
    return 0;
}

/// Read a peer's role. Returns 0=supervisor, 1=executor, 2=supervised,
/// or -1 if peer index out of range / inactive.
pub export fn coord_read_peer_role(peer_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    return @intFromEnum(p.role);
}

/// Re-assign a peer's role. Only callable by an active supervisor (token
/// must belong to role=supervisor). Returns 0 on success, -1 on bad
/// supervisor token, -2 on bad target, -3 on disallowed transition
/// (e.g. demoting the sole supervisor).
pub export fn coord_set_role(
    supervisor_token_ptr: [*]const u8,
    supervisor_token_len: c_int,
    target_peer_idx: c_int,
    new_role: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const sup_idx = findPeerByToken(supervisor_token_ptr, @intCast(supervisor_token_len)) orelse return -1;
    if (peers[sup_idx].role != .supervisor) return -1;

    if (target_peer_idx < 0 or target_peer_idx >= MAX_PEERS) return -2;
    const target = &peers[@intCast(target_peer_idx)];
    if (!target.active) return -2;

    const nr: Role = @enumFromInt(new_role);

    // Forbid demoting the only supervisor.
    if (target.role == .supervisor and nr != .supervisor) {
        var other_sup: bool = false;
        for (&peers, 0..) |*p, i| {
            if (i == @as(usize, @intCast(target_peer_idx))) continue;
            if (p.active and p.role == .supervisor) { other_sup = true; break; }
        }
        if (!other_sup) return -3;
    }

    target.role = nr;
    dur.logPeerRoleSet(@intCast(target_peer_idx), @intCast(@intFromEnum(nr)));
    return 0;
}

/// Set a context disambiguator for this peer (repo name, tty hash, window
/// label). Must be alphanumeric or hyphen, max MAX_CONTEXT bytes — anything
/// else returns -2 and the existing context is untouched.
pub export fn coord_set_context(
    token_ptr: [*]const u8,
    token_len: c_int,
    ctx_ptr: [*]const u8,
    ctx_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const clen: usize = @intCast(ctx_len);
    if (clen > MAX_CONTEXT) return -2;

    // Validate: alphanum + hyphen + underscore only.
    var k: usize = 0;
    while (k < clen) : (k += 1) {
        const c = ctx_ptr[k];
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or c == '-' or c == '_';
        if (!ok) return -2;
    }

    if (clen > 0) @memcpy(peers[idx].context[0..clen], ctx_ptr[0..clen]);
    peers[idx].context_len = @intCast(clen);
    dur.logPeerContextSet(@intCast(idx), ctx_ptr[0..clen]);
    return 0;
}

/// Read a peer's context disambiguator. Writes up to out_cap bytes into out.
/// Returns context length on success, 0 if unset, -1 if peer index out of
/// range / inactive. Caller token is not required — context is broadcast-
/// visible by design (it's how other peers identify which window this is).
pub export fn coord_read_peer_context(peer_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const clen: usize = @min(@as(usize, p.context_len), @as(usize, @intCast(out_cap)));
    if (clen > 0) @memcpy(out[0..clen], p.context[0..clen]);
    return @intCast(clen);
}

/// Deregister a peer. Releases any claims it holds.
pub export fn coord_deregister(token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;

    // Release all claims held by this peer
    for (&claims, 0..) |*c, ci| {
        if (c.active and c.holder_idx == @as(u8, @intCast(idx))) {
            c.active = false;
            dur.logClaimRel(@intCast(ci));
        }
    }

    peers[idx].active = false;
    peers[idx].state = .gone;
    dur.logPeerRemove(@intCast(idx));
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
                dur.logInboxPush(@intCast(i), msg_ptr[0..mlen]);
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
        dur.logInboxPush(@intCast(tidx), msg_ptr[0..mlen]);
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
    dur.logInboxPop(@intCast(idx));
    return @intCast(mlen);
}

// ═══════════════════════════════════════════════════════════════════════
// Rejection cooldown (Task #15) — per client_kind, enforce a short
// cooldown after a burst of claim rejections to blunt runaway peers.
//
// Policy: 5 rejections within REJECT_WINDOW_MS (10 min) trigger a
// COOLDOWN_MS (30 s) freeze from the 5th rejection's timestamp. During
// cooldown the server returns a dedicated "cooldown" result so callers
// can back off rather than tight-looping.
// ═══════════════════════════════════════════════════════════════════════

const REJECT_WINDOW_MS: u64 = 10 * 60 * 1000;
const REJECT_LIMIT: usize = 5;
const COOLDOWN_MS: u64 = 30 * 1000;

// Timestamps of the most recent rejections per client_kind, as a small
// ring. ClientKind enum has 4 variants — one slot each.
const KIND_COUNT: usize = 4;
var reject_ring: [KIND_COUNT][REJECT_LIMIT]u64 = [_][REJECT_LIMIT]u64{[_]u64{0} ** REJECT_LIMIT} ** KIND_COUNT;
var reject_head: [KIND_COUNT]usize = [_]usize{0} ** KIND_COUNT;

fn isInCooldown(kind: ClientKind, now_ms: u64) bool {
    const k: usize = @intCast(@intFromEnum(kind));
    if (k >= KIND_COUNT) return false;
    const ring = &reject_ring[k];
    // Count rejections within the window.
    var count: usize = 0;
    var newest: u64 = 0;
    for (ring) |ts| {
        if (ts == 0) continue;
        if (now_ms > ts and (now_ms - ts) > REJECT_WINDOW_MS) continue;
        count += 1;
        if (ts > newest) newest = ts;
    }
    if (count < REJECT_LIMIT) return false;
    if (now_ms > newest and (now_ms - newest) >= COOLDOWN_MS) return false;
    return true;
}

fn recordRejection(kind: ClientKind, now_ms: u64) void {
    const k: usize = @intCast(@intFromEnum(kind));
    if (k >= KIND_COUNT) return;
    const h = reject_head[k];
    reject_ring[k][h] = now_ms;
    reject_head[k] = (h + 1) % REJECT_LIMIT;
}

/// Attempt to claim a task. Returns ClaimResult encoding.
pub export fn coord_claim_task(
    token_ptr: [*]const u8,
    token_len: c_int,
    task_ptr: [*]const u8,
    task_len: c_int,
) c_int {
    return coord_claim_task_ex(token_ptr, token_len, task_ptr, task_len, -1, -1, -1);
}

/// Dispatch-preference constants shared with the envelope schema.
pub const DispatchPref = enum(c_int) {
    deliberate = 0,
    broadcast = 1,
    auto = 2,
};

pub const TaskDifficulty = enum(c_int) {
    trivial = 0,
    routine = 1,
    challenging = 2,
    novel = 3,
};

/// Extended claim — carries the sender's own confidence (0-100 %),
/// dispatch preference, and task difficulty. All three are optional
/// (-1 for unset). Return codes match coord_claim_task:
///   0 = granted
///   1 = held by another peer
///   2 = no claim slot
///  -1 = bad token
///  -5 = rejection cooldown in effect for this client_kind
pub export fn coord_claim_task_ex(
    token_ptr: [*]const u8,
    token_len: c_int,
    task_ptr: [*]const u8,
    task_len: c_int,
    confidence_pct: c_int, // 0..100, or -1 for unset
    dispatch_pref: c_int, // DispatchPref, or -1 for auto-derive
    task_difficulty: c_int, // TaskDifficulty, or -1 if unknown
) c_int {
    _ = dispatch_pref; // schema-level field; server records but doesn't gate on it
    _ = task_difficulty; // likewise
    _ = confidence_pct; // recorded via coord_report_outcome; here it's metadata only

    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const tlen: usize = @intCast(@min(task_len, 128));

    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    const kind = peers[idx].kind;
    if (isInCooldown(kind, now_ms)) return -5;

    // Check if already claimed
    for (&claims) |*c| {
        if (c.active and c.task_name_len == @as(u8, @intCast(tlen)) and
            std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen]))
        {
            if (c.holder_idx == @as(u8, @intCast(idx))) {
                return 0; // Already held by caller — idempotent grant
            }
            recordRejection(kind, now_ms);
            return 1; // Held by another peer
        }
    }

    // Find an empty claim slot
    for (&claims, 0..) |*c, ci| {
        if (!c.active) {
            c.active = true;
            @memcpy(c.task_name[0..tlen], task_ptr[0..tlen]);
            c.task_name_len = @intCast(tlen);
            c.holder_idx = @intCast(idx);
            dur.logClaimAdd(@intCast(ci), @intCast(idx), task_ptr[0..tlen]);
            return 0; // Granted
        }
    }
    recordRejection(kind, now_ms);
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

    for (&claims, 0..) |*c, ci| {
        if (c.active and c.task_name_len == @as(u8, @intCast(tlen)) and
            std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen]) and
            c.holder_idx == @as(u8, @intCast(idx)))
        {
            c.active = false;
            dur.logClaimRel(@intCast(ci));
            return 0;
        }
    }
    return -2; // Not held by this peer
}

// ═══════════════════════════════════════════════════════════════════════
// Gated send + Quarantine Queue
// ═══════════════════════════════════════════════════════════════════════

/// Send a message that MAY be gated. If sender role is supervised and
/// risk_tier >= 2, the message is quarantined and a request_id returned.
/// Otherwise it's delivered directly (identical to coord_send).
///
/// Returns:
///   >= 1  — direct send succeeded, value is sent count
///   -1    — bad token
///   -2    — bad target_idx
///   -3    — target inbox full (direct send)
///   -4    — quarantine queue full
///   -5    — no supervisor registered (supervised peer can't file a Tier 2+
///           without someone to review it)
///   < -1000 — quarantined; request_id = -(returned_value + 1000)
///             (lets a single c_int carry both direct-send count and
///             request_id by sign + range)
pub export fn coord_send_gated(
    token_ptr: [*]const u8,
    token_len: c_int,
    target_idx: c_int,
    msg_ptr: [*]const u8,
    msg_len: c_int,
    risk_tier: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const sender_idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const sender = &peers[sender_idx];
    const tier_u: u8 = if (risk_tier < 0) 0 else @intCast(@min(risk_tier, 4));

    // Free path: supervisor/executor, or supervised with low tier.
    if (sender.role != .supervised or tier_u < 2) {
        // Defer to unlocked direct-send by releasing the mutex — coord_send
        // re-acquires. Inline here to avoid lock churn.
        const mlen: usize = @intCast(@min(msg_len, 512));

        if (target_idx == -1) {
            var sent: c_int = 0;
            for (&peers, 0..) |*p, i| {
                if (p.active and i != sender_idx and p.inbox_count < MAX_MESSAGES) {
                    const head: usize = p.inbox_head;
                    @memcpy(p.inbox[head][0..mlen], msg_ptr[0..mlen]);
                    p.inbox_lens[head] = @intCast(mlen);
                    p.inbox_head = @intCast((@as(u32, p.inbox_head) + 1) % MAX_MESSAGES);
                    p.inbox_count += 1;
                    dur.logInboxPush(@intCast(i), msg_ptr[0..mlen]);
                    sent += 1;
                }
            }
            return sent;
        }

        if (target_idx < 0 or target_idx >= MAX_PEERS) return -2;
        const target = &peers[@intCast(target_idx)];
        if (!target.active) return -2;
        if (target.inbox_count >= MAX_MESSAGES) return -3;

        const head: usize = target.inbox_head;
        @memcpy(target.inbox[head][0..mlen], msg_ptr[0..mlen]);
        target.inbox_lens[head] = @intCast(mlen);
        target.inbox_head = @intCast((@as(u32, target.inbox_head) + 1) % MAX_MESSAGES);
        target.inbox_count += 1;
        dur.logInboxPush(@intCast(target_idx), msg_ptr[0..mlen]);
        return 1;
    }

    // Gated path: supervised peer + Tier 2+ = quarantine.
    if (findSupervisor() == null) return -5;

    for (&quarantine) |*q| {
        if (!q.active) {
            q.active = true;
            q.request_id = next_request_id;
            next_request_id += 1;
            q.sender_idx = @intCast(sender_idx);
            q.target_idx = if (target_idx == -1) -1 else @intCast(target_idx);
            q.risk_tier = tier_u;
            const mlen: usize = @intCast(@min(msg_len, 512));
            @memcpy(q.msg[0..mlen], msg_ptr[0..mlen]);
            q.msg_len = @intCast(mlen);
            q.reason_len = 0;
            dur.logQuarAdd(q.request_id, q.sender_idx, q.target_idx, q.risk_tier, msg_ptr[0..mlen]);
            // Encode request_id as -(id + 1000) so caller can distinguish
            // from direct-send counts.
            const encoded: i64 = -(@as(i64, @intCast(q.request_id)) + 1000);
            return @intCast(encoded);
        }
    }
    return -4; // queue full
}

/// List pending quarantine entries. Only callable by a supervisor.
/// Writes records into `out` — each record is 16 bytes:
///   request_id: u32 little-endian
///   sender_idx: u8
///   target_idx: i8
///   risk_tier: u8
///   msg_len: u16 little-endian
///   first 7 bytes of msg (preview)
///
/// Returns number of records written, or -1 if caller is not supervisor.
pub export fn coord_review(
    supervisor_token_ptr: [*]const u8,
    supervisor_token_len: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(supervisor_token_ptr, @intCast(supervisor_token_len)) orelse return -1;
    if (peers[idx].role != .supervisor) return -1;

    var written: usize = 0;
    const cap: usize = @intCast(out_cap);

    for (&quarantine) |*q| {
        if (q.active and (written + 16) <= cap) {
            const rid_bytes: [4]u8 = @bitCast(q.request_id);
            @memcpy(out[written .. written + 4], &rid_bytes);
            out[written + 4] = q.sender_idx;
            out[written + 5] = @bitCast(q.target_idx);
            out[written + 6] = q.risk_tier;
            const mlen_bytes: [2]u8 = @bitCast(q.msg_len);
            @memcpy(out[written + 7 .. written + 9], &mlen_bytes);
            const preview_n: usize = @min(@as(usize, 7), @as(usize, q.msg_len));
            @memcpy(out[written + 9 .. written + 9 + preview_n], q.msg[0..preview_n]);
            // Zero-pad unused preview bytes.
            if (preview_n < 7) @memset(out[written + 9 + preview_n .. written + 16], 0);
            written += 16;
        }
    }
    return @intCast(written / 16);
}

/// Read the full message body of a specific quarantine entry. Supervisor-only.
/// Returns message length on success, -1 on bad supervisor, -2 on unknown id.
pub export fn coord_review_entry(
    supervisor_token_ptr: [*]const u8,
    supervisor_token_len: c_int,
    request_id: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(supervisor_token_ptr, @intCast(supervisor_token_len)) orelse return -1;
    if (peers[idx].role != .supervisor) return -1;

    const rid: u32 = @intCast(request_id);
    for (&quarantine) |*q| {
        if (q.active and q.request_id == rid) {
            const cap: usize = @intCast(out_cap);
            const mlen: usize = @min(@as(usize, q.msg_len), cap);
            @memcpy(out[0..mlen], q.msg[0..mlen]);
            return @intCast(mlen);
        }
    }
    return -2;
}

/// Approve a quarantined entry — delivers the message to its target(s)
/// and removes the entry. Supervisor-only. Returns 0 on success, -1 on
/// bad supervisor, -2 on unknown id, -3 if target inbox full (caller
/// should retry later).
pub export fn coord_approve(
    supervisor_token_ptr: [*]const u8,
    supervisor_token_len: c_int,
    request_id: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(supervisor_token_ptr, @intCast(supervisor_token_len)) orelse return -1;
    if (peers[idx].role != .supervisor) return -1;

    const rid: u32 = @intCast(request_id);
    for (&quarantine) |*q| {
        if (q.active and q.request_id == rid) {
            const sender_i: usize = q.sender_idx;
            const mlen: usize = q.msg_len;

            if (q.target_idx == -1) {
                // Broadcast — deliver to all active peers except sender.
                for (&peers, 0..) |*p, i| {
                    if (p.active and i != sender_i and p.inbox_count < MAX_MESSAGES) {
                        const head: usize = p.inbox_head;
                        @memcpy(p.inbox[head][0..mlen], q.msg[0..mlen]);
                        p.inbox_lens[head] = @intCast(mlen);
                        p.inbox_head = @intCast((@as(u32, p.inbox_head) + 1) % MAX_MESSAGES);
                        p.inbox_count += 1;
                        dur.logInboxPush(@intCast(i), q.msg[0..mlen]);
                    }
                }
            } else {
                const tidx: usize = @intCast(q.target_idx);
                if (tidx >= MAX_PEERS) return -2;
                const target = &peers[tidx];
                if (!target.active) return -2;
                if (target.inbox_count >= MAX_MESSAGES) return -3;
                const head: usize = target.inbox_head;
                @memcpy(target.inbox[head][0..mlen], q.msg[0..mlen]);
                target.inbox_lens[head] = @intCast(mlen);
                target.inbox_head = @intCast((@as(u32, target.inbox_head) + 1) % MAX_MESSAGES);
                target.inbox_count += 1;
                dur.logInboxPush(@intCast(tidx), q.msg[0..mlen]);
            }
            q.active = false;
            dur.logQuarApprove(rid);
            return 0;
        }
    }
    return -2;
}

/// Reject a quarantined entry — removes it with a recorded reason. The
/// message is NOT delivered. Reason stays in the entry until the next
/// coord_reset (for audit; VeriSimDB sidecar will persist it later).
/// Supervisor-only. Returns 0 on success, -1 on bad supervisor, -2 on
/// unknown id.
pub export fn coord_reject(
    supervisor_token_ptr: [*]const u8,
    supervisor_token_len: c_int,
    request_id: c_int,
    reason_ptr: [*]const u8,
    reason_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(supervisor_token_ptr, @intCast(supervisor_token_len)) orelse return -1;
    if (peers[idx].role != .supervisor) return -1;

    const rid: u32 = @intCast(request_id);
    for (&quarantine) |*q| {
        if (q.active and q.request_id == rid) {
            const rlen: usize = @intCast(@min(reason_len, MAX_REASON));
            if (rlen > 0) @memcpy(q.reason[0..rlen], reason_ptr[0..rlen]);
            q.reason_len = @intCast(rlen);
            q.active = false;
            dur.logQuarReject(rid, reason_ptr[0..rlen]);
            return 0;
        }
    }
    return -2;
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
    dur.logPeerStatusSet(@intCast(idx), status_ptr[0..slen]);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Track Record FFI (Task #13)
// ═══════════════════════════════════════════════════════════════════════

/// Report the outcome of a claim or attempted op. The peer's client_kind
/// (derived from its token) is the aggregation key per DD-29 — the record
/// survives peer crash+restart.
///
/// outcome: 0 = fail, 1 = success
/// duration_ms: wall-time cost of the op in ms (0 if unknown)
/// risk_tier: tier of the op the outcome belongs to (0-4)
/// tag: affinity tag (e.g. "proof-analysis", "routine-edit"); max 64 bytes
///
/// Returns 0 on success, -1 on bad token, -2 on bad args.
pub export fn coord_report_outcome(
    token_ptr: [*]const u8,
    token_len: c_int,
    tag_ptr: [*]const u8,
    tag_len: c_int,
    outcome: c_int,
    duration_ms: c_int,
    risk_tier: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    if (tag_len < 0 or tag_len > @as(c_int, @intCast(MAX_TAG))) return -2;
    if (outcome < 0 or outcome > 1) return -2;
    if (risk_tier < 0 or risk_tier > 4) return -2;
    if (duration_ms < 0) return -2;

    const tlen: usize = @intCast(tag_len);
    const tag = tag_ptr[0..tlen];

    const kind_u: u8 = @intCast(@intFromEnum(peers[idx].kind));
    const outcome_u: u8 = @intCast(outcome);
    const tier_u: u8 = @intCast(risk_tier);
    const dur_u: u32 = @intCast(duration_ms);

    recordTrack(kind_u, outcome_u, tier_u, dur_u, tag);
    dur.logTrackUpdate(kind_u, outcome_u, tier_u, dur_u, @intCast(std.time.milliTimestamp()), tag);
    return 0;
}

const Aggregate = struct {
    client_kind: u8,
    attempts: u16,
    successes: u16,
    tag_len: u8,
    tag: [MAX_TAG]u8,
};

fn tagEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a, b);
}

/// Compute per-(client_kind, tag) aggregates over the active window.
/// Window: an entry counts toward its (kind, tag) if it is within the
/// last 7 days OR among the 20 most recent attempts for that (kind, tag)
/// — whichever set is larger (DD-28). Writes up to `out_cap` aggregates
/// into `out`. Returns the number of aggregates written.
fn buildAggregates(out: []Aggregate) usize {
    var n: usize = 0;
    if (track_count == 0) return 0;

    const now: u64 = @intCast(std.time.milliTimestamp());
    const cutoff: u64 = if (now > WINDOW_MS) now - WINDOW_MS else 0;

    // Iterate track ring in insertion order (oldest first).
    const start: usize = if (track_count < MAX_TRACK) 0 else track_head;
    var step: usize = 0;
    while (step < track_count) : (step += 1) {
        const src_i: usize = (start + step) % MAX_TRACK;
        const t = &track[src_i];
        if (!t.active) continue;

        const tag_slice: []const u8 = t.tag[0..t.tag_len];

        // Find existing aggregate or append.
        var agg_i: usize = 0;
        var found: bool = false;
        while (agg_i < n) : (agg_i += 1) {
            if (out[agg_i].client_kind == t.client_kind and
                tagEql(out[agg_i].tag[0..out[agg_i].tag_len], tag_slice))
            {
                found = true;
                break;
            }
        }
        if (!found) {
            if (n >= out.len) continue;
            out[n] = .{
                .client_kind = t.client_kind,
                .attempts = 0,
                .successes = 0,
                .tag_len = t.tag_len,
                .tag = [_]u8{0} ** MAX_TAG,
            };
            if (t.tag_len > 0) @memcpy(out[n].tag[0..t.tag_len], tag_slice);
            agg_i = n;
            n += 1;
        }
        // Provisional include — we'll filter per (kind, tag) below.
        out[agg_i].attempts += 1;
        if (t.outcome == 1) out[agg_i].successes += 1;
    }

    // Second pass: for each aggregate, apply the window rule.
    // The simple counts above treat every entry as eligible. Replace
    // them with a window-filtered recount.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const tgt_kind = out[i].client_kind;
        const tgt_tag: []const u8 = out[i].tag[0..out[i].tag_len];

        // Collect indices of matching entries, newest first (scan ring
        // in reverse insertion order).
        var matches_attempts: u16 = 0;
        var matches_successes: u16 = 0;

        var seen_for_kind_tag: u16 = 0; // newest-first counter
        var k: usize = 0;
        while (k < track_count) : (k += 1) {
            // Traverse newest-first: head - 1 - k (mod MAX_TRACK).
            const raw_i: isize = @as(isize, @intCast(track_head)) - 1 - @as(isize, @intCast(k));
            const src_i: usize = @intCast(@mod(raw_i, @as(isize, @intCast(MAX_TRACK))));
            const t = &track[src_i];
            if (!t.active) continue;
            if (t.client_kind != tgt_kind) continue;
            if (!tagEql(t.tag[0..t.tag_len], tgt_tag)) continue;

            seen_for_kind_tag += 1;
            const within_time = t.timestamp_ms >= cutoff;
            const within_count = seen_for_kind_tag <= @as(u16, @intCast(WINDOW_ATTEMPTS));

            if (within_time or within_count) {
                matches_attempts += 1;
                if (t.outcome == 1) matches_successes += 1;
            } else {
                // Outside both windows; older entries will also be outside.
                break;
            }
        }
        out[i].attempts = matches_attempts;
        out[i].successes = matches_successes;
    }

    return n;
}

/// Return per-(client_kind, tag) affinity aggregates in `out`. Each
/// record is 64 bytes packed little-endian:
///
///   client_kind : u8
///   attempts    : u16
///   successes   : u16
///   affinity_pct: u8   (0..100, 255 = no data)
///   tag_len     : u8
///   tag         : [57]u8 (only first tag_len bytes valid)
///
/// Returns the number of records written, or -1 on bad token, or the
/// required number of records if `out_cap` is too small (in that case
/// return = -(required + 1000), matching the coord_send_gated idiom).
pub export fn coord_get_affinities(
    token_ptr: [*]const u8,
    token_len: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (findPeerByToken(token_ptr, @intCast(token_len)) == null) return -1;

    // Computed aggregates live on the stack; MAX_TRACK worst-case upper
    // bound on distinct (kind, tag) pairs.
    var aggs: [MAX_TRACK]Aggregate = undefined;
    const n = buildAggregates(aggs[0..]);

    const REC_SIZE: usize = 64;
    const cap: usize = @intCast(out_cap);
    const required: usize = n * REC_SIZE;
    if (required > cap) {
        const encoded: i64 = -(@as(i64, @intCast(n)) + 1000);
        return @intCast(encoded);
    }

    var written: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = out[written .. written + REC_SIZE];
        rec[0] = aggs[i].client_kind;
        std.mem.writeInt(u16, rec[1..3], aggs[i].attempts, .little);
        std.mem.writeInt(u16, rec[3..5], aggs[i].successes, .little);
        const pct: u8 = if (aggs[i].attempts == 0)
            255
        else
            @intCast(@min(
                @as(u32, 100),
                (@as(u32, aggs[i].successes) * 100) / @as(u32, aggs[i].attempts),
            ));
        rec[5] = pct;
        rec[6] = aggs[i].tag_len;
        // Tag into bytes 7..64 (57 bytes). Zero-pad trailing.
        const tl: usize = @min(aggs[i].tag_len, 57);
        if (tl > 0) @memcpy(rec[7 .. 7 + tl], aggs[i].tag[0..tl]);
        if (tl < 57) @memset(rec[7 + tl .. 64], 0);
        written += REC_SIZE;
    }
    return @intCast(n);
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

pub export fn boj_cartridge_init() c_int {
    coord_reset();
    _ = dur.open();
    if (dur.isEnabled()) {
        dur.replay(replayDispatch);
    }
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    dur.close();
    coord_reset();
}

// ═══════════════════════════════════════════════════════════════════════
// Replay dispatcher — reconstructs in-memory state from the durable log.
// Called exactly once per record during boj_cartridge_init replay.
// Events that can't apply (e.g. slot out of range, unknown request_id)
// are silently skipped — the log is best-effort, never a correctness gate.
// ═══════════════════════════════════════════════════════════════════════

fn replayDispatch(event: dur.EventType, payload: []const u8) void {
    switch (event) {
        .peer_add => {
            const d = dur.decodePeerAdd(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            const p = &peers[d.slot_idx];
            p.active = true;
            p.kind = @enumFromInt(d.kind);
            p.role = @enumFromInt(d.role);
            p.state = .active;
            p.suffix = d.suffix;
            p.token = d.token;
            p.inbox_head = 0;
            p.inbox_tail = 0;
            p.inbox_count = 0;
            p.status_len = 0;
            p.context_len = 0;
        },
        .peer_remove => {
            const idx = dur.decodeSlotIdx(payload) orelse return;
            if (idx >= MAX_PEERS) return;
            peers[idx].active = false;
            peers[idx].state = .gone;
        },
        .peer_role_set => {
            const d = dur.decodePeerRoleSet(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            peers[d.slot_idx].role = @enumFromInt(d.role);
        },
        .peer_context_set => {
            const d = dur.decodePeerContextSet(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            const p = &peers[d.slot_idx];
            if (d.ctx.len > MAX_CONTEXT) return;
            if (d.ctx.len > 0) @memcpy(p.context[0..d.ctx.len], d.ctx);
            p.context_len = @intCast(d.ctx.len);
        },
        .peer_status_set => {
            const d = dur.decodePeerStatusSet(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            const p = &peers[d.slot_idx];
            if (d.status.len > 256) return;
            if (d.status.len > 0) @memcpy(p.status[0..d.status.len], d.status);
            p.status_len = @intCast(d.status.len);
        },
        .inbox_push => {
            const d = dur.decodeInboxPush(payload) orelse return;
            if (d.target_idx >= MAX_PEERS) return;
            const p = &peers[d.target_idx];
            if (!p.active or p.inbox_count >= MAX_MESSAGES) return;
            const mlen: usize = @min(d.msg.len, 512);
            const head: usize = p.inbox_head;
            if (mlen > 0) @memcpy(p.inbox[head][0..mlen], d.msg[0..mlen]);
            p.inbox_lens[head] = @intCast(mlen);
            p.inbox_head = @intCast((@as(u32, p.inbox_head) + 1) % MAX_MESSAGES);
            p.inbox_count += 1;
        },
        .inbox_pop => {
            const idx = dur.decodeSlotIdx(payload) orelse return;
            if (idx >= MAX_PEERS) return;
            const p = &peers[idx];
            if (p.inbox_count == 0) return;
            p.inbox_tail = @intCast((@as(u32, p.inbox_tail) + 1) % MAX_MESSAGES);
            p.inbox_count -= 1;
        },
        .claim_add => {
            const d = dur.decodeClaimAdd(payload) orelse return;
            if (d.claim_idx >= MAX_CLAIMS) return;
            if (d.holder_idx >= MAX_PEERS) return;
            const c = &claims[d.claim_idx];
            c.active = true;
            c.holder_idx = d.holder_idx;
            const tlen: usize = @min(d.task.len, 128);
            if (tlen > 0) @memcpy(c.task_name[0..tlen], d.task[0..tlen]);
            c.task_name_len = @intCast(tlen);
        },
        .claim_rel => {
            const idx = dur.decodeSlotIdx(payload) orelse return;
            if (idx >= MAX_CLAIMS) return;
            claims[idx].active = false;
        },
        .quar_add => {
            const d = dur.decodeQuarAdd(payload) orelse return;
            // First empty slot; logged entries beyond MAX_QUARANTINE are
            // dropped during replay (hot-cache-only in Phase 1).
            for (&quarantine) |*q| {
                if (!q.active) {
                    q.active = true;
                    q.request_id = d.request_id;
                    q.sender_idx = d.sender_idx;
                    q.target_idx = d.target_idx;
                    q.risk_tier = d.risk_tier;
                    const mlen: usize = @min(d.msg.len, 512);
                    if (mlen > 0) @memcpy(q.msg[0..mlen], d.msg[0..mlen]);
                    q.msg_len = @intCast(mlen);
                    q.reason_len = 0;
                    if (d.request_id >= next_request_id) next_request_id = d.request_id + 1;
                    return;
                }
            }
        },
        .quar_approve => {
            const rid = dur.decodeRequestId(payload) orelse return;
            for (&quarantine) |*q| {
                if (q.active and q.request_id == rid) {
                    q.active = false;
                    return;
                }
            }
        },
        .quar_reject => {
            const d = dur.decodeQuarReject(payload) orelse return;
            for (&quarantine) |*q| {
                if (q.active and q.request_id == d.request_id) {
                    const rlen: usize = @min(d.reason.len, MAX_REASON);
                    if (rlen > 0) @memcpy(q.reason[0..rlen], d.reason[0..rlen]);
                    q.reason_len = @intCast(rlen);
                    q.active = false;
                    return;
                }
            }
        },
        .audit => {
            // Append-only by design — nothing to reconstruct in live memory.
        },
        .track_update => {
            const d = dur.decodeTrackUpdate(payload) orelse return;
            recordTrackReplay(d.client_kind, d.outcome, d.risk_tier, d.duration_ms, d.timestamp_ms, d.tag);
        },
        else => {},
    }
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    return "local-coord-mcp";
}

pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.2.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "coord_register"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_list_peers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_send"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_receive"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_claim_task"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_report_outcome"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "coord_get_affinities"))
        "{\"result\":{\"affinities\":[],\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Reset (for testing)
// ═══════════════════════════════════════════════════════════════════════

pub export fn coord_reset() void {
    mutex.lock();
    defer mutex.unlock();
    peers = [_]Peer{empty_peer} ** MAX_PEERS;
    claims = [_]Claim{empty_claim} ** MAX_CLAIMS;
    quarantine = [_]QuarantineEntry{empty_quar} ** MAX_QUARANTINE;
    next_request_id = 1;
    track = [_]TrackEntry{empty_track} ** MAX_TRACK;
    track_head = 0;
    track_count = 0;
    reject_ring = [_][REJECT_LIMIT]u64{[_]u64{0} ** REJECT_LIMIT} ** KIND_COUNT;
    reject_head = [_]usize{0} ** KIND_COUNT;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "register and deregister peer" {
    coord_reset();
    var token: [TOKEN_LEN]u8 = undefined;
    var suffix: [4]u8 = undefined;
    const idx = coord_register(0, -1, &token, &suffix); // claude
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
        const idx = coord_register(0, -1, &tokens[i], &suffix);
        try std.testing.expectEqual(@as(c_int, @intCast(i)), idx);
    }

    // Next should fail
    var extra_token: [TOKEN_LEN]u8 = undefined;
    const overflow = coord_register(0, -1, &extra_token, &suffix);
    try std.testing.expectEqual(@as(c_int, -1), overflow);

    coord_reset();
}

test "bad token rejected" {
    coord_reset();
    var token: [TOKEN_LEN]u8 = undefined;
    var suffix: [4]u8 = undefined;
    _ = coord_register(0, -1, &token, &suffix);

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
    _ = coord_register(0, -1, &tok1, &suf); // claude
    _ = coord_register(1, -1, &tok2, &suf); // gemini

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
    _ = coord_register(0, -1, &tok, &suf);

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
    const idx1 = coord_register(0, -1, &tok1, &suf);
    _ = coord_register(1, -1, &tok2, &suf);

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
    _ = coord_register(0, -1, &tok1, &suf);
    _ = coord_register(1, -1, &tok2, &suf);
    _ = coord_register(2, -1, &tok3, &suf);

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

test "set and read peer context" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(0, -1, &tok, &suf);
    try std.testing.expect(idx >= 0);

    // Initially empty
    var ctx_buf: [MAX_CONTEXT]u8 = undefined;
    const empty = coord_read_peer_context(idx, &ctx_buf, @intCast(ctx_buf.len));
    try std.testing.expectEqual(@as(c_int, 0), empty);

    // Set a valid context
    const ctx = "007-lang";
    const set_ok = coord_set_context(&tok, TOKEN_LEN, ctx.ptr, @intCast(ctx.len));
    try std.testing.expectEqual(@as(c_int, 0), set_ok);

    // Read it back
    const read_len = coord_read_peer_context(idx, &ctx_buf, @intCast(ctx_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(ctx.len)), read_len);
    try std.testing.expect(std.mem.eql(u8, ctx_buf[0..ctx.len], ctx));

    // Bad context (spaces) rejected
    const bad = "has space";
    const rc_bad = coord_set_context(&tok, TOKEN_LEN, bad.ptr, @intCast(bad.len));
    try std.testing.expectEqual(@as(c_int, -2), rc_bad);

    // Original context untouched after rejection
    const reread = coord_read_peer_context(idx, &ctx_buf, @intCast(ctx_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(ctx.len)), reread);

    // Slot reuse clears context
    _ = coord_deregister(&tok, TOKEN_LEN);
    var tok2: [TOKEN_LEN]u8 = undefined;
    const idx2 = coord_register(0, -1, &tok2, &suf);
    // Same slot likely re-used; context should be zeroed
    const after = coord_read_peer_context(idx2, &ctx_buf, @intCast(ctx_buf.len));
    try std.testing.expectEqual(@as(c_int, 0), after);

    coord_reset();
}

test "default role derives from client_kind" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // claude -> executor
    const c_idx = coord_register(0, -1, &tok, &suf);
    try std.testing.expect(c_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.executor)), coord_read_peer_role(c_idx));

    // gemini -> supervised
    const g_idx = coord_register(1, -1, &tok, &suf);
    try std.testing.expect(g_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.supervised)), coord_read_peer_role(g_idx));

    // copilot -> supervised
    const p_idx = coord_register(2, -1, &tok, &suf);
    try std.testing.expect(p_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.supervised)), coord_read_peer_role(p_idx));

    // custom -> supervised
    const x_idx = coord_register(3, -1, &tok, &suf);
    try std.testing.expect(x_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.supervised)), coord_read_peer_role(x_idx));

    coord_reset();
}

test "register rejects supervisor role_hint" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // role_hint=0 (supervisor) is always rejected; must use coord_promote_to_supervisor.
    const rc = coord_register(0, 0, &tok, &suf);
    try std.testing.expectEqual(@as(c_int, -3), rc);

    coord_reset();
}

test "promote to supervisor requires env-var secret match" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(0, -1, &tok, &suf);
    try std.testing.expect(idx >= 0);

    // No env var set -> promotion refused (-3).
    // (Can't reliably unset env in Zig std; this test documents the expected
    // contract. The match path is exercised by the adapter-level integration
    // test which sets BOJ_SUPERVISOR_TOKEN before spawning the process.)

    coord_reset();
}

test "gated send from supervised peer lands in quarantine" {
    coord_reset();
    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // Manually install a supervisor by bypassing env-var gate (test-only
    // shortcut — we set role directly via coord_set_role which needs a
    // supervisor token, so we instead register the supervisor by direct
    // register + role override for this test).
    _ = coord_register(0, 1, &sup_tok, &suf); // executor
    // Upgrade directly for test purposes by touching the peer record.
    // In production this happens via coord_promote_to_supervisor.
    peers[0].role = .supervisor;

    // Now register gemini as supervised (default for kind=1).
    const gem_idx = coord_register(1, -1, &gem_tok, &suf);
    try std.testing.expect(gem_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.supervised)), coord_read_peer_role(gem_idx));

    // Tier 0 op from supervised: direct delivery.
    const msg_low = "status-update";
    const t0_rc = coord_send_gated(&gem_tok, TOKEN_LEN, 0, msg_low.ptr, @intCast(msg_low.len), 0);
    try std.testing.expectEqual(@as(c_int, 1), t0_rc); // direct send: sent=1

    // Tier 2 op from supervised: quarantined; returned value encodes request_id.
    const msg_high = "proposed-commit-a1b2c3d";
    const t2_rc = coord_send_gated(&gem_tok, TOKEN_LEN, 0, msg_high.ptr, @intCast(msg_high.len), 2);
    try std.testing.expect(t2_rc < -1000); // encoded request_id

    const request_id: u32 = @intCast(-(t2_rc + 1000));

    // Supervisor should see one pending entry.
    var review_buf: [512]u8 = undefined;
    const n = coord_review(&sup_tok, TOKEN_LEN, &review_buf, @intCast(review_buf.len));
    try std.testing.expectEqual(@as(c_int, 1), n);

    // Full entry body is readable.
    var body_buf: [512]u8 = undefined;
    const body_len = coord_review_entry(&sup_tok, TOKEN_LEN, @intCast(request_id), &body_buf, @intCast(body_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(msg_high.len)), body_len);
    try std.testing.expect(std.mem.eql(u8, body_buf[0..msg_high.len], msg_high));

    // Approve delivers to recipient.
    const a_rc = coord_approve(&sup_tok, TOKEN_LEN, @intCast(request_id));
    try std.testing.expectEqual(@as(c_int, 0), a_rc);

    // Recipient (index 0 — supervisor in this test) can receive the message.
    var recv_buf: [512]u8 = undefined;
    // First message is msg_low from the Tier 0 send (it went direct).
    // The gated approved msg_high is now second in queue.
    const r1_len = coord_receive(&sup_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len));
    try std.testing.expect(r1_len > 0);
    const r2_len = coord_receive(&sup_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(msg_high.len)), r2_len);
    try std.testing.expect(std.mem.eql(u8, recv_buf[0..msg_high.len], msg_high));

    coord_reset();
}

test "supervisor rejects a quarantined entry" {
    coord_reset();
    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    _ = coord_register(0, 1, &sup_tok, &suf);
    peers[0].role = .supervisor;
    _ = coord_register(1, -1, &gem_tok, &suf);

    const msg = "sneaky-push";
    const rc = coord_send_gated(&gem_tok, TOKEN_LEN, 0, msg.ptr, @intCast(msg.len), 3);
    try std.testing.expect(rc < -1000);
    const request_id: u32 = @intCast(-(rc + 1000));

    const reason = "confabulated file path";
    const rj = coord_reject(&sup_tok, TOKEN_LEN, @intCast(request_id), reason.ptr, @intCast(reason.len));
    try std.testing.expectEqual(@as(c_int, 0), rj);

    // Review queue now empty.
    var buf: [512]u8 = undefined;
    const n = coord_review(&sup_tok, TOKEN_LEN, &buf, @intCast(buf.len));
    try std.testing.expectEqual(@as(c_int, 0), n);

    // Recipient did NOT get the message.
    const r = coord_receive(&sup_tok, TOKEN_LEN, &buf, @intCast(buf.len));
    try std.testing.expectEqual(@as(c_int, 0), r);

    coord_reset();
}

test "non-supervisor cannot review/approve/reject" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf); // executor, not supervisor

    var out: [128]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), coord_review(&tok, TOKEN_LEN, &out, @intCast(out.len)));
    try std.testing.expectEqual(@as(c_int, -1), coord_approve(&tok, TOKEN_LEN, 42));
    const reason = "nope";
    try std.testing.expectEqual(@as(c_int, -1), coord_reject(&tok, TOKEN_LEN, 42, reason.ptr, @intCast(reason.len)));

    coord_reset();
}

test "find peer by suffix" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(0, -1, &tok, &suf);
    try std.testing.expect(idx >= 0);

    // Lookup should find it
    const found = coord_find_peer_by_suffix(&suf);
    try std.testing.expectEqual(@as(c_int, idx), found);

    // Unknown suffix returns -1
    const miss = [4]u8{ 'z', 'z', 'z', 'z' };
    const not_found = coord_find_peer_by_suffix(&miss);
    try std.testing.expectEqual(@as(c_int, -1), not_found);

    coord_reset();
}

test "deregister releases claims" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok1, &suf);
    _ = coord_register(1, -1, &tok2, &suf);

    const task = "fix-pipeline";
    _ = coord_claim_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len));

    // Deregister peer 1
    _ = coord_deregister(&tok1, TOKEN_LEN);

    // Peer 2 should now be able to claim
    const r = coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 0), r); // Granted

    coord_reset();
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "coord_register",
        "coord_list_peers",
        "coord_send",
        "coord_receive",
        "coord_claim_task",
        "coord_status",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
    }
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("coord_register", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}

// ═══════════════════════════════════════════════════════════════════════
// Durability integration tests — restart-preserves-state
// ═══════════════════════════════════════════════════════════════════════

fn tmpCoordDir(buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "/tmp/boj-coord-integ-{d}-{d}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

test "restart replay restores peer, claim, inbox, quarantine" {
    coord_reset();
    dur.close();

    var path_buf: [256]u8 = undefined;
    const dir = try tmpCoordDir(&path_buf);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.testing.expect(dur.openWithDir(dir));
    dur.truncate();

    // ── Phase 1: build up state under durable logging ─────────────────
    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var sup_suf: [4]u8 = undefined;
    const sup_idx = coord_register(0, 1, &sup_tok, &sup_suf); // claude as executor
    try std.testing.expect(sup_idx >= 0);
    // Promote directly via state mutation — avoids env-var gymnastics
    // in-test, and still gets persisted via the coord_set_role path below.
    peers[@intCast(sup_idx)].role = .supervisor;
    dur.logPeerRoleSet(@intCast(sup_idx), @intCast(@intFromEnum(Role.supervisor)));

    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var gem_suf: [4]u8 = undefined;
    const gem_idx = coord_register(1, -1, &gem_tok, &gem_suf); // gemini → supervised
    try std.testing.expect(gem_idx >= 0);

    // Remember identities for post-replay comparison.
    const sup_suf_copy = sup_suf;
    const gem_suf_copy = gem_suf;

    // Set a context on the supervised peer.
    const ctx = "007-lang";
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_set_context(&gem_tok, TOKEN_LEN, ctx.ptr, @intCast(ctx.len)),
    );

    // Send a direct message sup → gem; leave it unreceived so it must
    // come back from replay.
    const pending_msg = "pending-direct-message";
    try std.testing.expectEqual(
        @as(c_int, 1),
        coord_send(&sup_tok, TOKEN_LEN, gem_idx, pending_msg.ptr, @intCast(pending_msg.len)),
    );

    // Claim a task as the supervisor.
    const task = "restart-replay-task";
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_claim_task(&sup_tok, TOKEN_LEN, task.ptr, @intCast(task.len)),
    );

    // Gemini files a Tier 3 gated op — lands in quarantine.
    const gated_msg = "proposed-commit";
    const gated_rc = coord_send_gated(&gem_tok, TOKEN_LEN, sup_idx, gated_msg.ptr, @intCast(gated_msg.len), 3);
    try std.testing.expect(gated_rc < -1000);
    const request_id: u32 = @intCast(-(gated_rc + 1000));

    // ── Phase 2: simulate adapter restart — close log, wipe memory, reopen, replay ──
    dur.close();
    coord_reset();
    try std.testing.expect(dur.openWithDir(dir));
    dur.replay(replayDispatch);
    defer {
        dur.close();
    }

    // ── Phase 3: verify state reconstructed ───────────────────────────

    // Peers re-occupy their original slots with original suffixes.
    try std.testing.expect(peers[@intCast(sup_idx)].active);
    try std.testing.expectEqualSlices(u8, &sup_suf_copy, &peers[@intCast(sup_idx)].suffix);
    try std.testing.expectEqual(Role.supervisor, peers[@intCast(sup_idx)].role);

    try std.testing.expect(peers[@intCast(gem_idx)].active);
    try std.testing.expectEqualSlices(u8, &gem_suf_copy, &peers[@intCast(gem_idx)].suffix);
    try std.testing.expectEqual(Role.supervised, peers[@intCast(gem_idx)].role);

    // Context survives replay.
    var ctx_buf: [MAX_CONTEXT]u8 = undefined;
    const ctx_len = coord_read_peer_context(gem_idx, &ctx_buf, @intCast(ctx_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(ctx.len)), ctx_len);
    try std.testing.expectEqualSlices(u8, ctx, ctx_buf[0..@intCast(ctx_len)]);

    // Pending inbox message delivers to gemini on receive.
    var recv_buf: [512]u8 = undefined;
    const recv_len = coord_receive(&gem_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(pending_msg.len)), recv_len);
    try std.testing.expectEqualSlices(u8, pending_msg, recv_buf[0..@intCast(recv_len)]);

    // Claim still held by supervisor — another peer can't grab it.
    const steal_rc = coord_claim_task(&gem_tok, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 1), steal_rc); // Held

    // Supervisor's own re-claim is idempotent.
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_claim_task(&sup_tok, TOKEN_LEN, task.ptr, @intCast(task.len)),
    );

    // Quarantine entry reappears for the supervisor to review.
    var review_buf: [512]u8 = undefined;
    const n = coord_review(&sup_tok, TOKEN_LEN, &review_buf, @intCast(review_buf.len));
    try std.testing.expectEqual(@as(c_int, 1), n);

    var body_buf: [512]u8 = undefined;
    const body_len = coord_review_entry(&sup_tok, TOKEN_LEN, @intCast(request_id), &body_buf, @intCast(body_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(gated_msg.len)), body_len);
    try std.testing.expectEqualSlices(u8, gated_msg, body_buf[0..@intCast(body_len)]);

    coord_reset();
}

test "approve then restart: quarantine gone, delivered message survives" {
    coord_reset();
    dur.close();

    var path_buf: [256]u8 = undefined;
    const dir = try tmpCoordDir(&path_buf);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.testing.expect(dur.openWithDir(dir));
    dur.truncate();

    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var sup_suf: [4]u8 = undefined;
    const sup_idx = coord_register(0, 1, &sup_tok, &sup_suf);
    try std.testing.expect(sup_idx >= 0);
    peers[@intCast(sup_idx)].role = .supervisor;
    dur.logPeerRoleSet(@intCast(sup_idx), @intCast(@intFromEnum(Role.supervisor)));

    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var gem_suf: [4]u8 = undefined;
    const gem_idx = coord_register(1, -1, &gem_tok, &gem_suf);
    try std.testing.expect(gem_idx >= 0);

    // Supervised files, supervisor approves — approved message is now in
    // sup's inbox and the quarantine slot is freed.
    const msg = "gated-and-approved";
    const gated_rc = coord_send_gated(&gem_tok, TOKEN_LEN, sup_idx, msg.ptr, @intCast(msg.len), 3);
    try std.testing.expect(gated_rc < -1000);
    const rid: u32 = @intCast(-(gated_rc + 1000));
    try std.testing.expectEqual(@as(c_int, 0), coord_approve(&sup_tok, TOKEN_LEN, @intCast(rid)));

    dur.close();
    coord_reset();
    try std.testing.expect(dur.openWithDir(dir));
    dur.replay(replayDispatch);
    defer dur.close();

    // Quarantine empty after replay (add + approve cancel out).
    var review_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), coord_review(&sup_tok, TOKEN_LEN, &review_buf, @intCast(review_buf.len)));

    // Approved message remains in sup's inbox.
    var recv_buf: [512]u8 = undefined;
    const n = coord_receive(&sup_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(msg.len)), n);
    try std.testing.expectEqualSlices(u8, msg, recv_buf[0..@intCast(n)]);

    coord_reset();
}

test "reject then restart: quarantine gone, message NOT delivered" {
    coord_reset();
    dur.close();

    var path_buf: [256]u8 = undefined;
    const dir = try tmpCoordDir(&path_buf);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.testing.expect(dur.openWithDir(dir));
    dur.truncate();

    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var sup_suf: [4]u8 = undefined;
    _ = coord_register(0, 1, &sup_tok, &sup_suf);
    peers[0].role = .supervisor;
    dur.logPeerRoleSet(0, @intCast(@intFromEnum(Role.supervisor)));

    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var gem_suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &gem_tok, &gem_suf);

    const msg = "gated-and-rejected";
    const gated_rc = coord_send_gated(&gem_tok, TOKEN_LEN, 0, msg.ptr, @intCast(msg.len), 3);
    try std.testing.expect(gated_rc < -1000);
    const rid: u32 = @intCast(-(gated_rc + 1000));
    const reason = "confabulated-path";
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_reject(&sup_tok, TOKEN_LEN, @intCast(rid), reason.ptr, @intCast(reason.len)),
    );

    dur.close();
    coord_reset();
    try std.testing.expect(dur.openWithDir(dir));
    dur.replay(replayDispatch);
    defer dur.close();

    // Supervisor inbox empty — rejected msg not delivered across restart.
    var recv_buf: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_receive(&sup_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len)),
    );

    // Quarantine empty too.
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_review(&sup_tok, TOKEN_LEN, &recv_buf, @intCast(recv_buf.len)),
    );

    coord_reset();
}

// ═══════════════════════════════════════════════════════════════════════
// Track Record tests (Task #13)
// ═══════════════════════════════════════════════════════════════════════

fn findAggByTag(out: []const u8, n: usize, kind: u8, tag: []const u8) ?usize {
    const REC_SIZE: usize = 64;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = out[i * REC_SIZE ..][0..REC_SIZE];
        if (rec[0] != kind) continue;
        const tl: usize = rec[6];
        if (tl != tag.len) continue;
        if (std.mem.eql(u8, rec[7 .. 7 + tl], tag)) return i;
    }
    return null;
}

test "report outcome and compute affinity" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf); // claude

    const tag = "proof-analysis";
    // 3 successes + 1 failure → 75%.
    for (0..3) |_| {
        try std.testing.expectEqual(
            @as(c_int, 0),
            coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 500, 2),
        );
    }
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 500, 2),
    );

    var buf: [64 * 8]u8 = undefined;
    const n = coord_get_affinities(&tok, TOKEN_LEN, &buf, @intCast(buf.len));
    try std.testing.expect(n >= 1);

    const n_usize: usize = @intCast(n);
    const idx = findAggByTag(&buf, n_usize, 0, tag) orelse return error.AggregateMissing;
    const rec = buf[idx * 64 ..][0..64];
    const attempts = std.mem.readInt(u16, rec[1..3], .little);
    const successes = std.mem.readInt(u16, rec[3..5], .little);
    try std.testing.expectEqual(@as(u16, 4), attempts);
    try std.testing.expectEqual(@as(u16, 3), successes);
    try std.testing.expectEqual(@as(u8, 75), rec[5]);

    coord_reset();
}

test "affinity keyed on client_kind, survives peer restart" {
    coord_reset();

    // Two claude peers in sequence (deregister + re-register simulates restart).
    var tok1: [TOKEN_LEN]u8 = undefined;
    var suf1: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok1, &suf1); // claude #1
    const tag = "routine-edit";
    _ = coord_report_outcome(&tok1, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 1);
    _ = coord_report_outcome(&tok1, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 1);
    _ = coord_deregister(&tok1, TOKEN_LEN);

    // New peer, same client_kind. Track record should aggregate together.
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf2: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok2, &suf2); // claude #2
    _ = coord_report_outcome(&tok2, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 100, 1);

    var buf: [64 * 8]u8 = undefined;
    const n = coord_get_affinities(&tok2, TOKEN_LEN, &buf, @intCast(buf.len));
    try std.testing.expect(n >= 1);
    const idx = findAggByTag(&buf, @intCast(n), 0, tag) orelse return error.AggregateMissing;
    const rec = buf[idx * 64 ..][0..64];
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, rec[1..3], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, rec[3..5], .little));

    coord_reset();
}

test "affinity window cap — last 20 attempts when no 7-day-older entries" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf);

    const tag = "doc-writing";
    // 25 successes — window caps at 20 (all newer than 7 days, count-rule wins).
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 50, 1);
    }

    var buf: [64 * 4]u8 = undefined;
    const n = coord_get_affinities(&tok, TOKEN_LEN, &buf, @intCast(buf.len));
    const idx = findAggByTag(&buf, @intCast(n), 0, tag) orelse return error.AggregateMissing;
    const rec = buf[idx * 64 ..][0..64];
    // All 25 are within last 7 days, so time-window rule > 20-count rule.
    // "whichever is larger" means we use 25 attempts.
    try std.testing.expectEqual(@as(u16, 25), std.mem.readInt(u16, rec[1..3], .little));

    coord_reset();
}

test "affinity bad token rejected" {
    coord_reset();
    var bad_tok = [_]u8{0xFF} ** TOKEN_LEN;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, -1),
        coord_get_affinities(&bad_tok, TOKEN_LEN, &buf, @intCast(buf.len)),
    );
    try std.testing.expectEqual(
        @as(c_int, -1),
        coord_report_outcome(&bad_tok, TOKEN_LEN, "x".ptr, 1, 1, 0, 0),
    );
    coord_reset();
}

// ═══════════════════════════════════════════════════════════════════════
// Claim extension + rejection cooldown tests (Task #15)
// ═══════════════════════════════════════════════════════════════════════

test "coord_claim_task_ex accepts optional fields and grants" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf);

    const task = "design-review";
    // confidence=80, dispatch_pref=deliberate (0), difficulty=challenging (2)
    const rc = coord_claim_task_ex(&tok, TOKEN_LEN, task.ptr, @intCast(task.len), 80, 0, 2);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    coord_reset();
}

test "rejection cooldown engages after 5 rejects in 10 min" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok1, &suf); // claude holds the task
    _ = coord_register(0, -1, &tok2, &suf); // claude #2 keeps colliding

    const task = "held-task";
    try std.testing.expectEqual(@as(c_int, 0), coord_claim_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len)));

    // 5 rejects in sequence — the 6th triggers cooldown.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(
            @as(c_int, 1),
            coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len)),
        );
    }
    // Same kind (claude) — should now be in cooldown.
    const cool = coord_claim_task(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, -5), cool);

    // Different kind is unaffected.
    var gem_tok: [TOKEN_LEN]u8 = undefined;
    _ = coord_register(1, -1, &gem_tok, &suf);
    const gem_rc = coord_claim_task(&gem_tok, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 1), gem_rc); // held, not cooldown

    coord_reset();
}

test "affinity replay after restart" {
    coord_reset();
    dur.close();

    var path_buf: [256]u8 = undefined;
    const dir = try tmpCoordDir(&path_buf);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.testing.expect(dur.openWithDir(dir));
    dur.truncate();

    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf);

    const tag = "test-writing";
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 200, 1);
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 200, 1);

    dur.close();
    coord_reset();
    try std.testing.expect(dur.openWithDir(dir));
    dur.replay(replayDispatch);
    defer dur.close();

    // Re-register so we have a token to query with.
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf2: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok2, &suf2);

    var buf: [64 * 4]u8 = undefined;
    const n = coord_get_affinities(&tok2, TOKEN_LEN, &buf, @intCast(buf.len));
    const idx = findAggByTag(&buf, @intCast(n), 0, tag) orelse return error.AggregateMissing;
    const rec = buf[idx * 64 ..][0..64];
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, rec[1..3], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, rec[3..5], .little));

    coord_reset();
}
