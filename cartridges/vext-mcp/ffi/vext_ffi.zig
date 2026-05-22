// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Vext FFI — C-compatible exports for verifiable communications.

const std = @import("std");

/// Verify status codes: 0=verified, 1=unverified, 2=tampered, 3=expired.
pub const VerifyStatus = enum(u8) { verified = 0, unverified = 1, tampered = 2, expired = 3 };

/// Verify a message. Returns status code.
export fn vext_verify_message(msg: [*c]const u8, sig: [*c]const u8) u8 {
    if (msg == null or sig == null) return @intFromEnum(VerifyStatus.unverified);
    return @intFromEnum(VerifyStatus.verified); // Stub
}

/// Check an attestation by issuer. Returns depth or 0 if not found.
export fn vext_check_attestation(issuer: [*c]const u8) u32 {
    if (issuer == null) return 0;
    return 1; // Stub
}

/// Append an entry to the verification chain. Returns 0 on success.
export fn vext_append_chain(payload: [*c]const u8) i32 {
    if (payload == null) return -1;
    return 0; // Stub
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "vext-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "vext_verify_message"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vext_check_attestation"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vext_append_chain"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ── Tests ──

test "verify rejects null message" {
    try std.testing.expectEqual(@as(u8, 1), vext_verify_message(null, "sig"));
}

test "verify accepts valid inputs" {
    try std.testing.expectEqual(@as(u8, 0), vext_verify_message("hello", "sig"));
}

test "append rejects null payload" {
    try std.testing.expectEqual(@as(i32, -1), vext_append_chain(null));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns vext-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("vext-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "vext_verify_message",
        "vext_check_attestation",
        "vext_append_chain",
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
    const rc = boj_cartridge_invoke("vext_verify_message", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
