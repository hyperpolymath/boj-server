// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Reposystem FFI — C-compatible exports for repository management.

const std = @import("std");

/// List repository count.
export fn reposystem_list_repos_count() u32 {
    return 0; // Stub
}

/// Check health of a repo. Returns 0=green, 1=yellow, 2=red, 3=unknown.
export fn reposystem_check_health(repo_name: [*c]const u8) u8 {
    if (repo_name == null) return 3;
    return 0; // Stub — green
}

/// Sync mirrors for a repo. Returns 0 on success, -1 on error.
export fn reposystem_sync_mirrors(repo_name: [*c]const u8) i32 {
    if (repo_name == null) return -1;
    return 0; // Stub
}

/// Run audit. Returns number of checks passed.
export fn reposystem_run_audit(repo_name: [*c]const u8) u32 {
    if (repo_name == null) return 0;
    return 17; // Stub — all RSR checks pass
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "reposystem-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "reposystem_list_repos"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "reposystem_check_health"))
        "{\"result\":{\"health\":\"healthy\",\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "reposystem_sync_mirrors"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "reposystem_run_audit"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "health returns unknown for null" {
    try std.testing.expectEqual(@as(u8, 3), reposystem_check_health(null));
}

test "sync rejects null repo" {
    try std.testing.expectEqual(@as(i32, -1), reposystem_sync_mirrors(null));
}

test "audit returns zero for null" {
    try std.testing.expectEqual(@as(u32, 0), reposystem_run_audit(null));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns reposystem-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("reposystem-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "reposystem_list_repos",
        "reposystem_check_health",
        "reposystem_sync_mirrors",
        "reposystem_run_audit",
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
    const rc = boj_cartridge_invoke("reposystem_list_repos", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
