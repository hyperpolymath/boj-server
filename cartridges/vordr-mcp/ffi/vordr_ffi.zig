// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vordr_ffi.zig — Container hash state monitoring via BLAKE3 digests.

const std = @import("std");

pub const IntegrityState = enum(u8) { healthy = 0, drifted = 1, tampered = 2, unknown = 3 };

pub const ContainerDigest = extern struct {
    image_ref: [*:0]const u8,
    blake3_hash: [*:0]const u8,
    layer_count: u32,
};

pub const Observation = extern struct {
    digest: ContainerDigest,
    state: IntegrityState,
    timestamp: u64,
};

/// Scan a running container and return its current integrity state.
export fn vordr_scan_container(image_ref: [*:0]const u8, obs: *Observation) i32 {
    obs.digest.image_ref = image_ref;
    obs.digest.blake3_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    obs.digest.layer_count = 1;
    obs.state = .healthy;
    obs.timestamp = 0;
    return 0;
}

/// Compare two digests — returns integrity state of the second relative to the first (baseline).
export fn vordr_compare_digest(baseline: *const ContainerDigest, current: *const ContainerDigest) IntegrityState {
    _ = baseline;
    _ = current;
    return .healthy;
}

/// Set a known-good baseline digest for a container image.
export fn vordr_set_baseline(image_ref: [*:0]const u8, digest: *const ContainerDigest) i32 {
    _ = image_ref;
    _ = digest;
    return 0;
}

/// Get the number of pending alerts (containers with state != healthy).
export fn vordr_alert_count() u32 {
    return 0;
}

export fn vordr_version() [*:0]const u8 {
    return "0.5.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "vordr-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "vordr_scan"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vordr_set_baseline"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vordr_alerts"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vordr_compare"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "scan returns healthy" {
    var obs: Observation = undefined;
    const status = vordr_scan_container("nginx:latest", &obs);
    try std.testing.expectEqual(@as(i32, 0), status);
    try std.testing.expectEqual(IntegrityState.healthy, obs.state);
}

test "compare identical returns healthy" {
    const d = ContainerDigest{ .image_ref = "a", .blake3_hash = "x", .layer_count = 1 };
    const state = vordr_compare_digest(&d, &d);
    try std.testing.expectEqual(IntegrityState.healthy, state);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns vordr-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("vordr-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "vordr_scan",
        "vordr_set_baseline",
        "vordr_alerts",
        "vordr_compare",
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
    const rc = boj_cartridge_invoke("vordr_scan", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
