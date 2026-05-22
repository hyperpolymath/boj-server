// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Laminar FFI — C-compatible exports for pipeline orchestration.

const std = @import("std");

/// Create a pipeline. Returns pipeline ID or 0 on failure.
export fn laminar_create_pipeline(name: [*c]const u8) u32 {
    if (name == null) return 0;
    return 1; // Stub
}

/// Run the next stage. Returns 0 on success, -1 on error.
export fn laminar_run_stage(pipeline_id: u32, stage_name: [*c]const u8) i32 {
    if (pipeline_id == 0 or stage_name == null) return -1;
    return 0; // Stub
}

/// Get pipeline status: 0=pending, 1=running, 2=succeeded, 3=failed, 4=cancelled.
export fn laminar_get_status(pipeline_id: u32) u8 {
    if (pipeline_id == 0) return 3; // Failed for invalid ID
    return 1; // Stub — running
}

/// Cancel a pipeline. Returns 0 on success.
export fn laminar_cancel_pipeline(pipeline_id: u32) i32 {
    if (pipeline_id == 0) return -1;
    return 0; // Stub
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "laminar-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "laminar_create_pipeline"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "laminar_run_stage"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "laminar_get_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "laminar_cancel_pipeline"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "create rejects null name" {
    try std.testing.expectEqual(@as(u32, 0), laminar_create_pipeline(null));
}

test "run stage rejects invalid pipeline" {
    try std.testing.expectEqual(@as(i32, -1), laminar_run_stage(0, "build"));
}

test "cancel rejects invalid pipeline" {
    try std.testing.expectEqual(@as(i32, -1), laminar_cancel_pipeline(0));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns laminar-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("laminar-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "laminar_create_pipeline",
        "laminar_run_stage",
        "laminar_get_status",
        "laminar_cancel_pipeline",
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
    const rc = boj_cartridge_invoke("laminar_create_pipeline", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
