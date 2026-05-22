// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Aerie FFI — C-compatible exports for environment management.
//
// Reference implementation of the 5-symbol cartridge ABI (ADR-0006):
//   boj_cartridge_init / deinit / name / version / invoke.
// Other cartridges should follow this file's shape.

const std = @import("std");

// ── Bespoke tool exports (kept for backward compat during migration) ──

/// List active environment count.
export fn aerie_list_envs_count() u32 {
    return 0; // Stub
}

/// Create an environment. Returns env ID or 0 on failure.
export fn aerie_create_env(name: [*c]const u8, mem_mb: u32) u32 {
    if (name == null or mem_mb == 0) return 0;
    return 1; // Stub
}

/// Destroy an environment. Returns 0 on success.
export fn aerie_destroy_env(env_id: u32) i32 {
    if (env_id == 0) return -1;
    return 0; // Stub
}

/// Get env status: 0=provisioning, 1=ready, 2=destroying, 3=destroyed, 4=error.
export fn aerie_get_status(env_id: u32) u8 {
    if (env_id == 0) return 4; // Error
    return 1; // Stub — ready
}

// ── Standard ABI symbols (ADR-0005 + ADR-0006) ─────────────────────────

const shim = @import("cartridge_shim.zig");

// String literals in Zig are already NUL-terminated sentinel arrays; hold
// their addresses in module-level constants so the exported pointers have
// stable lifetime.
const CARTRIDGE_NAME_PTR: [*:0]const u8 = "aerie-mcp";
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

/// ADR-0006 reference: dispatch `tool_name` with `json_args`, write result
/// into `out_buf`/`*in_out_len`. Return codes documented in ADR-0006.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args; // reference implementation ignores args

    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    // Tool table — extend this for every tool the cartridge exposes.
    const body: []const u8 = if (shim.toolIs(tool_name, "list_envs_count"))
        "{\"result\":{\"count\":0}}"
    else if (shim.toolIs(tool_name, "create_env"))
        "{\"result\":{\"env_id\":1}}"
    else if (shim.toolIs(tool_name, "destroy_env"))
        "{\"result\":{\"ok\":true}}"
    else if (shim.toolIs(tool_name, "get_status"))
        "{\"result\":{\"status\":\"ready\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "create rejects null name" {
    try std.testing.expectEqual(@as(u32, 0), aerie_create_env(null, 512));
}

test "create rejects zero memory" {
    try std.testing.expectEqual(@as(u32, 0), aerie_create_env("dev", 0));
}

test "destroy rejects zero id" {
    try std.testing.expectEqual(@as(i32, -1), aerie_destroy_env(0));
}

test "boj_cartridge_name returns aerie-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("aerie-mcp", n);
}

test "boj_cartridge_version returns semver" {
    const v = std.mem.span(boj_cartridge_version());
    try std.testing.expectEqualStrings("0.1.0", v);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke unknown tool returns -1" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke known tool writes JSON and returns 0" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("list_envs_count", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "count") != null);
}

test "invoke with too-small buffer returns -3 and sets required length" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("list_envs_count", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
