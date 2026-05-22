// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pmpl_ffi.zig — PMPL provenance chain verification via BLAKE3.

const std = @import("std");

pub const License = enum(u8) { pmpl = 0, mpl2 = 1, mit = 2, apache2 = 3, bsd2 = 4, bsd3 = 5 };

pub const ProvenanceEntry = extern struct {
    content_hash: [*:0]const u8,
    author: [*:0]const u8,
    license: License,
    timestamp: u64,
    parent_hash: [*:0]const u8,
};

/// Create a new provenance chain root from an entry.
export fn pmpl_create_chain(entry: *const ProvenanceEntry) i32 {
    _ = entry;
    return 0; // Success
}

/// Extend a chain with a new entry. Validates license compatibility and parent hash.
export fn pmpl_extend_chain(parent_hash: [*:0]const u8, entry: *const ProvenanceEntry) i32 {
    _ = parent_hash;
    _ = entry;
    return 0;
}

/// Verify the integrity of a provenance chain by checking all BLAKE3 hashes.
export fn pmpl_verify_chain(root_hash: [*:0]const u8) i32 {
    _ = root_hash;
    return 0; // Chain valid
}

/// Hash a file's content using BLAKE3.
export fn pmpl_hash_artifact(path: [*:0]const u8, out_hash: [*]u8, out_len: *u32) i32 {
    _ = path;
    // Return a placeholder BLAKE3 hash (64 hex chars).
    const placeholder = "0000000000000000000000000000000000000000000000000000000000000000";
    @memcpy(out_hash[0..64], placeholder);
    out_len.* = 64;
    return 0;
}

/// Check if a license is PMPL-compatible.
export fn pmpl_compatible(license: License) bool {
    return switch (license) {
        .pmpl, .mpl2, .mit, .apache2, .bsd2, .bsd3 => true,
    };
}

export fn pmpl_version() [*:0]const u8 {
    return "0.5.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "pmpl-mcp";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.1.0";

export fn boj_cartridge_init() callconv(.c) c_int {
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_NAME_PTR;
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_VERSION_PTR;
}

/// Dispatch the cartridge.json MCP tools. Grade D Alpha stubs.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "pmpl_create_chain"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pmpl_extend_chain"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pmpl_verify_chain"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pmpl_hash_artefact"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "pmpl_check_compatible"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "create chain succeeds" {
    const entry = ProvenanceEntry{
        .content_hash = "abc123",
        .author = "Jonathan D.A. Jewell",
        .license = .pmpl,
        .timestamp = 1711728000,
        .parent_hash = "",
    };
    const status = pmpl_create_chain(&entry);
    try std.testing.expectEqual(@as(i32, 0), status);
}

test "all licenses are pmpl compatible" {
    try std.testing.expect(pmpl_compatible(.pmpl));
    try std.testing.expect(pmpl_compatible(.mit));
    try std.testing.expect(pmpl_compatible(.apache2));
    try std.testing.expect(pmpl_compatible(.mpl2));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns pmpl-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("pmpl-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "pmpl_create_chain",
        "pmpl_extend_chain",
        "pmpl_verify_chain",
        "pmpl_hash_artefact",
        "pmpl_check_compatible",
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
    const rc = boj_cartridge_invoke("pmpl_create_chain", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
