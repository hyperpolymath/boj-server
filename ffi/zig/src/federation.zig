// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Federation FFI — Umoja gossip protocol runtime (Phase 5 stub).
//
// Implements the node handshake and heartbeat protocol for BoJ federation.
// Tracks up to 16 peer nodes with status, heartbeat timestamps, and
// catalogue hash state for sync detection.
//
// The gossip protocol follows a SWIM-inspired model:
//   alive → suspected (missed heartbeats) → dead (confirmed failure)
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

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// Node liveness status (SWIM-style protocol states).
pub const NodeStatus = enum(c_int) {
    unknown = 0,
    alive = 1,
    suspected = 2,
    dead = 3,
};

/// A federation peer node entry.
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
// Global state (module-level, C-ABI safe)
// ═══════════════════════════════════════════════════════════════════════

/// The federation node registry.
var nodes: [MAX_NODES]FederationNode = [_]FederationNode{FederationNode{}} ** MAX_NODES;

/// Number of registered nodes.
var node_count: usize = 0;

// ═══════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot index is in-bounds and active.
fn validSlot(index: usize) bool {
    return index < MAX_NODES and nodes[index].active;
}

/// Copy a bounded byte slice into a fixed buffer. Returns actual length copied.
fn copyBounded(dst: []u8, src_ptr: [*]const u8, src_len: usize) usize {
    const len = @min(src_len, dst.len);
    @memcpy(dst[0..len], src_ptr[0..len]);
    return len;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI exports
// ═══════════════════════════════════════════════════════════════════════

/// Initialise (or reset) the federation registry.
/// Returns 0 on success.
pub export fn boj_federation_init() c_int {
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
    return 0;
}

/// Clean up the federation registry.
pub export fn boj_federation_deinit() void {
    nodes = [_]FederationNode{FederationNode{}} ** MAX_NODES;
    node_count = 0;
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
// Tests
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
