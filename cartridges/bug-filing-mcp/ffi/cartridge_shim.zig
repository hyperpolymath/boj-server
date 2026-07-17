// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cartridge_shim.zig — Shared helpers for the ADR-0006 five-symbol
// cartridge ABI (`boj_cartridge_init / deinit / name / version / invoke`).
//
// The shim centralises the seven-code return convention, NUL-argument
// guards, tool-name comparison, and the buffer-too-small path so each
// cartridge's `boj_cartridge_invoke` can stay short — typically a tool
// table plus `shim.writeResult(...)`.
//
// Cartridges import this file by relative path (no build-graph change
// needed). Example:
//
//   const shim = @import("../../../ffi/zig/src/cartridge_shim.zig");
//
//   export fn boj_cartridge_invoke(
//       tool_name: [*c]const u8,
//       json_args: [*c]const u8,
//       out_buf: [*c]u8,
//       in_out_len: [*c]usize,
//   ) callconv(.c) i32 {
//       _ = json_args;
//       if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;
//       const body = if (shim.toolIs(tool_name, "foo")) "{\"result\":{}}"
//           else return shim.RC_UNKNOWN_TOOL;
//       return shim.writeResult(out_buf, in_out_len, body);
//   }

const std = @import("std");

// ── Return codes (ADR-0006 §Return codes) ────────────────────────────
//
// Frozen by ADR-0006. New failure modes compose these via the error
// JSON body — the integer surface does not grow without a follow-up ADR.

pub const RC_SUCCESS: i32 = 0;
pub const RC_UNKNOWN_TOOL: i32 = -1;
pub const RC_BAD_ARGS: i32 = -2;
pub const RC_BUFFER_TOO_SMALL: i32 = -3;
pub const RC_RUNTIME_ERROR: i32 = -4;
pub const RC_PANIC: i32 = -5;
pub const RC_AUTH_DENIED: i32 = -6;

// ── Invoke-path helpers ──────────────────────────────────────────────

/// True if any of the three mandatory `boj_cartridge_invoke` output-path
/// pointers is null. Use at the top of every invoke to short-circuit to
/// `RC_BAD_ARGS`.
pub fn invokeArgsNull(
    tool_name: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) bool {
    return tool_name == null or out_buf == null or in_out_len == null;
}

/// Compare a C-NUL-terminated tool-name pointer against a Zig string
/// literal. Caller must have already verified `tool_name` is non-null
/// (usually via `invokeArgsNull`).
///
/// Implementation note (CWE-704 fix, post-#146): uses
/// `std.mem.sliceTo(ptr, 0)` which scans the C string up to the first
/// NUL — no `@ptrCast` and no `[*:0]` re-typing. The earlier
/// `std.mem.spanZ` call was removed in Zig 0.14+ and would not
/// compile under the 0.15.1 CI pin.
pub fn toolIs(tool_name: [*c]const u8, expected: []const u8) bool {
    const s = std.mem.sliceTo(tool_name, 0);
    return std.mem.eql(u8, s, expected);
}

/// Copy `body` into `out_buf[0..*in_out_len]` (as a capacity) and update
/// `*in_out_len` to the number of bytes written. Returns `RC_SUCCESS`.
///
/// If `body.len` exceeds the current capacity stored in `*in_out_len`,
/// sets `*in_out_len` to the required size and returns
/// `RC_BUFFER_TOO_SMALL` — the caller is then expected to re-allocate
/// and retry, per ADR-0006 §Memory ownership.
///
/// Caller must have already verified that `out_buf` and `in_out_len`
/// are non-null.
pub fn writeResult(
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
    body: []const u8,
) i32 {
    const cap = in_out_len.*;
    if (body.len > cap) {
        in_out_len.* = body.len;
        return RC_BUFFER_TOO_SMALL;
    }
    @memcpy(out_buf[0..body.len], body);
    in_out_len.* = body.len;
    return RC_SUCCESS;
}

// ── Tests ────────────────────────────────────────────────────────────

test "writeResult: body fits, writes and sets length" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(RC_SUCCESS, rc);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("hello", buf[0..len]);
}

test "writeResult: too small returns -3 and sets required length" {
    var buf: [2]u8 = undefined;
    var len: usize = buf.len;
    const rc = writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(RC_BUFFER_TOO_SMALL, rc);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "writeResult: exact-fit succeeds" {
    var buf: [5]u8 = undefined;
    var len: usize = buf.len;
    const rc = writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(RC_SUCCESS, rc);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "writeResult: empty body" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = writeResult(&buf, &len, "");
    try std.testing.expectEqual(RC_SUCCESS, rc);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "toolIs: matches and rejects" {
    const name: [*c]const u8 = "foo";
    try std.testing.expect(toolIs(name, "foo"));
    try std.testing.expect(!toolIs(name, "bar"));
    try std.testing.expect(!toolIs(name, "foobar"));
    try std.testing.expect(!toolIs(name, "fo"));
}

test "invokeArgsNull: detects each null slot" {
    var buf: [4]u8 = undefined;
    var len: usize = 4;
    const name: [*c]const u8 = "x";
    try std.testing.expect(!invokeArgsNull(name, &buf, &len));
    try std.testing.expect(invokeArgsNull(null, &buf, &len));
    try std.testing.expect(invokeArgsNull(name, null, &len));
    try std.testing.expect(invokeArgsNull(name, &buf, null));
}
