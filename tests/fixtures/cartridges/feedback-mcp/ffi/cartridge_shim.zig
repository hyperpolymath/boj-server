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

// ── Shared runtime Io (Zig 0.16 compat) ──────────────────────────────
//
// Zig 0.16 moved blocking primitives and the wall clock onto the
// `std.Io` interface (`std.Thread.Mutex` and `std.time.*Timestamp`
// were removed from the stdlib). The shim owns one process-wide Io
// backed by `std.Io.Threaded` so cartridge code keeps drop-in call
// sites — `var m: shim.Mutex = .{}; m.lock(); defer m.unlock();` and
// `shim.milliTimestamp()` — without threading an Io handle through the
// C ABI. Cartridges that need richer Io (http, fs, net) should use
// this same `shim.io()` rather than constructing their own runtime.

var shared_threaded: std.Io.Threaded = undefined;
var shared_io_state: std.atomic.Value(u8) = .init(0); // 0=uninit 1=initing 2=ready

/// The process-wide `std.Io`, lazily initialised on first use.
/// Thread-safe: a single CAS winner runs `Threaded.init`; racing
/// callers yield until it is published.
pub fn io() std.Io {
    if (shared_io_state.load(.acquire) != 2) {
        if (shared_io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            shared_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            shared_io_state.store(2, .release);
        } else {
            while (shared_io_state.load(.acquire) != 2) std.Thread.yield() catch {};
        }
    }
    return shared_threaded.io();
}

/// Drop-in replacement for the removed `std.Thread.Mutex`, backed by
/// `std.Io.Mutex` over the shim's shared Io. Zero-initialisable:
/// `var m: shim.Mutex = .{};`
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(io());
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(io());
    }

    pub fn tryLock(m: *Mutex) bool {
        return m.inner.tryLock();
    }
};

/// Nanoseconds since the POSIX epoch (drop-in for the removed
/// `std.time.nanoTimestamp`).
pub fn nanoTimestamp() i128 {
    const ts = std.Io.Clock.Timestamp.now(io(), .real);
    return @intCast(ts.raw.nanoseconds);
}

/// Milliseconds since the POSIX epoch (drop-in for the removed
/// `std.time.milliTimestamp`).
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

/// Seconds since the POSIX epoch (drop-in for the removed
/// `std.time.timestamp`).
pub fn timestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_s));
}

/// Fill `buffer` with cryptographically secure random bytes (drop-in for
/// the removed `std.crypto.random.bytes`).
pub fn randomBytes(buffer: []u8) void {
    io().random(buffer);
}

/// Cryptographically secure random integer (drop-in for the removed
/// `std.crypto.random.int(T)`).
pub fn randomInt(comptime T: type) T {
    var buf: [@sizeOf(T)]u8 = undefined;
    io().random(&buf);
    return @bitCast(buf);
}

/// Process environment lookup (drop-in for the removed
/// `std.posix.getenv`). Only analysed when referenced; callers must link
/// libc (`root_module.link_libc = true` — the standard ffi build shape).
pub fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

// ── Tests ────────────────────────────────────────────────────────────

test "Mutex: lock/unlock and tryLock round-trip" {
    var m: Mutex = .{};
    m.lock();
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "timestamps: monotone-ish and unit-consistent" {
    const ns = nanoTimestamp();
    const ms = milliTimestamp();
    const s = timestamp();
    try std.testing.expect(ns > 0);
    // Same instant expressed in three units must agree to within a step.
    try std.testing.expect(@abs(@divTrunc(ns, std.time.ns_per_s) - s) <= 1);
    try std.testing.expect(@abs(@divTrunc(ms, std.time.ms_per_s) - s) <= 1);
}

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
