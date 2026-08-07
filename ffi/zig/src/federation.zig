// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Federation FFI — Umoja gossip protocol runtime.
//
// Implements the node handshake, heartbeat, and gossip protocol for BoJ
// federation. Tracks up to 16 peer nodes with status, heartbeat timestamps,
// catalogue hash state for sync detection, and a full gossip protocol for
// anti-entropy catalogue synchronisation across federated instances.
//
// The gossip protocol follows a SWIM-inspired model:
//   alive -> suspected (missed heartbeats) -> dead (confirmed failure)
//
// The Umoja layer adds:
//   - Peer discovery (simulated for now, real UDP broadcast interface ready)
//   - Anti-entropy gossip rounds (digest exchange via SHA-256)
//   - Node handshake with attestation (pending -> exchanged -> verified | rejected)
//
// "Umoja" means "unity" in Swahili — fitting for a federation layer.

const std = @import("std");

// `std.atomic.Mutex` was removed from the standard library; its replacement is
// `shim.Mutex`, whose lock/unlock surface is identical to the hand-rolled
// wrapper this replaces. The wrapper also busy-waited via `spinLoopHint`, burning
// a core under contention; `shim.Mutex` parks the thread instead. 81 other
// files in this repo already use this form.
const Mutex = shim.Mutex;

// `std.net` was removed in Zig 0.16; the networking surface now lives behind
// the `std.Io` interface as `std.Io.net`. The raw socket calls this file used
// (`std.posix.socket`/`bind`/`sendto`/`recvfrom`/`close`) were trimmed from
// the posix surface at the same time — `std.Io.net.Socket` replaces all five.
// Every call site below takes its `std.Io` from `shim.io()`, the process-wide
// `std.Io.Threaded` this repo already uses for the clock, mutexes, and CSPRNG.
const net = std.Io.net;

// Non-blocking receive. `std.posix.recvfrom(..., MSG.DONTWAIT, ...)` is gone;
// `Socket.receiveTimeout` with a zero duration is the exact equivalent, because
// `std.Io.Threaded` issues `recvmsg(2)` with `MSG_DONTWAIT` first and only then
// falls back to `poll(2)` for the remainder of the timeout — which here is
// nothing. The "no packet queued" signal is renamed from `error.WouldBlock` to
// `error.Timeout`; both map to the same `0` return, so callers see no change.
const RECV_NONBLOCKING: std.Io.Timeout = .{
    .duration = .{ .raw = .zero, .clock = .awake },
};

// ═══════════════════════════════════════════════════════════════════════
// Proven-hardened: Circuit breaker, retry, and rate limiter state
//
// These integrate with the formally verified Idris2 SafeCircuitBreaker,
// SafeRetry, and SafeRateLimiter modules from the proven repo. The Zig
// implementation mirrors the proven state machines for runtime use,
// while the Idris2 proofs guarantee correctness of the transition logic.
// ═══════════════════════════════════════════════════════════════════════

/// Per-peer circuit breaker state (mirrors Proven.SafeCircuitBreaker).
/// Prevents cascading failures by stopping sends to unresponsive peers.
const PeerCircuitBreaker = struct {
    /// Closed=0 (normal), Open=1 (failing), HalfOpen=2 (testing)
    state: u8 = 0,
    consecutive_failures: u32 = 0,
    consecutive_successes: u32 = 0,
    last_failure_time: i64 = 0,
    half_open_calls: u32 = 0,

    // Configuration (matches proven defaults)
    const FAILURE_THRESHOLD: u32 = 5;
    const SUCCESS_THRESHOLD: u32 = 2;
    const TIMEOUT_SECS: i64 = 30;
    const HALF_OPEN_MAX: u32 = 3;

    /// Check if a send is allowed through the circuit breaker.
    fn canExecute(self: *const PeerCircuitBreaker, now: i64) bool {
        return switch (self.state) {
            0 => true, // Closed: allow
            1 => { // Open: check timeout for half-open transition
                return now >= self.last_failure_time + TIMEOUT_SECS;
            },
            2 => self.half_open_calls < HALF_OPEN_MAX, // HalfOpen: limited
            else => false,
        };
    }

    /// Record a successful send. May transition HalfOpen→Closed.
    fn recordSuccess(self: *PeerCircuitBreaker) void {
        switch (self.state) {
            0 => { // Closed: reset failure count
                self.consecutive_failures = 0;
            },
            2 => { // HalfOpen: count successes toward closing
                self.consecutive_successes += 1;
                if (self.consecutive_successes >= SUCCESS_THRESHOLD) {
                    self.state = 0; // → Closed
                    self.consecutive_failures = 0;
                    self.consecutive_successes = 0;
                    self.half_open_calls = 0;
                }
            },
            else => {},
        }
    }

    /// Record a failed send. May transition Closed→Open or HalfOpen→Open.
    fn recordFailure(self: *PeerCircuitBreaker, now: i64) void {
        self.consecutive_failures += 1;
        self.last_failure_time = now;
        switch (self.state) {
            0 => { // Closed: check threshold
                if (self.consecutive_failures >= FAILURE_THRESHOLD) {
                    self.state = 1; // → Open
                    self.consecutive_successes = 0;
                }
            },
            2 => { // HalfOpen: any failure reopens
                self.state = 1; // → Open
                self.consecutive_successes = 0;
                self.half_open_calls = 0;
            },
            else => {},
        }
    }

    /// Attempt to transition Open→HalfOpen if timeout elapsed.
    fn maybeTransition(self: *PeerCircuitBreaker, now: i64) void {
        if (self.state == 1 and now >= self.last_failure_time + TIMEOUT_SECS) {
            self.state = 2; // → HalfOpen
            self.consecutive_successes = 0;
            self.half_open_calls = 0;
        }
    }

    /// Record an attempt in half-open state.
    fn recordAttempt(self: *PeerCircuitBreaker) void {
        if (self.state == 2) {
            self.half_open_calls += 1;
        }
    }

    /// Reset to initial state.
    fn reset(self: *PeerCircuitBreaker) void {
        self.* = PeerCircuitBreaker{};
    }
};

/// Per-peer retry state (mirrors Proven.SafeRetry).
/// Implements jittered exponential backoff for transient failures.
const PeerRetryState = struct {
    attempt: u32 = 0,
    total_delay_ms: u64 = 0,
    last_retry_time: i64 = 0,

    const MAX_ATTEMPTS: u32 = 3;
    const INITIAL_DELAY_MS: u64 = 100;
    const MULTIPLIER: u64 = 2;
    const MAX_DELAY_MS: u64 = 30_000;

    /// Calculate delay for current attempt using exponential backoff.
    fn calculateDelay(self: *const PeerRetryState) u64 {
        var delay = INITIAL_DELAY_MS;
        var i: u32 = 0;
        while (i < self.attempt) : (i += 1) {
            delay *|= MULTIPLIER; // saturating multiply
            if (delay > MAX_DELAY_MS) {
                delay = MAX_DELAY_MS;
                break;
            }
        }
        return delay;
    }

    /// Check if more retries are available.
    fn canRetry(self: *const PeerRetryState) bool {
        return self.attempt < MAX_ATTEMPTS;
    }

    /// Advance to next attempt.
    fn nextAttempt(self: *PeerRetryState, now: i64) void {
        self.attempt += 1;
        self.last_retry_time = now;
        self.total_delay_ms += self.calculateDelay();
    }

    /// Reset after success or circuit break.
    fn reset(self: *PeerRetryState) void {
        self.* = PeerRetryState{};
    }
};

/// Incoming packet rate limiter (mirrors Proven.SafeRateLimiter token bucket).
/// Prevents flood attacks from consuming all processing capacity.
const InboundRateLimiter = struct {
    tokens: u32 = CAPACITY,
    last_refill_time: i64 = 0,

    const CAPACITY: u32 = 200; // Max burst
    const REFILL_RATE: u32 = 50; // Tokens per second

    /// Try to acquire one token. Returns true if allowed.
    fn tryAcquire(self: *InboundRateLimiter, now: i64) bool {
        // Refill based on elapsed time.
        if (now > self.last_refill_time) {
            const elapsed: u32 = @intCast(@min(now - self.last_refill_time, 60));
            const new_tokens = REFILL_RATE * elapsed;
            self.tokens = @min(CAPACITY, self.tokens + new_tokens);
            self.last_refill_time = now;
        }
        if (self.tokens > 0) {
            self.tokens -= 1;
            return true;
        }
        return false;
    }

    fn reset(self: *InboundRateLimiter) void {
        self.* = InboundRateLimiter{};
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

/// Maximum number of nodes in the federation ring.
const MAX_NODES: usize = 16;

/// Maximum length of a node identifier.
const MAX_NODE_ID_LEN: usize = 64;

/// Maximum length of a region tag.
const MAX_REGION_LEN: usize = 32;

/// Maximum length of a catalogue hash.
const MAX_HASH_LEN: usize = 64;

/// Maximum length of a host string for peer nodes.
const MAX_HOST_LEN: usize = 256;

/// Maximum number of peers in the Umoja gossip layer.
const MAX_PEERS: usize = 16;

/// SHA-256 digest length in bytes.
const DIGEST_LEN: usize = 32;

/// Maximum number of cartridge entries used for digest computation.
const MAX_DIGEST_ENTRIES: usize = 128;

/// Maximum length of a single cartridge digest entry string.
const MAX_ENTRY_LEN: usize = 160;

/// Default federation port for UDP communication.
const DEFAULT_PORT: u16 = 9999;

/// Multicast group for peer discovery (link-local, site-scoped).
/// ff02::b04 = "boj" on link-local scope.
const MULTICAST_GROUP: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0b, 0x04 };

/// Maximum size of a UDP packet payload.
const MAX_PACKET_LEN: usize = 1024;

/// Discovery window: how many recv attempts before returning (non-blocking).
const DISCOVERY_RECV_ATTEMPTS: usize = 32;

/// Packet tag bytes for the wire protocol.
const PKT_DISCOVER: u8 = 0x01;
const PKT_DISCOVER_REPLY: u8 = 0x02;
const PKT_GOSSIP_DIGEST: u8 = 0x03;
const PKT_GOSSIP_DIGEST_REPLY: u8 = 0x04;
const PKT_HANDSHAKE_INIT: u8 = 0x05;
const PKT_HANDSHAKE_REPLY: u8 = 0x06;
const PKT_HEARTBEAT: u8 = 0x07;

// ═══════════════════════════════════════════════════════════════════════
// Types — Federation node registry (original SWIM layer)
// ═══════════════════════════════════════════════════════════════════════

/// Node liveness status (SWIM-style protocol states).
pub const NodeStatus = enum(c_int) {
    unknown = 0,
    alive = 1,
    suspected = 2,
    dead = 3,
};

/// A federation peer node entry (original registry).
pub const FederationNode = struct {
    /// Unique node identifier (e.g. hostname, UUID).
    node_id: [MAX_NODE_ID_LEN]u8 = [_]u8{0} ** MAX_NODE_ID_LEN,
    node_id_len: usize = 0,

    /// Geographic or logical region tag.
    region: [MAX_REGION_LEN]u8 = [_]u8{0} ** MAX_REGION_LEN,
    region_len: usize = 0,

    /// Unix timestamp of last heartbeat received.
    last_heartbeat: i64 = 0,

    /// Current liveness status.
    status: NodeStatus = .unknown,

    /// Hash of the node's catalogue state (for sync checks).
    catalogue_hash: [MAX_HASH_LEN]u8 = [_]u8{0} ** MAX_HASH_LEN,
    catalogue_hash_len: usize = 0,

    /// Whether this slot is occupied.
    active: bool = false,
};

// ═══════════════════════════════════════════════════════════════════════
// Types — Umoja gossip protocol layer
// ═══════════════════════════════════════════════════════════════════════

/// Handshake state for peer attestation.
pub const HandshakeState = enum(c_int) {
    none = 0,
    pending = 1,
    exchanged = 2,
    verified = 3,
    rejected = 4,
};

/// A peer node in the Umoja gossip layer.
/// Extends the federation node concept with networking and handshake state.
pub const PeerNode = struct {
    /// Host address (IP or hostname).
    host: [MAX_HOST_LEN]u8 = [_]u8{0} ** MAX_HOST_LEN,
    host_len: usize = 0,

    /// Port number.
    port: u16 = 0,

    /// Node identifier (set during handshake).
    node_id: [MAX_NODE_ID_LEN]u8 = [_]u8{0} ** MAX_NODE_ID_LEN,
    node_id_len: usize = 0,

    /// Unix timestamp of last activity.
    last_seen: i64 = 0,

    /// Handshake / attestation state.
    handshake_state: HandshakeState = .none,

    /// Catalogue digest received from this peer (SHA-256).
    catalogue_digest: [DIGEST_LEN]u8 = [_]u8{0} ** DIGEST_LEN,
    has_digest: bool = false,

    /// Whether this peer slot is occupied.
    active: bool = false,
};

// ═══════════════════════════════════════════════════════════════════════
// Global state (module-level, C-ABI safe)
// ═══════════════════════════════════════════════════════════════════════

/// The federation node registry (original SWIM layer).
var nodes: [MAX_NODES]FederationNode = [_]FederationNode{FederationNode{}} ** MAX_NODES;

/// Number of registered nodes.
var node_count: usize = 0;

/// The Umoja peer registry (gossip layer).
var peers: [MAX_PEERS]PeerNode = [_]PeerNode{PeerNode{}} ** MAX_PEERS;

/// Number of active peers.
var peer_count: usize = 0;

/// Local catalogue digest (SHA-256 of sorted cartridge names+versions+hashes).
var local_digest: [DIGEST_LEN]u8 = [_]u8{0} ** DIGEST_LEN;

/// Whether the local digest has been computed at least once.
var local_digest_valid: bool = false;

/// Counter for gossip rounds completed (for testing/metrics).
var gossip_round_count: usize = 0;

/// Our local node identifier (set by umoja_set_node_id).
var local_node_id: [MAX_NODE_ID_LEN]u8 = [_]u8{0} ** MAX_NODE_ID_LEN;
var local_node_id_len: usize = 0;

/// Our listen port (set by umoja_bind).
var local_port: u16 = 0;

/// UDP socket. `null` means not bound. (Was a bare `std.posix.socket_t` fd
/// sentinelled with -1; `std.Io.net.Socket` carries the handle plus the
/// resolved bound address, and has no spare sentinel value.)
var udp_socket: ?net.Socket = null;

/// Whether the UDP socket is bound and ready.
var socket_bound: bool = false;

/// Last error code from a network operation (for diagnostics).
var last_net_error: c_int = 0;

/// Statistics: packets sent and received.
var packets_sent: usize = 0;
var packets_received: usize = 0;

/// Packets dropped by rate limiter (for diagnostics).
var packets_rate_limited: usize = 0;

/// Per-peer circuit breaker state (proven-hardened).
/// Prevents cascading failures when peers become unresponsive.
var peer_circuit_breakers: [MAX_PEERS]PeerCircuitBreaker = [_]PeerCircuitBreaker{PeerCircuitBreaker{}} ** MAX_PEERS;

/// Per-peer retry state (proven-hardened).
var peer_retry_state: [MAX_PEERS]PeerRetryState = [_]PeerRetryState{PeerRetryState{}} ** MAX_PEERS;

/// Inbound packet rate limiter (proven-hardened).
/// Single limiter for the whole federation socket.
var inbound_rate_limiter: InboundRateLimiter = InboundRateLimiter{};

/// Thread-safety mutex for all C-ABI exported functions.
/// Protects all module-level global state (including QUIC globals declared
/// below near the QUIC transport section: transport_mode, quic_sessions,
/// quic_local_secret, quic_local_public, quic_keypair_valid).
var mutex: Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot index is in-bounds and active (federation registry).
fn validSlot(index: usize) bool {
    return index < MAX_NODES and nodes[index].active;
}

/// Validate that a peer index is in-bounds and active (Umoja layer).
fn validPeer(index: usize) bool {
    return index < MAX_PEERS and peers[index].active;
}

/// Copy a bounded byte slice into a fixed buffer. Returns actual length copied.
fn copyBounded(dst: []u8, src_ptr: [*]const u8, src_len: usize) usize {
    const len = @min(src_len, dst.len);
    @memcpy(dst[0..len], src_ptr[0..len]);
    return len;
}

/// PRNG for peer selection during gossip rounds.
/// HARDENED: Uses OS cryptographic randomness instead of predictable xorshift.
/// The old xorshift was seeded from timestamp, making peer selection predictable
/// to an attacker who knew the approximate startup time. This matters because
/// gossip peer selection influences which nodes converge first.
fn prngNext() u32 {
    var buf: [4]u8 = undefined;
    shim.randomBytes(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

/// Pick a random active peer index. Returns null if no peers exist.
fn pickRandomPeer() ?usize {
    if (peer_count == 0) return null;

    // Collect active indices.
    var active_indices: [MAX_PEERS]usize = undefined;
    var active_count: usize = 0;
    for (0..MAX_PEERS) |i| {
        if (peers[i].active) {
            active_indices[active_count] = i;
            active_count += 1;
        }
    }
    if (active_count == 0) return null;

    const idx = prngNext() % @as(u32, @intCast(active_count));
    return active_indices[@as(usize, idx)];
}

// ═══════════════════════════════════════════════════════════════════════
// Internal helpers — UDP networking
// ═══════════════════════════════════════════════════════════════════════

/// Build a packet with tag + node_id + payload into the provided buffer.
/// Format: [tag:1][id_len:2 LE][id:N][payload_len:2 LE][payload:M]
/// Returns total length, or 0 on overflow.
fn buildPacket(
    buf: []u8,
    tag: u8,
    payload: ?[]const u8,
) usize {
    const id_len = local_node_id_len;
    const pay_len: usize = if (payload) |p| p.len else 0;
    const total = 1 + 2 + id_len + 2 + pay_len;
    if (total > buf.len) return 0;

    buf[0] = tag;
    buf[1] = @truncate(id_len & 0xFF);
    buf[2] = @truncate((id_len >> 8) & 0xFF);
    if (id_len > 0) {
        @memcpy(buf[3 .. 3 + id_len], local_node_id[0..id_len]);
    }
    const pay_off = 3 + id_len;
    buf[pay_off] = @truncate(pay_len & 0xFF);
    buf[pay_off + 1] = @truncate((pay_len >> 8) & 0xFF);
    if (payload) |p| {
        if (p.len > 0) {
            @memcpy(buf[pay_off + 2 .. pay_off + 2 + p.len], p);
        }
    }
    return total;
}

/// Parse a received packet. Returns tag, node_id slice, and payload slice.
/// Returns null on malformed packets.
const ParsedPacket = struct {
    tag: u8,
    node_id: []const u8,
    payload: []const u8,
};

fn parsePacket(buf: []const u8) ?ParsedPacket {
    if (buf.len < 5) return null; // minimum: tag + id_len(2) + pay_len(2)

    const tag = buf[0];
    const id_len: usize = @as(usize, buf[1]) | (@as(usize, buf[2]) << 8);
    if (3 + id_len + 2 > buf.len) return null;

    const pay_off = 3 + id_len;
    const pay_len: usize = @as(usize, buf[pay_off]) | (@as(usize, buf[pay_off + 1]) << 8);
    if (pay_off + 2 + pay_len > buf.len) return null;

    return ParsedPacket{
        .tag = tag,
        .node_id = buf[3 .. 3 + id_len],
        .payload = buf[pay_off + 2 .. pay_off + 2 + pay_len],
    };
}

/// Send a UDP packet to a peer by index.
/// HARDENED: Wrapped with per-peer circuit breaker (proven SafeCircuitBreaker).
/// The circuit breaker prevents flooding unresponsive peers, which would waste
/// bandwidth and cause backpressure on the gossip loop.
/// Returns 0 on success, -1 on error, -2 if circuit is open.
fn sendToPeer(peer_idx: usize, buf: []const u8) c_int {
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;
    if (peer_idx >= MAX_PEERS) return -1;

    const now = shim.timestamp();
    var cb = &peer_circuit_breakers[peer_idx];

    // Circuit breaker gate: check if sends are allowed to this peer.
    cb.maybeTransition(now);
    if (!cb.canExecute(now)) {
        return -2; // Circuit open — peer presumed down.
    }
    cb.recordAttempt();

    // Actual send.
    const result = sendToPeerUnchecked(peer_idx, buf);
    if (result == 0) {
        cb.recordSuccess();
        peer_retry_state[peer_idx].reset();
    } else {
        cb.recordFailure(now);
    }
    return result;
}

/// Raw UDP send without circuit breaker (used internally).
fn sendToPeerUnchecked(peer_idx: usize, buf: []const u8) c_int {
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    const peer = &peers[peer_idx];

    // Parse IPv6 address from peer host string.
    const host_slice = peer.host[0..peer.host_len];
    const parsed = net.Ip6Address.parse(host_slice, peer.port) catch {
        last_net_error = -2;
        return -1;
    };
    const dest: net.IpAddress = .{ .ip6 = parsed };

    // `Socket.send` carries the destination address itself, so the hand-filled
    // `sockaddr.in6` (family/port/@ptrCast to `sockaddr`) that sendto(2)
    // required is gone; the address family and length are derived from the
    // `IpAddress` union tag.
    udp_socket.?.send(shim.io(), &dest, buf) catch {
        last_net_error = -3;
        return -1;
    };
    packets_sent += 1;
    return 0;
}

/// Try to receive one UDP packet (non-blocking).
/// Returns the number of bytes received, 0 if nothing available, or -1 on error.
/// Stores the sender's address in the provided address slot.
fn recvPacket(buf: []u8, src_addr: *net.Ip6Address) c_int {
    if (!socket_bound) return -1;

    const msg = udp_socket.?.receiveTimeout(shim.io(), buf, RECV_NONBLOCKING) catch |err| switch (err) {
        // Nothing queued. `MSG.DONTWAIT` used to surface this as
        // `error.WouldBlock`; the zero-duration timeout surfaces it here.
        error.Timeout => return 0,
        else => {
            last_net_error = -4;
            return -1;
        },
    };

    // `IncomingMessage.from` is an `IpAddress` union. `Ip6Address.fromAny`
    // re-maps an IPv4 sender into its IPv4-mapped IPv6 form, which is exactly
    // what the old dual-stack `recvfrom` wrote into the `sockaddr.in6` slot.
    src_addr.* = net.Ip6Address.fromAny(msg.from);

    packets_received += 1;
    return @intCast(msg.data.len);
}

/// Format an IPv6 address (16 bytes) into a human-readable string.
/// Uses compressed notation (e.g. "::1" for loopback).
fn formatIp6(raw: [16]u8, buf: []u8) usize {
    // Convert 16 bytes to 8 groups of 16-bit values.
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = (@as(u16, raw[i * 2]) << 8) | @as(u16, raw[i * 2 + 1]);
    }

    // Find longest run of zeros for "::" compression.
    var best_start: usize = 8;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    for (0..8) |i| {
        if (groups[i] == 0) {
            if (run_len == 0) run_start = i;
            run_len += 1;
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
        } else {
            run_len = 0;
        }
    }
    if (best_len < 2) {
        best_start = 8; // don't compress single zeros
        best_len = 0;
    }

    var pos: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (i == best_start) {
            if (i == 0) {
                if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
            }
            if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
            i += best_len;
            continue;
        }
        if (i > 0 and i != best_start + best_len) {
            // Need separator only if we didn't just emit "::"
            if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
        } else if (i == best_start + best_len and i > 0) {
            // After "::", no extra colon needed — already have trailing ':'
        }
        // Write group as hex without leading zeros.
        const val = groups[i];
        const hex_str = std.fmt.bufPrint(buf[pos..], "{x}", .{val}) catch return pos;
        pos += hex_str.len;
        i += 1;
    }
    return pos;
}

/// Find or add a peer by IPv6 address and port. Returns peer index.
fn findOrAddPeerByAddr(addr: *const net.Ip6Address) c_int {
    // Format the raw IPv6 address bytes as a string. `Ip6Address.bytes` is the
    // same big-endian [16]u8 the old `sockaddr.in6.addr` held, but `.port` is
    // already native-endian, so the `bigToNative` conversion is gone.
    var addr_buf: [46]u8 = undefined;
    const host_len = formatIp6(addr.bytes, &addr_buf);
    const port = addr.port;

    if (host_len == 0 or host_len > MAX_HOST_LEN) return -1;

    return umoja_add_peer_impl(addr_buf[0..host_len].ptr, host_len, port);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja UDP socket lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Set the local node identifier used in all outgoing packets.
/// Must be called before umoja_bind(). Returns 0 on success, -1 on error.
pub export fn umoja_set_node_id(
    id_ptr: [*]const u8,
    id_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (id_len == 0 or id_len > MAX_NODE_ID_LEN) return -1;
    local_node_id_len = copyBounded(&local_node_id, id_ptr, id_len);
    return 0;
}

/// Internal bind logic (caller must hold mutex).
fn umoja_bind_impl(port: u16) c_int {
    if (socket_bound) return -1; // already bound
    if (port == 0) return -1;

    // Bind to [::]:port. `IpAddress.bind` fuses the old socket(2)+bind(2)
    // pair into one call, so the two failures can no longer be reported
    // separately by construction — the error set is split back out below to
    // keep the -10 (socket creation) / -11 (bind) diagnostic codes meaningful.
    // `ip6_only = false` is the default and preserves the dual-stack
    // behaviour the old bare AF_INET6 socket had.
    //
    // The best-effort `SO_REUSEADDR` that used to sit between socket(2) and
    // bind(2) is dropped: `BindOptions` exposes no such knob and the option is
    // only meaningful *before* bind, so there is no longer a window in which to
    // set it. For a unicast UDP socket its practical effect was nil (there is
    // no TIME_WAIT for UDP, and sharing a port needs SO_REUSEPORT).
    const bind_addr: net.IpAddress = .{ .ip6 = .unspecified(port) };
    const sock = bind_addr.bind(shim.io(), .{ .mode = .dgram, .ip6_only = false }) catch |err| switch (err) {
        error.AddressInUse,
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        => {
            last_net_error = -11;
            return -1;
        },
        else => {
            last_net_error = -10;
            return -1;
        },
    };

    // Set non-blocking via ioctl FIONBIO. Receives already pass MSG_DONTWAIT
    // (see RECV_NONBLOCKING), but this keeps sends non-blocking too, exactly
    // as before.
    const fionbio: c_int = 1;
    const FIONBIO: u32 = 0x5421;
    const ioctl_result = std.posix.system.ioctl(sock.handle, FIONBIO, @intFromPtr(&fionbio));
    if (ioctl_result != 0) {
        sock.close(shim.io());
        last_net_error = -12;
        return -1;
    }

    udp_socket = sock;
    local_port = port;
    socket_bound = true;
    return 0;
}

/// Bind a UDP socket to the given port for federation communication.
/// Uses IPv6 dual-stack (receives both IPv4-mapped and IPv6).
/// Returns 0 on success, -1 on error.
pub export fn umoja_bind(port: u16) c_int {
    mutex.lock();
    defer mutex.unlock();
    return umoja_bind_impl(port);
}

/// Internal unbind logic (caller must hold mutex).
fn umoja_unbind_impl() c_int {
    if (!socket_bound) return -1;

    // `std.posix.close` was trimmed; `Socket.close` is the replacement and
    // takes the same `std.Io` as every other call site here.
    udp_socket.?.close(shim.io());
    udp_socket = null;
    local_port = 0;
    socket_bound = false;
    packets_sent = 0;
    packets_received = 0;
    last_net_error = 0;
    return 0;
}

/// Close the UDP socket and reset networking state.
/// Returns 0 on success, -1 if not bound.
pub export fn umoja_unbind() c_int {
    mutex.lock();
    defer mutex.unlock();
    return umoja_unbind_impl();
}

/// Return 1 if the UDP socket is bound, 0 otherwise.
pub export fn umoja_is_bound() c_int {
    mutex.lock();
    defer mutex.unlock();
    return if (socket_bound) 1 else 0;
}

/// Return the last network error code (for diagnostics).
pub export fn umoja_last_net_error() c_int {
    mutex.lock();
    defer mutex.unlock();
    return last_net_error;
}

/// Return the number of packets sent since bind.
pub export fn umoja_packets_sent() usize {
    mutex.lock();
    defer mutex.unlock();
    return packets_sent;
}

/// Return the number of packets received since bind.
pub export fn umoja_packets_received() usize {
    mutex.lock();
    defer mutex.unlock();
    return packets_received;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja real UDP gossip
// ═══════════════════════════════════════════════════════════════════════

/// Send a gossip digest to a specific peer over UDP.
/// Sends our local catalogue digest in a GOSSIP_DIGEST packet.
/// Returns 0 on success, -1 on error.
pub export fn umoja_send_digest(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;
    if (!local_digest_valid) return -1;
    if (!validPeer(peer_idx)) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_GOSSIP_DIGEST, &local_digest);
    if (pkt_len == 0) return -1;

    return sendToPeer(peer_idx, buf[0..pkt_len]);
}

/// Send a handshake initiation packet to a peer.
/// Returns 0 on success, -1 on error.
pub export fn umoja_send_handshake(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_HANDSHAKE_INIT, null);
    if (pkt_len == 0) return -1;

    const result = sendToPeer(peer_idx, buf[0..pkt_len]);
    if (result == 0) {
        peers[peer_idx].handshake_state = .pending;
        peers[peer_idx].last_seen = shim.timestamp();
    }
    return result;
}

/// Send a heartbeat packet to a peer.
/// Returns 0 on success, -1 on error.
pub export fn umoja_send_heartbeat(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_HEARTBEAT, null);
    if (pkt_len == 0) return -1;

    return sendToPeer(peer_idx, buf[0..pkt_len]);
}

/// Process one incoming UDP packet (non-blocking).
/// Reads one packet from the socket and handles it according to tag:
///   - DISCOVER: adds sender as peer, sends DISCOVER_REPLY
///   - DISCOVER_REPLY: adds sender as peer
///   - GOSSIP_DIGEST: stores digest, sends our digest back
///   - GOSSIP_DIGEST_REPLY: stores digest
///   - HANDSHAKE_INIT: transitions to pending, sends reply
///   - HANDSHAKE_REPLY: transitions to exchanged
///   - HEARTBEAT: updates last_seen
///
/// Internal recv-and-process logic (caller must hold mutex).
/// HARDENED: Rate-limited to prevent flood attacks (proven SafeRateLimiter).
fn umoja_recv_and_process_impl() c_int {
    if (!socket_bound) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    var src_addr: net.Ip6Address = .unspecified(0);

    const n = recvPacket(&buf, &src_addr);
    if (n <= 0) return n; // 0 = no data, -1 = error

    // Rate limiter gate: drop packets if bucket exhausted.
    const now = shim.timestamp();
    if (!inbound_rate_limiter.tryAcquire(now)) {
        packets_rate_limited += 1;
        return 0; // Silently drop — return 0 (no data) to caller.
    }

    const pkt = parsePacket(buf[0..@intCast(n)]) orelse return -1;

    // Find or create the peer entry for this sender.
    const peer_result = findOrAddPeerByAddr(&src_addr);
    if (peer_result < 0) return -1;
    const pidx: usize = @intCast(peer_result);

    // Store the sender's node_id if provided.
    if (pkt.node_id.len > 0 and pkt.node_id.len <= MAX_NODE_ID_LEN) {
        peers[pidx].node_id_len = copyBounded(&peers[pidx].node_id, pkt.node_id.ptr, pkt.node_id.len);
    }
    peers[pidx].last_seen = shim.timestamp();

    switch (pkt.tag) {
        PKT_DISCOVER => {
            // Reply with our identity so the sender knows we exist.
            var reply: [MAX_PACKET_LEN]u8 = undefined;
            const rlen = buildPacket(&reply, PKT_DISCOVER_REPLY, null);
            if (rlen > 0) {
                _ = sendToPeer(pidx, reply[0..rlen]);
            }
        },
        PKT_DISCOVER_REPLY => {
            // Peer already added by findOrAddPeerByAddr above.
        },
        PKT_GOSSIP_DIGEST => {
            // Store received digest.
            if (pkt.payload.len == DIGEST_LEN) {
                @memcpy(&peers[pidx].catalogue_digest, pkt.payload[0..DIGEST_LEN]);
                peers[pidx].has_digest = true;
            }
            // Send our digest back.
            if (local_digest_valid) {
                var reply: [MAX_PACKET_LEN]u8 = undefined;
                const rlen = buildPacket(&reply, PKT_GOSSIP_DIGEST_REPLY, &local_digest);
                if (rlen > 0) {
                    _ = sendToPeer(pidx, reply[0..rlen]);
                }
            }
            gossip_round_count += 1;
        },
        PKT_GOSSIP_DIGEST_REPLY => {
            // Store received digest.
            if (pkt.payload.len == DIGEST_LEN) {
                @memcpy(&peers[pidx].catalogue_digest, pkt.payload[0..DIGEST_LEN]);
                peers[pidx].has_digest = true;
            }
            gossip_round_count += 1;
        },
        PKT_HANDSHAKE_INIT => {
            peers[pidx].handshake_state = .pending;
            // Reply to complete handshake.
            var reply: [MAX_PACKET_LEN]u8 = undefined;
            const rlen = buildPacket(&reply, PKT_HANDSHAKE_REPLY, null);
            if (rlen > 0) {
                _ = sendToPeer(pidx, reply[0..rlen]);
            }
        },
        PKT_HANDSHAKE_REPLY => {
            if (peers[pidx].handshake_state == .pending) {
                peers[pidx].handshake_state = .exchanged;
            }
        },
        PKT_HEARTBEAT => {
            // last_seen already updated above.
        },
        else => {
            // Unknown tag — ignore.
        },
    }

    return @intCast(pkt.tag);
}

/// Returns the packet tag on success (>0), 0 if no packet available, -1 on error.
pub export fn umoja_recv_and_process() c_int {
    mutex.lock();
    defer mutex.unlock();
    return umoja_recv_and_process_impl();
}

/// Discover peers by sending a broadcast discovery packet to the given
/// target address (e.g. "ff02::b04" for multicast or "::1" for loopback testing).
/// Then processes up to DISCOVERY_RECV_ATTEMPTS incoming responses.
/// Returns the number of newly discovered peers (>= 0), or -1 on error.
pub export fn umoja_discover_udp(
    target_ptr: [*]const u8,
    target_len: usize,
    target_port: u16,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;
    if (target_len == 0 or target_len > MAX_HOST_LEN) return -1;

    // Build discovery packet.
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_DISCOVER, null);
    if (pkt_len == 0) return -1;

    // Parse target address.
    const target_slice = target_ptr[0..target_len];
    const parsed_ip6 = net.Ip6Address.parse(target_slice, target_port) catch {
        last_net_error = -20;
        return -1;
    };
    const dest: net.IpAddress = .{ .ip6 = parsed_ip6 };

    // Send discovery packet.
    udp_socket.?.send(shim.io(), &dest, buf[0..pkt_len]) catch {
        last_net_error = -21;
        return -1;
    };
    packets_sent += 1;

    // Collect responses (non-blocking).
    const before = peer_count;
    var attempts: usize = 0;
    while (attempts < DISCOVERY_RECV_ATTEMPTS) : (attempts += 1) {
        const tag = umoja_recv_and_process_impl();
        if (tag <= 0) break; // no more packets
    }

    const new_peers = peer_count - before;
    return @intCast(new_peers);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Federation node registry (original SWIM layer)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise (or reset) the federation registry and Umoja gossip state.
/// If a UDP socket is bound, it is closed first.
/// Returns 0 on success.
pub export fn boj_federation_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (socket_bound) _ = umoja_unbind_impl();
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    peers = [_]PeerNode{PeerNode{}} ** MAX_PEERS;
    peer_count = 0;
    local_digest = [_]u8{0} ** DIGEST_LEN;
    local_digest_valid = false;
    gossip_round_count = 0;
    local_node_id = [_]u8{0} ** MAX_NODE_ID_LEN;
    local_node_id_len = 0;
    local_port = 0;
    last_net_error = 0;
    packets_sent = 0;
    packets_received = 0;
    packets_rate_limited = 0;
    // Reset proven-hardened per-peer state.
    peer_circuit_breakers = [_]PeerCircuitBreaker{PeerCircuitBreaker{}} ** MAX_PEERS;
    peer_retry_state = [_]PeerRetryState{PeerRetryState{}} ** MAX_PEERS;
    inbound_rate_limiter.reset();
    transport_mode = .udp;
    resetQuicSessions();
    quic_keypair_valid = false;
    return 0;
}

/// Clean up the federation registry and Umoja gossip state.
pub export fn boj_federation_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    peers = [_]PeerNode{PeerNode{}} ** MAX_PEERS;
    peer_count = 0;
    local_digest = [_]u8{0} ** DIGEST_LEN;
    local_digest_valid = false;
    gossip_round_count = 0;
    transport_mode = .udp;
    resetQuicSessions();
}

/// Register a new peer node in the federation.
/// Returns the slot index on success, or -1 if the registry is full
/// or the input lengths exceed buffer limits.
pub export fn boj_federation_register_node(
    id_ptr: [*]const u8,
    id_len: usize,
    region_ptr: [*]const u8,
    region_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    // Validate input lengths.
    if (id_len == 0 or id_len > MAX_NODE_ID_LEN) return -1;
    if (region_len > MAX_REGION_LEN) return -1;

    // Find a free slot.
    if (node_count >= MAX_NODES) return -1;

    var slot: usize = 0;
    while (slot < MAX_NODES) : (slot += 1) {
        if (!nodes[slot].active) break;
    }
    if (slot >= MAX_NODES) return -1;

    // Populate the slot.
    nodes[slot] = FederationNode{};
    nodes[slot].node_id_len = copyBounded(&nodes[slot].node_id, id_ptr, id_len);
    nodes[slot].region_len = copyBounded(&nodes[slot].region, region_ptr, region_len);
    nodes[slot].status = .unknown;
    nodes[slot].active = true;

    node_count += 1;
    return @intCast(slot);
}

/// Record a heartbeat for the node at the given index.
/// Updates the timestamp and sets status to alive.
/// Returns 0 on success, -1 if the index is invalid.
pub export fn boj_federation_heartbeat(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(index)) return -1;

    nodes[index].last_heartbeat = shim.timestamp();
    nodes[index].status = .alive;
    return 0;
}

/// Mark a node as suspected (missed heartbeats).
/// Returns 0 on success, -1 if the index is invalid.
pub export fn boj_federation_suspect(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(index)) return -1;

    nodes[index].status = .suspected;
    return 0;
}

/// Declare a node dead (confirmed failure).
/// Returns 0 on success, -1 if the index is invalid.
pub export fn boj_federation_declare_dead(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(index)) return -1;

    nodes[index].status = .dead;
    return 0;
}

/// Return the number of registered (active) nodes.
pub export fn boj_federation_node_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return node_count;
}

/// Return the number of nodes with status == alive.
pub export fn boj_federation_alive_count() usize {
    mutex.lock();
    defer mutex.unlock();
    var count: usize = 0;
    for (&nodes) |*n| {
        if (n.active and n.status == .alive) count += 1;
    }
    return count;
}

/// Get the status of a node by index.
/// Returns the status integer (0-3), or -1 if the index is invalid.
pub export fn boj_federation_node_status(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(index)) return -1;

    return @intFromEnum(nodes[index].status);
}

/// Set the catalogue hash for a node (used for sync detection).
/// Returns 0 on success, -1 if the index or hash length is invalid.
pub export fn boj_federation_set_catalogue_hash(
    index: usize,
    hash_ptr: [*]const u8,
    hash_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(index)) return -1;
    if (hash_len == 0 or hash_len > MAX_HASH_LEN) return -1;

    nodes[index].catalogue_hash = [_]u8{0} ** MAX_HASH_LEN;
    nodes[index].catalogue_hash_len = copyBounded(
        &nodes[index].catalogue_hash,
        hash_ptr,
        hash_len,
    );
    return 0;
}

/// Check whether two nodes have matching catalogue hashes.
/// Returns 1 if synced (hashes match and both are non-empty),
/// 0 if not synced, or -1 if either index is invalid.
pub export fn boj_federation_check_sync(idx_a: usize, idx_b: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validSlot(idx_a) or !validSlot(idx_b)) return -1;

    const a = &nodes[idx_a];
    const b = &nodes[idx_b];

    // Both must have a hash set.
    if (a.catalogue_hash_len == 0 or b.catalogue_hash_len == 0) return 0;

    // Lengths must match.
    if (a.catalogue_hash_len != b.catalogue_hash_len) return 0;

    // Compare hash bytes.
    const len = a.catalogue_hash_len;
    if (std.mem.eql(u8, a.catalogue_hash[0..len], b.catalogue_hash[0..len])) {
        return 1;
    }
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja node discovery
// ═══════════════════════════════════════════════════════════════════════

/// Scan for peers (simulated: returns the current known peer count).
/// In a real implementation this would send a UDP broadcast on port 9999
/// and wait for responses. The simulated version simply returns the
/// number of peers already known, serving as the interface contract.
/// Returns the number of discovered peers (>= 0).
pub export fn umoja_discover_nodes() c_int {
    mutex.lock();
    defer mutex.unlock();
    // Simulated discovery: return current peer count.
    // Real implementation would:
    //   1. Bind UDP socket to 0.0.0.0:9999
    //   2. Send broadcast packet with our node_id
    //   3. Collect responses for a brief window
    //   4. Add any new peers via umoja_add_peer()
    return @intCast(peer_count);
}

/// Internal add-peer logic (caller must hold mutex).
fn umoja_add_peer_impl(
    host_ptr: [*]const u8,
    host_len: usize,
    port: u16,
) c_int {
    if (host_len == 0 or host_len > MAX_HOST_LEN) return -1;
    if (port == 0) return -1;
    if (peer_count >= MAX_PEERS) return -1;

    // Check for duplicates (same host + port).
    for (0..MAX_PEERS) |i| {
        if (peers[i].active and peers[i].host_len == host_len and peers[i].port == port) {
            if (std.mem.eql(u8, peers[i].host[0..host_len], host_ptr[0..host_len])) {
                // Already exists — return existing index.
                return @intCast(i);
            }
        }
    }

    // Find a free slot.
    var slot: usize = 0;
    while (slot < MAX_PEERS) : (slot += 1) {
        if (!peers[slot].active) break;
    }
    if (slot >= MAX_PEERS) return -1;

    peers[slot] = PeerNode{};
    peers[slot].host_len = copyBounded(&peers[slot].host, host_ptr, host_len);
    peers[slot].port = port;
    peers[slot].last_seen = shim.timestamp();
    peers[slot].active = true;

    peer_count += 1;
    return @intCast(slot);
}

/// Manually add a peer by host and port.
/// Returns the peer index on success, -1 if full or invalid input.
pub export fn umoja_add_peer(
    host_ptr: [*]const u8,
    host_len: usize,
    port: u16,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    return umoja_add_peer_impl(host_ptr, host_len, port);
}

/// Remove a peer by index.
/// Returns 0 on success, -1 if the index is invalid.
pub export fn umoja_remove_peer(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(index)) return -1;

    peers[index] = PeerNode{};
    peer_count -= 1;
    return 0;
}

/// Return the number of known peers.
pub export fn umoja_peer_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return peer_count;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja gossip protocol (anti-entropy)
// ═══════════════════════════════════════════════════════════════════════

/// Perform one round of gossip: pick a random peer and exchange digests.
/// Returns the index of the peer contacted, or -1 if no peers available.
///
/// In a real implementation this would:
///   1. Pick a random peer
///   2. Send our local digest to that peer
///   3. Receive their digest
///   4. Compare and trigger sync if different
///
/// The simulated version picks a random peer, marks it as seen,
/// and increments the gossip round counter.
pub export fn umoja_gossip_round() c_int {
    mutex.lock();
    defer mutex.unlock();
    const maybe_idx = pickRandomPeer();
    if (maybe_idx) |idx| {
        peers[idx].last_seen = shim.timestamp();
        gossip_round_count += 1;
        return @intCast(idx);
    }
    return -1;
}

/// Process an incoming digest from a peer.
/// Stores the peer's digest for later attestation verification.
/// Returns 0 on success, -1 if peer index is invalid or digest_len != 32.
pub export fn umoja_receive_digest(
    peer_idx: usize,
    digest_ptr: [*]const u8,
    digest_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;
    if (digest_len != DIGEST_LEN) return -1;

    @memcpy(&peers[peer_idx].catalogue_digest, digest_ptr[0..DIGEST_LEN]);
    peers[peer_idx].has_digest = true;
    peers[peer_idx].last_seen = shim.timestamp();
    return 0;
}

/// Get our current local catalogue digest (SHA-256).
/// Writes up to out_len bytes into out_ptr.
/// Returns the number of bytes written (32 on success, 0 if no digest computed).
pub export fn umoja_get_digest(out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!local_digest_valid) return 0;
    const write_len = @min(out_len, DIGEST_LEN);
    @memcpy(out_ptr[0..write_len], local_digest[0..write_len]);
    return write_len;
}

/// Compute the local catalogue digest from a list of cartridge entries.
/// Each entry is formatted as "name:version:hash" and sorted lexicographically
/// before hashing with SHA-256 to ensure deterministic output.
///
/// Takes parallel arrays of name/version/hash pointers+lengths and entry_count.
/// Returns 0 on success, -1 on invalid input.
pub export fn umoja_compute_digest(
    names_ptr: [*]const [*]const u8,
    names_len: [*]const usize,
    versions_ptr: [*]const [*]const u8,
    versions_len: [*]const usize,
    hashes_ptr: [*]const [*]const u8,
    hashes_len: [*]const usize,
    entry_count: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (entry_count == 0 or entry_count > MAX_DIGEST_ENTRIES) return -1;

    // Build formatted entry strings for sorting.
    var entries: [MAX_DIGEST_ENTRIES][MAX_ENTRY_LEN]u8 = undefined;
    var entry_lengths: [MAX_DIGEST_ENTRIES]usize = undefined;

    for (0..entry_count) |i| {
        const nlen = names_len[i];
        const vlen = versions_len[i];
        const hlen = hashes_len[i];

        // Validate individual lengths.
        if (nlen == 0 or nlen > 64) return -1;
        if (vlen == 0 or vlen > 16) return -1;
        if (hlen > 64) return -1;

        // Format: "name:version:hash"
        const total = nlen + 1 + vlen + 1 + hlen;
        if (total > MAX_ENTRY_LEN) return -1;

        var pos: usize = 0;
        @memcpy(entries[i][pos .. pos + nlen], names_ptr[i][0..nlen]);
        pos += nlen;
        entries[i][pos] = ':';
        pos += 1;
        @memcpy(entries[i][pos .. pos + vlen], versions_ptr[i][0..vlen]);
        pos += vlen;
        entries[i][pos] = ':';
        pos += 1;
        if (hlen > 0) {
            @memcpy(entries[i][pos .. pos + hlen], hashes_ptr[i][0..hlen]);
            pos += hlen;
        }
        entry_lengths[i] = pos;
    }

    // Sort entries lexicographically (insertion sort — max 128 entries).
    for (1..entry_count) |i| {
        const key_entry = entries[i];
        const key_len = entry_lengths[i];
        var j: usize = i;
        while (j > 0) {
            const prev_len = entry_lengths[j - 1];
            const min_len = @min(prev_len, key_len);
            const order = std.mem.order(u8, entries[j - 1][0..min_len], key_entry[0..min_len]);
            const should_swap = switch (order) {
                .gt => true,
                .eq => prev_len > key_len,
                .lt => false,
            };
            if (!should_swap) break;
            entries[j] = entries[j - 1];
            entry_lengths[j] = entry_lengths[j - 1];
            j -= 1;
        }
        entries[j] = key_entry;
        entry_lengths[j] = key_len;
    }

    // Hash the sorted concatenation with SHA-256.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..entry_count) |i| {
        hasher.update(entries[i][0..entry_lengths[i]]);
        hasher.update("\n");
    }
    local_digest = hasher.finalResult();
    local_digest_valid = true;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja handshake + attestation
// ═══════════════════════════════════════════════════════════════════════

/// Initiate a handshake with a peer.
/// Sets handshake state to 'pending', stores our node_id on the peer,
/// and marks the exchange timestamp.
/// Returns 0 on success, -1 if peer index invalid.
pub export fn umoja_handshake(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;

    peers[peer_idx].handshake_state = .pending;
    peers[peer_idx].last_seen = shim.timestamp();
    return 0;
}

/// Mark a handshake as exchanged (both sides have sent their info).
/// This is typically called after receiving the peer's handshake response.
/// Returns 0 on success, -1 if peer index invalid or not in pending state.
pub export fn umoja_handshake_exchanged(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;
    if (peers[peer_idx].handshake_state != .pending) return -1;

    peers[peer_idx].handshake_state = .exchanged;
    peers[peer_idx].last_seen = shim.timestamp();
    return 0;
}

/// Verify a peer's attestation: check that their catalogue digest matches
/// what we expect. If local_digest is valid and the peer has a digest,
/// compare them. Sets state to 'verified' on match, 'rejected' on mismatch.
/// Returns 1 if verified, 0 if rejected, -1 if peer invalid or no digests.
pub export fn umoja_verify_attestation(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;
    if (!local_digest_valid) return -1;
    if (!peers[peer_idx].has_digest) return -1;

    // Must be in exchanged state to verify.
    if (peers[peer_idx].handshake_state != .exchanged) return -1;

    if (std.mem.eql(u8, &peers[peer_idx].catalogue_digest, &local_digest)) {
        peers[peer_idx].handshake_state = .verified;
        return 1;
    } else {
        peers[peer_idx].handshake_state = .rejected;
        return 0;
    }
}

/// Get the handshake state of a peer.
/// Returns the state integer (0-4), or -1 if peer index invalid.
pub export fn umoja_handshake_state(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;
    return @intFromEnum(peers[peer_idx].handshake_state);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja peer state tracking
// ═══════════════════════════════════════════════════════════════════════

/// Record a heartbeat for a peer. Updates last_seen timestamp.
/// Returns 0 on success, -1 if peer index invalid.
pub export fn umoja_heartbeat(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;

    peers[peer_idx].last_seen = shim.timestamp();
    return 0;
}

/// Get the number of completed gossip rounds.
pub export fn umoja_gossip_round_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return gossip_round_count;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Proven-hardened diagnostics
//
// Circuit breaker, rate limiter, and retry state exposed for the zig
// adapter's /health and /status endpoints.
// ═══════════════════════════════════════════════════════════════════════

/// Get the circuit breaker state for a peer.
/// Returns 0=Closed, 1=Open, 2=HalfOpen, -1=invalid peer.
pub export fn umoja_peer_circuit_state(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx >= MAX_PEERS) return -1;
    return @intCast(peer_circuit_breakers[peer_idx].state);
}

/// Get the consecutive failure count for a peer's circuit breaker.
pub export fn umoja_peer_circuit_failures(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx >= MAX_PEERS) return -1;
    return @intCast(peer_circuit_breakers[peer_idx].consecutive_failures);
}

/// Reset a peer's circuit breaker (manual recovery).
/// Returns 0 on success, -1 if invalid peer.
pub export fn umoja_peer_circuit_reset(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx >= MAX_PEERS) return -1;
    peer_circuit_breakers[peer_idx].reset();
    peer_retry_state[peer_idx].reset();
    return 0;
}

/// Get the number of packets dropped by the rate limiter.
pub export fn umoja_packets_rate_limited() usize {
    mutex.lock();
    defer mutex.unlock();
    return packets_rate_limited;
}

/// Get remaining tokens in the inbound rate limiter.
pub export fn umoja_rate_limiter_tokens() u32 {
    mutex.lock();
    defer mutex.unlock();
    return inbound_rate_limiter.tokens;
}

// ═══════════════════════════════════════════════════════════════════════
// QUIC-first transport layer
//
// Provides authenticated-encrypted UDP using:
//   - X25519 Diffie-Hellman key exchange (per-peer shared secret)
//   - ChaCha20-Poly1305 AEAD (authenticated encryption with associated data)
//
// QUIC-first means: try encrypted transport first, fall back to cleartext
// UDP if key exchange hasn't completed or if QUIC is disabled.
//
// Wire format for encrypted packets:
//   [0x80 | tag : 1][nonce : 12][ciphertext : N][auth_tag : 16]
//
// The high bit of byte 0 distinguishes encrypted (0x80+) from cleartext
// packets (0x01-0x07). Recipients check the high bit to determine whether
// to decrypt before parsing.
// ═══════════════════════════════════════════════════════════════════════

const X25519 = std.crypto.dh.X25519;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// QUIC transport mode.
const TransportMode = enum(u8) {
    /// Cleartext UDP only (legacy, Grade D Alpha).
    udp = 0,
    /// QUIC-first: encrypted if handshake complete, UDP fallback otherwise.
    quic = 1,
};

/// Per-peer QUIC session state.
const QuicPeerSession = struct {
    /// Our ephemeral keypair for this peer session.
    local_secret: [32]u8 = [_]u8{0} ** 32,
    local_public: [32]u8 = [_]u8{0} ** 32,
    /// Peer's public key (received during handshake).
    remote_public: [32]u8 = [_]u8{0} ** 32,
    /// Shared secret derived from X25519(local_secret, remote_public).
    shared_secret: [32]u8 = [_]u8{0} ** 32,
    /// Whether the key exchange is complete and encryption is active.
    established: bool = false,
    /// Monotonic nonce counter for this session (prevents replay).
    send_nonce_counter: u64 = 0,
    /// Whether we have the peer's public key.
    has_remote_key: bool = false,
};

/// QUIC transport global state.
var transport_mode: TransportMode = .udp;

/// Per-peer QUIC sessions (indexed same as peers array).
var quic_sessions: [MAX_PEERS]QuicPeerSession = [_]QuicPeerSession{QuicPeerSession{}} ** MAX_PEERS;

/// Our long-lived QUIC identity keypair (generated once at bind time).
var quic_local_secret: [32]u8 = [_]u8{0} ** 32;
var quic_local_public: [32]u8 = [_]u8{0} ** 32;
var quic_keypair_valid: bool = false;

/// QUIC packet marker — high bit set to distinguish from cleartext tags.
const QUIC_MARKER: u8 = 0x80;

/// QUIC-specific packet tags (OR'd with QUIC_MARKER).
const PKT_QUIC_KEY_EXCHANGE: u8 = 0x08;
const PKT_QUIC_KEY_REPLY: u8 = 0x09;

/// Nonce size for ChaCha20-Poly1305.
const NONCE_LEN: usize = 12;

/// Authentication tag size for ChaCha20-Poly1305.
const AEAD_TAG_LEN: usize = 16;

/// QUIC overhead per packet: marker(1) + nonce(12) + auth_tag(16) = 29 bytes.
const QUIC_OVERHEAD: usize = 1 + NONCE_LEN + AEAD_TAG_LEN;

/// Generate the local QUIC keypair using system randomness.
/// HARDENED: Returns error status instead of silently giving up.
/// The old code returned void and silently left quic_keypair_valid=false,
/// which caused umoja_bind_quic to succeed but silently run in cleartext —
/// a security regression disguised as graceful degradation.
fn generateQuicKeypair() bool {
    // Use OS random for the secret key.
    shim.randomBytes(&quic_local_secret);

    // Derive public key. Retry once on degenerate key (probability ~2^-128).
    quic_local_public = X25519.recoverPublicKey(quic_local_secret) catch {
        // Degenerate key — regenerate with fresh randomness.
        shim.randomBytes(&quic_local_secret);
        quic_local_public = X25519.recoverPublicKey(quic_local_secret) catch {
            quic_keypair_valid = false;
            return false; // Two consecutive degenerate keys — hardware RNG failure.
        };
        quic_keypair_valid = true;
        return true;
    };
    quic_keypair_valid = true;
    return true;
}

/// Derive a shared secret for a peer session using X25519 ECDH.
fn deriveSharedSecret(session: *QuicPeerSession) bool {
    if (!session.has_remote_key) return false;
    session.shared_secret = X25519.scalarmult(session.local_secret, session.remote_public) catch {
        return false; // Degenerate point.
    };
    session.established = true;
    return true;
}

/// Build a nonce from the counter value.
fn buildNonce(counter: u64) [NONCE_LEN]u8 {
    var nonce: [NONCE_LEN]u8 = [_]u8{0} ** NONCE_LEN;
    // First 4 bytes: zero padding. Last 8 bytes: little-endian counter.
    const counter_bytes = std.mem.toBytes(counter);
    @memcpy(nonce[4..12], &counter_bytes);
    return nonce;
}

/// Encrypt a packet using the peer's QUIC session.
/// Input: cleartext packet (tag + payload from buildPacket).
/// Output: [QUIC_MARKER | tag][nonce:12][ciphertext:N][auth_tag:16]
/// Returns total encrypted length, or 0 on failure.
fn encryptPacket(session: *QuicPeerSession, cleartext: []const u8, out: []u8) usize {
    if (!session.established) return 0;
    if (cleartext.len == 0) return 0;
    const total = 1 + NONCE_LEN + cleartext.len + AEAD_TAG_LEN;
    if (total > out.len) return 0;

    // Marker byte: QUIC_MARKER OR'd with original tag.
    out[0] = QUIC_MARKER | cleartext[0];

    // Generate nonce from counter.
    const nonce = buildNonce(session.send_nonce_counter);
    session.send_nonce_counter += 1;
    @memcpy(out[1 .. 1 + NONCE_LEN], &nonce);

    // Encrypt (cleartext → ciphertext + auth tag).
    var auth_tag: [AEAD_TAG_LEN]u8 = undefined;
    ChaCha20Poly1305.encrypt(
        out[1 + NONCE_LEN .. 1 + NONCE_LEN + cleartext.len],
        &auth_tag,
        cleartext,
        &[_]u8{}, // no additional data
        nonce,
        session.shared_secret,
    );
    @memcpy(out[1 + NONCE_LEN + cleartext.len .. total], &auth_tag);

    return total;
}

/// Decrypt a QUIC packet using the peer's session.
/// Input: encrypted packet (marker + nonce + ciphertext + auth_tag).
/// Output: cleartext packet.
/// Returns cleartext length, or 0 on failure (bad auth, no session, etc.).
fn decryptPacket(session: *const QuicPeerSession, encrypted: []const u8, out: []u8) usize {
    if (!session.established) return 0;
    if (encrypted.len < QUIC_OVERHEAD) return 0;

    const ct_len = encrypted.len - QUIC_OVERHEAD;
    if (ct_len > out.len) return 0;

    // Extract nonce.
    var nonce: [NONCE_LEN]u8 = undefined;
    @memcpy(&nonce, encrypted[1 .. 1 + NONCE_LEN]);

    // Extract auth tag.
    var auth_tag: [AEAD_TAG_LEN]u8 = undefined;
    @memcpy(&auth_tag, encrypted[encrypted.len - AEAD_TAG_LEN .. encrypted.len]);

    // Decrypt and verify.
    ChaCha20Poly1305.decrypt(
        out[0..ct_len],
        encrypted[1 + NONCE_LEN .. 1 + NONCE_LEN + ct_len],
        auth_tag,
        &[_]u8{}, // no additional data
        nonce,
        session.shared_secret,
    ) catch {
        return 0; // Authentication failed.
    };

    // Restore original tag (strip QUIC_MARKER).
    if (ct_len > 0) {
        out[0] = encrypted[0] & 0x7F;
    }
    return ct_len;
}

/// Send a packet to a peer, encrypting if QUIC session is established.
/// HARDENED: Wrapped with per-peer circuit breaker (proven SafeCircuitBreaker).
/// Falls back to cleartext UDP if no QUIC session or in UDP mode.
/// Returns 0 on success, -1 on error, -2 if circuit is open.
fn sendToPeerQuicAware(peer_idx: usize, buf: []const u8) c_int {
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;
    if (peer_idx >= MAX_PEERS) return -1;

    const now = shim.timestamp();
    var cb = &peer_circuit_breakers[peer_idx];

    // Circuit breaker gate.
    cb.maybeTransition(now);
    if (!cb.canExecute(now)) {
        return -2; // Circuit open — peer presumed down.
    }
    cb.recordAttempt();

    var result: c_int = -1;
    if (transport_mode == .quic and quic_sessions[peer_idx].established) {
        // Encrypt and send.
        var enc_buf: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
        const enc_len = encryptPacket(&quic_sessions[peer_idx], buf, &enc_buf);
        if (enc_len > 0) {
            result = sendToPeerRaw(peer_idx, enc_buf[0..enc_len]);
        }
        // If encryption failed, fall through to cleartext.
        if (result != 0) {
            result = sendToPeerRaw(peer_idx, buf);
        }
    } else {
        // Cleartext UDP fallback.
        result = sendToPeerRaw(peer_idx, buf);
    }

    // Record circuit breaker outcome.
    if (result == 0) {
        cb.recordSuccess();
        peer_retry_state[peer_idx].reset();
    } else {
        cb.recordFailure(now);
    }
    return result;
}

/// Raw send — identical to the original sendToPeer but renamed to avoid collision.
fn sendToPeerRaw(peer_idx: usize, buf: []const u8) c_int {
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    const peer = &peers[peer_idx];

    const host_slice = peer.host[0..peer.host_len];
    const parsed = net.Ip6Address.parse(host_slice, peer.port) catch {
        last_net_error = -2;
        return -1;
    };
    const dest: net.IpAddress = .{ .ip6 = parsed };

    // `Socket.send` takes the destination address directly — no hand-filled
    // `sockaddr.in6` and no @ptrCast to `sockaddr`.
    udp_socket.?.send(shim.io(), &dest, buf) catch {
        last_net_error = -3;
        return -1;
    };
    packets_sent += 1;
    return 0;
}

/// Process one incoming packet with QUIC-awareness.
/// If the high bit is set, attempts decryption before parsing.
/// Falls back to cleartext parsing if decryption fails.
/// Returns the packet tag on success, 0 if no data, -1 on error.
pub export fn umoja_recv_and_process_quic() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;

    var buf: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    var src_addr: net.Ip6Address = .unspecified(0);

    const n = recvPacket(@as([]u8, &buf), &src_addr);
    if (n <= 0) return n;

    const raw = buf[0..@intCast(n)];

    // Check for QUIC key exchange packets (always cleartext).
    if (raw.len > 0 and raw[0] == PKT_QUIC_KEY_EXCHANGE) {
        return handleQuicKeyExchange(raw, &src_addr);
    }
    if (raw.len > 0 and raw[0] == PKT_QUIC_KEY_REPLY) {
        return handleQuicKeyReply(raw, &src_addr);
    }

    // Check for encrypted packet (high bit set).
    if (raw.len > 0 and (raw[0] & QUIC_MARKER) != 0) {
        // Find peer by address to get their session.
        const peer_result = findOrAddPeerByAddr(&src_addr);
        if (peer_result < 0) return -1;
        const pidx: usize = @intCast(peer_result);

        var cleartext: [MAX_PACKET_LEN]u8 = undefined;
        const ct_len = decryptPacket(&quic_sessions[pidx], raw, &cleartext);
        if (ct_len > 0) {
            // Successfully decrypted — process as normal packet.
            return processPacket(cleartext[0..ct_len], &src_addr);
        }
        // Decryption failed — might be cleartext with coincidental high bit.
        // Fall through to cleartext processing.
    }

    // Cleartext packet — process normally.
    return processPacket(raw, &src_addr);
}

/// Process a cleartext (or decrypted) packet. Shared logic for both
/// umoja_recv_and_process() and umoja_recv_and_process_quic().
fn processPacket(raw: []const u8, src_addr: *net.Ip6Address) c_int {
    const pkt = parsePacket(raw) orelse return -1;

    const peer_result = findOrAddPeerByAddr(src_addr);
    if (peer_result < 0) return -1;
    const pidx: usize = @intCast(peer_result);

    if (pkt.node_id.len > 0 and pkt.node_id.len <= MAX_NODE_ID_LEN) {
        peers[pidx].node_id_len = copyBounded(&peers[pidx].node_id, pkt.node_id.ptr, pkt.node_id.len);
    }
    peers[pidx].last_seen = shim.timestamp();

    switch (pkt.tag) {
        PKT_DISCOVER => {
            var reply: [MAX_PACKET_LEN]u8 = undefined;
            const rlen = buildPacket(&reply, PKT_DISCOVER_REPLY, null);
            if (rlen > 0) _ = sendToPeerQuicAware(pidx, reply[0..rlen]);
        },
        PKT_DISCOVER_REPLY => {},
        PKT_GOSSIP_DIGEST => {
            if (pkt.payload.len == DIGEST_LEN) {
                @memcpy(&peers[pidx].catalogue_digest, pkt.payload[0..DIGEST_LEN]);
                peers[pidx].has_digest = true;
            }
            if (local_digest_valid) {
                var reply: [MAX_PACKET_LEN]u8 = undefined;
                const rlen = buildPacket(&reply, PKT_GOSSIP_DIGEST_REPLY, &local_digest);
                if (rlen > 0) _ = sendToPeerQuicAware(pidx, reply[0..rlen]);
            }
            gossip_round_count += 1;
        },
        PKT_GOSSIP_DIGEST_REPLY => {
            if (pkt.payload.len == DIGEST_LEN) {
                @memcpy(&peers[pidx].catalogue_digest, pkt.payload[0..DIGEST_LEN]);
                peers[pidx].has_digest = true;
            }
            gossip_round_count += 1;
        },
        PKT_HANDSHAKE_INIT => {
            peers[pidx].handshake_state = .pending;
            var reply: [MAX_PACKET_LEN]u8 = undefined;
            const rlen = buildPacket(&reply, PKT_HANDSHAKE_REPLY, null);
            if (rlen > 0) _ = sendToPeerQuicAware(pidx, reply[0..rlen]);
        },
        PKT_HANDSHAKE_REPLY => {
            if (peers[pidx].handshake_state == .pending) {
                peers[pidx].handshake_state = .exchanged;
            }
        },
        PKT_HEARTBEAT => {},
        else => {},
    }

    return @intCast(pkt.tag);
}

/// Handle an incoming QUIC key exchange packet.
/// Format: [0x08][id_len:2][id:N][payload_len:2][public_key:32]
fn handleQuicKeyExchange(raw: []const u8, src_addr: *net.Ip6Address) c_int {
    const pkt = parsePacket(raw) orelse return -1;
    if (pkt.payload.len != 32) return -1; // X25519 public key is 32 bytes

    const peer_result = findOrAddPeerByAddr(src_addr);
    if (peer_result < 0) return -1;
    const pidx: usize = @intCast(peer_result);

    if (pkt.node_id.len > 0 and pkt.node_id.len <= MAX_NODE_ID_LEN) {
        peers[pidx].node_id_len = copyBounded(&peers[pidx].node_id, pkt.node_id.ptr, pkt.node_id.len);
    }
    peers[pidx].last_seen = shim.timestamp();

    // Store peer's public key.
    @memcpy(&quic_sessions[pidx].remote_public, pkt.payload[0..32]);
    quic_sessions[pidx].has_remote_key = true;

    // Generate per-session ephemeral keypair if not yet done.
    if (!quic_sessions[pidx].established) {
        shim.randomBytes(&quic_sessions[pidx].local_secret);
        quic_sessions[pidx].local_public = X25519.recoverPublicKey(quic_sessions[pidx].local_secret) catch {
            return -1;
        };
        _ = deriveSharedSecret(&quic_sessions[pidx]);
    }

    // Reply with our public key.
    var reply: [MAX_PACKET_LEN]u8 = undefined;
    const rlen = buildPacket(&reply, PKT_QUIC_KEY_REPLY, &quic_sessions[pidx].local_public);
    if (rlen > 0) {
        _ = sendToPeerRaw(pidx, reply[0..rlen]); // Key reply is always cleartext.
    }

    return PKT_QUIC_KEY_EXCHANGE;
}

/// Handle an incoming QUIC key reply packet.
fn handleQuicKeyReply(raw: []const u8, src_addr: *net.Ip6Address) c_int {
    const pkt = parsePacket(raw) orelse return -1;
    if (pkt.payload.len != 32) return -1;

    const peer_result = findOrAddPeerByAddr(src_addr);
    if (peer_result < 0) return -1;
    const pidx: usize = @intCast(peer_result);

    if (pkt.node_id.len > 0 and pkt.node_id.len <= MAX_NODE_ID_LEN) {
        peers[pidx].node_id_len = copyBounded(&peers[pidx].node_id, pkt.node_id.ptr, pkt.node_id.len);
    }
    peers[pidx].last_seen = shim.timestamp();

    // Store peer's public key and derive shared secret.
    @memcpy(&quic_sessions[pidx].remote_public, pkt.payload[0..32]);
    quic_sessions[pidx].has_remote_key = true;
    _ = deriveSharedSecret(&quic_sessions[pidx]);

    return PKT_QUIC_KEY_REPLY;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — QUIC transport management
// ═══════════════════════════════════════════════════════════════════════

/// Bind with QUIC-first transport. Binds the UDP socket, generates a
/// local QUIC keypair, and enables QUIC mode. All subsequent packets will
/// be encrypted once per-peer key exchange completes.
/// Returns 0 on success, -1 on error.
pub export fn umoja_bind_quic(port: u16) c_int {
    mutex.lock();
    defer mutex.unlock();
    const result = umoja_bind_impl(port);
    if (result != 0) return result;

    if (!generateQuicKeypair()) {
        // HARDENED: Keypair generation failed — return error instead of
        // silently degrading to cleartext UDP. Callers must handle this.
        return -1;
    }

    transport_mode = .quic;
    return 0;
}

/// Get the current transport mode: 0 = UDP, 1 = QUIC.
pub export fn umoja_transport_mode() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intFromEnum(transport_mode);
}

/// Set transport mode explicitly. 0 = UDP, 1 = QUIC.
/// Returns 0 on success, -1 on invalid mode.
pub export fn umoja_set_transport_mode(mode: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (mode == 0) {
        transport_mode = .udp;
        return 0;
    }
    if (mode == 1) {
        if (!quic_keypair_valid) {
            if (!generateQuicKeypair()) return -1;
        }
        transport_mode = .quic;
        return 0;
    }
    return -1;
}

/// Initiate QUIC key exchange with a peer.
/// Sends our public key to the peer; they reply with theirs.
/// After both sides exchange keys, the shared secret is derived and
/// all subsequent packets are encrypted.
/// Returns 0 on success, -1 on error.
pub export fn umoja_quic_key_exchange(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;
    if (!quic_keypair_valid) return -1;

    // Generate per-session ephemeral keypair.
    shim.randomBytes(&quic_sessions[peer_idx].local_secret);
    quic_sessions[peer_idx].local_public = X25519.recoverPublicKey(quic_sessions[peer_idx].local_secret) catch {
        return -1;
    };

    // Send our public key to the peer.
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_QUIC_KEY_EXCHANGE, &quic_sessions[peer_idx].local_public);
    if (pkt_len == 0) return -1;

    return sendToPeerRaw(peer_idx, buf[0..pkt_len]);
}

/// Check whether a QUIC session is established with a peer.
/// Returns 1 if established, 0 if not, -1 if invalid peer.
pub export fn umoja_quic_session_established(peer_idx: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!validPeer(peer_idx)) return -1;
    return if (quic_sessions[peer_idx].established) 1 else 0;
}

/// Get the number of encrypted packets sent to a peer (via nonce counter).
pub export fn umoja_quic_packets_encrypted(peer_idx: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (peer_idx >= MAX_PEERS) return 0;
    return quic_sessions[peer_idx].send_nonce_counter;
}

/// Reset all QUIC sessions. Called during federation init/deinit.
fn resetQuicSessions() void {
    quic_sessions = [_]QuicPeerSession{QuicPeerSession{}} ** MAX_PEERS;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — Original SWIM layer
// ═══════════════════════════════════════════════════════════════════════

test "register and heartbeat" {
    _ = boj_federation_init();

    const id = "node-alpha-01";
    const region = "eu-west-1";
    const idx = boj_federation_register_node(id.ptr, id.len, region.ptr, region.len);
    try std.testing.expect(idx >= 0);

    const slot: usize = @intCast(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(NodeStatus.unknown)), boj_federation_node_status(slot));

    // Send heartbeat — should become alive.
    try std.testing.expectEqual(@as(c_int, 0), boj_federation_heartbeat(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(NodeStatus.alive)), boj_federation_node_status(slot));
    try std.testing.expect(nodes[slot].last_heartbeat > 0);
}

test "suspect and declare dead" {
    _ = boj_federation_init();

    const id = "node-beta-02";
    const region = "us-east-1";
    const idx = boj_federation_register_node(id.ptr, id.len, region.ptr, region.len);
    const slot: usize = @intCast(idx);

    // Heartbeat then suspect.
    _ = boj_federation_heartbeat(slot);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(NodeStatus.alive)), boj_federation_node_status(slot));

    _ = boj_federation_suspect(slot);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(NodeStatus.suspected)), boj_federation_node_status(slot));

    _ = boj_federation_declare_dead(slot);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(NodeStatus.dead)), boj_federation_node_status(slot));
}

test "catalogue hash sync check — matching" {
    _ = boj_federation_init();

    const id_a = "sync-node-a";
    const id_b = "sync-node-b";
    const region = "ap-south-1";
    const idx_a: usize = @intCast(boj_federation_register_node(id_a.ptr, id_a.len, region.ptr, region.len));
    const idx_b: usize = @intCast(boj_federation_register_node(id_b.ptr, id_b.len, region.ptr, region.len));

    const hash = "sha256:abcdef1234567890abcdef1234567890";
    _ = boj_federation_set_catalogue_hash(idx_a, hash.ptr, hash.len);
    _ = boj_federation_set_catalogue_hash(idx_b, hash.ptr, hash.len);

    try std.testing.expectEqual(@as(c_int, 1), boj_federation_check_sync(idx_a, idx_b));
}

test "catalogue hash sync check — not matching" {
    _ = boj_federation_init();

    const id_a = "drift-node-a";
    const id_b = "drift-node-b";
    const region = "eu-central-1";
    const idx_a: usize = @intCast(boj_federation_register_node(id_a.ptr, id_a.len, region.ptr, region.len));
    const idx_b: usize = @intCast(boj_federation_register_node(id_b.ptr, id_b.len, region.ptr, region.len));

    const hash_a = "sha256:aaaa";
    const hash_b = "sha256:bbbb";
    _ = boj_federation_set_catalogue_hash(idx_a, hash_a.ptr, hash_a.len);
    _ = boj_federation_set_catalogue_hash(idx_b, hash_b.ptr, hash_b.len);

    try std.testing.expectEqual(@as(c_int, 0), boj_federation_check_sync(idx_a, idx_b));
}

test "node count queries" {
    _ = boj_federation_init();
    try std.testing.expectEqual(@as(usize, 0), boj_federation_node_count());
    try std.testing.expectEqual(@as(usize, 0), boj_federation_alive_count());

    const id1 = "count-node-1";
    const id2 = "count-node-2";
    const id3 = "count-node-3";
    const region = "local";

    const s1: usize = @intCast(boj_federation_register_node(id1.ptr, id1.len, region.ptr, region.len));
    const s2: usize = @intCast(boj_federation_register_node(id2.ptr, id2.len, region.ptr, region.len));
    _ = boj_federation_register_node(id3.ptr, id3.len, region.ptr, region.len);

    try std.testing.expectEqual(@as(usize, 3), boj_federation_node_count());
    try std.testing.expectEqual(@as(usize, 0), boj_federation_alive_count());

    // Make two alive.
    _ = boj_federation_heartbeat(s1);
    _ = boj_federation_heartbeat(s2);
    try std.testing.expectEqual(@as(usize, 2), boj_federation_alive_count());

    // Suspect one — should no longer count as alive.
    _ = boj_federation_suspect(s1);
    try std.testing.expectEqual(@as(usize, 1), boj_federation_alive_count());
}

test "out-of-bounds safety" {
    _ = boj_federation_init();

    // All operations on invalid indices must return -1.
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_heartbeat(0));
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_heartbeat(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_suspect(MAX_NODES));
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_declare_dead(42));
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_node_status(0));
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_check_sync(0, 1));

    const hash = "test-hash";
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_set_catalogue_hash(0, hash.ptr, hash.len));

    // Registry full test.
    var i: usize = 0;
    const region = "test";
    while (i < MAX_NODES) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id_slice = std.fmt.bufPrint(&id_buf, "node-{d:0>4}", .{i}) catch unreachable;
        const result = boj_federation_register_node(id_slice.ptr, id_slice.len, region.ptr, region.len);
        try std.testing.expect(result >= 0);
    }
    try std.testing.expectEqual(@as(usize, MAX_NODES), boj_federation_node_count());

    // 17th registration must fail.
    const overflow_id = "overflow-node";
    try std.testing.expectEqual(@as(c_int, -1), boj_federation_register_node(overflow_id.ptr, overflow_id.len, region.ptr, region.len));
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — Umoja peer management
// ═══════════════════════════════════════════════════════════════════════

test "umoja add and remove peers" {
    _ = boj_federation_init();

    try std.testing.expectEqual(@as(usize, 0), umoja_peer_count());

    const host1 = "192.168.1.10";
    const host2 = "192.168.1.20";
    const idx1 = umoja_add_peer(host1.ptr, host1.len, 9999);
    const idx2 = umoja_add_peer(host2.ptr, host2.len, 9999);

    try std.testing.expect(idx1 >= 0);
    try std.testing.expect(idx2 >= 0);
    try std.testing.expectEqual(@as(usize, 2), umoja_peer_count());

    // Remove first peer.
    try std.testing.expectEqual(@as(c_int, 0), umoja_remove_peer(@intCast(idx1)));
    try std.testing.expectEqual(@as(usize, 1), umoja_peer_count());

    // Remove second peer.
    try std.testing.expectEqual(@as(c_int, 0), umoja_remove_peer(@intCast(idx2)));
    try std.testing.expectEqual(@as(usize, 0), umoja_peer_count());
}

test "umoja peer count tracking" {
    _ = boj_federation_init();

    try std.testing.expectEqual(@as(usize, 0), umoja_peer_count());

    // Add 5 peers.
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        var host_buf: [32]u8 = undefined;
        const host = std.fmt.bufPrint(&host_buf, "10.0.0.{d}", .{i + 1}) catch unreachable;
        const result = umoja_add_peer(host.ptr, host.len, 9999 + i);
        try std.testing.expect(result >= 0);
    }
    try std.testing.expectEqual(@as(usize, 5), umoja_peer_count());

    // Duplicate add should return existing index, not increase count.
    const dup_host = "10.0.0.1";
    _ = umoja_add_peer(dup_host.ptr, dup_host.len, 9999);
    try std.testing.expectEqual(@as(usize, 5), umoja_peer_count());

    // Invalid adds.
    const empty_host = "";
    try std.testing.expectEqual(@as(c_int, -1), umoja_add_peer(empty_host.ptr, 0, 9999));
    try std.testing.expectEqual(@as(c_int, -1), umoja_add_peer(dup_host.ptr, dup_host.len, 0)); // port 0

    // Remove invalid index.
    try std.testing.expectEqual(@as(c_int, -1), umoja_remove_peer(99));
}

test "umoja digest computation is deterministic" {
    _ = boj_federation_init();

    // Create test cartridge data.
    const names = [_][*]const u8{ "cart-alpha", "cart-beta", "cart-gamma" };
    const name_lens = [_]usize{ 10, 9, 10 };
    const versions = [_][*]const u8{ "1.0.0", "2.1.0", "0.5.0" };
    const version_lens = [_]usize{ 5, 5, 5 };
    const hashes = [_][*]const u8{ "aabbccdd", "eeff0011", "22334455" };
    const hash_lens = [_]usize{ 8, 8, 8 };

    // Compute digest.
    const result = umoja_compute_digest(
        &names,
        &name_lens,
        &versions,
        &version_lens,
        &hashes,
        &hash_lens,
        3,
    );
    try std.testing.expectEqual(@as(c_int, 0), result);

    // Save first digest.
    var digest1: [DIGEST_LEN]u8 = undefined;
    const len1 = umoja_get_digest(&digest1, DIGEST_LEN);
    try std.testing.expectEqual(@as(usize, DIGEST_LEN), len1);

    // Compute again with same data — should be identical.
    const result2 = umoja_compute_digest(
        &names,
        &name_lens,
        &versions,
        &version_lens,
        &hashes,
        &hash_lens,
        3,
    );
    try std.testing.expectEqual(@as(c_int, 0), result2);

    var digest2: [DIGEST_LEN]u8 = undefined;
    const len2 = umoja_get_digest(&digest2, DIGEST_LEN);
    try std.testing.expectEqual(@as(usize, DIGEST_LEN), len2);

    try std.testing.expectEqualSlices(u8, &digest1, &digest2);

    // Compute with reversed input order — should STILL be identical
    // because we sort before hashing.
    const names_rev = [_][*]const u8{ "cart-gamma", "cart-beta", "cart-alpha" };
    const name_lens_rev = [_]usize{ 10, 9, 10 };
    const versions_rev = [_][*]const u8{ "0.5.0", "2.1.0", "1.0.0" };
    const version_lens_rev = [_]usize{ 5, 5, 5 };
    const hashes_rev = [_][*]const u8{ "22334455", "eeff0011", "aabbccdd" };
    const hash_lens_rev = [_]usize{ 8, 8, 8 };

    const result3 = umoja_compute_digest(
        &names_rev,
        &name_lens_rev,
        &versions_rev,
        &version_lens_rev,
        &hashes_rev,
        &hash_lens_rev,
        3,
    );
    try std.testing.expectEqual(@as(c_int, 0), result3);

    var digest3: [DIGEST_LEN]u8 = undefined;
    _ = umoja_get_digest(&digest3, DIGEST_LEN);
    try std.testing.expectEqualSlices(u8, &digest1, &digest3);
}

test "umoja handshake state transitions" {
    _ = boj_federation_init();

    const host = "10.0.0.1";
    const idx: usize = @intCast(umoja_add_peer(host.ptr, host.len, 9999));

    // Initial state is none.
    try std.testing.expectEqual(@as(c_int, @intFromEnum(HandshakeState.none)), umoja_handshake_state(idx));

    // Initiate handshake -> pending.
    try std.testing.expectEqual(@as(c_int, 0), umoja_handshake(idx));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(HandshakeState.pending)), umoja_handshake_state(idx));

    // Exchange -> exchanged.
    try std.testing.expectEqual(@as(c_int, 0), umoja_handshake_exchanged(idx));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(HandshakeState.exchanged)), umoja_handshake_state(idx));

    // Cannot exchange again (not in pending state).
    try std.testing.expectEqual(@as(c_int, -1), umoja_handshake_exchanged(idx));

    // Invalid peer index.
    try std.testing.expectEqual(@as(c_int, -1), umoja_handshake(99));
    try std.testing.expectEqual(@as(c_int, -1), umoja_handshake_state(99));
}

test "umoja gossip round simulated" {
    _ = boj_federation_init();

    // No peers — gossip should fail.
    try std.testing.expectEqual(@as(c_int, -1), umoja_gossip_round());
    try std.testing.expectEqual(@as(usize, 0), umoja_gossip_round_count());

    // Add a peer.
    const host = "10.0.0.1";
    const peer_idx = umoja_add_peer(host.ptr, host.len, 9999);
    try std.testing.expect(peer_idx >= 0);

    // Gossip round should succeed and contact the only available peer.
    const contacted = umoja_gossip_round();
    try std.testing.expect(contacted >= 0);
    try std.testing.expectEqual(@as(usize, 1), umoja_gossip_round_count());

    // Run a few more rounds.
    _ = umoja_gossip_round();
    _ = umoja_gossip_round();
    try std.testing.expectEqual(@as(usize, 3), umoja_gossip_round_count());
}

test "umoja attestation verify — matching digests" {
    _ = boj_federation_init();

    // Add a peer.
    const host = "10.0.0.1";
    const idx: usize = @intCast(umoja_add_peer(host.ptr, host.len, 9999));

    // Compute local digest.
    const names = [_][*]const u8{"my-cartridge"};
    const name_lens = [_]usize{12};
    const versions = [_][*]const u8{"1.0.0"};
    const version_lens = [_]usize{5};
    const hashes = [_][*]const u8{"deadbeef"};
    const hash_lens = [_]usize{8};

    _ = umoja_compute_digest(
        &names,
        &name_lens,
        &versions,
        &version_lens,
        &hashes,
        &hash_lens,
        1,
    );

    // Send the SAME digest as if the peer sent it to us.
    var our_digest: [DIGEST_LEN]u8 = undefined;
    _ = umoja_get_digest(&our_digest, DIGEST_LEN);
    _ = umoja_receive_digest(idx, &our_digest, DIGEST_LEN);

    // Move through handshake states: pending -> exchanged -> verify.
    _ = umoja_handshake(idx);
    _ = umoja_handshake_exchanged(idx);

    const verified = umoja_verify_attestation(idx);
    try std.testing.expectEqual(@as(c_int, 1), verified);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(HandshakeState.verified)), umoja_handshake_state(idx));
}

test "umoja attestation verify — mismatched digests" {
    _ = boj_federation_init();

    const host = "10.0.0.2";
    const idx: usize = @intCast(umoja_add_peer(host.ptr, host.len, 9999));

    // Compute local digest.
    const names = [_][*]const u8{"my-cartridge"};
    const name_lens = [_]usize{12};
    const versions = [_][*]const u8{"1.0.0"};
    const version_lens = [_]usize{5};
    const hashes = [_][*]const u8{"deadbeef"};
    const hash_lens = [_]usize{8};

    _ = umoja_compute_digest(
        &names,
        &name_lens,
        &versions,
        &version_lens,
        &hashes,
        &hash_lens,
        1,
    );

    // Send a DIFFERENT digest from the peer.
    var fake_digest: [DIGEST_LEN]u8 = [_]u8{0xFF} ** DIGEST_LEN;
    _ = umoja_receive_digest(idx, &fake_digest, DIGEST_LEN);

    // Move through handshake: pending -> exchanged -> verify (rejected).
    _ = umoja_handshake(idx);
    _ = umoja_handshake_exchanged(idx);

    const rejected = umoja_verify_attestation(idx);
    try std.testing.expectEqual(@as(c_int, 0), rejected);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(HandshakeState.rejected)), umoja_handshake_state(idx));
}

test "umoja heartbeat updates last_seen" {
    _ = boj_federation_init();

    const host = "10.0.0.5";
    const idx: usize = @intCast(umoja_add_peer(host.ptr, host.len, 8080));

    const before = peers[idx].last_seen;
    _ = umoja_heartbeat(idx);
    try std.testing.expect(peers[idx].last_seen >= before);

    // Invalid index.
    try std.testing.expectEqual(@as(c_int, -1), umoja_heartbeat(99));
}

test "umoja discover nodes returns peer count" {
    _ = boj_federation_init();

    try std.testing.expectEqual(@as(c_int, 0), umoja_discover_nodes());

    const host = "10.0.0.1";
    _ = umoja_add_peer(host.ptr, host.len, 9999);
    try std.testing.expectEqual(@as(c_int, 1), umoja_discover_nodes());

    const host2 = "10.0.0.2";
    _ = umoja_add_peer(host2.ptr, host2.len, 9999);
    try std.testing.expectEqual(@as(c_int, 2), umoja_discover_nodes());
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — UDP networking layer
// ═══════════════════════════════════════════════════════════════════════

test "packet build and parse roundtrip" {
    // Set a local node id for packet building.
    const node_id = "test-node-01";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    var buf: [MAX_PACKET_LEN]u8 = undefined;

    // Build a digest packet with payload.
    var payload: [DIGEST_LEN]u8 = undefined;
    for (0..DIGEST_LEN) |i| {
        payload[i] = @truncate(i);
    }
    const pkt_len = buildPacket(&buf, PKT_GOSSIP_DIGEST, &payload);
    try std.testing.expect(pkt_len > 0);

    // Parse it back.
    const parsed = parsePacket(buf[0..pkt_len]);
    try std.testing.expect(parsed != null);

    const pkt = parsed.?;
    try std.testing.expectEqual(PKT_GOSSIP_DIGEST, pkt.tag);
    try std.testing.expectEqualSlices(u8, node_id, pkt.node_id);
    try std.testing.expectEqual(@as(usize, DIGEST_LEN), pkt.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, pkt.payload);
}

test "packet build with no payload" {
    const node_id = "heartbeat-node";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_HEARTBEAT, null);
    try std.testing.expect(pkt_len > 0);

    const parsed = parsePacket(buf[0..pkt_len]).?;
    try std.testing.expectEqual(PKT_HEARTBEAT, parsed.tag);
    try std.testing.expectEqualSlices(u8, node_id, parsed.node_id);
    try std.testing.expectEqual(@as(usize, 0), parsed.payload.len);
}

test "parse malformed packets" {
    // Too short.
    const short = [_]u8{ 0x01, 0x00 };
    try std.testing.expect(parsePacket(&short) == null);

    // ID length exceeds buffer.
    const bad_id = [_]u8{ 0x01, 0xFF, 0x00, 0x00, 0x00 };
    try std.testing.expect(parsePacket(&bad_id) == null);
}

test "umoja socket lifecycle" {
    _ = boj_federation_init();

    // Not bound initially.
    try std.testing.expectEqual(@as(c_int, 0), umoja_is_bound());

    // Set node id.
    const node_id = "socket-test-node";
    try std.testing.expectEqual(@as(c_int, 0), umoja_set_node_id(node_id.ptr, node_id.len));

    // Bind to a high port (unlikely to conflict in test).
    const test_port: u16 = 19876;
    const bind_result = umoja_bind(test_port);
    if (bind_result < 0) {
        // Port in use or insufficient privileges — skip gracefully.
        return;
    }
    try std.testing.expectEqual(@as(c_int, 1), umoja_is_bound());

    // Double bind should fail.
    try std.testing.expectEqual(@as(c_int, -1), umoja_bind(test_port + 1));

    // Unbind.
    try std.testing.expectEqual(@as(c_int, 0), umoja_unbind());
    try std.testing.expectEqual(@as(c_int, 0), umoja_is_bound());

    // Unbind again should fail.
    try std.testing.expectEqual(@as(c_int, -1), umoja_unbind());
}

test "umoja loopback send and receive" {
    _ = boj_federation_init();

    const node_id = "loopback-test";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    // Bind two sockets on different ports for loopback testing.
    const port_a: u16 = 19877;
    const port_b: u16 = 19878;

    // Bind socket A.
    if (umoja_bind(port_a) < 0) return; // skip if port unavailable

    // Add a peer pointing to ourselves on port_a (loopback).
    const loopback = "::1";
    const peer_idx = umoja_add_peer(loopback.ptr, loopback.len, port_a);
    try std.testing.expect(peer_idx >= 0);

    // Compute a local digest so we can send it.
    const names = [_][*]const u8{"test-cart"};
    const name_lens = [_]usize{9};
    const versions = [_][*]const u8{"1.0.0"};
    const version_lens = [_]usize{5};
    const hashes = [_][*]const u8{"abc123"};
    const hash_lens = [_]usize{6};
    _ = umoja_compute_digest(&names, &name_lens, &versions, &version_lens, &hashes, &hash_lens, 1);

    // Send a heartbeat to ourselves (loopback).
    const send_result = umoja_send_heartbeat(@intCast(peer_idx));
    try std.testing.expectEqual(@as(c_int, 0), send_result);
    try std.testing.expect(umoja_packets_sent() > 0);

    // Try to receive (may or may not arrive instantly on loopback).
    const recv_tag = umoja_recv_and_process();
    // On loopback, we should get our own packet back.
    if (recv_tag > 0) {
        try std.testing.expectEqual(@as(c_int, PKT_HEARTBEAT), recv_tag);
        try std.testing.expect(umoja_packets_received() > 0);
    }

    _ = umoja_unbind();
    _ = port_b; // reserved for future two-socket tests
}

test "umoja network stats tracking" {
    _ = boj_federation_init();

    try std.testing.expectEqual(@as(usize, 0), umoja_packets_sent());
    try std.testing.expectEqual(@as(usize, 0), umoja_packets_received());
    try std.testing.expectEqual(@as(c_int, 0), umoja_last_net_error());

    // Operations without socket should fail gracefully.
    try std.testing.expectEqual(@as(c_int, -1), umoja_send_heartbeat(0));
    try std.testing.expectEqual(@as(c_int, -1), umoja_send_digest(0));
    try std.testing.expectEqual(@as(c_int, -1), umoja_recv_and_process());
}

test "umoja set node id validation" {
    _ = boj_federation_init();

    // Empty id should fail.
    const empty = "";
    try std.testing.expectEqual(@as(c_int, -1), umoja_set_node_id(empty.ptr, 0));

    // Valid id should succeed.
    const valid = "my-federation-node";
    try std.testing.expectEqual(@as(c_int, 0), umoja_set_node_id(valid.ptr, valid.len));

    // Verify it's stored.
    try std.testing.expectEqual(valid.len, local_node_id_len);
    try std.testing.expectEqualSlices(u8, valid, local_node_id[0..local_node_id_len]);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — Multi-node integration (full protocol over loopback UDP)
// ═══════════════════════════════════════════════════════════════════════

test "integration: full gossip handshake over loopback UDP" {
    // This test exercises the complete Umoja federation protocol:
    //   1. Bind to a loopback port
    //   2. Send handshake init to self
    //   3. Receive and process (triggers handshake reply)
    //   4. Receive the reply (transitions to exchanged)
    //   5. Verify the full handshake completed
    _ = boj_federation_init();

    const node_id = "integration-handshake";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    const port: u16 = 19900;
    if (umoja_bind(port) < 0) return; // skip in restricted environments

    // Add loopback peer.
    const loopback = "::1";
    const pidx = umoja_add_peer(loopback.ptr, loopback.len, port);
    try std.testing.expect(pidx >= 0);
    const peer_idx: usize = @intCast(pidx);

    // Step 1: Send handshake init.
    const send_r = umoja_send_handshake(peer_idx);
    try std.testing.expectEqual(@as(c_int, 0), send_r);
    try std.testing.expectEqual(HandshakeState.pending, peers[peer_idx].handshake_state);

    // Step 2: Receive the HANDSHAKE_INIT we just sent to ourselves.
    // The recv_and_process handler will:
    //   a) Set the peer to pending
    //   b) Send a HANDSHAKE_REPLY back
    const tag1 = umoja_recv_and_process();
    if (tag1 > 0) {
        try std.testing.expectEqual(@as(c_int, PKT_HANDSHAKE_INIT), tag1);

        // Step 3: Receive the auto-sent HANDSHAKE_REPLY.
        // This should transition the peer from pending to exchanged.
        const tag2 = umoja_recv_and_process();
        if (tag2 > 0) {
            try std.testing.expectEqual(@as(c_int, PKT_HANDSHAKE_REPLY), tag2);
            try std.testing.expectEqual(HandshakeState.exchanged, peers[peer_idx].handshake_state);
        }
    }

    // Verify stats.
    try std.testing.expect(umoja_packets_sent() >= 1);

    _ = umoja_unbind();
}

test "integration: digest exchange and attestation over loopback UDP" {
    // Tests the full catalogue sync protocol:
    //   1. Compute local digest
    //   2. Send digest to self
    //   3. Receive (stores digest, sends reply)
    //   4. Receive reply (stores digest again)
    //   5. Verify attestation matches
    _ = boj_federation_init();

    const node_id = "integration-digest";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    const port: u16 = 19901;
    if (umoja_bind(port) < 0) return;

    const loopback = "::1";
    const pidx = umoja_add_peer(loopback.ptr, loopback.len, port);
    try std.testing.expect(pidx >= 0);
    const peer_idx: usize = @intCast(pidx);

    // Compute a local digest from cartridge data.
    const names = [_][*]const u8{ "database-mcp", "fleet-mcp", "nesy-mcp" };
    const name_lens = [_]usize{ 12, 9, 8 };
    const versions = [_][*]const u8{ "0.1.0", "0.1.0", "0.2.0" };
    const version_lens = [_]usize{ 5, 5, 5 };
    const hashes = [_][*]const u8{ "aabb", "ccdd", "eeff" };
    const hash_lens = [_]usize{ 4, 4, 4 };
    _ = umoja_compute_digest(&names, &name_lens, &versions, &version_lens, &hashes, &hash_lens, 3);
    try std.testing.expect(local_digest_valid);

    // Step 1: Send our digest to self.
    const send_r = umoja_send_digest(peer_idx);
    try std.testing.expectEqual(@as(c_int, 0), send_r);

    // Step 2: Receive GOSSIP_DIGEST — handler stores digest and sends reply.
    const tag1 = umoja_recv_and_process();
    if (tag1 > 0) {
        try std.testing.expectEqual(@as(c_int, PKT_GOSSIP_DIGEST), tag1);
        try std.testing.expect(peers[peer_idx].has_digest);
        try std.testing.expect(umoja_gossip_round_count() >= 1);

        // Step 3: Receive GOSSIP_DIGEST_REPLY.
        const tag2 = umoja_recv_and_process();
        if (tag2 > 0) {
            try std.testing.expectEqual(@as(c_int, PKT_GOSSIP_DIGEST_REPLY), tag2);
            try std.testing.expect(umoja_gossip_round_count() >= 2);
        }

        // Step 4: Verify attestation — digests should match (we sent our own).
        // First go through handshake states.
        _ = umoja_handshake(peer_idx);
        _ = umoja_handshake_exchanged(peer_idx);
        const verified = umoja_verify_attestation(peer_idx);
        try std.testing.expectEqual(@as(c_int, 1), verified);
        try std.testing.expectEqual(HandshakeState.verified, peers[peer_idx].handshake_state);
    }

    _ = umoja_unbind();
}

test "integration: discovery over loopback UDP" {
    // Tests peer discovery protocol:
    //   1. Bind to port
    //   2. Send discovery packet to self
    //   3. Receive DISCOVER — handler sends DISCOVER_REPLY
    //   4. Receive DISCOVER_REPLY — peer confirmed
    _ = boj_federation_init();

    const node_id = "integration-discover";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    const port: u16 = 19902;
    if (umoja_bind(port) < 0) return;

    // Use umoja_discover_udp targeting loopback.
    const loopback = "::1";
    const initial_peers = peer_count;
    const result = umoja_discover_udp(loopback.ptr, loopback.len, port);

    // Should succeed (>=0). On loopback, we send DISCOVER to ourselves.
    try std.testing.expect(result >= 0);

    // We should have at least as many peers as before (discover doesn't remove).
    try std.testing.expect(peer_count >= initial_peers);

    // Verify we sent at least one packet.
    try std.testing.expect(umoja_packets_sent() >= 1);

    _ = umoja_unbind();
}

test "integration: heartbeat keeps peer alive after multiple rounds" {
    // Tests that heartbeat packets successfully update peer state over UDP.
    _ = boj_federation_init();

    const node_id = "integration-heartbeat";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    const port: u16 = 19903;
    if (umoja_bind(port) < 0) return;

    const loopback = "::1";
    const pidx = umoja_add_peer(loopback.ptr, loopback.len, port);
    try std.testing.expect(pidx >= 0);
    const peer_idx: usize = @intCast(pidx);

    // Record initial last_seen.
    const initial_last_seen = peers[peer_idx].last_seen;

    // Send 3 heartbeats and process them.
    var heartbeats_received: usize = 0;
    for (0..3) |_| {
        _ = umoja_send_heartbeat(peer_idx);
        const tag = umoja_recv_and_process();
        if (tag == PKT_HEARTBEAT) heartbeats_received += 1;
    }

    // At least some heartbeats should have been received on loopback.
    if (heartbeats_received > 0) {
        try std.testing.expect(peers[peer_idx].last_seen >= initial_last_seen);
        try std.testing.expect(umoja_packets_sent() >= 3);
        try std.testing.expect(umoja_packets_received() >= 1);
    }

    _ = umoja_unbind();
}

test "integration: mixed protocol traffic over loopback" {
    // Sends multiple packet types in sequence and verifies correct handling.
    _ = boj_federation_init();

    const node_id = "integration-mixed";
    _ = umoja_set_node_id(node_id.ptr, node_id.len);

    const port: u16 = 19904;
    if (umoja_bind(port) < 0) return;

    const loopback = "::1";
    const pidx = umoja_add_peer(loopback.ptr, loopback.len, port);
    try std.testing.expect(pidx >= 0);
    const peer_idx: usize = @intCast(pidx);

    // Compute digest for gossip.
    const names = [_][*]const u8{"mixed-test"};
    const name_lens = [_]usize{10};
    const versions = [_][*]const u8{"1.0.0"};
    const version_lens = [_]usize{5};
    const hashes = [_][*]const u8{"abcd1234"};
    const hash_lens = [_]usize{8};
    _ = umoja_compute_digest(&names, &name_lens, &versions, &version_lens, &hashes, &hash_lens, 1);

    // Send sequence: heartbeat, digest, handshake.
    _ = umoja_send_heartbeat(peer_idx);
    _ = umoja_send_digest(peer_idx);
    _ = umoja_send_handshake(peer_idx);

    // Drain all packets (6 possible: 3 sent + up to 3 auto-replies).
    var tags_seen: [8]c_int = [_]c_int{0} ** 8;
    var tag_count: usize = 0;
    for (0..8) |_| {
        const tag = umoja_recv_and_process();
        if (tag <= 0) break;
        if (tag_count < 8) {
            tags_seen[tag_count] = tag;
            tag_count += 1;
        }
    }

    // We should have received at least some of our packets.
    try std.testing.expect(tag_count >= 1);
    try std.testing.expect(umoja_packets_sent() >= 3);

    _ = umoja_unbind();
}

test "umoja last_net_error tracks errors" {
    _ = boj_federation_init();

    // After init, last error should be 0.
    try std.testing.expectEqual(@as(c_int, 0), umoja_last_net_error());

    // Attempt an operation that sets error state — discover without binding.
    // umoja_discover_udp should return -1 when not bound.
    const target = "::1";
    try std.testing.expectEqual(@as(c_int, -1), umoja_discover_udp(target.ptr, target.len, 19999));

    // No error set for "not bound" — it's a pre-check, not a network error.
    // last_net_error stays 0 because the function returns early before touching network.
    try std.testing.expectEqual(@as(c_int, 0), umoja_last_net_error());
}

test "umoja gossip_round_count increments" {
    _ = boj_federation_init();

    // After init, count should be 0.
    try std.testing.expectEqual(@as(usize, 0), umoja_gossip_round_count());

    // Add a peer and run a gossip round.
    const host = "::1";
    const pidx = umoja_add_peer(host.ptr, host.len, 19998);
    try std.testing.expect(pidx >= 0);

    // Gossip round increments the counter.
    _ = umoja_gossip_round();
    try std.testing.expectEqual(@as(usize, 1), umoja_gossip_round_count());

    // Another round.
    _ = umoja_gossip_round();
    try std.testing.expectEqual(@as(usize, 2), umoja_gossip_round_count());
}

test "umoja discover_udp validates inputs" {
    _ = boj_federation_init();

    // Not bound → -1.
    const target = "::1";
    try std.testing.expectEqual(@as(c_int, -1), umoja_discover_udp(target.ptr, target.len, 19997));

    // Empty target → -1 even if bound.
    const port: u16 = 19996;
    if (umoja_bind(port) < 0) return; // Skip if can't bind.

    const empty = "";
    try std.testing.expectEqual(@as(c_int, -1), umoja_discover_udp(empty.ptr, empty.len, 19995));

    _ = umoja_unbind();
}

// ═══════════════════════════════════════════════════════════════════════
// Tests — QUIC transport layer
// ═══════════════════════════════════════════════════════════════════════

test "quic keypair generation" {
    _ = boj_federation_init();

    _ = generateQuicKeypair();
    try std.testing.expect(quic_keypair_valid);

    // Public key should not be all zeros.
    var all_zero = true;
    for (quic_local_public) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    try std.testing.expect(!all_zero);
}

test "quic bind sets transport mode" {
    _ = boj_federation_init();
    try std.testing.expectEqual(@as(c_int, 0), umoja_transport_mode());

    const id = "quic-test-node";
    _ = umoja_set_node_id(id.ptr, id.len);

    const port: u16 = 19800;
    if (umoja_bind_quic(port) < 0) return; // Skip if can't bind.

    try std.testing.expectEqual(@as(c_int, 1), umoja_transport_mode());
    try std.testing.expect(quic_keypair_valid);
    try std.testing.expectEqual(@as(c_int, 1), umoja_is_bound());

    _ = umoja_unbind();
}

test "quic transport mode toggle" {
    _ = boj_federation_init();

    // Start in UDP mode.
    try std.testing.expectEqual(@as(c_int, 0), umoja_transport_mode());

    // Switch to QUIC.
    try std.testing.expectEqual(@as(c_int, 0), umoja_set_transport_mode(1));
    try std.testing.expectEqual(@as(c_int, 1), umoja_transport_mode());

    // Switch back to UDP.
    try std.testing.expectEqual(@as(c_int, 0), umoja_set_transport_mode(0));
    try std.testing.expectEqual(@as(c_int, 0), umoja_transport_mode());

    // Invalid mode.
    try std.testing.expectEqual(@as(c_int, -1), umoja_set_transport_mode(42));
}

test "quic encrypt and decrypt roundtrip" {
    _ = boj_federation_init();

    // Simulate two peers with X25519 key exchange.
    var session_a = QuicPeerSession{};
    var session_b = QuicPeerSession{};

    // Generate keypairs for both sides.
    shim.randomBytes(&session_a.local_secret);
    session_a.local_public = X25519.recoverPublicKey(session_a.local_secret) catch unreachable;

    shim.randomBytes(&session_b.local_secret);
    session_b.local_public = X25519.recoverPublicKey(session_b.local_secret) catch unreachable;

    // Exchange public keys.
    session_a.remote_public = session_b.local_public;
    session_a.has_remote_key = true;
    session_b.remote_public = session_a.local_public;
    session_b.has_remote_key = true;

    // Derive shared secrets (should match).
    try std.testing.expect(deriveSharedSecret(&session_a));
    try std.testing.expect(deriveSharedSecret(&session_b));
    try std.testing.expectEqualSlices(u8, &session_a.shared_secret, &session_b.shared_secret);

    // Encrypt a packet with A.
    const cleartext = [_]u8{ PKT_GOSSIP_DIGEST, 0x01, 0x02, 0x03, 0x04, 0x05 };
    var encrypted: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    const enc_len = encryptPacket(&session_a, &cleartext, &encrypted);
    try std.testing.expect(enc_len > 0);
    try std.testing.expect(enc_len > cleartext.len); // Must be larger (nonce + tag).

    // High bit should be set on marker byte.
    try std.testing.expect((encrypted[0] & QUIC_MARKER) != 0);

    // Decrypt with B.
    var decrypted: [MAX_PACKET_LEN]u8 = undefined;
    const dec_len = decryptPacket(&session_b, encrypted[0..enc_len], &decrypted);
    try std.testing.expectEqual(cleartext.len, dec_len);
    try std.testing.expectEqualSlices(u8, &cleartext, decrypted[0..dec_len]);
}

test "quic decrypt fails with wrong key" {
    _ = boj_federation_init();

    var session_a = QuicPeerSession{};
    var session_wrong = QuicPeerSession{};

    // Generate keypairs.
    shim.randomBytes(&session_a.local_secret);
    session_a.local_public = X25519.recoverPublicKey(session_a.local_secret) catch unreachable;

    shim.randomBytes(&session_wrong.local_secret);
    session_wrong.local_public = X25519.recoverPublicKey(session_wrong.local_secret) catch unreachable;

    // A encrypts with its own shared secret (self-loop for test).
    session_a.remote_public = session_a.local_public;
    session_a.has_remote_key = true;
    _ = deriveSharedSecret(&session_a);

    // Wrong derives with different key.
    session_wrong.remote_public = session_wrong.local_public;
    session_wrong.has_remote_key = true;
    _ = deriveSharedSecret(&session_wrong);

    // Encrypt with A.
    const cleartext = [_]u8{ PKT_HEARTBEAT, 0xAA, 0xBB };
    var encrypted: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    const enc_len = encryptPacket(&session_a, &cleartext, &encrypted);
    try std.testing.expect(enc_len > 0);

    // Decrypt with wrong key should fail (return 0).
    var decrypted: [MAX_PACKET_LEN]u8 = undefined;
    const dec_len = decryptPacket(&session_wrong, encrypted[0..enc_len], &decrypted);
    try std.testing.expectEqual(@as(usize, 0), dec_len);
}

test "quic session established tracking" {
    _ = boj_federation_init();

    // No peer → -1.
    try std.testing.expectEqual(@as(c_int, -1), umoja_quic_session_established(0));

    // Add a peer.
    const host = "::1";
    const port: u16 = 19801;
    _ = umoja_add_peer(host.ptr, host.len, port);

    // Not established yet.
    try std.testing.expectEqual(@as(c_int, 0), umoja_quic_session_established(0));

    // Manually establish.
    shim.randomBytes(&quic_sessions[0].local_secret);
    quic_sessions[0].local_public = X25519.recoverPublicKey(quic_sessions[0].local_secret) catch unreachable;
    quic_sessions[0].remote_public = quic_sessions[0].local_public;
    quic_sessions[0].has_remote_key = true;
    _ = deriveSharedSecret(&quic_sessions[0]);

    try std.testing.expectEqual(@as(c_int, 1), umoja_quic_session_established(0));
}

test "quic nonce counter increments" {
    _ = boj_federation_init();

    var session = QuicPeerSession{};
    shim.randomBytes(&session.local_secret);
    session.local_public = X25519.recoverPublicKey(session.local_secret) catch unreachable;
    session.remote_public = session.local_public;
    session.has_remote_key = true;
    _ = deriveSharedSecret(&session);

    try std.testing.expectEqual(@as(u64, 0), session.send_nonce_counter);

    // Encrypt twice — counter should increment.
    const cleartext = [_]u8{PKT_HEARTBEAT};
    var enc1: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    _ = encryptPacket(&session, &cleartext, &enc1);
    try std.testing.expectEqual(@as(u64, 1), session.send_nonce_counter);

    var enc2: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    _ = encryptPacket(&session, &cleartext, &enc2);
    try std.testing.expectEqual(@as(u64, 2), session.send_nonce_counter);
}

test "quic nonce produces unique ciphertexts" {
    _ = boj_federation_init();

    var session = QuicPeerSession{};
    shim.randomBytes(&session.local_secret);
    session.local_public = X25519.recoverPublicKey(session.local_secret) catch unreachable;
    session.remote_public = session.local_public;
    session.has_remote_key = true;
    _ = deriveSharedSecret(&session);

    // Encrypt same plaintext twice — ciphertext must differ (different nonces).
    const cleartext = [_]u8{ PKT_GOSSIP_DIGEST, 0xDE, 0xAD, 0xBE, 0xEF };
    var enc1: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    const len1 = encryptPacket(&session, &cleartext, &enc1);

    var enc2: [MAX_PACKET_LEN + QUIC_OVERHEAD]u8 = undefined;
    const len2 = encryptPacket(&session, &cleartext, &enc2);

    try std.testing.expectEqual(len1, len2);
    // Ciphertexts should differ (different nonces).
    var same = true;
    for (0..len1) |i| {
        if (enc1[i] != enc2[i]) { same = false; break; }
    }
    try std.testing.expect(!same);
}

test "integration: quic key exchange over loopback" {
    _ = boj_federation_init();

    const id = "quic-kex-node";
    _ = umoja_set_node_id(id.ptr, id.len);

    const port: u16 = 19802;
    if (umoja_bind_quic(port) < 0) return; // Skip if can't bind.

    // Add self as peer for loopback testing.
    const host = "::1";
    _ = umoja_add_peer(host.ptr, host.len, port);

    // Initiate key exchange.
    const kex_result = umoja_quic_key_exchange(0);
    try std.testing.expectEqual(@as(c_int, 0), kex_result);

    // Process the key exchange packet we just sent to ourselves.
    const tag = umoja_recv_and_process_quic();
    // Should get KEY_EXCHANGE (0x08) processed.
    if (tag > 0) {
        try std.testing.expectEqual(@as(c_int, PKT_QUIC_KEY_EXCHANGE), tag);
    }

    // Process the KEY_REPLY that handleQuicKeyExchange sent back.
    const tag2 = umoja_recv_and_process_quic();
    if (tag2 > 0) {
        try std.testing.expectEqual(@as(c_int, PKT_QUIC_KEY_REPLY), tag2);
    }

    // Session should now be established (both keys exchanged).
    if (tag > 0 and tag2 > 0) {
        try std.testing.expectEqual(@as(c_int, 1), umoja_quic_session_established(0));
    }

    _ = umoja_unbind();
}

test "quic federation init resets sessions" {
    _ = boj_federation_init();

    // Set up some QUIC state.
    _ = generateQuicKeypair();
    transport_mode = .quic;
    quic_sessions[0].established = true;

    // Init should reset everything.
    _ = boj_federation_init();
    try std.testing.expectEqual(@as(c_int, 0), umoja_transport_mode());
    try std.testing.expect(!quic_keypair_valid);
    try std.testing.expect(!quic_sessions[0].established);
}

const shim = @import("cartridge_shim");
