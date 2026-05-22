// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Per-box durability layer for local-coord-mcp — append-only event log with
// replay-on-init so coord state (peers, claims, inbox, quarantine, audit,
// track record) survives adapter restart.
//
// Future-swap note: temporary in-tree backend. A follow-up task replaces
// open/append/replay with calls into verisimdb-mcp's FFI once that FFI is
// real; the typed log helpers exposed here (logPeerAdd, logInboxPush, ...)
// are the stable seam local_coord_ffi.zig depends on, so the swap is
// contained.
//
// Enabled when BOJ_COORD_STATE_DIR is set to a writable directory. When
// the env var is unset, every entry point is a silent no-op — existing
// in-memory-only behaviour (and existing tests) is preserved.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Record format (little-endian throughout)
// ═══════════════════════════════════════════════════════════════════════
//
//   magic       u32    = MAGIC
//   event_type  u16    EventType
//   format_ver  u16    = FORMAT_VERSION
//   payload_len u32    (<= MAX_PAYLOAD)
//   timestamp   u64    ms since unix epoch
//   payload     [payload_len]u8
//   crc32       u32    CRC32 over (header || payload)
//
// Total record = HEADER_SIZE + payload_len + TRAILER_SIZE.

pub const MAGIC: u32 = 0x07B0C00D;
pub const FORMAT_VERSION: u16 = 1;
pub const MAX_PAYLOAD: usize = 1024;
pub const HEADER_SIZE: usize = 4 + 2 + 2 + 4 + 8;
pub const TRAILER_SIZE: usize = 4;

pub const EventType = enum(u16) {
    peer_add = 1,
    peer_remove = 2,
    peer_role_set = 3,
    peer_context_set = 4,
    peer_status_set = 5,
    inbox_push = 6,
    inbox_pop = 7,
    claim_add = 8,
    claim_rel = 9,
    quar_add = 10,
    quar_approve = 11,
    quar_reject = 12,
    audit = 13,
    track_update = 14,
    // Task #33 — variant label (free-form model identifier).
    peer_variant_set = 15,
    // Task #34 — capability advertisement (class / tier / prover_strengths).
    peer_capabilities_set = 16,
    // DD-20 — watchdog heartbeat for a claim.
    claim_progress = 17,
    _,
};

const ENV_VAR = "BOJ_COORD_STATE_DIR";
const LOG_FILE_NAME = "coord.log";

// ── VeriSimDB backend (Task #7b) ──────────────────────────────────────
//
// When BOJ_VERISIMDB_ENDPOINT is set, events are also forwarded to VeriSimDB
// alongside the local file backend. The local file backend remains the
// primary durability store; VeriSimDB adds cross-restart queryability and
// multi-modality provenance.
//
// Current status: infrastructure wired, VeriSimDB API call stubs pending.
// Completion requires verisimdb-mcp FFI to expose an append-log API beyond
// the current octad-level interface (verisimdb_store_octad / verisimdb_get_octad
// are too coarse for per-event streaming). This wiring establishes the seam.

const VDB_ENV_VAR = "BOJ_VERISIMDB_ENDPOINT";
const VDB_ENDPOINT_MAX = 128;

var vdb_endpoint: [VDB_ENDPOINT_MAX]u8 = undefined;
var vdb_endpoint_len: usize = 0;

/// True when the VeriSimDB endpoint is configured.
pub fn vdbEnabled() bool {
    return vdb_endpoint_len > 0;
}

/// Forward one event to VeriSimDB. Stub: real impl will call verisimdb-mcp
/// FFI once that exposes a streaming append-log endpoint. Errors are swallowed
/// — VeriSimDB is supplementary; the local file log is authoritative.
fn vdb_append_event(event: EventType, payload: []const u8) void {
    if (!vdbEnabled()) return;
    // TODO(Task #7b): call verisimdb_store_octad or a future
    // verisimdb_append_event once the FFI exposes a log-entry API.
    // Key: std.fmt.bufPrint("coord-event-{d}-{d}", .{@intFromEnum(event), timestamp})
    // Data: binary payload or A2ML-encoded event record.
    _ = event;
    _ = payload;
}

/// Query VeriSimDB for all coord events and replay them via cb.
/// Stub: real impl will use verisimdb query-by-tag once the FFI is richer.
fn vdb_replay_events(cb: ReplayCb) void {
    if (!vdbEnabled()) return;
    // TODO(Task #7b): query verisimdb for events with prefix "coord-event-"
    // ordered by timestamp and call cb for each valid record.
    _ = cb;
}

var log_file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Open / close / truncate / status
// ═══════════════════════════════════════════════════════════════════════

/// True when the log is open for appends.
pub fn isEnabled() bool {
    mutex.lock();
    defer mutex.unlock();
    return log_file != null;
}

/// Open the log at an explicit directory (test-usable entry point).
/// Creates the directory if missing. Returns true on success.
pub fn openWithDir(dir: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    if (log_file != null) return true;
    if (dir.len == 0 or dir.len >= 256) return false;

    std.fs.cwd().makePath(dir) catch return false;

    var path_buf: [512]u8 = undefined;
    const log_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, LOG_FILE_NAME }) catch return false;

    const f = std.fs.cwd().createFile(log_path, .{ .truncate = false, .read = true }) catch return false;
    f.seekFromEnd(0) catch {
        f.close();
        return false;
    };
    log_file = f;
    return true;
}

/// Open the log using BOJ_COORD_STATE_DIR. No-op if unset / empty.
/// Also arms the VeriSimDB supplementary backend if BOJ_VERISIMDB_ENDPOINT
/// is set (Task #7b). VeriSimDB does not gate file-backend success.
pub fn open() bool {
    // Arm VeriSimDB supplementary backend.
    if (std.posix.getenv(VDB_ENV_VAR)) |ep| {
        if (ep.len > 0 and ep.len <= VDB_ENDPOINT_MAX) {
            @memcpy(vdb_endpoint[0..ep.len], ep);
            vdb_endpoint_len = ep.len;
        }
    }
    const env = std.posix.getenv(ENV_VAR) orelse return false;
    if (env.len == 0) return false;
    return openWithDir(env);
}

/// Close the log. Idempotent.
pub fn close() void {
    mutex.lock();
    defer mutex.unlock();
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
}

/// Truncate the log to zero bytes (test-only utility).
pub fn truncate() void {
    mutex.lock();
    defer mutex.unlock();
    const f = log_file orelse return;
    f.setEndPos(0) catch {};
    f.seekTo(0) catch {};
}

// ═══════════════════════════════════════════════════════════════════════
// Low-level append / replay
// ═══════════════════════════════════════════════════════════════════════

/// Append a typed event. Silently no-ops when the log is closed; errors
/// during write are swallowed — durability is best-effort and must not
/// block the coord hot path. Also forwards to VeriSimDB if configured.
pub fn append(event: EventType, payload: []const u8) void {
    if (payload.len > MAX_PAYLOAD) return;

    // Forward to VeriSimDB supplementary backend (Task #7b).
    // Runs before the mutex so VeriSimDB can have its own concurrency model.
    vdb_append_event(event, payload);

    mutex.lock();
    defer mutex.unlock();
    const f = log_file orelse return;

    var hdr: [HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], MAGIC, .little);
    std.mem.writeInt(u16, hdr[4..6], @intFromEnum(event), .little);
    std.mem.writeInt(u16, hdr[6..8], FORMAT_VERSION, .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(payload.len), .little);
    std.mem.writeInt(u64, hdr[12..20], @intCast(std.time.milliTimestamp()), .little);

    var crc = std.hash.Crc32.init();
    crc.update(&hdr);
    crc.update(payload);
    var trailer: [TRAILER_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &trailer, crc.final(), .little);

    f.writeAll(&hdr) catch return;
    if (payload.len > 0) f.writeAll(payload) catch return;
    f.writeAll(&trailer) catch return;
}

/// Callback shape for replay(). The callback is invoked once per valid
/// record in order. Payload slice is valid only for the duration of the
/// call (copy if needed).
pub const ReplayCb = *const fn (event: EventType, payload: []const u8) void;

/// Iterate the log from the start, invoking cb for every valid record.
/// Stops at the first corrupt / truncated record — treated as a partial
/// tail from a previous crash. After replay, seeks back to end for
/// subsequent appends.
pub fn replay(cb: ReplayCb) void {
    mutex.lock();
    defer mutex.unlock();
    const f = log_file orelse return;

    f.seekTo(0) catch return;

    var hdr: [HEADER_SIZE]u8 = undefined;
    var payload_buf: [MAX_PAYLOAD]u8 = undefined;
    var trailer: [TRAILER_SIZE]u8 = undefined;

    while (true) {
        const n = f.readAll(&hdr) catch break;
        if (n < HEADER_SIZE) break;

        const magic = std.mem.readInt(u32, hdr[0..4], .little);
        if (magic != MAGIC) break;
        const event_raw = std.mem.readInt(u16, hdr[4..6], .little);
        const format_ver = std.mem.readInt(u16, hdr[6..8], .little);
        if (format_ver != FORMAT_VERSION) break;
        const payload_len: usize = @intCast(std.mem.readInt(u32, hdr[8..12], .little));
        if (payload_len > MAX_PAYLOAD) break;

        if (payload_len > 0) {
            const pn = f.readAll(payload_buf[0..payload_len]) catch break;
            if (pn < payload_len) break;
        }

        const tn = f.readAll(&trailer) catch break;
        if (tn < TRAILER_SIZE) break;

        var crc = std.hash.Crc32.init();
        crc.update(&hdr);
        crc.update(payload_buf[0..payload_len]);
        const expected = std.mem.readInt(u32, &trailer, .little);
        if (crc.final() != expected) break;

        const event: EventType = @enumFromInt(event_raw);
        cb(event, payload_buf[0..payload_len]);
    }

    f.seekFromEnd(0) catch {};
}

// ═══════════════════════════════════════════════════════════════════════
// Typed log helpers — the stable seam local_coord_ffi.zig depends on.
// Each helper packs its payload in a fixed layout. Replay decoders mirror
// these shapes.
// ═══════════════════════════════════════════════════════════════════════

/// PEER_ADD — slot_idx:u8 kind:u8 role:u8 suffix[4]u8 token[16]u8 (23B)
pub fn logPeerAdd(slot_idx: u8, kind: u8, role: u8, suffix: *const [4]u8, token: *const [16]u8) void {
    var buf: [23]u8 = undefined;
    buf[0] = slot_idx;
    buf[1] = kind;
    buf[2] = role;
    @memcpy(buf[3..7], suffix);
    @memcpy(buf[7..23], token);
    append(.peer_add, &buf);
}

/// PEER_REMOVE — slot_idx:u8 (1B)
pub fn logPeerRemove(slot_idx: u8) void {
    append(.peer_remove, &[_]u8{slot_idx});
}

/// PEER_ROLE_SET — slot_idx:u8 role:u8 (2B)
pub fn logPeerRoleSet(slot_idx: u8, role: u8) void {
    append(.peer_role_set, &[_]u8{ slot_idx, role });
}

/// PEER_CONTEXT_SET — slot_idx:u8 ctx_len:u8 ctx[ctx_len]
pub fn logPeerContextSet(slot_idx: u8, ctx: []const u8) void {
    if (ctx.len > 32) return;
    var buf: [34]u8 = undefined;
    buf[0] = slot_idx;
    buf[1] = @intCast(ctx.len);
    if (ctx.len > 0) @memcpy(buf[2 .. 2 + ctx.len], ctx);
    append(.peer_context_set, buf[0 .. 2 + ctx.len]);
}

/// PEER_VARIANT_SET — slot_idx:u8 variant_len:u8 variant[variant_len] (Task #33)
pub fn logPeerVariantSet(slot_idx: u8, variant: []const u8) void {
    if (variant.len > 32) return;
    var buf: [34]u8 = undefined;
    buf[0] = slot_idx;
    buf[1] = @intCast(variant.len);
    if (variant.len > 0) @memcpy(buf[2 .. 2 + variant.len], variant);
    append(.peer_variant_set, buf[0 .. 2 + variant.len]);
}

/// PEER_CAPABILITIES_SET — Task #34.
/// Payload: slot_idx:u8 tier:u8 class_len:u16 class[class_len] provers_len:u16 provers[provers_len]
/// class_len ≤ 128, provers_len ≤ 256; oversized payloads drop silently.
pub fn logPeerCapabilitiesSet(slot_idx: u8, tier: u8, class: []const u8, provers: []const u8) void {
    if (class.len > 128 or provers.len > 256) return;
    var buf: [2 + 2 + 128 + 2 + 256]u8 = undefined;
    buf[0] = slot_idx;
    buf[1] = tier;
    std.mem.writeInt(u16, buf[2..4], @intCast(class.len), .little);
    if (class.len > 0) @memcpy(buf[4 .. 4 + class.len], class);
    const p_off: usize = 4 + class.len;
    std.mem.writeInt(u16, buf[p_off..][0..2], @intCast(provers.len), .little);
    if (provers.len > 0) @memcpy(buf[p_off + 2 .. p_off + 2 + provers.len], provers);
    append(.peer_capabilities_set, buf[0 .. p_off + 2 + provers.len]);
}

/// PEER_STATUS_SET — slot_idx:u8 status_len:u16 status[status_len]
pub fn logPeerStatusSet(slot_idx: u8, status: []const u8) void {
    if (status.len > 256) return;
    var buf: [3 + 256]u8 = undefined;
    buf[0] = slot_idx;
    std.mem.writeInt(u16, buf[1..3], @intCast(status.len), .little);
    if (status.len > 0) @memcpy(buf[3 .. 3 + status.len], status);
    append(.peer_status_set, buf[0 .. 3 + status.len]);
}

/// INBOX_PUSH — target_idx:u8 msg_len:u16 msg[msg_len]
pub fn logInboxPush(target_idx: u8, msg: []const u8) void {
    if (msg.len > 512) return;
    var buf: [3 + 512]u8 = undefined;
    buf[0] = target_idx;
    std.mem.writeInt(u16, buf[1..3], @intCast(msg.len), .little);
    if (msg.len > 0) @memcpy(buf[3 .. 3 + msg.len], msg);
    append(.inbox_push, buf[0 .. 3 + msg.len]);
}

/// INBOX_POP — peer_idx:u8 (1B)
pub fn logInboxPop(peer_idx: u8) void {
    append(.inbox_pop, &[_]u8{peer_idx});
}

/// CLAIM_ADD — claim_idx:u8 holder_idx:u8 task_len:u8 task[task_len]
pub fn logClaimAdd(claim_idx: u8, holder_idx: u8, task: []const u8) void {
    if (task.len > 128) return;
    var buf: [3 + 128]u8 = undefined;
    buf[0] = claim_idx;
    buf[1] = holder_idx;
    buf[2] = @intCast(task.len);
    if (task.len > 0) @memcpy(buf[3 .. 3 + task.len], task);
    append(.claim_add, buf[0 .. 3 + task.len]);
}

/// CLAIM_REL — claim_idx:u8 (1B)
pub fn logClaimRel(claim_idx: u8) void {
    append(.claim_rel, &[_]u8{claim_idx});
}

/// CLAIM_PROGRESS — claim_idx:u8 timestamp_ms:u64 (9B). DD-20 watchdog.
pub fn logClaimProgress(claim_idx: u8, timestamp_ms: u64) void {
    var buf: [9]u8 = undefined;
    buf[0] = claim_idx;
    std.mem.writeInt(u64, buf[1..9], timestamp_ms, .little);
    append(.claim_progress, &buf);
}

/// QUAR_ADD — request_id:u32 sender_idx:u8 target_idx:i8 risk_tier:u8
///            msg_len:u16 msg[msg_len]
pub fn logQuarAdd(request_id: u32, sender_idx: u8, target_idx: i8, risk_tier: u8, msg: []const u8) void {
    if (msg.len > 512) return;
    var buf: [9 + 512]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], request_id, .little);
    buf[4] = sender_idx;
    buf[5] = @bitCast(target_idx);
    buf[6] = risk_tier;
    std.mem.writeInt(u16, buf[7..9], @intCast(msg.len), .little);
    if (msg.len > 0) @memcpy(buf[9 .. 9 + msg.len], msg);
    append(.quar_add, buf[0 .. 9 + msg.len]);
}

/// QUAR_APPROVE — request_id:u32 (4B)
pub fn logQuarApprove(request_id: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, request_id, .little);
    append(.quar_approve, &buf);
}

/// QUAR_REJECT — request_id:u32 reason_len:u16 reason[reason_len]
pub fn logQuarReject(request_id: u32, reason: []const u8) void {
    if (reason.len > 256) return;
    var buf: [6 + 256]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], request_id, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(reason.len), .little);
    if (reason.len > 0) @memcpy(buf[6 .. 6 + reason.len], reason);
    append(.quar_reject, buf[0 .. 6 + reason.len]);
}

/// AUDIT — kind:u8 detail_len:u16 detail[detail_len]
/// Generic audit line for supervision decisions and policy trips beyond
/// the quarantine flow (e.g. tier-promotion, bad-token attempts).
pub fn logAudit(kind: u8, detail: []const u8) void {
    if (detail.len > 512) return;
    var buf: [3 + 512]u8 = undefined;
    buf[0] = kind;
    std.mem.writeInt(u16, buf[1..3], @intCast(detail.len), .little);
    if (detail.len > 0) @memcpy(buf[3 .. 3 + detail.len], detail);
    append(.audit, buf[0 .. 3 + detail.len]);
}

/// TRACK_UPDATE — client_kind:u8 outcome:u8 risk_tier:u8 duration_ms:u32
///                timestamp_ms:u64 tag_len:u8 tag[tag_len] confidence_pct:u8
///
/// confidence_pct is 0..100, or 255 = unset. Always the last byte so old
/// decoders (16+tag.len) can still parse the leading fields.
///
/// DD-29: keyed on client_kind (not peer_id/suffix) so the track record
/// survives peer crash+restart — a fresh peer of the same client_kind
/// inherits the track record.
pub fn logTrackUpdate(
    client_kind: u8,
    outcome: u8,
    risk_tier: u8,
    duration_ms: u32,
    timestamp_ms: u64,
    tag: []const u8,
    confidence_pct: u8,
) void {
    if (tag.len > 64) return;
    var buf: [17 + 64]u8 = undefined;
    buf[0] = client_kind;
    buf[1] = outcome;
    buf[2] = risk_tier;
    std.mem.writeInt(u32, buf[3..7], duration_ms, .little);
    std.mem.writeInt(u64, buf[7..15], timestamp_ms, .little);
    buf[15] = @intCast(tag.len);
    if (tag.len > 0) @memcpy(buf[16 .. 16 + tag.len], tag);
    buf[16 + tag.len] = confidence_pct;
    append(.track_update, buf[0 .. 17 + tag.len]);
}

// ═══════════════════════════════════════════════════════════════════════
// Typed decoders — helpers for replay callbacks. Each returns null if the
// payload is too short for the fixed portion of the event.
// ═══════════════════════════════════════════════════════════════════════

pub const PeerAdd = struct { slot_idx: u8, kind: u8, role: u8, suffix: [4]u8, token: [16]u8 };
pub fn decodePeerAdd(p: []const u8) ?PeerAdd {
    if (p.len < 23) return null;
    var out: PeerAdd = undefined;
    out.slot_idx = p[0];
    out.kind = p[1];
    out.role = p[2];
    @memcpy(&out.suffix, p[3..7]);
    @memcpy(&out.token, p[7..23]);
    return out;
}

pub fn decodeSlotIdx(p: []const u8) ?u8 {
    if (p.len < 1) return null;
    return p[0];
}

pub const PeerRoleSet = struct { slot_idx: u8, role: u8 };
pub fn decodePeerRoleSet(p: []const u8) ?PeerRoleSet {
    if (p.len < 2) return null;
    return .{ .slot_idx = p[0], .role = p[1] };
}

pub const PeerContextSet = struct { slot_idx: u8, ctx: []const u8 };
pub fn decodePeerContextSet(p: []const u8) ?PeerContextSet {
    if (p.len < 2) return null;
    const n: usize = p[1];
    if (p.len < 2 + n) return null;
    return .{ .slot_idx = p[0], .ctx = p[2 .. 2 + n] };
}

/// Task #33 — identical shape to PeerContextSet.
pub const PeerVariantSet = struct { slot_idx: u8, variant: []const u8 };
pub fn decodePeerVariantSet(p: []const u8) ?PeerVariantSet {
    if (p.len < 2) return null;
    const n: usize = p[1];
    if (p.len < 2 + n) return null;
    return .{ .slot_idx = p[0], .variant = p[2 .. 2 + n] };
}

/// Task #34 — layout mirrors logPeerCapabilitiesSet exactly.
pub const PeerCapabilitiesSet = struct {
    slot_idx: u8,
    tier: u8,
    class: []const u8,
    provers: []const u8,
};
pub fn decodePeerCapabilitiesSet(p: []const u8) ?PeerCapabilitiesSet {
    if (p.len < 4) return null;
    const class_len: usize = std.mem.readInt(u16, p[2..4], .little);
    if (p.len < 4 + class_len + 2) return null;
    const p_off: usize = 4 + class_len;
    const provers_len: usize = std.mem.readInt(u16, p[p_off..][0..2], .little);
    if (p.len < p_off + 2 + provers_len) return null;
    return .{
        .slot_idx = p[0],
        .tier = p[1],
        .class = p[4 .. 4 + class_len],
        .provers = p[p_off + 2 .. p_off + 2 + provers_len],
    };
}

pub const PeerStatusSet = struct { slot_idx: u8, status: []const u8 };
pub fn decodePeerStatusSet(p: []const u8) ?PeerStatusSet {
    if (p.len < 3) return null;
    const n: usize = std.mem.readInt(u16, p[1..3], .little);
    if (p.len < 3 + n) return null;
    return .{ .slot_idx = p[0], .status = p[3 .. 3 + n] };
}

pub const InboxPush = struct { target_idx: u8, msg: []const u8 };
pub fn decodeInboxPush(p: []const u8) ?InboxPush {
    if (p.len < 3) return null;
    const n: usize = std.mem.readInt(u16, p[1..3], .little);
    if (p.len < 3 + n) return null;
    return .{ .target_idx = p[0], .msg = p[3 .. 3 + n] };
}

pub const ClaimAdd = struct { claim_idx: u8, holder_idx: u8, task: []const u8 };
pub fn decodeClaimAdd(p: []const u8) ?ClaimAdd {
    if (p.len < 3) return null;
    const n: usize = p[2];
    if (p.len < 3 + n) return null;
    return .{ .claim_idx = p[0], .holder_idx = p[1], .task = p[3 .. 3 + n] };
}

pub const ClaimProgress = struct { claim_idx: u8, timestamp_ms: u64 };
pub fn decodeClaimProgress(p: []const u8) ?ClaimProgress {
    if (p.len < 9) return null;
    return .{
        .claim_idx = p[0],
        .timestamp_ms = std.mem.readInt(u64, p[1..9], .little),
    };
}

pub const QuarAdd = struct {
    request_id: u32,
    sender_idx: u8,
    target_idx: i8,
    risk_tier: u8,
    msg: []const u8,
};
pub fn decodeQuarAdd(p: []const u8) ?QuarAdd {
    if (p.len < 9) return null;
    const n: usize = std.mem.readInt(u16, p[7..9], .little);
    if (p.len < 9 + n) return null;
    return .{
        .request_id = std.mem.readInt(u32, p[0..4], .little),
        .sender_idx = p[4],
        .target_idx = @bitCast(p[5]),
        .risk_tier = p[6],
        .msg = p[9 .. 9 + n],
    };
}

pub fn decodeRequestId(p: []const u8) ?u32 {
    if (p.len < 4) return null;
    return std.mem.readInt(u32, p[0..4], .little);
}

pub const QuarReject = struct { request_id: u32, reason: []const u8 };
pub fn decodeQuarReject(p: []const u8) ?QuarReject {
    if (p.len < 6) return null;
    const n: usize = std.mem.readInt(u16, p[4..6], .little);
    if (p.len < 6 + n) return null;
    return .{
        .request_id = std.mem.readInt(u32, p[0..4], .little),
        .reason = p[6 .. 6 + n],
    };
}

pub const Audit = struct { kind: u8, detail: []const u8 };
pub fn decodeAudit(p: []const u8) ?Audit {
    if (p.len < 3) return null;
    const n: usize = std.mem.readInt(u16, p[1..3], .little);
    if (p.len < 3 + n) return null;
    return .{ .kind = p[0], .detail = p[3 .. 3 + n] };
}

pub const TrackUpdate = struct {
    client_kind: u8,
    outcome: u8,
    risk_tier: u8,
    duration_ms: u32,
    timestamp_ms: u64,
    tag: []const u8,
    confidence_pct: u8, // 255 = unset (old event or never reported)
};
pub fn decodeTrackUpdate(p: []const u8) ?TrackUpdate {
    if (p.len < 16) return null;
    const n: usize = p[15];
    if (p.len < 16 + n) return null;
    const conf: u8 = if (p.len >= 17 + n) p[16 + n] else 255;
    return .{
        .client_kind = p[0],
        .outcome = p[1],
        .risk_tier = p[2],
        .duration_ms = std.mem.readInt(u32, p[3..7], .little),
        .timestamp_ms = std.mem.readInt(u64, p[7..15], .little),
        .tag = p[16 .. 16 + n],
        .confidence_pct = conf,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — round-trip append/replay through a temp file
// ═══════════════════════════════════════════════════════════════════════

// Replay tests capture events into these globals. Zig doesn't support
// closures in function pointers; a module-level capture is the simplest
// way to assert replayed state in tests.
var t_events: [64]EventType = undefined;
var t_payloads: [64][MAX_PAYLOAD]u8 = undefined;
var t_payload_lens: [64]usize = undefined;
var t_count: usize = 0;

fn tCapture(event: EventType, payload: []const u8) void {
    if (t_count >= t_events.len) return;
    t_events[t_count] = event;
    @memcpy(t_payloads[t_count][0..payload.len], payload);
    t_payload_lens[t_count] = payload.len;
    t_count += 1;
}

fn tReset() void {
    t_count = 0;
}

fn tTempDir(buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "/tmp/boj-coord-dur-test-{d}-{d}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

test "disabled when dir unset" {
    // Fresh state — no dir opened.
    close();
    try std.testing.expect(!isEnabled());
    // Append silently no-ops.
    logPeerRemove(3);
    try std.testing.expect(!isEnabled());
}

test "open creates dir and log file" {
    var buf: [256]u8 = undefined;
    const dir = try tTempDir(&buf);
    defer std.fs.cwd().deleteTree(dir) catch {};
    close();

    try std.testing.expect(openWithDir(dir));
    try std.testing.expect(isEnabled());
    close();
    try std.testing.expect(!isEnabled());
}

test "append and replay round-trip peer add" {
    var buf: [256]u8 = undefined;
    const dir = try tTempDir(&buf);
    defer std.fs.cwd().deleteTree(dir) catch {};
    close();

    try std.testing.expect(openWithDir(dir));
    const suffix = [4]u8{ '7', 'f', '3', 'a' };
    const token = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    logPeerAdd(2, 0, 1, &suffix, &token);
    close();

    // Re-open and replay.
    try std.testing.expect(openWithDir(dir));
    tReset();
    replay(tCapture);
    close();

    try std.testing.expectEqual(@as(usize, 1), t_count);
    try std.testing.expectEqual(EventType.peer_add, t_events[0]);

    const decoded = decodePeerAdd(t_payloads[0][0..t_payload_lens[0]]) orelse return error.DecodeFailed;
    try std.testing.expectEqual(@as(u8, 2), decoded.slot_idx);
    try std.testing.expectEqual(@as(u8, 0), decoded.kind);
    try std.testing.expectEqual(@as(u8, 1), decoded.role);
    try std.testing.expectEqualSlices(u8, &suffix, &decoded.suffix);
    try std.testing.expectEqualSlices(u8, &token, &decoded.token);
}

test "replay stops at CRC corruption" {
    var buf: [256]u8 = undefined;
    const dir = try tTempDir(&buf);
    defer std.fs.cwd().deleteTree(dir) catch {};
    close();

    try std.testing.expect(openWithDir(dir));
    logPeerRemove(1);
    logPeerRemove(2);
    logPeerRemove(3);
    close();

    // Corrupt the tail by overwriting the last CRC byte.
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/coord.log", .{dir});
    const f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer f.close();
    const size = try f.getEndPos();
    try f.seekTo(size - 1);
    _ = try f.write(&[_]u8{0xFF});

    // Replay should recover the first two records, stop at the corrupt tail.
    try std.testing.expect(openWithDir(dir));
    tReset();
    replay(tCapture);
    close();

    try std.testing.expectEqual(@as(usize, 2), t_count);
}

test "replay decodes every event type" {
    var buf: [256]u8 = undefined;
    const dir = try tTempDir(&buf);
    defer std.fs.cwd().deleteTree(dir) catch {};
    close();

    try std.testing.expect(openWithDir(dir));
    const suffix = [4]u8{ 'a', 'b', 'c', 'd' };
    const token = [_]u8{0} ** 16;

    logPeerAdd(0, 0, 1, &suffix, &token);
    logPeerRoleSet(0, 2);
    logPeerContextSet(0, "007-lang");
    logPeerStatusSet(0, "auditing proofs");
    logInboxPush(1, "hello");
    logInboxPop(1);
    logClaimAdd(3, 0, "fix-ci");
    logClaimRel(3);
    logQuarAdd(42, 0, 1, 3, "proposed-push");
    logQuarApprove(42);
    logQuarReject(43, "confabulated path");
    logAudit(1, "tier3-from-supervised");
    logTrackUpdate(0, 1, 2, 1234, 1_700_000_000_000, "proof-analysis", 85);
    logPeerRemove(0);
    close();

    try std.testing.expect(openWithDir(dir));
    tReset();
    replay(tCapture);
    close();

    try std.testing.expectEqual(@as(usize, 14), t_count);

    // Spot-check a few decoders.
    try std.testing.expectEqual(EventType.peer_add, t_events[0]);
    try std.testing.expectEqual(EventType.inbox_push, t_events[4]);
    const push = decodeInboxPush(t_payloads[4][0..t_payload_lens[4]]) orelse return error.DecodeFailed;
    try std.testing.expectEqual(@as(u8, 1), push.target_idx);
    try std.testing.expectEqualSlices(u8, "hello", push.msg);

    try std.testing.expectEqual(EventType.quar_reject, t_events[10]);
    const rej = decodeQuarReject(t_payloads[10][0..t_payload_lens[10]]) orelse return error.DecodeFailed;
    try std.testing.expectEqual(@as(u32, 43), rej.request_id);
    try std.testing.expectEqualSlices(u8, "confabulated path", rej.reason);

    try std.testing.expectEqual(EventType.track_update, t_events[12]);
    const tr = decodeTrackUpdate(t_payloads[12][0..t_payload_lens[12]]) orelse return error.DecodeFailed;
    try std.testing.expectEqual(@as(u8, 0), tr.client_kind);
    try std.testing.expectEqual(@as(u8, 1), tr.outcome);
    try std.testing.expectEqual(@as(u8, 2), tr.risk_tier);
    try std.testing.expectEqual(@as(u32, 1234), tr.duration_ms);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000), tr.timestamp_ms);
    try std.testing.expectEqualSlices(u8, "proof-analysis", tr.tag);
    try std.testing.expectEqual(@as(u8, 85), tr.confidence_pct);
}
