// SPDX-License-Identifier: PMPL-1.0-or-later
// Bofig Cartridge FFI — Evidence graph query bindings

const std = @import("std");
const mem = std.mem;

// Evidence source constants
pub const SOURCE_DOCUMENT = 0;
pub const SOURCE_INTERVIEW = 1;
pub const SOURCE_DATASET = 2;
pub const SOURCE_ANALYSIS = 3;
pub const SOURCE_MEDIA = 4;
pub const SOURCE_ARCHIVE = 5;

// Confidence levels
pub const CONF_HIGH = 0;
pub const CONF_MEDIUM = 1;
pub const CONF_LOW = 2;
pub const CONF_UNVERIFIED = 3;

// Result codes
pub const RESULT_SUCCESS = 0;
pub const RESULT_NOT_FOUND = 1;
pub const RESULT_QUERY_ERROR = 2;
pub const RESULT_INVALID_INPUT = 3;

// Evidence struct
pub const Evidence = extern struct {
    evidence_id: [128]u8,
    title: [256]u8,
    source: u32,
    confidence: u32,
    description: [1024]u8,
    date_collected: [32]u8,
};

// Connection struct
pub const Connection = extern struct {
    from_id: [128]u8,
    to_id: [128]u8,
    relationship_type: [128]u8,
    strength: u32,
    description: [512]u8,
};

// Query evidence by ID
pub export fn bofig_query_evidence(
    evidence_id: [*c]const u8,
    out_evidence: [*c]Evidence,
) callconv(.C) i32 {
    if (evidence_id == null or out_evidence == null) {
        return RESULT_INVALID_INPUT;
    }

    // Stub — would query evidence graph database
    return RESULT_NOT_FOUND;
}

// Search evidence by keyword
pub export fn bofig_search_evidence(
    keyword: [*c]const u8,
    out_results: [*c]Evidence,
    max_results: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (keyword == null or out_results == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would search graph
    }
    return RESULT_SUCCESS;
}

// Get connections for an entity
pub export fn bofig_get_connections(
    entity_id: [*c]const u8,
    out_connections: [*c]Connection,
    max_connections: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (entity_id == null or out_connections == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would enumerate connections
    }
    return RESULT_SUCCESS;
}

// Find shortest path between two nodes
pub export fn bofig_find_path(
    from_id: [*c]const u8,
    to_id: [*c]const u8,
    out_path: [*c][128]u8,
    max_path_nodes: usize,
    out_path_length: [*c]usize,
) callconv(.C) i32 {
    if (from_id == null or to_id == null or out_path == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_path_length) |len| {
        len.* = 0;  // Stub — would compute shortest path
    }
    return RESULT_NOT_FOUND;
}

// Execute graph query
pub export fn bofig_execute_query(
    query: [*c]const u8,
    out_result: [*c]u8,
    out_len: usize,
) callconv(.C) i32 {
    if (query == null or out_result == null) {
        return RESULT_QUERY_ERROR;
    }

    const result_stub = "Query executed (stub)";
    if (out_len > 0) {
        const copy_len = @min(result_stub.len, out_len - 1);
        @memcpy(out_result[0..copy_len], result_stub[0..copy_len]);
        out_result[copy_len] = 0;
        return RESULT_SUCCESS;
    }
    return RESULT_QUERY_ERROR;
}

// Get graph statistics
pub export fn bofig_get_graph_stats(
    out_node_count: [*c]usize,
    out_edge_count: [*c]usize,
) callconv(.C) i32 {
    if (out_node_count) |nc| {
        nc.* = 0;  // Stub
    }
    if (out_edge_count) |ec| {
        ec.* = 0;  // Stub
    }
    return RESULT_SUCCESS;
}
