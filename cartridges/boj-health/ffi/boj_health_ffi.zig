// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// boj-health cartridge — ADR-0006 five-symbol Zig FFI implementation.
//
// Reference implementation: no external services, no env vars required.
// Demonstrates the full Idris2 ABI → Zig FFI → boj-invoke → Elixir chain.
//
// Tools:
//   boj_health_status  — JSON health blob: ok, version, uptime_ms
//   boj_health_ping    — always {pong: true}
//   boj_health_version — version string only
//
// Runtime note: boj-invoke targets x86_64-linux-gnu (glibc) so it uses
// DlDynLib (real dlopen). This .so can therefore safely use link_libc = true
// (glibc) without a musl/glibc clash. The std_options override prevents
// this .so from overwriting boj-invoke's SIGSEGV handler at dlopen time.

const std = @import("std");
const shim = @import("cartridge_shim");

// Use the C clock_gettime directly — straightforward, no Zig TLS involved.
const c = @cImport({
    @cInclude("time.h");
});

// Suppress Zig's debug segfault signal handler so this .so does not
// overwrite boj-invoke's handler when dlopened into the host Zig binary.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

var init_time_ms: i64 = 0;
var init_done: bool = false;

// ─── Five-symbol ADR-0006 ABI ────────────────────────────────────────────────

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return "boj-health";
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return "0.1.0";
}

export fn boj_cartridge_init() callconv(.c) c_int {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    init_time_ms = ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
    init_done = true;
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {
    init_done = false;
}

export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    if (shim.toolIs(tool_name, "boj_health_ping")) {
        return shim.writeResult(out_buf, in_out_len, "{\"pong\":true}");
    }

    if (shim.toolIs(tool_name, "boj_health_version")) {
        return shim.writeResult(out_buf, in_out_len, "{\"version\":\"0.1.0\"}");
    }

    if (shim.toolIs(tool_name, "boj_health_status")) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const now_ms: i64 = ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
        const uptime: i64 = if (init_done) now_ms - init_time_ms else 0;

        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            "{{\"ok\":true,\"version\":\"0.1.0\",\"uptime_ms\":{d},\"cartridge\":\"boj-health\"}}",
            .{uptime},
        ) catch return shim.RC_RUNTIME_ERROR;
        return shim.writeResult(out_buf, in_out_len, body);
    }

    return shim.RC_UNKNOWN_TOOL;
}
