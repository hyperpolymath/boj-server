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
// C-ABI exports — Federation node registry (original SWIM layer)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise (or reset) the federation registry and Umoja gossip state.
/// Returns 0 on success.
pub export fn boj_federation_init() c_int {
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    peers = [_]PeerNode{PeerNode{}} ** MAX_PEERS;
    peer_count = 0;
    local_digest = [_]u8{0} ** DIGEST_LEN;
    local_digest_valid = false;
    gossip_round_count = 0;
    prng_state = 0;
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
