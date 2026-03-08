// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
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

/// UDP socket file descriptor. -1 means not bound.
var udp_fd: std.posix.socket_t = -1;

/// Whether the UDP socket is bound and ready.
var socket_bound: bool = false;

/// Last error code from a network operation (for diagnostics).
var last_net_error: c_int = 0;

/// Statistics: packets sent and received.
var packets_sent: usize = 0;
var packets_received: usize = 0;

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

/// Simple PRNG for peer selection during gossip rounds.
/// Uses a basic xorshift32 seeded from the current timestamp.
/// Not cryptographically secure — only needs to be fair for peer selection.
var prng_state: u32 = 0;

fn prngNext() u32 {
    if (prng_state == 0) {
        // Seed from timestamp on first call.
        const ts = std.time.timestamp();
        prng_state = @truncate(@as(u64, @bitCast(ts)));
        if (prng_state == 0) prng_state = 1;
    }
    var x = prng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    prng_state = x;
    return x;
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
/// Returns 0 on success, -1 on error.
fn sendToPeer(peer_idx: usize, buf: []const u8) c_int {
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    const peer = &peers[peer_idx];
    var addr: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);
    addr.family = std.posix.AF.INET6;
    addr.port = std.mem.nativeToBig(u16, peer.port);

    // Parse IPv6 address from peer host string.
    const host_slice = peer.host[0..peer.host_len];
    const parsed = std.net.Ip6Address.parse(host_slice, peer.port) catch {
        last_net_error = -2;
        return -1;
    };
    addr = parsed.sa;

    const dest: *const std.posix.sockaddr = @ptrCast(&addr);
    const sent = std.posix.sendto(udp_fd, buf, 0, dest, @sizeOf(std.posix.sockaddr.in6)) catch {
        last_net_error = -3;
        return -1;
    };
    _ = sent;
    packets_sent += 1;
    return 0;
}

/// Try to receive one UDP packet (non-blocking).
/// Returns the number of bytes received, 0 if nothing available, or -1 on error.
/// Stores the sender's address in the provided sockaddr.
fn recvPacket(buf: []u8, src_addr: *std.posix.sockaddr.in6) c_int {
    if (!socket_bound) return -1;

    var addr6: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);
    var addr6_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);

    const n = std.posix.recvfrom(udp_fd, buf, std.posix.MSG.DONTWAIT, @ptrCast(&addr6), &addr6_len) catch |err| {
        if (err == error.WouldBlock) return 0;
        last_net_error = -4;
        return -1;
    };

    src_addr.* = addr6;

    packets_received += 1;
    return @intCast(n);
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
fn findOrAddPeerByAddr(addr: *const std.posix.sockaddr.in6) c_int {
    // Format the raw IPv6 address bytes as a string.
    var addr_buf: [46]u8 = undefined;
    const host_len = formatIp6(addr.addr, &addr_buf);
    const port = std.mem.bigToNative(u16, addr.port);

    if (host_len == 0 or host_len > MAX_HOST_LEN) return -1;

    return umoja_add_peer(addr_buf[0..host_len].ptr, host_len, port);
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
    if (id_len == 0 or id_len > MAX_NODE_ID_LEN) return -1;
    local_node_id_len = copyBounded(&local_node_id, id_ptr, id_len);
    return 0;
}

/// Bind a UDP socket to the given port for federation communication.
/// Uses IPv6 dual-stack (receives both IPv4-mapped and IPv6).
/// Returns 0 on success, -1 on error.
pub export fn umoja_bind(port: u16) c_int {
    if (socket_bound) return -1; // already bound
    if (port == 0) return -1;

    const fd = std.posix.socket(std.posix.AF.INET6, std.posix.SOCK.DGRAM, 0) catch {
        last_net_error = -10;
        return -1;
    };

    // Allow address reuse.
    const one: c_int = 1;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};

    // Bind to [::]:port.
    var addr: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);
    addr.family = std.posix.AF.INET6;
    addr.port = std.mem.nativeToBig(u16, port);

    std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in6)) catch {
        std.posix.close(fd);
        last_net_error = -11;
        return -1;
    };

    // Set non-blocking via ioctl FIONBIO.
    const fionbio: c_int = 1;
    const FIONBIO: u32 = 0x5421;
    const ioctl_result = std.posix.system.ioctl(fd, FIONBIO, @intFromPtr(&fionbio));
    if (ioctl_result != 0) {
        std.posix.close(fd);
        last_net_error = -12;
        return -1;
    }

    udp_fd = fd;
    local_port = port;
    socket_bound = true;
    return 0;
}

/// Close the UDP socket and reset networking state.
/// Returns 0 on success, -1 if not bound.
pub export fn umoja_unbind() c_int {
    if (!socket_bound) return -1;

    std.posix.close(udp_fd);
    udp_fd = -1;
    local_port = 0;
    socket_bound = false;
    packets_sent = 0;
    packets_received = 0;
    last_net_error = 0;
    return 0;
}

/// Return 1 if the UDP socket is bound, 0 otherwise.
pub export fn umoja_is_bound() c_int {
    return if (socket_bound) 1 else 0;
}

/// Return the last network error code (for diagnostics).
pub export fn umoja_last_net_error() c_int {
    return last_net_error;
}

/// Return the number of packets sent since bind.
pub export fn umoja_packets_sent() usize {
    return packets_sent;
}

/// Return the number of packets received since bind.
pub export fn umoja_packets_received() usize {
    return packets_received;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja real UDP gossip
// ═══════════════════════════════════════════════════════════════════════

/// Send a gossip digest to a specific peer over UDP.
/// Sends our local catalogue digest in a GOSSIP_DIGEST packet.
/// Returns 0 on success, -1 on error.
pub export fn umoja_send_digest(peer_idx: usize) c_int {
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
    if (!socket_bound) return -1;
    if (!validPeer(peer_idx)) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_HANDSHAKE_INIT, null);
    if (pkt_len == 0) return -1;

    const result = sendToPeer(peer_idx, buf[0..pkt_len]);
    if (result == 0) {
        peers[peer_idx].handshake_state = .pending;
        peers[peer_idx].last_seen = std.time.timestamp();
    }
    return result;
}

/// Send a heartbeat packet to a peer.
/// Returns 0 on success, -1 on error.
pub export fn umoja_send_heartbeat(peer_idx: usize) c_int {
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
/// Returns the packet tag on success (>0), 0 if no packet available, -1 on error.
pub export fn umoja_recv_and_process() c_int {
    if (!socket_bound) return -1;

    var buf: [MAX_PACKET_LEN]u8 = undefined;
    var src_addr: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);

    const n = recvPacket(&buf, &src_addr);
    if (n <= 0) return n; // 0 = no data, -1 = error

    const pkt = parsePacket(buf[0..@intCast(n)]) orelse return -1;

    // Find or create the peer entry for this sender.
    const peer_result = findOrAddPeerByAddr(&src_addr);
    if (peer_result < 0) return -1;
    const pidx: usize = @intCast(peer_result);

    // Store the sender's node_id if provided.
    if (pkt.node_id.len > 0 and pkt.node_id.len <= MAX_NODE_ID_LEN) {
        peers[pidx].node_id_len = copyBounded(&peers[pidx].node_id, pkt.node_id.ptr, pkt.node_id.len);
    }
    peers[pidx].last_seen = std.time.timestamp();

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

/// Discover peers by sending a broadcast discovery packet to the given
/// target address (e.g. "ff02::b04" for multicast or "::1" for loopback testing).
/// Then processes up to DISCOVERY_RECV_ATTEMPTS incoming responses.
/// Returns the number of newly discovered peers (>= 0), or -1 on error.
pub export fn umoja_discover_udp(
    target_ptr: [*]const u8,
    target_len: usize,
    target_port: u16,
) c_int {
    if (!socket_bound) return -1;
    if (target_len == 0 or target_len > MAX_HOST_LEN) return -1;

    // Build discovery packet.
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const pkt_len = buildPacket(&buf, PKT_DISCOVER, null);
    if (pkt_len == 0) return -1;

    // Parse target address.
    const target_slice = target_ptr[0..target_len];
    const parsed_ip6 = std.net.Ip6Address.parse(target_slice, target_port) catch {
        last_net_error = -20;
        return -1;
    };

    // Send discovery packet.
    const dest: *const std.posix.sockaddr = @ptrCast(&parsed_ip6.sa);
    _ = std.posix.sendto(udp_fd, buf[0..pkt_len], 0, dest, @sizeOf(std.posix.sockaddr.in6)) catch {
        last_net_error = -21;
        return -1;
    };
    packets_sent += 1;

    // Collect responses (non-blocking).
    const before = peer_count;
    var attempts: usize = 0;
    while (attempts < DISCOVERY_RECV_ATTEMPTS) : (attempts += 1) {
        const tag = umoja_recv_and_process();
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
    if (socket_bound) _ = umoja_unbind();
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    peers = [_]PeerNode{PeerNode{}} ** MAX_PEERS;
    peer_count = 0;
    local_digest = [_]u8{0} ** DIGEST_LEN;
    local_digest_valid = false;
    gossip_round_count = 0;
    prng_state = 0;
    local_node_id = [_]u8{0} ** MAX_NODE_ID_LEN;
    local_node_id_len = 0;
    local_port = 0;
    last_net_error = 0;
    packets_sent = 0;
    packets_received = 0;
    return 0;
}

/// Clean up the federation registry and Umoja gossip state.
pub export fn boj_federation_deinit() void {
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    peers = [_]PeerNode{PeerNode{}} ** MAX_PEERS;
    peer_count = 0;
    local_digest = [_]u8{0} ** DIGEST_LEN;
    local_digest_valid = false;
    gossip_round_count = 0;
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
    if (!validSlot(index)) return -1;

    nodes[index].last_heartbeat = std.time.timestamp();
    nodes[index].status = .alive;
    return 0;
}

/// Mark a node as suspected (missed heartbeats).
/// Returns 0 on success, -1 if the index is invalid.
pub export fn boj_federation_suspect(index: usize) c_int {
    if (!validSlot(index)) return -1;

    nodes[index].status = .suspected;
    return 0;
}

/// Declare a node dead (confirmed failure).
/// Returns 0 on success, -1 if the index is invalid.
pub export fn boj_federation_declare_dead(index: usize) c_int {
    if (!validSlot(index)) return -1;

    nodes[index].status = .dead;
    return 0;
}

/// Return the number of registered (active) nodes.
pub export fn boj_federation_node_count() usize {
    return node_count;
}

/// Return the number of nodes with status == alive.
pub export fn boj_federation_alive_count() usize {
    var count: usize = 0;
    for (&nodes) |*n| {
        if (n.active and n.status == .alive) count += 1;
    }
    return count;
}

/// Get the status of a node by index.
/// Returns the status integer (0-3), or -1 if the index is invalid.
pub export fn boj_federation_node_status(index: usize) c_int {
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
    // Simulated discovery: return current peer count.
    // Real implementation would:
    //   1. Bind UDP socket to 0.0.0.0:9999
    //   2. Send broadcast packet with our node_id
    //   3. Collect responses for a brief window
    //   4. Add any new peers via umoja_add_peer()
    return @intCast(peer_count);
}

/// Manually add a peer by host and port.
/// Returns the peer index on success, -1 if full or invalid input.
pub export fn umoja_add_peer(
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
    peers[slot].last_seen = std.time.timestamp();
    peers[slot].active = true;

    peer_count += 1;
    return @intCast(slot);
}

/// Remove a peer by index.
/// Returns 0 on success, -1 if the index is invalid.
pub export fn umoja_remove_peer(index: usize) c_int {
    if (!validPeer(index)) return -1;

    peers[index] = PeerNode{};
    peer_count -= 1;
    return 0;
}

/// Return the number of known peers.
pub export fn umoja_peer_count() usize {
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
    const maybe_idx = pickRandomPeer();
    if (maybe_idx) |idx| {
        peers[idx].last_seen = std.time.timestamp();
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
    if (!validPeer(peer_idx)) return -1;
    if (digest_len != DIGEST_LEN) return -1;

    @memcpy(&peers[peer_idx].catalogue_digest, digest_ptr[0..DIGEST_LEN]);
    peers[peer_idx].has_digest = true;
    peers[peer_idx].last_seen = std.time.timestamp();
    return 0;
}

/// Get our current local catalogue digest (SHA-256).
/// Writes up to out_len bytes into out_ptr.
/// Returns the number of bytes written (32 on success, 0 if no digest computed).
pub export fn umoja_get_digest(out_ptr: [*]u8, out_len: usize) usize {
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
    if (!validPeer(peer_idx)) return -1;

    peers[peer_idx].handshake_state = .pending;
    peers[peer_idx].last_seen = std.time.timestamp();
    return 0;
}

/// Mark a handshake as exchanged (both sides have sent their info).
/// This is typically called after receiving the peer's handshake response.
/// Returns 0 on success, -1 if peer index invalid or not in pending state.
pub export fn umoja_handshake_exchanged(peer_idx: usize) c_int {
    if (!validPeer(peer_idx)) return -1;
    if (peers[peer_idx].handshake_state != .pending) return -1;

    peers[peer_idx].handshake_state = .exchanged;
    peers[peer_idx].last_seen = std.time.timestamp();
    return 0;
}

/// Verify a peer's attestation: check that their catalogue digest matches
/// what we expect. If local_digest is valid and the peer has a digest,
/// compare them. Sets state to 'verified' on match, 'rejected' on mismatch.
/// Returns 1 if verified, 0 if rejected, -1 if peer invalid or no digests.
pub export fn umoja_verify_attestation(peer_idx: usize) c_int {
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
    if (!validPeer(peer_idx)) return -1;
    return @intFromEnum(peers[peer_idx].handshake_state);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports — Umoja peer state tracking
// ═══════════════════════════════════════════════════════════════════════

/// Record a heartbeat for a peer. Updates last_seen timestamp.
/// Returns 0 on success, -1 if peer index invalid.
pub export fn umoja_heartbeat(peer_idx: usize) c_int {
    if (!validPeer(peer_idx)) return -1;

    peers[peer_idx].last_seen = std.time.timestamp();
    return 0;
}

/// Get the number of completed gossip rounds.
pub export fn umoja_gossip_round_count() usize {
    return gossip_round_count;
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
