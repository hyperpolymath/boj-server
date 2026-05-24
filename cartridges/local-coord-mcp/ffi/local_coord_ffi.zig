// SPDX-License-Identifier: MPL-2.0
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

// ADR-0016 Phase 1: pull in coord_identity so its `pub export fn`
// symbols are part of the shared library. The module does not need to
// be referenced directly from this file — the import side-effect is
// to surface the FFI exports for `boj_coord_identity_*`.
comptime {
    _ = @import("coord_identity.zig");
}

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
    openai = 4,
    mistral = 5,
};

pub const PeerState = enum(c_int) {
    registering = 0,
    active = 1,
    departing = 2,
    gone = 3,
};

/// Trust role — determines what a peer may do without a master gate.
/// See docs/envelope-design.adoc for the risk ladder. Integer ordinals
/// preserved across the 2026-04-20 rename (old supervisor → master,
/// executor → journeyman, supervised → apprentice — DD-32) so logs
/// written before the rename still replay correctly
/// from before the rename still replay.
pub const Role = enum(c_int) {
    master = 0, // Opus (or whoever holds BOJ_MASTER_TOKEN) — approval authority
    journeyman = 1, // Claude Sonnet/Haiku — trusted to act solo on Tier 2
    apprentice = 2, // gemini/codex/vibe — Tier 2+ quarantined for master review
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

/// Declared affinities — comma-joined list of tags the peer self-reports
/// as strengths at register time. The reassignment engine (Task #14)
/// cross-checks these against effective_affinity to detect gaps and
/// overclaims. Stored as the raw CSV string so comparison is cheap.
const MAX_DECLARED: usize = 256;

/// Variant label — free-form model/variant identifier (e.g. "opus-4.7",
/// "flash-2.5", "leanstral"). Task #33. Alphanumeric + `.`/`-`/`_` only.
const MAX_VARIANT: usize = 32;

/// Capability class CSV — e.g. "reasoning,coding,proof". Task #34.
const MAX_CLASS: usize = 128;

/// Prover-strengths CSV — e.g. "coq,isabelle,lean,tlaps". Task #34.
const MAX_PROVERS: usize = 256;

/// Sentinel for unset capability tier. Valid advertised tiers are 1..5.
const TIER_UNSET: u8 = 0;

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
    // Declared affinities (CSV of tag names)
    declared_affinities: [MAX_DECLARED]u8,
    declared_affinities_len: u16,
    // Task #33 — model/variant label (e.g. "opus-4.7", "flash-2.5")
    variant: [MAX_VARIANT]u8,
    variant_len: u8,
    // Task #34 — capability advertisement
    class_csv: [MAX_CLASS]u8,
    class_csv_len: u16,
    tier: u8, // 0 = unset (TIER_UNSET), 1..5 = advertised tier
    prover_strengths: [MAX_PROVERS]u8,
    prover_strengths_len: u16,
};

const empty_peer = Peer{
    .active = false,
    .kind = .claude,
    .suffix = [_]u8{ '0', '0', '0', '0' },
    .state = .gone,
    .token = [_]u8{0} ** TOKEN_LEN,
    .role = .apprentice,
    .inbox = [_][512]u8{[_]u8{0} ** 512} ** MAX_MESSAGES,
    .inbox_lens = [_]u16{0} ** MAX_MESSAGES,
    .inbox_head = 0,
    .inbox_tail = 0,
    .inbox_count = 0,
    .status = [_]u8{0} ** 256,
    .status_len = 0,
    .context = [_]u8{0} ** MAX_CONTEXT,
    .context_len = 0,
    .declared_affinities = [_]u8{0} ** MAX_DECLARED,
    .declared_affinities_len = 0,
    .variant = [_]u8{0} ** MAX_VARIANT,
    .variant_len = 0,
    .class_csv = [_]u8{0} ** MAX_CLASS,
    .class_csv_len = 0,
    .tier = TIER_UNSET,
    .prover_strengths = [_]u8{0} ** MAX_PROVERS,
    .prover_strengths_len = 0,
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
    // Task #15-watchdog (DD-20) — ms since epoch of claim acquisition or
    // most recent coord_progress heartbeat. sweepExpiredClaims compares
    // (now - claimed_at_ms) against the holder's role-specific TTL.
    claimed_at_ms: u64,
};

const empty_claim = Claim{
    .active = false,
    .task_name = [_]u8{0} ** 128,
    .task_name_len = 0,
    .holder_idx = 0,
    .claimed_at_ms = 0,
};

var claims: [MAX_CLAIMS]Claim = [_]Claim{empty_claim} ** MAX_CLAIMS;

/// Watchdog TTLs per role (DD-20). master has no TTL — they're the
/// approval authority, not an executor. Values chosen to catch abandoned
/// work fast (apprentice) while allowing deep thought time (journeyman).
const TTL_APPRENTICE_MS: u64 = 30 * 1000;       // 30 s
const TTL_JOURNEYMAN_MS: u64 = 5 * 60 * 1000;   // 5 min

/// Return the TTL in ms for a role, or 0 for roles with no watchdog.
fn watchdogTtlMs(role: Role) u64 {
    return switch (role) {
        .apprentice => TTL_APPRENTICE_MS,
        .journeyman => TTL_JOURNEYMAN_MS,
        .master => 0,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Quarantine Queue — Tier 2+ ops from role=apprentice peers held here
// until a master approves or rejects.
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
    confidence_pct: u8, // 255 = unset
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
    .confidence_pct = 255,
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
    confidence_pct: u8,
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
    t.confidence_pct = confidence_pct;
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
    confidence_pct: u8,
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
    t.confidence_pct = confidence_pct;
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
/// claude -> journeyman (trusted to act solo on Tier 2)
/// everything else (gemini, copilot, custom, openai, mistral) -> apprentice
fn defaultRoleForKind(kind: ClientKind) Role {
    return switch (kind) {
        .claude => .journeyman,
        else => .apprentice,
    };
}

/// Find the active master, if any. Returns the peer index or null.
fn findMaster() ?usize {
    for (&peers, 0..) |*p, i| {
        if (p.active and p.role == .master) return i;
    }
    return null;
}

/// Register a new peer. Returns peer index, or -1 if full, -3 if the
/// caller tries to claim master via role_hint (use
/// coord_promote_to_master instead).
///
/// role_hint = -1 (ROLE_HINT_DEFAULT): server assigns from kind
/// role_hint = 0 (master): REJECTED here — use coord_promote_to_master
/// role_hint = 1 (journeyman): granted journeyman role
/// role_hint = 2 (apprentice): granted apprentice role (self-downgrade)
pub export fn coord_register(kind: c_int, role_hint: c_int, token_out: [*]u8, suffix_out: [*]u8) c_int {
    mutex.lock();
    defer mutex.unlock();

    const client_kind: ClientKind = @enumFromInt(kind);

    // Resolve role. Master NEVER granted at register — must be
    // promoted via coord_promote_to_master with env-var secret.
    const role: Role = blk: {
        if (role_hint == ROLE_HINT_DEFAULT) break :blk defaultRoleForKind(client_kind);
        const r: Role = @enumFromInt(role_hint);
        if (r == .master) return -3;
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
            p.declared_affinities_len = 0;
            p.variant_len = 0;
            p.class_csv_len = 0;
            p.tier = TIER_UNSET;
            p.prover_strengths_len = 0;

            @memcpy(token_out[0..TOKEN_LEN], &p.token);
            @memcpy(suffix_out[0..4], &p.suffix);

            dur.logPeerAdd(@intCast(i), @intCast(@intFromEnum(client_kind)), @intCast(@intFromEnum(role)), &p.suffix, &p.token);
            return @intCast(i);
        }
    }
    return -1; // registry full
}

/// Promote the caller's peer to master role. Gated by the
/// BOJ_MASTER_TOKEN env var (must be set, and presented secret must
/// match). At most one master at a time. `BOJ_SUPERVISOR_TOKEN` is
/// honoured as a fallback for one release (DD-32 backward-compat).
///
/// Returns:
///   0   — promoted
///  -1   — bad own token
///  -2   — master already exists
///  -3   — BOJ_MASTER_TOKEN (and deprecated BOJ_SUPERVISOR_TOKEN) not
///          set — server doesn't allow master role in this deployment
///  -4   — presented secret does not match env var
pub export fn coord_promote_to_master(
    own_token_ptr: [*]const u8,
    own_token_len: c_int,
    secret_ptr: [*]const u8,
    secret_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(own_token_ptr, @intCast(own_token_len)) orelse return -1;
    if (findMaster() != null) return -2;

    // Env-var check — BOJ_MASTER_TOKEN first, BOJ_SUPERVISOR_TOKEN fallback
    // for one release (DD-32). Read at promotion time so a running server
    // can have its policy changed by restart.
    const env_secret = std.posix.getenv("BOJ_MASTER_TOKEN") orelse
        std.posix.getenv("BOJ_SUPERVISOR_TOKEN") orelse return -3;
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

    peers[idx].role = .master;
    dur.logPeerRoleSet(@intCast(idx), @intCast(@intFromEnum(Role.master)));
    return 0;
}

/// Backward-compat alias for the 2026-04-20 rename (DD-32). Old MCP
/// clients call this name; it forwards to coord_promote_to_master.
/// Remove one release after DD-32 lands.
pub export fn coord_promote_to_supervisor(
    own_token_ptr: [*]const u8,
    own_token_len: c_int,
    secret_ptr: [*]const u8,
    secret_len: c_int,
) c_int {
    return coord_promote_to_master(own_token_ptr, own_token_len, secret_ptr, secret_len);
}

/// Live master handoff (Task #35) — pass the master role to a named
/// successor without a process restart. Secret-gated by BOJ_MASTER_TOKEN
/// (BOJ_SUPERVISOR_TOKEN fallback for one release). Target must be
/// journeyman or already master — apprentices are rejected (prevents
/// hostile handoff to an untrusted peer). Audit-logged so replay
/// reconstructs the transfer.
///
/// Returns:
///   0   promoted successor + demoted self to journeyman
///  -1   caller not master / bad token
///  -2   target peer not found / inactive
///  -3   secret mismatch (or env var unset)
///  -4   target is apprentice — blocked, must be journeyman+
pub export fn coord_transfer_master(
    current_master_token_ptr: [*]const u8,
    current_master_token_len: c_int,
    target_peer_idx: c_int,
    secret_ptr: [*]const u8,
    secret_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const cur_idx = findPeerByToken(current_master_token_ptr, @intCast(current_master_token_len)) orelse return -1;
    if (peers[cur_idx].role != .master) return -1;

    if (target_peer_idx < 0 or target_peer_idx >= MAX_PEERS) return -2;
    const tidx: usize = @intCast(target_peer_idx);
    const target = &peers[tidx];
    if (!target.active) return -2;
    if (target.role == .apprentice) return -4;
    if (tidx == cur_idx) return -2; // handoff to self is a no-op, treat as bad target

    // Secret must match BOJ_MASTER_TOKEN (or BOJ_SUPERVISOR_TOKEN as
    // back-compat fallback). Fail closed if neither is set.
    const env_secret = std.posix.getenv("BOJ_MASTER_TOKEN")
        orelse std.posix.getenv("BOJ_SUPERVISOR_TOKEN")
        orelse return -3;
    if (env_secret.len == 0) return -3;

    const slen: usize = @intCast(secret_len);
    if (slen != env_secret.len) return -3;
    var diff: u8 = 0;
    var k: usize = 0;
    while (k < slen) : (k += 1) {
        diff |= env_secret[k] ^ secret_ptr[k];
    }
    if (diff != 0) return -3;

    // Atomic pair: demote caller to journeyman, promote target to master.
    peers[cur_idx].role = .journeyman;
    dur.logPeerRoleSet(@intCast(cur_idx), @intCast(@intFromEnum(Role.journeyman)));
    target.role = .master;
    dur.logPeerRoleSet(@intCast(tidx), @intCast(@intFromEnum(Role.master)));

    // Audit breadcrumb — kind=2 reserved for MASTER_HANDOFF.
    var detail_buf: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "from={d}|to={d}", .{ cur_idx, tidx }) catch "";
    dur.logAudit(2, detail);
    return 0;
}

/// Read a peer's role. Returns 0=master, 1=journeyman, 2=apprentice,
/// or -1 if peer index out of range / inactive.
pub export fn coord_read_peer_role(peer_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    return @intFromEnum(p.role);
}

/// Re-assign a peer's role. Only callable by an active master (token
/// must belong to role=master). Returns 0 on success, -1 on bad
/// master token, -2 on bad target, -3 on disallowed transition
/// (e.g. demoting the sole master).
pub export fn coord_set_role(
    master_token_ptr: [*]const u8,
    master_token_len: c_int,
    target_peer_idx: c_int,
    new_role: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const sup_idx = findPeerByToken(master_token_ptr, @intCast(master_token_len)) orelse return -1;
    if (peers[sup_idx].role != .master) return -1;

    if (target_peer_idx < 0 or target_peer_idx >= MAX_PEERS) return -2;
    const target = &peers[@intCast(target_peer_idx)];
    if (!target.active) return -2;

    const nr: Role = @enumFromInt(new_role);

    // Forbid demoting the only master.
    if (target.role == .master and nr != .master) {
        var other_sup: bool = false;
        for (&peers, 0..) |*p, i| {
            if (i == @as(usize, @intCast(target_peer_idx))) continue;
            if (p.active and p.role == .master) { other_sup = true; break; }
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

// ═══════════════════════════════════════════════════════════════════════
// Task #33 — variant label (model / variant identifier)
// ═══════════════════════════════════════════════════════════════════════

/// Set a free-form model/variant label for this peer (e.g. "opus-4.7",
/// "flash-2.5", "leanstral"). Alphanumeric + `.`/`-`/`_` only, max
/// MAX_VARIANT bytes; anything else returns -2 and the existing variant
/// is untouched. Empty (len=0) clears the variant.
pub export fn coord_set_variant(
    token_ptr: [*]const u8,
    token_len: c_int,
    variant_ptr: [*]const u8,
    variant_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const vlen: usize = @intCast(variant_len);
    if (vlen > MAX_VARIANT) return -2;

    var k: usize = 0;
    while (k < vlen) : (k += 1) {
        const c = variant_ptr[k];
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or c == '-' or c == '_' or c == '.';
        if (!ok) return -2;
    }

    if (vlen > 0) @memcpy(peers[idx].variant[0..vlen], variant_ptr[0..vlen]);
    peers[idx].variant_len = @intCast(vlen);
    dur.logPeerVariantSet(@intCast(idx), variant_ptr[0..vlen]);
    return 0;
}

/// Read a peer's variant label. Writes up to out_cap bytes into out.
/// Returns variant length on success, 0 if unset, -1 if peer index out of
/// range / inactive. Caller token is not required — variant is broadcast-
/// visible by design (other peers use it for cold-start routing).
pub export fn coord_read_peer_variant(peer_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const vlen: usize = @min(@as(usize, p.variant_len), @as(usize, @intCast(out_cap)));
    if (vlen > 0) @memcpy(out[0..vlen], p.variant[0..vlen]);
    return @intCast(vlen);
}

// ═══════════════════════════════════════════════════════════════════════
// Task #34 — capability advertisement (class / tier / prover_strengths)
// ═══════════════════════════════════════════════════════════════════════

/// Set this peer's advertised capabilities in one shot.
///   class       — CSV of capability classes (e.g. "reasoning,coding").
///                 Max MAX_CLASS bytes. Empty clears.
///   tier        — 0 (unset) or 1..5 (advertised tier). >5 is clamped-reject (-2).
///   provers     — CSV of prover strengths (e.g. "coq,lean"). Max MAX_PROVERS bytes.
///
/// Validation is minimal (length + tier range) so the engine can treat
/// the fields as opaque hints; the reassignment loop does the semantic
/// cross-check against track_record later.
///
/// Returns 0 on success, -1 on bad token, -2 on range/length violation.
pub export fn coord_set_capabilities(
    token_ptr: [*]const u8,
    token_len: c_int,
    class_ptr: [*]const u8,
    class_len: c_int,
    tier: c_int,
    provers_ptr: [*]const u8,
    provers_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const clen: usize = @intCast(class_len);
    const plen: usize = @intCast(provers_len);
    if (clen > MAX_CLASS) return -2;
    if (plen > MAX_PROVERS) return -2;
    if (tier < 0 or tier > 5) return -2;

    // Reject bytes that would break CSV or JSON rendering. Allow the
    // union of [A-Za-z0-9], `.`, `-`, `_`, `+`, `/`, and `,` (the CSV
    // separator itself).
    var k: usize = 0;
    while (k < clen) : (k += 1) {
        const c = class_ptr[k];
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or c == '-' or c == '_' or c == '.' or
            c == '+' or c == '/' or c == ',';
        if (!ok) return -2;
    }
    k = 0;
    while (k < plen) : (k += 1) {
        const c = provers_ptr[k];
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or c == '-' or c == '_' or c == '.' or
            c == '+' or c == '/' or c == ',';
        if (!ok) return -2;
    }

    const p = &peers[idx];
    if (clen > 0) @memcpy(p.class_csv[0..clen], class_ptr[0..clen]);
    p.class_csv_len = @intCast(clen);
    p.tier = @intCast(tier);
    if (plen > 0) @memcpy(p.prover_strengths[0..plen], provers_ptr[0..plen]);
    p.prover_strengths_len = @intCast(plen);

    dur.logPeerCapabilitiesSet(
        @intCast(idx),
        p.tier,
        class_ptr[0..clen],
        provers_ptr[0..plen],
    );
    return 0;
}

/// Read a peer's class CSV. Returns length, 0 if unset, -1 if idx invalid.
pub export fn coord_read_peer_class(peer_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const clen: usize = @min(@as(usize, p.class_csv_len), @as(usize, @intCast(out_cap)));
    if (clen > 0) @memcpy(out[0..clen], p.class_csv[0..clen]);
    return @intCast(clen);
}

/// Read a peer's advertised tier. Returns 0 (unset) or 1..5, or -1 if idx invalid.
pub export fn coord_read_peer_tier(peer_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    return @intCast(p.tier);
}

/// Read a peer's prover-strengths CSV. Returns length, 0 if unset, -1 if idx invalid.
pub export fn coord_read_peer_provers(peer_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const plen: usize = @min(@as(usize, p.prover_strengths_len), @as(usize, @intCast(out_cap)));
    if (plen > 0) @memcpy(out[0..plen], p.prover_strengths[0..plen]);
    return @intCast(plen);
}

// ═══════════════════════════════════════════════════════════════════════
// Health metrics — read-only aggregates over live registries. Exposed so
// the adapter can render `coord_health` without knowing the registry
// layout. All functions take the caller's token and return -1 on auth
// failure so individual peers can poll without a master gate but rogue
// local processes can't.
// ═══════════════════════════════════════════════════════════════════════

fn validateToken(token_ptr: [*]const u8, token_len: c_int) bool {
    return findPeerByToken(token_ptr, @intCast(token_len)) != null;
}

/// Count active quarantine entries. Returns count, -1 on bad token.
pub export fn coord_count_quarantine(token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    var n: c_int = 0;
    for (&quarantine) |*q| {
        if (q.active) n += 1;
    }
    return n;
}

/// Count active claims. Returns count, -1 on bad token.
pub export fn coord_count_claims(token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    var n: c_int = 0;
    for (&claims) |*c| {
        if (c.active) n += 1;
    }
    return n;
}

/// Read the task name of active claim at slot `claim_idx` (0-based over all 64 slots).
/// Writes the task name into `out` (max `out_cap` bytes). Returns bytes written, or
/// -1 if token invalid / slot inactive / out of range.
/// Use alongside coord_count_claims to iterate: call with idx 0..MAX_CLAIMS-1,
/// skip -1 results.
pub export fn coord_read_claim_task(token_ptr: [*]const u8, token_len: c_int, claim_idx: c_int, out: [*]u8, out_cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    if (claim_idx < 0 or claim_idx >= MAX_CLAIMS) return -1;
    const c = &claims[@intCast(claim_idx)];
    if (!c.active) return -1;
    const len: usize = @min(@as(usize, c.task_name_len), @as(usize, @intCast(out_cap)));
    if (len > 0) @memcpy(out[0..len], c.task_name[0..len]);
    return @intCast(len);
}

/// Read the peer suffix (4-byte printable hex) of the holder of active claim `claim_idx`.
/// Writes into `out` (must be >= 4 bytes). Returns 4 on success, -1 otherwise.
pub export fn coord_read_claim_holder_suffix(token_ptr: [*]const u8, token_len: c_int, claim_idx: c_int, out: [*]u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    if (claim_idx < 0 or claim_idx >= MAX_CLAIMS) return -1;
    const c = &claims[@intCast(claim_idx)];
    if (!c.active) return -1;
    const p = &peers[c.holder_idx];
    if (!p.active) return -1;
    @memcpy(out[0..4], &p.suffix);
    return 4;
}

/// Count track-record entries in the ring (saturates at MAX_TRACK).
/// Returns count, -1 on bad token.
pub export fn coord_count_track(token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    return @intCast(track_count);
}

/// Count rejections in the current window for the given client_kind.
/// Returns count, -1 on bad token, -2 on bad kind.
pub export fn coord_count_rejects_recent(
    token_ptr: [*]const u8,
    token_len: c_int,
    kind: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    if (kind < 0 or kind >= KIND_COUNT) return -2;
    const k: usize = @intCast(kind);
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    var n: c_int = 0;
    for (reject_ring[k]) |ts| {
        if (ts == 0) continue;
        if (now_ms > ts and (now_ms - ts) > REJECT_WINDOW_MS) continue;
        n += 1;
    }
    return n;
}

/// Returns 1 if the given client_kind is currently in reject-cooldown,
/// 0 otherwise, -1 on bad token, -2 on bad kind.
pub export fn coord_kind_in_cooldown(
    token_ptr: [*]const u8,
    token_len: c_int,
    kind: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validateToken(token_ptr, token_len)) return -1;
    if (kind < 0 or kind >= KIND_COUNT) return -2;
    const ck: ClientKind = @enumFromInt(kind);
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    return if (isInCooldown(ck, now_ms)) 1 else 0;
}

/// Count rejections in the current window for the given peer slot (Item A).
/// Returns count, -1 on bad token, -2 on bad/inactive peer_idx.
pub export fn coord_count_rejects_recent_peer(
    token_ptr: [*]const u8,
    token_len: usize,
    peer_idx: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (findPeerByToken(token_ptr, token_len) == null) return -1;
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -2;
    const pi: usize = @intCast(peer_idx);
    if (!peers[pi].active) return -2;
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    var n: c_int = 0;
    for (peer_reject_ring[pi]) |ts| {
        if (ts == 0) continue;
        if (now_ms > ts and (now_ms - ts) > REJECT_WINDOW_MS) continue;
        n += 1;
    }
    return n;
}

/// Returns 1 if peer_idx is currently in reject-cooldown, 0 otherwise,
/// -1 on bad token, -2 on bad/inactive peer_idx (Item A).
pub export fn coord_peer_in_cooldown(
    token_ptr: [*]const u8,
    token_len: usize,
    peer_idx: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (findPeerByToken(token_ptr, token_len) == null) return -1;
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -2;
    const pi: usize = @intCast(peer_idx);
    if (!peers[pi].active) return -2;
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    return if (isPeerInCooldown(pi, now_ms)) 1 else 0;
}

/// Read a peer's 4-char hex suffix into out (must be at least 4 bytes).
/// Returns 4 on success, -1 if peer_idx is out of range or inactive.
pub export fn coord_read_peer_suffix(peer_idx: c_int, out: [*]u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    @memcpy(out[0..4], &p.suffix);
    return 4;
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
    peer_reject_ring[idx] = [_]u64{0} ** REJECT_LIMIT;
    peer_reject_head[idx] = 0;
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
// ring. ClientKind enum has 6 variants — one slot each.
// (Task #33: extended from 4 → 6 for openai + mistral.)
const KIND_COUNT: usize = 6;
var reject_ring: [KIND_COUNT][REJECT_LIMIT]u64 = [_][REJECT_LIMIT]u64{[_]u64{0} ** REJECT_LIMIT} ** KIND_COUNT;
var reject_head: [KIND_COUNT]usize = [_]usize{0} ** KIND_COUNT;

// Per-peer rejection ring (Item A — per-peer reject tracking).
// 16 peers × 5 slots × 8 bytes = 640 bytes overhead.
var peer_reject_ring: [MAX_PEERS][REJECT_LIMIT]u64 = [_][REJECT_LIMIT]u64{[_]u64{0} ** REJECT_LIMIT} ** MAX_PEERS;
var peer_reject_head: [MAX_PEERS]usize = [_]usize{0} ** MAX_PEERS;

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

fn isPeerInCooldown(peer_idx: usize, now_ms: u64) bool {
    if (peer_idx >= MAX_PEERS) return false;
    const ring = &peer_reject_ring[peer_idx];
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

fn recordPeerRejection(peer_idx: usize, now_ms: u64) void {
    if (peer_idx >= MAX_PEERS) return;
    const h = peer_reject_head[peer_idx];
    peer_reject_ring[peer_idx][h] = now_ms;
    peer_reject_head[peer_idx] = (h + 1) % REJECT_LIMIT;
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
    if (isPeerInCooldown(idx, now_ms)) return -5;

    // Watchdog sweep piggybacks on claim contention — the natural moment
    // an abandoned claim matters. DD-20: apprentice = 30 s, journeyman =
    // 5 min, master no TTL. Releases happen before contention is checked
    // so a freshly-expired slot becomes available to this caller.
    _ = sweepExpiredClaims(now_ms);

    // Check if already claimed
    for (&claims) |*c| {
        if (c.active and c.task_name_len == @as(u8, @intCast(tlen)) and
            std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen]))
        {
            if (c.holder_idx == @as(u8, @intCast(idx))) {
                c.claimed_at_ms = now_ms; // re-claim resets TTL
                return 0; // Already held by caller — idempotent grant
            }
            recordRejection(kind, now_ms);
            recordPeerRejection(idx, now_ms);
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
            c.claimed_at_ms = now_ms;
            dur.logClaimAdd(@intCast(ci), @intCast(idx), task_ptr[0..tlen]);
            return 0; // Granted
        }
    }
    recordRejection(kind, now_ms);
    recordPeerRejection(idx, now_ms);
    return 2; // No slots available (treated as NotFound)
}

// ═══════════════════════════════════════════════════════════════════════
// Watchdog (DD-20) — auto-release claims whose holder missed the TTL.
// ═══════════════════════════════════════════════════════════════════════

/// Sweep all active claims, auto-releasing any that have exceeded the
/// TTL for their holder's role. Returns the number of claims released.
/// Caller must already hold `mutex`.
///
/// Master claims are never swept (TTL=0). Inactive-holder claims (peer
/// deregistered without releasing) are cleared by coord_deregister, so
/// the sweep just treats their slots as already free.
// Audit event kinds used by the watchdog path (DD-20 / DD-21).
// 1 = tier3-from-supervised, 2 = master-transfer (defined elsewhere).
const AUDIT_AUTO_RELEASE: u8 = 3;
const AUDIT_WARN_DRIFT_QUEUED: u8 = 4;
const AUDIT_WARN_DRIFT_BROADCAST: u8 = 5;

fn roleStr(r: Role) []const u8 {
    return switch (r) {
        .master => "master",
        .journeyman => "journeyman",
        .apprentice => "apprentice",
    };
}

/// DD-21: when the watchdog auto-releases a claim, broadcast a `warn_drift`
/// envelope so the rest of the coordination pool notices the stalled peer.
/// Route through quarantine (sender_idx = server-origin sentinel) if a
/// master is present; otherwise push directly into every active peer's
/// inbox so the warning still lands in master-less local sessions.
fn emitWarnDrift(
    holder_idx: u8,
    role: Role,
    task: []const u8,
    held_ms: u64,
) void {
    const holder = &peers[holder_idx];
    if (!holder.active) return;

    const kind_name = kindStr(@intCast(@intFromEnum(holder.kind)));
    const role_name = roleStr(role);
    const ctx_slice = holder.context[0..holder.context_len];

    var env_buf: [512]u8 = undefined;
    const env = blk: {
        if (ctx_slice.len > 0) {
            break :blk std.fmt.bufPrint(&env_buf,
                "{{\"kind\":\"warn_drift\",\"op_kind\":\"warn\",\"risk_tier\":1," ++
                "\"peer_id\":\"{s}-{s}@{s}\",\"peer_kind\":\"{s}\"," ++
                "\"task\":\"{s}\",\"held_ms\":{d},\"role\":\"{s}\"," ++
                "\"rationale\":\"watchdog auto-release: peer held claim past TTL without heartbeat\"}}",
                .{ kind_name, holder.suffix[0..], ctx_slice, kind_name, task, held_ms, role_name },
            ) catch return;
        } else {
            break :blk std.fmt.bufPrint(&env_buf,
                "{{\"kind\":\"warn_drift\",\"op_kind\":\"warn\",\"risk_tier\":1," ++
                "\"peer_id\":\"{s}-{s}\",\"peer_kind\":\"{s}\"," ++
                "\"task\":\"{s}\",\"held_ms\":{d},\"role\":\"{s}\"," ++
                "\"rationale\":\"watchdog auto-release: peer held claim past TTL without heartbeat\"}}",
                .{ kind_name, holder.suffix[0..], kind_name, task, held_ms, role_name },
            ) catch return;
        }
    };

    if (findMaster() != null) {
        const rid = enqueueServerSuggestion(-1, 1, env);
        if (rid >= 0) dur.logAudit(AUDIT_WARN_DRIFT_QUEUED, env);
        return;
    }

    // Master absent — direct broadcast to every active peer except the holder.
    var pushed: c_int = 0;
    for (&peers, 0..) |*p, i| {
        if (!p.active) continue;
        if (i == holder_idx) continue;
        if (p.inbox_count >= MAX_MESSAGES) continue;
        const head: usize = p.inbox_head;
        @memcpy(p.inbox[head][0..env.len], env);
        p.inbox_lens[head] = @intCast(env.len);
        p.inbox_head = @intCast((@as(u32, p.inbox_head) + 1) % MAX_MESSAGES);
        p.inbox_count += 1;
        dur.logInboxPush(@intCast(i), env);
        pushed += 1;
    }
    if (pushed > 0) dur.logAudit(AUDIT_WARN_DRIFT_BROADCAST, env);
}

fn sweepExpiredClaims(now_ms: u64) c_int {
    var released: c_int = 0;
    for (&claims, 0..) |*c, ci| {
        if (!c.active) continue;
        const holder = &peers[c.holder_idx];
        if (!holder.active) {
            // Shouldn't normally happen (deregister releases), but be safe.
            c.active = false;
            dur.logClaimRel(@intCast(ci));
            released += 1;
            continue;
        }
        const ttl = watchdogTtlMs(holder.role);
        if (ttl == 0) continue; // master or unknown — no watchdog
        if (c.claimed_at_ms == 0) continue; // replayed without timestamp; skip first pass
        if (now_ms <= c.claimed_at_ms) continue; // clock skew guard
        if ((now_ms - c.claimed_at_ms) <= ttl) continue;

        // Auto-release.
        const age_ms = now_ms - c.claimed_at_ms;
        const task_slice = c.task_name[0..c.task_name_len];
        const holder_role = holder.role;
        const holder_idx_copy = c.holder_idx;

        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf,
            "claim={d}|holder={d}|role={d}|age_ms={d}|task={s}",
            .{ ci, c.holder_idx, @intFromEnum(holder_role), age_ms, task_slice },
        ) catch "";
        c.active = false;
        dur.logClaimRel(@intCast(ci));
        dur.logAudit(AUDIT_AUTO_RELEASE, detail);

        // DD-21: warn-drift broadcast so the pool sees the stalled peer.
        // Emitted after the auto-release audit so the release is durable
        // even if the warning path fails to serialize.
        emitWarnDrift(holder_idx_copy, holder_role, task_slice, age_ms);
        released += 1;
    }
    return released;
}

/// Heartbeat: bump the claimed_at_ms of a claim held by the caller so
/// long-running work doesn't get swept. The caller must be the current
/// holder; other peers cannot refresh someone else's claim.
///
/// Returns 0 OK, -1 bad token, -2 no matching claim, -3 not the holder.
pub export fn coord_progress(
    token_ptr: [*]const u8,
    token_len: c_int,
    task_ptr: [*]const u8,
    task_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const tlen: usize = @intCast(@min(task_len, 128));
    const now_ms: u64 = @intCast(std.time.milliTimestamp());

    for (&claims, 0..) |*c, ci| {
        if (!c.active) continue;
        if (c.task_name_len != @as(u8, @intCast(tlen))) continue;
        if (!std.mem.eql(u8, c.task_name[0..tlen], task_ptr[0..tlen])) continue;
        if (c.holder_idx != @as(u8, @intCast(idx))) return -3;
        c.claimed_at_ms = now_ms;
        dur.logClaimProgress(@intCast(ci), now_ms);
        return 0;
    }
    return -2;
}

/// Externally-callable watchdog sweep. Any active peer may invoke it
/// (loopback-only, trusted session); callers can schedule it as a
/// polling tick. Returns released-count, -1 on bad token.
pub export fn coord_sweep_watchdog(
    token_ptr: [*]const u8,
    token_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (findPeerByToken(token_ptr, @intCast(token_len)) == null) return -1;
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    return sweepExpiredClaims(now_ms);
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

/// Send a message that MAY be gated. If sender role is apprentice and
/// risk_tier >= 2, the message is quarantined and a request_id returned.
/// Otherwise it's delivered directly (identical to coord_send).
///
/// Returns:
///   >= 1  — direct send succeeded, value is sent count
///   -1    — bad token
///   -2    — bad target_idx
///   -3    — target inbox full (direct send)
///   -4    — quarantine queue full
///   -5    — no master registered (apprentice peer can't file a Tier 2+
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

    // Free path: master/journeyman, or apprentice with low tier.
    if (sender.role != .apprentice or tier_u < 2) {
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

    // Gated path: apprentice peer + Tier 2+ = quarantine.
    if (findMaster() == null) return -5;

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

/// List pending quarantine entries. Only callable by a master.
/// Writes records into `out` — each record is 16 bytes:
///   request_id: u32 little-endian
///   sender_idx: u8
///   target_idx: i8
///   risk_tier: u8
///   msg_len: u16 little-endian
///   first 7 bytes of msg (preview)
///
/// Returns number of records written, or -1 if caller is not master.
pub export fn coord_review(
    master_token_ptr: [*]const u8,
    master_token_len: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(master_token_ptr, @intCast(master_token_len)) orelse return -1;
    if (peers[idx].role != .master) return -1;

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
/// Returns message length on success, -1 on bad master, -2 on unknown id.
pub export fn coord_review_entry(
    master_token_ptr: [*]const u8,
    master_token_len: c_int,
    request_id: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(master_token_ptr, @intCast(master_token_len)) orelse return -1;
    if (peers[idx].role != .master) return -1;

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
/// bad master, -2 on unknown id, -3 if target inbox full (caller
/// should retry later).
pub export fn coord_approve(
    master_token_ptr: [*]const u8,
    master_token_len: c_int,
    request_id: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(master_token_ptr, @intCast(master_token_len)) orelse return -1;
    if (peers[idx].role != .master) return -1;

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
/// Supervisor-only. Returns 0 on success, -1 on bad master, -2 on
/// unknown id.
pub export fn coord_reject(
    master_token_ptr: [*]const u8,
    master_token_len: c_int,
    request_id: c_int,
    reason_ptr: [*]const u8,
    reason_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(master_token_ptr, @intCast(master_token_len)) orelse return -1;
    if (peers[idx].role != .master) return -1;

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

/// Set this peer's declared affinities — a CSV of tag names the peer
/// self-reports as strengths. Feeds the reassignment engine (Task #14):
/// tags not in this list but with high effective_affinity trigger a
/// promotion suggestion; tags in the list with low effective_affinity
/// trigger an overclaim or removal suggestion.
///
/// Returns 0 on success, -1 on bad token, -2 if csv exceeds MAX_DECLARED.
/// An empty csv (len=0) clears the declared list.
pub export fn coord_set_declared_affinities(
    token_ptr: [*]const u8,
    token_len: c_int,
    csv_ptr: [*]const u8,
    csv_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    const clen: usize = @intCast(csv_len);
    if (clen > MAX_DECLARED) return -2;

    if (clen > 0) @memcpy(peers[idx].declared_affinities[0..clen], csv_ptr[0..clen]);
    peers[idx].declared_affinities_len = @intCast(clen);
    return 0;
}

/// Return this peer's declared affinities CSV in `out`. Writes up to
/// `out_cap` bytes. Returns csv length, 0 if unset, -1 on bad index.
pub export fn coord_read_declared_affinities(
    peer_idx: c_int,
    out: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx < 0 or peer_idx >= MAX_PEERS) return -1;
    const p = &peers[@intCast(peer_idx)];
    if (!p.active) return -1;
    const dlen: usize = @min(@as(usize, p.declared_affinities_len), @as(usize, @intCast(out_cap)));
    if (dlen > 0) @memcpy(out[0..dlen], p.declared_affinities[0..dlen]);
    return @intCast(dlen);
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
/// confidence_pct: self-assessed confidence at claim time (0-100), or -1
///   if unreported. Used by the reassignment engine (Task #14) to detect
///   overclaim (high confidence vs low effective_affinity).
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
    confidence_pct: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx = findPeerByToken(token_ptr, @intCast(token_len)) orelse return -1;
    if (tag_len < 0 or tag_len > @as(c_int, @intCast(MAX_TAG))) return -2;
    if (outcome < 0 or outcome > 1) return -2;
    if (risk_tier < 0 or risk_tier > 4) return -2;
    if (duration_ms < 0) return -2;
    if (confidence_pct < -1 or confidence_pct > 100) return -2;

    const tlen: usize = @intCast(tag_len);
    const tag = tag_ptr[0..tlen];

    const kind_u: u8 = @intCast(@intFromEnum(peers[idx].kind));
    const outcome_u: u8 = @intCast(outcome);
    const tier_u: u8 = @intCast(risk_tier);
    const dur_u: u32 = @intCast(duration_ms);
    const conf_u: u8 = if (confidence_pct < 0) 255 else @intCast(confidence_pct);

    recordTrack(kind_u, outcome_u, tier_u, dur_u, tag, conf_u);
    dur.logTrackUpdate(kind_u, outcome_u, tier_u, dur_u, @intCast(std.time.milliTimestamp()), tag, conf_u);
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
// Reassignment suggestion engine (Task #14)
//
// Scans track-record aggregates + per-peer declared_affinities and
// synthesises candidate envelopes that land in the QUARANTINE as
// server-origin entries (sender_idx = SERVER_ORIGIN_SENTINEL). Opus
// (master) then approves or rejects via coord_approve / coord_reject
// — never auto-modifies.
//
// Suggestion kinds:
//   - "overclaim": avg_confidence > 0.8 AND effective_affinity < 0.3
//                  → routing FYI (op_kind=fyi, tier 1)
//   - "drift":     same condition as overclaim, but framed as a self-
//                  assessment monitoring flag (DD-9 layer D). Emitted
//                  alongside overclaim with op_kind=warn, tier 2, and a
//                  drift_pct field carrying the confidence-vs-affinity gap.
//   - "promote":   effective_affinity >= 0.7 AND tag not in declared set
//   - "remove":    effective_affinity <= 0.2 AND attempts >= 5
//
// Envelope payload is a compact JSON object surfaced to Opus verbatim.
// ═══════════════════════════════════════════════════════════════════════

pub const SERVER_ORIGIN_SENTINEL: u8 = 0xFE;

const OVERCLAIM_CONF_MIN: u32 = 80;
const OVERCLAIM_AFFINITY_MAX: u32 = 30;
const PROMOTE_AFFINITY_MIN: u32 = 70;
const REMOVE_AFFINITY_MAX: u32 = 20;
const REMOVE_MIN_ATTEMPTS: u16 = 5;

/// Enqueue a server-origin candidate envelope into the quarantine.
/// Supervisor reviews via coord_review + coord_review_entry. Targets:
///   target_idx = -1 -> broadcast on approve
///   target_idx >= 0 -> direct delivery on approve
///
/// Returns the assigned request_id, or -1 if the quarantine queue is
/// full (caller should back off).
fn enqueueServerSuggestion(
    target_idx: i8,
    risk_tier: u8,
    msg: []const u8,
) i64 {
    for (&quarantine) |*q| {
        if (!q.active) {
            q.active = true;
            q.request_id = next_request_id;
            next_request_id += 1;
            q.sender_idx = SERVER_ORIGIN_SENTINEL;
            q.target_idx = target_idx;
            q.risk_tier = risk_tier;
            const mlen: usize = @min(msg.len, 512);
            if (mlen > 0) @memcpy(q.msg[0..mlen], msg[0..mlen]);
            q.msg_len = @intCast(mlen);
            q.reason_len = 0;
            dur.logQuarAdd(q.request_id, q.sender_idx, q.target_idx, q.risk_tier, msg[0..mlen]);
            return @intCast(q.request_id);
        }
    }
    return -1;
}

/// Internal kind→string for engine-side rendering. Mirrors the adapter's
/// kindName but lives in FFI so server-origin envelopes can name peers
/// correctly. Updated when ClientKind grows (Task #33 added openai/mistral).
fn kindStr(k: u8) []const u8 {
    return switch (k) {
        0 => "claude",
        1 => "gemini",
        2 => "copilot",
        4 => "openai",
        5 => "mistral",
        else => "custom",
    };
}

fn affinityPct(attempts: u16, successes: u16) u32 {
    if (attempts == 0) return 0;
    return (@as(u32, successes) * 100) / @as(u32, attempts);
}

/// Average confidence (pct) for entries matching (kind, tag) within the
/// active window. Returns 256 when there is no confidence-tagged data.
fn windowedAvgConfidence(tgt_kind: u8, tgt_tag: []const u8) u32 {
    if (track_count == 0) return 256;

    const now: u64 = @intCast(std.time.milliTimestamp());
    const cutoff: u64 = if (now > WINDOW_MS) now - WINDOW_MS else 0;

    var seen: u16 = 0;
    var sum_conf: u32 = 0;
    var conf_n: u32 = 0;

    var k: usize = 0;
    while (k < track_count) : (k += 1) {
        const raw_i: isize = @as(isize, @intCast(track_head)) - 1 - @as(isize, @intCast(k));
        const src_i: usize = @intCast(@mod(raw_i, @as(isize, @intCast(MAX_TRACK))));
        const t = &track[src_i];
        if (!t.active) continue;
        if (t.client_kind != tgt_kind) continue;
        if (!tagEql(t.tag[0..t.tag_len], tgt_tag)) continue;

        seen += 1;
        const within_time = t.timestamp_ms >= cutoff;
        const within_count = seen <= @as(u16, @intCast(WINDOW_ATTEMPTS));

        if (within_time or within_count) {
            if (t.confidence_pct != 255) {
                sum_conf += t.confidence_pct;
                conf_n += 1;
            }
        } else break;
    }
    if (conf_n == 0) return 256;
    return sum_conf / conf_n;
}

/// Is `tag` present in any peer of the given client_kind's declared CSV?
fn tagInDeclaredFor(kind: u8, tag: []const u8) bool {
    for (&peers) |*p| {
        if (!p.active) continue;
        if (@intFromEnum(p.kind) != kind) continue;
        const csv = p.declared_affinities[0..p.declared_affinities_len];
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " ");
            if (trimmed.len == 0) continue;
            if (tagEql(trimmed, tag)) return true;
        }
    }
    return false;
}

/// Scan track-record aggregates and enqueue candidate envelopes into the
/// quarantine. Returns the number of suggestions emitted, or -1 on bad
/// token. Caller should be a master — only the master can act
/// on these through coord_approve/coord_reject anyway, but any peer can
/// trigger the scan since it mutates only server-owned queue state.
pub export fn coord_scan_suggestions(
    token_ptr: [*]const u8,
    token_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (findPeerByToken(token_ptr, @intCast(token_len)) == null) return -1;

    var aggs: [MAX_TRACK]Aggregate = undefined;
    const n = buildAggregates(aggs[0..]);

    var emitted: c_int = 0;
    var msg_buf: [512]u8 = undefined;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const agg = &aggs[i];
        if (agg.attempts == 0) continue;
        const pct = affinityPct(agg.attempts, agg.successes);
        const tag_slice: []const u8 = agg.tag[0..agg.tag_len];
        const kind_str = kindStr(agg.client_kind);

        // Overclaim: high self-confidence + low real affinity.
        // (Routing suggestion — op_kind=fyi, tier 1.)
        const avg_conf = windowedAvgConfidence(agg.client_kind, tag_slice);
        if (avg_conf != 256 and avg_conf >= OVERCLAIM_CONF_MIN and pct < OVERCLAIM_AFFINITY_MAX) {
            const msg = std.fmt.bufPrint(&msg_buf,
                "{{\"kind\":\"overclaim\",\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity_pct\":{d},\"avg_confidence_pct\":{d},\"op_kind\":\"fyi\",\"rationale\":\"high self-confidence with low track-record success — reassignment suggested\"}}",
                .{ kind_str, tag_slice, agg.attempts, agg.successes, pct, avg_conf },
            ) catch continue;
            if (enqueueServerSuggestion(-1, 1, msg) >= 0) emitted += 1;

            // Drift detector (DD-9 layer D / TODO P1): same condition, but
            // framed as a self-assessment monitoring flag for the master
            // to act on at the peer-trust level (op_kind=warn, tier 2).
            // Carries `drift_pct = avg_conf - effective_affinity` so the
            // master sees the magnitude of the gap at a glance.
            const drift_pct: u32 = avg_conf - pct;
            const drift_msg = std.fmt.bufPrint(&msg_buf,
                "{{\"kind\":\"drift\",\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity_pct\":{d},\"avg_confidence_pct\":{d},\"drift_pct\":{d},\"op_kind\":\"warn\",\"rationale\":\"self-assessment drift — confidence consistently outpaces track-record success\"}}",
                .{ kind_str, tag_slice, agg.attempts, agg.successes, pct, avg_conf, drift_pct },
            ) catch continue;
            if (enqueueServerSuggestion(-1, 2, drift_msg) >= 0) emitted += 1;
        }

        // Promote: high effective affinity, but tag not in any same-kind peer's declared list.
        if (pct >= PROMOTE_AFFINITY_MIN and !tagInDeclaredFor(agg.client_kind, tag_slice)) {
            const msg = std.fmt.bufPrint(&msg_buf,
                "{{\"kind\":\"promote\",\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity_pct\":{d},\"op_kind\":\"fyi\",\"rationale\":\"strong track record on an undeclared tag — consider adding to declared_affinities\"}}",
                .{ kind_str, tag_slice, agg.attempts, agg.successes, pct },
            ) catch continue;
            if (enqueueServerSuggestion(-1, 1, msg) >= 0) emitted += 1;
        }

        // Remove: low effective affinity with enough sample.
        if (agg.attempts >= REMOVE_MIN_ATTEMPTS and pct <= REMOVE_AFFINITY_MAX) {
            const msg = std.fmt.bufPrint(&msg_buf,
                "{{\"kind\":\"remove\",\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity_pct\":{d},\"op_kind\":\"clarify\",\"rationale\":\"consistently low success for this tag — consider removing from declared_affinities\"}}",
                .{ kind_str, tag_slice, agg.attempts, agg.successes, pct },
            ) catch continue;
            if (enqueueServerSuggestion(-1, 1, msg) >= 0) emitted += 1;
        }
    }
    return emitted;
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
            p.declared_affinities_len = 0;
            p.variant_len = 0;
            p.class_csv_len = 0;
            p.tier = TIER_UNSET;
            p.prover_strengths_len = 0;
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
            // Fresh TTL after replay: old logs predate claim_progress
            // events, so we restart the watchdog from now. A claim_progress
            // record later in the same log will override this.
            c.claimed_at_ms = @intCast(std.time.milliTimestamp());
        },
        .claim_rel => {
            const idx = dur.decodeSlotIdx(payload) orelse return;
            if (idx >= MAX_CLAIMS) return;
            claims[idx].active = false;
        },
        .claim_progress => {
            const d = dur.decodeClaimProgress(payload) orelse return;
            if (d.claim_idx >= MAX_CLAIMS) return;
            const c = &claims[d.claim_idx];
            if (!c.active) return;
            c.claimed_at_ms = d.timestamp_ms;
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
            recordTrackReplay(d.client_kind, d.outcome, d.risk_tier, d.duration_ms, d.timestamp_ms, d.tag, d.confidence_pct);
        },
        .peer_variant_set => {
            const d = dur.decodePeerVariantSet(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            const p = &peers[d.slot_idx];
            if (d.variant.len > MAX_VARIANT) return;
            if (d.variant.len > 0) @memcpy(p.variant[0..d.variant.len], d.variant);
            p.variant_len = @intCast(d.variant.len);
        },
        .peer_capabilities_set => {
            const d = dur.decodePeerCapabilitiesSet(payload) orelse return;
            if (d.slot_idx >= MAX_PEERS) return;
            const p = &peers[d.slot_idx];
            if (d.class.len > MAX_CLASS or d.provers.len > MAX_PROVERS) return;
            if (d.class.len > 0) @memcpy(p.class_csv[0..d.class.len], d.class);
            p.class_csv_len = @intCast(d.class.len);
            p.tier = d.tier;
            if (d.provers.len > 0) @memcpy(p.prover_strengths[0..d.provers.len], d.provers);
            p.prover_strengths_len = @intCast(d.provers.len);
        },
        else => {},
    }
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    return "local-coord-mcp";
}

pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.9.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

// ── JSON dispatch helpers ─────────────────────────────────────────────
//
// These mirror local_coord_adapter.zig but call the exported coord_*
// functions directly (same compilation unit — no ffi.* prefix needed).

fn ci_kindFromString(s: []const u8) i32 {
    if (std.mem.eql(u8, s, "claude")) return 0;
    if (std.mem.eql(u8, s, "gemini")) return 1;
    if (std.mem.eql(u8, s, "copilot")) return 2;
    if (std.mem.eql(u8, s, "openai")) return 4;
    if (std.mem.eql(u8, s, "mistral")) return 5;
    return 3; // custom
}

fn ci_kindName(kind: i32) []const u8 {
    return switch (kind) {
        0 => "claude",
        1 => "gemini",
        2 => "copilot",
        4 => "openai",
        5 => "mistral",
        else => "custom",
    };
}

fn ci_stateName(state: i32) []const u8 {
    return switch (state) {
        0 => "registering",
        1 => "active",
        2 => "departing",
        else => "gone",
    };
}

fn ci_parseToken(token_hex: []const u8, out: *[16]u8) bool {
    if (token_hex.len != 32) return false;
    _ = std.fmt.hexToBytes(out, token_hex) catch return false;
    return true;
}

fn ci_extractSuffix(target: []const u8) ?[]const u8 {
    const at_pos = std.mem.indexOfScalar(u8, target, '@') orelse target.len;
    const left = target[0..at_pos];
    const dash_pos = std.mem.lastIndexOfScalar(u8, left, '-') orelse return null;
    const suffix = left[dash_pos + 1 ..];
    if (suffix.len != 4) return null;
    return suffix;
}

fn ci_arrayToCsv(items: []const std.json.Value, buf: []u8) usize {
    var len: usize = 0;
    for (items) |item| {
        if (item != .string) continue;
        const s = item.string;
        if (len > 0 and len < buf.len) {
            buf[len] = ',';
            len += 1;
        }
        const to_copy: usize = @min(s.len, buf.len - len);
        if (to_copy > 0) @memcpy(buf[len .. len + to_copy], s[0..to_copy]);
        len += to_copy;
    }
    return len;
}

fn ci_renderPeerId(buf: []u8, kind_str: []const u8, suffix: []const u8, ctx: []const u8) ![]u8 {
    if (ctx.len == 0) return try std.fmt.bufPrint(buf, "{s}-{s}", .{ kind_str, suffix });
    return try std.fmt.bufPrint(buf, "{s}-{s}@{s}", .{ kind_str, suffix, ctx });
}

fn ci_writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try std.fmt.format(w, "\\u00{x:0>2}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn ci_writeCsvAsJsonStrings(w: anytype, csv: []const u8) !void {
    if (csv.len == 0) return;
    var it = std.mem.splitScalar(u8, csv, ',');
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try ci_writeJsonString(w, part);
    }
}

const InvokeResult = struct { written: usize, rc: i32 };

fn ci_fail(out: []u8, msg: []const u8, rc: i32) InvokeResult {
    const b = std.fmt.bufPrint(out, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch out[0..0];
    return .{ .written = b.len, .rc = rc };
}

fn ci_ok(out: []u8, msg: []const u8) InvokeResult {
    const b = std.fmt.bufPrint(out, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch out[0..0];
    return .{ .written = b.len, .rc = shim.RC_SUCCESS };
}

/// Main tool dispatch — mirrors the adapter's dispatch() with direct FFI calls.
/// Writes a complete JSON body into `out` and returns (bytes_written, rc_code).
/// Error responses are always written to `out` even when rc < 0, so callers
/// can surface the message while still acting on the return code.
fn ci_dispatch(tool: []const u8, json_args: []const u8, out: []u8, alloc: std.mem.Allocator) InvokeResult {
    if (std.mem.eql(u8, tool, "coord_register")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();

        const kind_val = parsed.value.object.get("client_kind") orelse
            return ci_fail(out, "missing client_kind", shim.RC_BAD_ARGS);
        const kind_str = kind_val.string;
        const kind: i32 = ci_kindFromString(kind_str);

        const ctx_str: []const u8 = blk: {
            const v = parsed.value.object.get("context") orelse break :blk "";
            break :blk v.string;
        };
        const role_hint: i32 = blk: {
            const rv = parsed.value.object.get("role") orelse break :blk -1;
            const rs = rv.string;
            if (std.mem.eql(u8, rs, "master") or std.mem.eql(u8, rs, "supervisor")) break :blk 0;
            if (std.mem.eql(u8, rs, "journeyman") or std.mem.eql(u8, rs, "executor")) break :blk 1;
            if (std.mem.eql(u8, rs, "apprentice") or std.mem.eql(u8, rs, "supervised")) break :blk 2;
            break :blk -1;
        };

        var token: [16]u8 = undefined;
        var suffix: [4]u8 = undefined;
        const idx = coord_register(kind, role_hint, &token, &suffix);
        if (idx == -3) return ci_fail(out, "master role must be obtained via coord_promote_to_master", shim.RC_BAD_ARGS);
        if (idx < 0) return ci_fail(out, "registry full", shim.RC_RUNTIME_ERROR);

        if (ctx_str.len > 0) {
            if (coord_set_context(&token, 16, ctx_str.ptr, @intCast(ctx_str.len)) < 0) {
                _ = coord_deregister(&token, 16);
                return ci_fail(out, "invalid context (alphanumeric/hyphen/underscore only, max 32 bytes)", shim.RC_BAD_ARGS);
            }
        }
        if (parsed.value.object.get("declared_affinities")) |dv| {
            if (dv == .array) {
                var csv_buf: [256]u8 = undefined;
                const csv_len = ci_arrayToCsv(dv.array.items, &csv_buf);
                if (csv_len > 0) _ = coord_set_declared_affinities(&token, 16, &csv_buf, @intCast(csv_len));
            }
        }
        if (parsed.value.object.get("variant")) |vv| {
            if (vv == .string and vv.string.len > 0) {
                if (coord_set_variant(&token, 16, vv.string.ptr, @intCast(vv.string.len)) < 0) {
                    _ = coord_deregister(&token, 16);
                    return ci_fail(out, "invalid variant (alphanum / . / - / _ only, max 32 bytes)", shim.RC_BAD_ARGS);
                }
            }
        }
        if (parsed.value.object.get("capabilities")) |caps| {
            if (caps == .object) {
                var class_buf: [128]u8 = undefined;
                var class_len: usize = 0;
                if (caps.object.get("class")) |cv| {
                    if (cv == .array) class_len = ci_arrayToCsv(cv.array.items, &class_buf);
                }
                var tier: i32 = 0;
                if (caps.object.get("tier")) |tv| {
                    if (tv == .integer) tier = @intCast(tv.integer);
                }
                var pro_buf: [256]u8 = undefined;
                var pro_len: usize = 0;
                if (caps.object.get("prover_strengths")) |pv| {
                    if (pv == .array) pro_len = ci_arrayToCsv(pv.array.items, &pro_buf);
                }
                if (class_len != 0 or tier != 0 or pro_len != 0) {
                    if (coord_set_capabilities(&token, 16, &class_buf, @intCast(class_len), tier, &pro_buf, @intCast(pro_len)) < 0) {
                        _ = coord_deregister(&token, 16);
                        return ci_fail(out, "invalid capabilities (tier 0..5, class ≤128B, prover_strengths ≤256B)", shim.RC_BAD_ARGS);
                    }
                }
            }
        }

        const hex_chars = "0123456789abcdef";
        var token_hex: [32]u8 = undefined;
        for (token, 0..) |b, i| {
            token_hex[i * 2] = hex_chars[b >> 4];
            token_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        var pid_buf: [96]u8 = undefined;
        const peer_id = ci_renderPeerId(&pid_buf, kind_str, &suffix, ctx_str) catch
            return ci_fail(out, "peer_id render overflow", shim.RC_RUNTIME_ERROR);
        const body = std.fmt.bufPrint(out, "{{\"success\":true,\"peer_id\":\"{s}\",\"token\":\"{s}\"}}", .{ peer_id, token_hex }) catch
            return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = body.len, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_deregister")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const rc = coord_deregister(&token, 16);
        if (rc == 0) return ci_ok(out, "deregistered");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        return ci_fail(out, "deregister failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_list_peers")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);

        var raw: [192]u8 = undefined;
        const count = coord_list_peers(&token, 16, &raw, @intCast(raw.len));
        if (count < 0) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);

        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"peers\":[") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        var pi: i32 = 0;
        var written_idx: usize = 0;
        const cnt: usize = @intCast(count);
        while (pi < 16 and written_idx < cnt) : (pi += 1) {
            const kv = coord_read_peer_kind(pi);
            if (kv < 0) continue;
            const rec = raw[written_idx * 12 ..];
            const suf = rec[4..8];
            const st: i32 = @bitCast([4]u8{ rec[8], rec[9], rec[10], rec[11] });
            var status_buf: [256]u8 = undefined;
            const sl = coord_read_peer_status(pi, &status_buf, @intCast(status_buf.len));
            const ss: []const u8 = if (sl > 0) status_buf[0..@intCast(sl)] else "";
            var ctx_buf: [32]u8 = undefined;
            const cl = coord_read_peer_context(pi, &ctx_buf, @intCast(ctx_buf.len));
            const cs: []const u8 = if (cl > 0) ctx_buf[0..@intCast(cl)] else "";
            var var_buf: [32]u8 = undefined;
            const vl = coord_read_peer_variant(pi, &var_buf, @intCast(var_buf.len));
            const vs: []const u8 = if (vl > 0) var_buf[0..@intCast(vl)] else "";
            var pid_buf: [96]u8 = undefined;
            const peer_id = ci_renderPeerId(&pid_buf, ci_kindName(kv), suf, cs) catch return ci_fail(out, "peer_id render overflow", shim.RC_RUNTIME_ERROR);
            if (written_idx > 0) w.writeByte(',') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            std.fmt.format(w, "{{\"peer_id\":\"{s}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"context\":\"{s}\",\"variant\":\"{s}\",\"status\":", .{
                peer_id, ci_kindName(kv), ci_stateName(st), cs, vs,
            }) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            ci_writeJsonString(w, ss) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            w.writeByte('}') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            written_idx += 1;
        }
        w.writeAll("]}") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_send")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const tgt = parsed.value.object.get("target") orelse return ci_fail(out, "missing target", shim.RC_BAD_ARGS);
        const mv = parsed.value.object.get("message") orelse return ci_fail(out, "missing message", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const target_str = tgt.string;
        var target_idx: i32 = -1;
        if (!std.mem.eql(u8, target_str, "*")) {
            const suf = ci_extractSuffix(target_str) orelse return ci_fail(out, "invalid target format — expected <kind>-<4hex>[@<context>]", shim.RC_BAD_ARGS);
            target_idx = coord_find_peer_by_suffix(suf.ptr);
            if (target_idx < 0) return ci_fail(out, "target peer not found", shim.RC_BAD_ARGS);
        }
        const msg = mv.string;
        const sent = coord_send(&token, 16, target_idx, msg.ptr, @intCast(msg.len));
        if (sent < 0) return ci_fail(out, "unauthenticated or invalid target", shim.RC_AUTH_DENIED);
        const b = std.fmt.bufPrint(out, "{{\"success\":true,\"sent\":{d}}}", .{sent}) catch
            return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = b.len, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_receive")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var msg_buf: [512]u8 = undefined;
        const mlen = coord_receive(&token, 16, &msg_buf, @intCast(msg_buf.len));
        if (mlen < 0) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (mlen == 0) {
            const b = std.fmt.bufPrint(out, "{{\"success\":true,\"message\":null}}", .{}) catch out[0..0];
            return .{ .written = b.len, .rc = shim.RC_SUCCESS };
        }
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"message\":") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        ci_writeJsonString(w, msg_buf[0..@intCast(mlen)]) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        w.writeByte('}') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_status")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const sv = parsed.value.object.get("status") orelse return ci_fail(out, "missing status", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const rc = coord_set_status(&token, 16, sv.string.ptr, @intCast(sv.string.len));
        if (rc < 0) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        return ci_ok(out, "ok");
    }

    if (std.mem.eql(u8, tool, "coord_claim_task")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const task = parsed.value.object.get("task") orelse return ci_fail(out, "missing task", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const confidence: i32 = blk: {
            const v = parsed.value.object.get("confidence") orelse break :blk -1;
            break :blk switch (v) {
                .float => |f| @intFromFloat(@min(@max(f * 100.0, 0.0), 100.0)),
                .integer => |i| @intCast(i),
                else => -1,
            };
        };
        const dispatch_pref: i32 = blk: {
            const v = parsed.value.object.get("dispatch_preference") orelse break :blk -1;
            const s = v.string;
            if (std.mem.eql(u8, s, "deliberate")) break :blk 0;
            if (std.mem.eql(u8, s, "broadcast")) break :blk 1;
            if (std.mem.eql(u8, s, "auto")) break :blk 2;
            break :blk -1;
        };
        const difficulty: i32 = blk: {
            const v = parsed.value.object.get("task_difficulty") orelse break :blk -1;
            const s = v.string;
            if (std.mem.eql(u8, s, "trivial")) break :blk 0;
            if (std.mem.eql(u8, s, "routine")) break :blk 1;
            if (std.mem.eql(u8, s, "challenging")) break :blk 2;
            if (std.mem.eql(u8, s, "novel")) break :blk 3;
            break :blk -1;
        };
        const result = coord_claim_task_ex(&token, 16, task.string.ptr, @intCast(task.string.len), confidence, dispatch_pref, difficulty);
        if (result == 0) return ci_ok(out, "granted");
        if (result == 1) return ci_fail(out, "held", shim.RC_RUNTIME_ERROR);
        if (result == -5) return ci_fail(out, "cooldown: too many recent claim rejections for this client_kind — wait 30s", shim.RC_RUNTIME_ERROR);
        return ci_fail(out, "claim failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_promote_to_master") or
        std.mem.eql(u8, tool, "coord_promote_to_supervisor"))
    {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const sv = parsed.value.object.get("secret") orelse return ci_fail(out, "missing secret", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const secret = sv.string;
        const rc = coord_promote_to_master(&token, 16, secret.ptr, @intCast(secret.len));
        if (rc == 0) return ci_ok(out, "promoted");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "master already exists", shim.RC_RUNTIME_ERROR);
        if (rc == -3) return ci_fail(out, "master role not configured on this server", shim.RC_AUTH_DENIED);
        if (rc == -4) return ci_fail(out, "secret does not match", shim.RC_AUTH_DENIED);
        return ci_fail(out, "promotion failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_transfer_master")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const nv = parsed.value.object.get("new_peer_id") orelse return ci_fail(out, "missing new_peer_id", shim.RC_BAD_ARGS);
        const sv = parsed.value.object.get("secret") orelse return ci_fail(out, "missing secret", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const suf = ci_extractSuffix(nv.string) orelse return ci_fail(out, "invalid new_peer_id format — expected <kind>-<4hex>[@<context>]", shim.RC_BAD_ARGS);
        const target_idx = coord_find_peer_by_suffix(suf.ptr);
        if (target_idx < 0) return ci_fail(out, "target peer not found", shim.RC_BAD_ARGS);
        const secret = sv.string;
        const rc = coord_transfer_master(&token, 16, target_idx, secret.ptr, @intCast(secret.len));
        if (rc == 0) return ci_ok(out, "transferred");
        if (rc == -1) return ci_fail(out, "caller is not the current master", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "target peer not found or same as caller", shim.RC_BAD_ARGS);
        if (rc == -3) return ci_fail(out, "secret does not match BOJ_MASTER_TOKEN", shim.RC_AUTH_DENIED);
        if (rc == -4) return ci_fail(out, "target is an apprentice — must be journeyman or master", shim.RC_BAD_ARGS);
        return ci_fail(out, "transfer failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_send_gated")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const tgt = parsed.value.object.get("target") orelse return ci_fail(out, "missing target", shim.RC_BAD_ARGS);
        const mv = parsed.value.object.get("message") orelse return ci_fail(out, "missing message", shim.RC_BAD_ARGS);
        const tier_v = parsed.value.object.get("risk_tier") orelse return ci_fail(out, "missing risk_tier", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const target_str = tgt.string;
        var target_idx: i32 = -1;
        if (!std.mem.eql(u8, target_str, "*")) {
            const suf = ci_extractSuffix(target_str) orelse return ci_fail(out, "invalid target format", shim.RC_BAD_ARGS);
            target_idx = coord_find_peer_by_suffix(suf.ptr);
            if (target_idx < 0) return ci_fail(out, "target peer not found", shim.RC_BAD_ARGS);
        }
        const msg = mv.string;
        const tier: i32 = @intCast(tier_v.integer);
        const rc = coord_send_gated(&token, 16, target_idx, msg.ptr, @intCast(msg.len), tier);
        if (rc >= 0) {
            const b = std.fmt.bufPrint(out, "{{\"success\":true,\"status\":\"delivered\",\"sent\":{d}}}", .{rc}) catch
                return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            return .{ .written = b.len, .rc = shim.RC_SUCCESS };
        }
        if (rc < -1000) {
            const request_id: i64 = -(@as(i64, rc) + 1000);
            const b = std.fmt.bufPrint(out, "{{\"success\":true,\"status\":\"quarantined\",\"request_id\":{d}}}", .{request_id}) catch
                return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            return .{ .written = b.len, .rc = shim.RC_SUCCESS };
        }
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "target peer not found", shim.RC_BAD_ARGS);
        if (rc == -3) return ci_fail(out, "target inbox full", shim.RC_RUNTIME_ERROR);
        if (rc == -4) return ci_fail(out, "quarantine queue full — spill to VeriSimDB not yet wired", shim.RC_RUNTIME_ERROR);
        if (rc == -5) return ci_fail(out, "no master registered — Tier 2+ from apprentice requires a master", shim.RC_RUNTIME_ERROR);
        return ci_fail(out, "gated send failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_review")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var raw: [512]u8 = undefined;
        const count = coord_review(&token, 16, &raw, @intCast(raw.len));
        if (count < 0) return ci_fail(out, "master role required", shim.RC_AUTH_DENIED);
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"entries\":[") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        var i: usize = 0;
        const cnt: usize = @intCast(count);
        while (i < cnt) : (i += 1) {
            const rec = raw[i * 16 ..][0..16];
            const rid: u32 = @bitCast([4]u8{ rec[0], rec[1], rec[2], rec[3] });
            const sender_idx: u8 = rec[4];
            const target_idx_sign: i8 = @bitCast(rec[5]);
            const risk_tier: u8 = rec[6];
            const mlen: u16 = @bitCast([2]u8{ rec[7], rec[8] });
            const preview_n: usize = @min(@as(usize, 7), @as(usize, mlen));
            const preview = rec[9 .. 9 + preview_n];
            if (i > 0) w.writeByte(',') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            const origin: []const u8 = if (sender_idx == 0xFE) "server-engine" else "peer";
            std.fmt.format(w, "{{\"request_id\":{d},\"origin\":\"{s}\",\"sender_idx\":{d},\"target_idx\":{d},\"risk_tier\":{d},\"msg_len\":{d},\"preview\":", .{
                rid, origin, sender_idx, target_idx_sign, risk_tier, mlen,
            }) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            ci_writeJsonString(w, preview) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            w.writeByte('}') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        }
        w.writeAll("]}") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_review_entry")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const rv = parsed.value.object.get("request_id") orelse return ci_fail(out, "missing request_id", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var msg_buf: [512]u8 = undefined;
        const rc = coord_review_entry(&token, 16, @intCast(rv.integer), &msg_buf, @intCast(msg_buf.len));
        if (rc == -1) return ci_fail(out, "master role required", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "request_id not found", shim.RC_BAD_ARGS);
        if (rc < 0) return ci_fail(out, "review failed", shim.RC_RUNTIME_ERROR);
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"message\":") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        ci_writeJsonString(w, msg_buf[0..@intCast(rc)]) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        w.writeByte('}') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_approve")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const rv = parsed.value.object.get("request_id") orelse return ci_fail(out, "missing request_id", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const rc = coord_approve(&token, 16, @intCast(rv.integer));
        if (rc == 0) return ci_ok(out, "approved");
        if (rc == -1) return ci_fail(out, "master role required", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "request_id not found", shim.RC_BAD_ARGS);
        if (rc == -3) return ci_fail(out, "target inbox full — retry", shim.RC_RUNTIME_ERROR);
        return ci_fail(out, "approve failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_reject")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const rv = parsed.value.object.get("request_id") orelse return ci_fail(out, "missing request_id", shim.RC_BAD_ARGS);
        const rea = parsed.value.object.get("reason") orelse return ci_fail(out, "missing reason", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const reason = rea.string;
        const rc = coord_reject(&token, 16, @intCast(rv.integer), reason.ptr, @intCast(reason.len));
        if (rc == 0) return ci_ok(out, "rejected");
        if (rc == -1) return ci_fail(out, "master role required", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "request_id not found", shim.RC_BAD_ARGS);
        return ci_fail(out, "reject failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_report_outcome")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const tag_v = parsed.value.object.get("tag") orelse return ci_fail(out, "missing tag", shim.RC_BAD_ARGS);
        const out_v = parsed.value.object.get("outcome") orelse return ci_fail(out, "missing outcome", shim.RC_BAD_ARGS);
        const tier_v = parsed.value.object.get("risk_tier") orelse return ci_fail(out, "missing risk_tier", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const tag_str = tag_v.string;
        if (tag_str.len > 64) return ci_fail(out, "tag exceeds 64 bytes", shim.RC_BAD_ARGS);
        const duration_ms: i64 = blk: {
            const v = parsed.value.object.get("duration_ms") orelse break :blk 0;
            break :blk v.integer;
        };
        const confidence: i32 = blk: {
            const v = parsed.value.object.get("confidence") orelse break :blk -1;
            break :blk switch (v) {
                .float => |f| @intFromFloat(@min(@max(f * 100.0, 0.0), 100.0)),
                .integer => |i| @intCast(i),
                else => -1,
            };
        };
        var outcome: i32 = -1;
        switch (out_v) {
            .string => |s| {
                if (std.mem.eql(u8, s, "success")) outcome = 1;
                if (std.mem.eql(u8, s, "fail")) outcome = 0;
            },
            .integer => |i| outcome = @intCast(i),
            else => {},
        }
        if (outcome != 0 and outcome != 1) return ci_fail(out, "outcome must be 'success'/'fail' or 0/1", shim.RC_BAD_ARGS);
        const tier: i32 = @intCast(tier_v.integer);
        const rc = coord_report_outcome(&token, 16, tag_str.ptr, @intCast(tag_str.len), outcome, @intCast(duration_ms), tier, confidence);
        if (rc == 0) return ci_ok(out, "recorded");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "invalid args", shim.RC_BAD_ARGS);
        return ci_fail(out, "report failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_set_declared_affinities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const tags_v = parsed.value.object.get("tags") orelse return ci_fail(out, "missing tags", shim.RC_BAD_ARGS);
        if (tags_v != .array) return ci_fail(out, "tags must be an array of strings", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var csv_buf: [256]u8 = undefined;
        const csv_len = ci_arrayToCsv(tags_v.array.items, &csv_buf);
        const rc = coord_set_declared_affinities(&token, 16, &csv_buf, @intCast(csv_len));
        if (rc == 0) return ci_ok(out, "declared");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "declared affinities CSV too long", shim.RC_BAD_ARGS);
        return ci_fail(out, "set failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_scan_suggestions")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const n = coord_scan_suggestions(&token, 16);
        if (n == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        const b = std.fmt.bufPrint(out, "{{\"success\":true,\"suggestions_queued\":{d},\"hint\":\"use coord_review to inspect, coord_approve/coord_reject to act\"}}", .{n}) catch
            return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = b.len, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_get_affinities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var raw: [4096]u8 = undefined;
        const n = coord_get_affinities(&token, 16, &raw, @intCast(raw.len));
        if (n == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (n < 0) return ci_fail(out, "affinity query failed", shim.RC_RUNTIME_ERROR);
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"affinities\":[") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        const REC_SIZE: usize = 64;
        const cnt: usize = @intCast(n);
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const rec = raw[i * REC_SIZE ..][0..REC_SIZE];
            const kind: u8 = rec[0];
            const attempts: u16 = @bitCast([2]u8{ rec[1], rec[2] });
            const successes: u16 = @bitCast([2]u8{ rec[3], rec[4] });
            const pct: u8 = rec[5];
            const tag_len: u8 = rec[6];
            const tag = rec[7 .. 7 + @min(@as(usize, tag_len), 57)];
            if (i > 0) w.writeByte(',') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            std.fmt.format(w, "{{\"client_kind\":\"{s}\",\"tag\":", .{ci_kindName(@intCast(kind))}) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            ci_writeJsonString(w, tag) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            if (pct == 255) {
                std.fmt.format(w, ",\"attempts\":{d},\"successes\":{d},\"effective_affinity\":null}}", .{ attempts, successes }) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            } else {
                std.fmt.format(w, ",\"attempts\":{d},\"successes\":{d},\"effective_affinity\":{d}.{d:0>2}}}", .{ attempts, successes, pct / 100, pct % 100 }) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            }
        }
        w.writeAll("]}") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_set_variant")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const vv = parsed.value.object.get("variant") orelse return ci_fail(out, "missing variant", shim.RC_BAD_ARGS);
        if (vv != .string) return ci_fail(out, "variant must be a string", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const vs = vv.string;
        const rc = coord_set_variant(&token, 16, vs.ptr, @intCast(vs.len));
        if (rc == 0) return ci_ok(out, "set");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "invalid variant (alphanum / . / - / _ only, max 32 bytes)", shim.RC_BAD_ARGS);
        return ci_fail(out, "set_variant failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_set_capabilities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var class_buf: [128]u8 = undefined;
        var class_len: usize = 0;
        if (parsed.value.object.get("class")) |cv| {
            if (cv == .array) class_len = ci_arrayToCsv(cv.array.items, &class_buf);
        }
        var tier: i32 = 0;
        if (parsed.value.object.get("tier")) |tier_v| {
            if (tier_v == .integer) tier = @intCast(tier_v.integer);
        }
        var pro_buf: [256]u8 = undefined;
        var pro_len: usize = 0;
        if (parsed.value.object.get("prover_strengths")) |pv| {
            if (pv == .array) pro_len = ci_arrayToCsv(pv.array.items, &pro_buf);
        }
        const rc = coord_set_capabilities(&token, 16, &class_buf, @intCast(class_len), tier, &pro_buf, @intCast(pro_len));
        if (rc == 0) return ci_ok(out, "set");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "invalid capabilities (tier 0..5, class ≤128B, prover_strengths ≤256B)", shim.RC_BAD_ARGS);
        return ci_fail(out, "set_capabilities failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_get_peer_capabilities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const pv = parsed.value.object.get("peer_id") orelse return ci_fail(out, "missing peer_id", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var probe: [1]u8 = undefined;
        if (coord_list_peers(&token, 16, &probe, 0) < 0) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        const suf = ci_extractSuffix(pv.string) orelse return ci_fail(out, "invalid peer_id format — expected <kind>-<4hex>[@<context>]", shim.RC_BAD_ARGS);
        const peer_idx = coord_find_peer_by_suffix(suf.ptr);
        if (peer_idx < 0) return ci_fail(out, "peer not found", shim.RC_BAD_ARGS);
        var class_buf: [128]u8 = undefined;
        const class_n = coord_read_peer_class(peer_idx, &class_buf, @intCast(class_buf.len));
        const class_slice: []const u8 = if (class_n > 0) class_buf[0..@intCast(class_n)] else "";
        const tier_val = coord_read_peer_tier(peer_idx);
        var pro_buf: [256]u8 = undefined;
        const pro_n = coord_read_peer_provers(peer_idx, &pro_buf, @intCast(pro_buf.len));
        const pro_slice: []const u8 = if (pro_n > 0) pro_buf[0..@intCast(pro_n)] else "";
        var var_buf: [32]u8 = undefined;
        const v_n = coord_read_peer_variant(peer_idx, &var_buf, @intCast(var_buf.len));
        const var_slice: []const u8 = if (v_n > 0) var_buf[0..@intCast(v_n)] else "";
        const kind_val = coord_read_peer_kind(peer_idx);
        var ctx_buf: [32]u8 = undefined;
        const ctx_n = coord_read_peer_context(peer_idx, &ctx_buf, @intCast(ctx_buf.len));
        const ctx_slice: []const u8 = if (ctx_n > 0) ctx_buf[0..@intCast(ctx_n)] else "";
        var pid_buf: [96]u8 = undefined;
        const canon_id = ci_renderPeerId(&pid_buf, ci_kindName(kind_val), suf, ctx_slice) catch
            return ci_fail(out, "peer_id render overflow", shim.RC_RUNTIME_ERROR);
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        std.fmt.format(w, "{{\"success\":true,\"peer_id\":\"{s}\",\"kind\":\"{s}\",\"variant\":\"{s}\",\"tier\":{d},\"class\":[", .{
            canon_id, ci_kindName(kind_val), var_slice, tier_val,
        }) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        ci_writeCsvAsJsonStrings(w, class_slice) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        w.writeAll("],\"prover_strengths\":[") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        ci_writeCsvAsJsonStrings(w, pro_slice) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        w.writeAll("]}") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_progress")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        const task = parsed.value.object.get("task") orelse return ci_fail(out, "missing task", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const rc = coord_progress(&token, 16, task.string.ptr, @intCast(task.string.len));
        if (rc == 0) return ci_ok(out, "heartbeat");
        if (rc == -1) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        if (rc == -2) return ci_fail(out, "no active claim for this task", shim.RC_BAD_ARGS);
        if (rc == -3) return ci_fail(out, "caller is not the claim holder", shim.RC_AUTH_DENIED);
        return ci_fail(out, "progress failed", shim.RC_RUNTIME_ERROR);
    }

    if (std.mem.eql(u8, tool, "coord_sweep_watchdog")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        const rc = coord_sweep_watchdog(&token, 16);
        if (rc < 0) return ci_fail(out, "unauthenticated", shim.RC_AUTH_DENIED);
        const b = std.fmt.bufPrint(out, "{{\"success\":true,\"released\":{d},\"ttl_apprentice_ms\":30000,\"ttl_journeyman_ms\":300000}}", .{rc}) catch
            return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = b.len, .rc = shim.RC_SUCCESS };
    }

    if (std.mem.eql(u8, tool, "coord_list_claims")) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_args, .{}) catch
            return ci_fail(out, "invalid json", shim.RC_BAD_ARGS);
        defer parsed.deinit();
        const tv = parsed.value.object.get("token") orelse return ci_fail(out, "missing token", shim.RC_BAD_ARGS);
        var token: [16]u8 = undefined;
        if (!ci_parseToken(tv.string, &token)) return ci_fail(out, "invalid token hex", shim.RC_BAD_ARGS);
        var stream = std.io.fixedBufferStream(out);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"active_claims\":[") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        var first = true;
        var ci: c_int = 0;
        while (ci < 64) : (ci += 1) {
            var task_buf: [128]u8 = undefined;
            const task_len = coord_read_claim_task(&token, 16, ci, &task_buf, @intCast(task_buf.len));
            if (task_len < 0) continue;
            const task_slice = task_buf[0..@intCast(task_len)];
            var holder_suffix: [4]u8 = undefined;
            const hs_rc = coord_read_claim_holder_suffix(&token, 16, ci, &holder_suffix);
            if (!first) w.writeByte(',') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            first = false;
            w.writeAll("{\"task\":") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            ci_writeJsonString(w, task_slice) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            if (hs_rc == 4) {
                std.fmt.format(w, ",\"holder\":\"{s}\"", .{holder_suffix}) catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            } else {
                w.writeAll(",\"holder\":\"\"") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
            }
            w.writeByte('}') catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        }
        w.writeAll("]}") catch return ci_fail(out, "buffer overflow", shim.RC_RUNTIME_ERROR);
        return .{ .written = stream.pos, .rc = shim.RC_SUCCESS };
    }

    return ci_fail(out, "unknown tool", shim.RC_UNKNOWN_TOOL);
}

/// Dispatch the cartridge.json MCP tools — Grade B: all 20+ tools wired to
/// real FFI calls (Task #2). Parses JSON args with page_allocator; error
/// bodies are written to out_buf even when rc < 0.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;
    const cap = in_out_len.*;
    if (cap == 0) {
        in_out_len.* = 64; // hint a minimum useful size
        return shim.RC_BUFFER_TOO_SMALL;
    }
    // CWE-704 fix (post-#146): std.mem.sliceTo(ptr, 0) reads the C string
    // up to the first NUL without an `@ptrCast` and without the
    // `std.mem.spanZ` that no longer exists in Zig 0.14+. The optional-payload
    // capture `if (json_args != null) |ja|` was also invalid for [*c]
    // pointers — those are null-checked with `== null`, not unwrapped.
    const tool = std.mem.sliceTo(tool_name, 0);
    const args: []const u8 = if (json_args == null) "{}" else std.mem.sliceTo(json_args, 0);
    const result = ci_dispatch(tool, args, out_buf[0..cap], std.heap.page_allocator);
    in_out_len.* = result.written;
    return result.rc;
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
    peer_reject_ring = [_][REJECT_LIMIT]u64{[_]u64{0} ** REJECT_LIMIT} ** MAX_PEERS;
    peer_reject_head = [_]usize{0} ** MAX_PEERS;
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

test "watchdog: apprentice claim swept past 30s TTL" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &tok, &suf); // gemini → apprentice, 30s TTL

    const task = "long-running-apprentice-task";
    try std.testing.expectEqual(@as(c_int, 0),
        coord_claim_task(&tok, TOKEN_LEN, task.ptr, @intCast(task.len)));

    // Rewind the claim timestamp past the apprentice TTL.
    claims[0].claimed_at_ms -= TTL_APPRENTICE_MS + 1000;

    const released = coord_sweep_watchdog(&tok, TOKEN_LEN);
    try std.testing.expectEqual(@as(c_int, 1), released);
    try std.testing.expectEqual(false, claims[0].active);

    coord_reset();
}

test "watchdog: progress heartbeat keeps claim alive" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &tok, &suf); // gemini → apprentice

    const task = "heartbeat-task";
    try std.testing.expectEqual(@as(c_int, 0),
        coord_claim_task(&tok, TOKEN_LEN, task.ptr, @intCast(task.len)));

    // Rewind just under the TTL to simulate nearly-expired work.
    claims[0].claimed_at_ms -= TTL_APPRENTICE_MS - 1000;

    // Heartbeat must succeed and bump the timestamp.
    try std.testing.expectEqual(@as(c_int, 0),
        coord_progress(&tok, TOKEN_LEN, task.ptr, @intCast(task.len)));

    // Sweep now should release nothing — TTL got reset.
    try std.testing.expectEqual(@as(c_int, 0), coord_sweep_watchdog(&tok, TOKEN_LEN));
    try std.testing.expectEqual(true, claims[0].active);

    coord_reset();
}

test "watchdog: journeyman gets 5min TTL, master never swept" {
    coord_reset();
    var tok_j: [TOKEN_LEN]u8 = undefined;
    var tok_a: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok_j, &suf); // claude → journeyman
    _ = coord_register(1, -1, &tok_a, &suf); // gemini → apprentice

    const t_j = "journeyman-task";
    const t_a = "apprentice-task";
    _ = coord_claim_task(&tok_j, TOKEN_LEN, t_j.ptr, @intCast(t_j.len));
    _ = coord_claim_task(&tok_a, TOKEN_LEN, t_a.ptr, @intCast(t_a.len));

    // Rewind both by 1 minute: journeyman still safe (5 min TTL), apprentice
    // is way over (30 s TTL).
    const one_min: u64 = 60 * 1000;
    claims[0].claimed_at_ms -= one_min;
    claims[1].claimed_at_ms -= one_min;

    try std.testing.expectEqual(@as(c_int, 1), coord_sweep_watchdog(&tok_j, TOKEN_LEN));
    try std.testing.expectEqual(true, claims[0].active);   // journeyman survives
    try std.testing.expectEqual(false, claims[1].active);  // apprentice swept

    // Now push the journeyman past its TTL.
    claims[0].claimed_at_ms -= TTL_JOURNEYMAN_MS;
    try std.testing.expectEqual(@as(c_int, 1), coord_sweep_watchdog(&tok_j, TOKEN_LEN));
    try std.testing.expectEqual(false, claims[0].active);

    coord_reset();
}

test "watchdog: progress rejected from non-holder" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok1, &suf);
    _ = coord_register(1, -1, &tok2, &suf);

    const task = "held-by-tok1";
    _ = coord_claim_task(&tok1, TOKEN_LEN, task.ptr, @intCast(task.len));

    // tok2 tries to refresh tok1's claim → -3.
    try std.testing.expectEqual(@as(c_int, -3),
        coord_progress(&tok2, TOKEN_LEN, task.ptr, @intCast(task.len)));

    // Unknown task → -2.
    const missing = "no-such-task";
    try std.testing.expectEqual(@as(c_int, -2),
        coord_progress(&tok1, TOKEN_LEN, missing.ptr, @intCast(missing.len)));

    coord_reset();
}

test "watchdog: implicit sweep frees stale slot on contention" {
    coord_reset();
    var tok_old: [TOKEN_LEN]u8 = undefined;
    var tok_new: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &tok_old, &suf); // gemini → apprentice
    _ = coord_register(1, -1, &tok_new, &suf);

    const task = "contested-task";
    _ = coord_claim_task(&tok_old, TOKEN_LEN, task.ptr, @intCast(task.len));
    claims[0].claimed_at_ms -= TTL_APPRENTICE_MS + 1000;

    // Second peer attempts to claim — sweep runs inline, old claim evaporates,
    // new peer gets granted (rc=0), not held (rc=1).
    try std.testing.expectEqual(@as(c_int, 0),
        coord_claim_task(&tok_new, TOKEN_LEN, task.ptr, @intCast(task.len)));

    coord_reset();
}

test "watchdog auto-release files warn_drift into quarantine when master present" {
    // DD-21: with a master on the pool, the warn_drift envelope is queued
    // for master review as a server-origin suggestion (sender_idx = 0xFE).
    coord_reset();
    var tok_m: [TOKEN_LEN]u8 = undefined;
    var tok_a: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok_m, &suf); // claude → journeyman; promote below
    _ = coord_register(1, -1, &tok_a, &suf); // gemini → apprentice
    peers[0].role = .master;

    const task = "stalled-work";
    try std.testing.expectEqual(@as(c_int, 0),
        coord_claim_task(&tok_a, TOKEN_LEN, task.ptr, @intCast(task.len)));
    claims[0].claimed_at_ms -= TTL_APPRENTICE_MS + 1000;

    const released = coord_sweep_watchdog(&tok_m, TOKEN_LEN);
    try std.testing.expectEqual(@as(c_int, 1), released);

    // Quarantine now has one server-origin entry with the warn_drift envelope.
    var found: bool = false;
    for (&quarantine) |*q| {
        if (!q.active) continue;
        if (q.sender_idx != SERVER_ORIGIN_SENTINEL) continue;
        try std.testing.expectEqual(@as(i8, -1), q.target_idx);
        try std.testing.expectEqual(@as(u8, 1), q.risk_tier);
        const body = q.msg[0..q.msg_len];
        try std.testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"warn_drift\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"task\":\"stalled-work\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"apprentice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"held_ms\":") != null);
        found = true;
        break;
    }
    try std.testing.expect(found);

    coord_reset();
}

test "watchdog auto-release broadcasts warn_drift when no master" {
    // DD-21 fallback: with no master present, the envelope goes straight
    // to every active peer's inbox so the warning still lands.
    coord_reset();
    var tok_a: [TOKEN_LEN]u8 = undefined;
    var tok_j: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &tok_a, &suf); // gemini → apprentice (holder)
    _ = coord_register(0, -1, &tok_j, &suf); // claude → journeyman (receiver)

    const task = "abandoned-claim";
    try std.testing.expectEqual(@as(c_int, 0),
        coord_claim_task(&tok_a, TOKEN_LEN, task.ptr, @intCast(task.len)));
    claims[0].claimed_at_ms -= TTL_APPRENTICE_MS + 1000;

    const released = coord_sweep_watchdog(&tok_j, TOKEN_LEN);
    try std.testing.expectEqual(@as(c_int, 1), released);

    // Journeyman (idx 1) should have a warn_drift envelope in its inbox.
    try std.testing.expect(peers[1].inbox_count >= 1);
    const tail = peers[1].inbox_tail;
    const len: usize = peers[1].inbox_lens[tail];
    const body = peers[1].inbox[tail][0..len];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"warn_drift\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"task\":\"abandoned-claim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"apprentice\"") != null);

    // Holder (idx 0) must NOT receive its own drift warning.
    try std.testing.expectEqual(@as(u16, 0), peers[0].inbox_count);

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

    // claude -> journeyman
    const c_idx = coord_register(0, -1, &tok, &suf);
    try std.testing.expect(c_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.journeyman)), coord_read_peer_role(c_idx));

    // gemini -> apprentice
    const g_idx = coord_register(1, -1, &tok, &suf);
    try std.testing.expect(g_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(g_idx));

    // copilot -> apprentice
    const p_idx = coord_register(2, -1, &tok, &suf);
    try std.testing.expect(p_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(p_idx));

    // custom -> apprentice
    const x_idx = coord_register(3, -1, &tok, &suf);
    try std.testing.expect(x_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(x_idx));

    // openai -> apprentice (Task #33)
    const o_idx = coord_register(4, -1, &tok, &suf);
    try std.testing.expect(o_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(o_idx));
    try std.testing.expectEqual(@as(c_int, 4), coord_read_peer_kind(o_idx));

    // mistral -> apprentice (Task #33)
    const m_idx = coord_register(5, -1, &tok, &suf);
    try std.testing.expect(m_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(m_idx));
    try std.testing.expectEqual(@as(c_int, 5), coord_read_peer_kind(m_idx));

    coord_reset();
}

test "set and read peer variant (Task #33)" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(4, -1, &tok, &suf); // openai
    try std.testing.expect(idx >= 0);

    // Initially empty.
    var vbuf: [MAX_VARIANT]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), coord_read_peer_variant(idx, &vbuf, @intCast(vbuf.len)));

    // Valid variant.
    const v = "opus-4.7";
    try std.testing.expectEqual(@as(c_int, 0), coord_set_variant(&tok, TOKEN_LEN, v.ptr, @intCast(v.len)));
    const n = coord_read_peer_variant(idx, &vbuf, @intCast(vbuf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(v.len)), n);
    try std.testing.expect(std.mem.eql(u8, vbuf[0..v.len], v));

    // Reject spaces.
    const bad = "has space";
    try std.testing.expectEqual(@as(c_int, -2), coord_set_variant(&tok, TOKEN_LEN, bad.ptr, @intCast(bad.len)));

    // Slot reuse clears variant.
    _ = coord_deregister(&tok, TOKEN_LEN);
    var tok2: [TOKEN_LEN]u8 = undefined;
    const idx2 = coord_register(4, -1, &tok2, &suf);
    try std.testing.expectEqual(@as(c_int, 0), coord_read_peer_variant(idx2, &vbuf, @intCast(vbuf.len)));

    coord_reset();
}

test "set and read peer capabilities (Task #34)" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(0, -1, &tok, &suf); // claude
    try std.testing.expect(idx >= 0);

    const class = "reasoning,coding,proof";
    const provers = "coq,lean,tlaps";
    const rc = coord_set_capabilities(
        &tok, TOKEN_LEN,
        class.ptr, @intCast(class.len),
        5,
        provers.ptr, @intCast(provers.len),
    );
    try std.testing.expectEqual(@as(c_int, 0), rc);

    try std.testing.expectEqual(@as(c_int, 5), coord_read_peer_tier(idx));

    var cbuf: [MAX_CLASS]u8 = undefined;
    const cn = coord_read_peer_class(idx, &cbuf, @intCast(cbuf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(class.len)), cn);
    try std.testing.expect(std.mem.eql(u8, cbuf[0..class.len], class));

    var pbuf: [MAX_PROVERS]u8 = undefined;
    const pn = coord_read_peer_provers(idx, &pbuf, @intCast(pbuf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(provers.len)), pn);
    try std.testing.expect(std.mem.eql(u8, pbuf[0..provers.len], provers));

    // tier out of range rejected.
    const rc_bad_tier = coord_set_capabilities(
        &tok, TOKEN_LEN,
        class.ptr, @intCast(class.len),
        99,
        provers.ptr, @intCast(provers.len),
    );
    try std.testing.expectEqual(@as(c_int, -2), rc_bad_tier);
    // Prior value retained on rejection.
    try std.testing.expectEqual(@as(c_int, 5), coord_read_peer_tier(idx));

    // Bad char (quote) in class CSV rejected.
    const bad_class = "a\",b";
    const rc_bad_char = coord_set_capabilities(
        &tok, TOKEN_LEN,
        bad_class.ptr, @intCast(bad_class.len),
        3,
        provers.ptr, @intCast(provers.len),
    );
    try std.testing.expectEqual(@as(c_int, -2), rc_bad_char);

    coord_reset();
}

test "coord_health counts basics" {
    coord_reset();
    var tok1: [TOKEN_LEN]u8 = undefined;
    var tok2: [TOKEN_LEN]u8 = undefined;
    var tok3: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    _ = coord_register(0, -1, &tok1, &suf); // claude → journeyman
    _ = coord_register(1, -1, &tok2, &suf); // gemini → apprentice
    _ = coord_register(4, -1, &tok3, &suf); // openai → apprentice

    // Claim from tok1 contributes to active claim count.
    const t = "health-test-task";
    try std.testing.expectEqual(@as(c_int, 0), coord_claim_task(&tok1, TOKEN_LEN, t.ptr, @intCast(t.len)));

    // Bad token returns -1.
    var bad: [TOKEN_LEN]u8 = [_]u8{0} ** TOKEN_LEN;
    try std.testing.expectEqual(@as(c_int, -1), coord_count_claims(&bad, TOKEN_LEN));
    try std.testing.expectEqual(@as(c_int, -1), coord_count_quarantine(&bad, TOKEN_LEN));
    try std.testing.expectEqual(@as(c_int, -1), coord_count_track(&bad, TOKEN_LEN));

    // With a valid token, counts are positive / zero as expected.
    try std.testing.expectEqual(@as(c_int, 1), coord_count_claims(&tok1, TOKEN_LEN));
    try std.testing.expectEqual(@as(c_int, 0), coord_count_quarantine(&tok1, TOKEN_LEN));
    try std.testing.expectEqual(@as(c_int, 0), coord_count_track(&tok1, TOKEN_LEN));

    // Recent-rejects for an unseen kind (mistral=5) is 0; kind out of range is -2.
    try std.testing.expectEqual(@as(c_int, 0), coord_count_rejects_recent(&tok1, TOKEN_LEN, 5));
    try std.testing.expectEqual(@as(c_int, -2), coord_count_rejects_recent(&tok1, TOKEN_LEN, 99));
    try std.testing.expectEqual(@as(c_int, 0), coord_kind_in_cooldown(&tok1, TOKEN_LEN, 0));

    coord_reset();
}

test "register rejects master role_hint" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // role_hint=0 (master) is always rejected; must use coord_promote_to_master.
    const rc = coord_register(0, 0, &tok, &suf);
    try std.testing.expectEqual(@as(c_int, -3), rc);

    coord_reset();
}

test "promote to master requires env-var secret match" {
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

test "coord_transfer_master rejects apprentice target" {
    coord_reset();
    var mas_tok: [TOKEN_LEN]u8 = undefined;
    var app_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // Install master directly to avoid env-var gymnastics.
    _ = coord_register(0, 1, &mas_tok, &suf); // journeyman
    peers[0].role = .master;

    // Register apprentice (gemini default).
    const app_idx = coord_register(1, -1, &app_tok, &suf);
    try std.testing.expect(app_idx >= 0);
    try std.testing.expectEqual(Role.apprentice, peers[@intCast(app_idx)].role);

    // Handoff to apprentice target -> -4.
    // Even with a valid env secret, target role blocks before secret check.
    // Without env secret the same target would yield -3 — but role gate
    // fires first in our implementation so -4 is returned when target is
    // an apprentice regardless of secret validity.
    const rc = coord_transfer_master(&mas_tok, TOKEN_LEN, app_idx, "whatever".ptr, 8);
    try std.testing.expectEqual(@as(c_int, -4), rc);

    coord_reset();
}

test "coord_transfer_master caller must be master" {
    coord_reset();
    var jm_tok: [TOKEN_LEN]u8 = undefined;
    var other_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    _ = coord_register(0, -1, &jm_tok, &suf); // claude -> journeyman
    const other_idx = coord_register(0, -1, &other_tok, &suf);
    try std.testing.expect(other_idx >= 0);

    const rc = coord_transfer_master(&jm_tok, TOKEN_LEN, other_idx, "x".ptr, 1);
    try std.testing.expectEqual(@as(c_int, -1), rc);
    coord_reset();
}

test "coord_transfer_master bad target idx" {
    coord_reset();
    var mas_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, 1, &mas_tok, &suf);
    peers[0].role = .master;

    const rc = coord_transfer_master(&mas_tok, TOKEN_LEN, 99, "x".ptr, 1);
    try std.testing.expectEqual(@as(c_int, -2), rc);
    coord_reset();
}

test "gated send from apprentice peer lands in quarantine" {
    coord_reset();
    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    // Manually install a master by bypassing env-var gate (test-only
    // shortcut — we set role directly via coord_set_role which needs a
    // master token, so we instead register the master by direct
    // register + role override for this test).
    _ = coord_register(0, 1, &sup_tok, &suf); // journeyman
    // Upgrade directly for test purposes by touching the peer record.
    // In production this happens via coord_promote_to_master.
    peers[0].role = .master;

    // Now register gemini as apprentice (default for kind=1).
    const gem_idx = coord_register(1, -1, &gem_tok, &suf);
    try std.testing.expect(gem_idx >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Role.apprentice)), coord_read_peer_role(gem_idx));

    // Tier 0 op from apprentice: direct delivery.
    const msg_low = "status-update";
    const t0_rc = coord_send_gated(&gem_tok, TOKEN_LEN, 0, msg_low.ptr, @intCast(msg_low.len), 0);
    try std.testing.expectEqual(@as(c_int, 1), t0_rc); // direct send: sent=1

    // Tier 2 op from apprentice: quarantined; returned value encodes request_id.
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

    // Recipient (index 0 — master in this test) can receive the message.
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

test "master rejects a quarantined entry" {
    coord_reset();
    var sup_tok: [TOKEN_LEN]u8 = undefined;
    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;

    _ = coord_register(0, 1, &sup_tok, &suf);
    peers[0].role = .master;
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

test "non-master cannot review/approve/reject" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf); // journeyman, not master

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

test "invoke: coord_register with valid client_kind succeeds" {
    coord_reset();
    var buf: [512]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("coord_register", "{\"client_kind\":\"claude\"}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "peer_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "token") != null);
}

test "invoke: missing required args returns RC_BAD_ARGS" {
    coord_reset();
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("coord_register", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, shim.RC_BAD_ARGS), rc);
    try std.testing.expect(len > 0); // error body written even on failure
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: zero-capacity buffer returns -3 with size hint" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    const rc = boj_cartridge_invoke("coord_register", "{\"client_kind\":\"claude\"}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 0); // hint provided
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
    const sup_idx = coord_register(0, 1, &sup_tok, &sup_suf); // claude as journeyman
    try std.testing.expect(sup_idx >= 0);
    // Promote directly via state mutation — avoids env-var gymnastics
    // in-test, and still gets persisted via the coord_set_role path below.
    peers[@intCast(sup_idx)].role = .master;
    dur.logPeerRoleSet(@intCast(sup_idx), @intCast(@intFromEnum(Role.master)));

    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var gem_suf: [4]u8 = undefined;
    const gem_idx = coord_register(1, -1, &gem_tok, &gem_suf); // gemini → apprentice
    try std.testing.expect(gem_idx >= 0);

    // Remember identities for post-replay comparison.
    const sup_suf_copy = sup_suf;
    const gem_suf_copy = gem_suf;

    // Set a context on the apprentice peer.
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

    // Claim a task as the master.
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
    try std.testing.expectEqual(Role.master, peers[@intCast(sup_idx)].role);

    try std.testing.expect(peers[@intCast(gem_idx)].active);
    try std.testing.expectEqualSlices(u8, &gem_suf_copy, &peers[@intCast(gem_idx)].suffix);
    try std.testing.expectEqual(Role.apprentice, peers[@intCast(gem_idx)].role);

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

    // Claim still held by master — another peer can't grab it.
    const steal_rc = coord_claim_task(&gem_tok, TOKEN_LEN, task.ptr, @intCast(task.len));
    try std.testing.expectEqual(@as(c_int, 1), steal_rc); // Held

    // Supervisor's own re-claim is idempotent.
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_claim_task(&sup_tok, TOKEN_LEN, task.ptr, @intCast(task.len)),
    );

    // Quarantine entry reappears for the master to review.
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
    peers[@intCast(sup_idx)].role = .master;
    dur.logPeerRoleSet(@intCast(sup_idx), @intCast(@intFromEnum(Role.master)));

    var gem_tok: [TOKEN_LEN]u8 = undefined;
    var gem_suf: [4]u8 = undefined;
    const gem_idx = coord_register(1, -1, &gem_tok, &gem_suf);
    try std.testing.expect(gem_idx >= 0);

    // Supervised files, master approves — approved message is now in
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
    peers[0].role = .master;
    dur.logPeerRoleSet(0, @intCast(@intFromEnum(Role.master)));

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
            coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 500, 2, -1),
        );
    }
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 500, 2, -1),
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
    _ = coord_report_outcome(&tok1, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 1, -1);
    _ = coord_report_outcome(&tok1, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 1, -1);
    _ = coord_deregister(&tok1, TOKEN_LEN);

    // New peer, same client_kind. Track record should aggregate together.
    var tok2: [TOKEN_LEN]u8 = undefined;
    var suf2: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok2, &suf2); // claude #2
    _ = coord_report_outcome(&tok2, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 100, 1, -1);

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
        _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 50, 1, -1);
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
        coord_report_outcome(&bad_tok, TOKEN_LEN, "x".ptr, 1, 1, 0, 0, -1),
    );
    coord_reset();
}

// ═══════════════════════════════════════════════════════════════════════
// Reassignment-engine tests (Task #14)
// ═══════════════════════════════════════════════════════════════════════

test "scan flags overclaim: high confidence + low effective_affinity" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf); // claude

    const tag = "formal-verification";
    // 1 success + 4 failures => 20% affinity. All with confidence 90.
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 2, 90);
    for (0..4) |_| {
        _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 100, 2, 90);
    }

    // No master registered — scan still runs.
    const n = coord_scan_suggestions(&tok, TOKEN_LEN);
    try std.testing.expect(n >= 1);

    // The quarantine should contain server-origin envelopes for both
    // overclaim (routing FYI, tier 1) and drift (monitoring warn, tier 2).
    var found_overclaim: bool = false;
    var found_remove: bool = false;
    var found_drift: bool = false;
    var drift_tier: u8 = 0;
    for (&quarantine) |*q| {
        if (!q.active) continue;
        try std.testing.expectEqual(SERVER_ORIGIN_SENTINEL, q.sender_idx);
        if (std.mem.indexOf(u8, q.msg[0..q.msg_len], "\"kind\":\"overclaim\"") != null) found_overclaim = true;
        if (std.mem.indexOf(u8, q.msg[0..q.msg_len], "\"kind\":\"remove\"") != null) found_remove = true;
        if (std.mem.indexOf(u8, q.msg[0..q.msg_len], "\"kind\":\"drift\"") != null) {
            found_drift = true;
            drift_tier = q.risk_tier;
            // Drift envelope must carry the gap magnitude.
            try std.testing.expect(std.mem.indexOf(u8, q.msg[0..q.msg_len], "\"drift_pct\":") != null);
            try std.testing.expect(std.mem.indexOf(u8, q.msg[0..q.msg_len], "\"op_kind\":\"warn\"") != null);
        }
    }
    try std.testing.expect(found_overclaim);
    try std.testing.expect(found_drift);
    try std.testing.expectEqual(@as(u8, 2), drift_tier);
    // 5 attempts + 20% affinity also fires the remove rule.
    try std.testing.expect(found_remove);

    coord_reset();
}

test "drift uses Task #33 kind names (openai)" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(4, -1, &tok, &suf); // openai

    const tag = "rust-codegen";
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 2, 90);
    for (0..4) |_| {
        _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 100, 2, 90);
    }
    _ = coord_scan_suggestions(&tok, TOKEN_LEN);

    var found_openai_drift: bool = false;
    for (&quarantine) |*q| {
        if (!q.active) continue;
        const body = q.msg[0..q.msg_len];
        if (std.mem.indexOf(u8, body, "\"kind\":\"drift\"") != null and
            std.mem.indexOf(u8, body, "\"client_kind\":\"openai\"") != null)
        {
            found_openai_drift = true;
        }
    }
    try std.testing.expect(found_openai_drift);

    coord_reset();
}

test "scan flags promote: high affinity on undeclared tag" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf);

    // Declare only 'routine-edit'; let 'proof-analysis' accumulate a
    // strong record to trigger the promote suggestion.
    const decl = "routine-edit";
    _ = coord_set_declared_affinities(&tok, TOKEN_LEN, decl.ptr, @intCast(decl.len));

    const tag = "proof-analysis";
    for (0..8) |_| {
        _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 100, 2, 60);
    }

    const n = coord_scan_suggestions(&tok, TOKEN_LEN);
    try std.testing.expect(n >= 1);

    var found_promote: bool = false;
    for (&quarantine) |*q| {
        if (!q.active) continue;
        if (std.mem.indexOf(u8, q.msg[0..q.msg_len], "promote") != null) found_promote = true;
    }
    try std.testing.expect(found_promote);
    coord_reset();
}

test "scan with no track record emits nothing" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(0, -1, &tok, &suf);
    const n = coord_scan_suggestions(&tok, TOKEN_LEN);
    try std.testing.expectEqual(@as(c_int, 0), n);
    coord_reset();
}

test "declared affinities round-trip" {
    coord_reset();
    var tok: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    const idx = coord_register(0, -1, &tok, &suf);

    const decl = "proof-analysis,supervision,doc-writing";
    try std.testing.expectEqual(
        @as(c_int, 0),
        coord_set_declared_affinities(&tok, TOKEN_LEN, decl.ptr, @intCast(decl.len)),
    );

    var buf: [256]u8 = undefined;
    const dlen = coord_read_declared_affinities(idx, &buf, @intCast(buf.len));
    try std.testing.expectEqual(@as(c_int, @intCast(decl.len)), dlen);
    try std.testing.expectEqualSlices(u8, decl, buf[0..@intCast(dlen)]);
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

test "per-peer reject ring counts independently of kind ring" {
    // Item A — after 5 rejections of one peer, coord_count_rejects_recent_peer
    // and coord_peer_in_cooldown reflect it via the public FFI.
    coord_reset();
    var tok_holder: [TOKEN_LEN]u8 = undefined;
    var tok_a: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(1, -1, &tok_holder, &suf); // gemini #1 (idx 0) holds
    _ = coord_register(1, -1, &tok_a, &suf);      // gemini #2 (idx 1) rejects 5x

    const task = "contested";
    try std.testing.expectEqual(@as(c_int, 0), coord_claim_task(&tok_holder, TOKEN_LEN, task.ptr, @intCast(task.len)));

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(
            @as(c_int, 1),
            coord_claim_task(&tok_a, TOKEN_LEN, task.ptr, @intCast(task.len)),
        );
    }

    // Per-peer counts via FFI — peer idx 1 accumulated 5, idx 0 (holder) 0.
    try std.testing.expectEqual(@as(c_int, 5), coord_count_rejects_recent_peer(&tok_holder, TOKEN_LEN, 1));
    try std.testing.expectEqual(@as(c_int, 0), coord_count_rejects_recent_peer(&tok_holder, TOKEN_LEN, 0));
    try std.testing.expectEqual(@as(c_int, 1), coord_peer_in_cooldown(&tok_holder, TOKEN_LEN, 1));
    try std.testing.expectEqual(@as(c_int, 0), coord_peer_in_cooldown(&tok_holder, TOKEN_LEN, 0));

    coord_reset();
}

test "per-peer reject ring resets on deregister" {
    // Item A — when a peer deregisters, its reject ring is zeroed so a
    // freshly-registered replacement in the same slot starts clean.
    coord_reset();
    var tok_holder: [TOKEN_LEN]u8 = undefined;
    var tok_a: [TOKEN_LEN]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = coord_register(2, -1, &tok_holder, &suf); // copilot #1 (idx 0)
    _ = coord_register(2, -1, &tok_a, &suf);      // copilot #2 (idx 1) rejects

    const task = "held";
    try std.testing.expectEqual(@as(c_int, 0), coord_claim_task(&tok_holder, TOKEN_LEN, task.ptr, @intCast(task.len)));

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = coord_claim_task(&tok_a, TOKEN_LEN, task.ptr, @intCast(task.len));
    }
    try std.testing.expectEqual(@as(c_int, 3), coord_count_rejects_recent_peer(&tok_holder, TOKEN_LEN, 1));

    // Deregister idx 1; re-register — replacement lands back in slot 1.
    try std.testing.expectEqual(@as(c_int, 0), coord_deregister(&tok_a, TOKEN_LEN));
    var tok_b: [TOKEN_LEN]u8 = undefined;
    _ = coord_register(2, -1, &tok_b, &suf);
    try std.testing.expectEqual(@as(c_int, 0), coord_count_rejects_recent_peer(&tok_holder, TOKEN_LEN, 1));

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
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 1, 200, 1, -1);
    _ = coord_report_outcome(&tok, TOKEN_LEN, tag.ptr, @intCast(tag.len), 0, 200, 1, -1);

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
