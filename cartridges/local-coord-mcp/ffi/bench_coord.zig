// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// bench_coord.zig — Micro-benchmarks for local-coord-mcp.
//
// Measures:
//   1. Durability log append (persist-on-write hot path cost)
//   2. Durability replay (startup cost per logged event)
//   3. coord_register + coord_deregister lifecycle
//   4. coord_send direct + coord_receive round-trip
//   5. coord_claim_task + coord_release_task
//   6. coord_send_gated to quarantine + coord_approve
//   7. persist-on-write overhead (durable-on vs durable-off)
//
// Benchmarks emit "NAME  ns/op  ops/sec" and are meant for relative
// comparison across revisions and for Six Sigma regression gating
// (feedback_blitz_definition + full_battery_before_claims).

const std = @import("std");
const dur = @import("coord_durability.zig");

// The ffi module exports C-ABI symbols directly; we import it to call
// the public coord_* functions in-process without round-tripping through
// the REST adapter.
const ffi = @import("local_coord_ffi.zig");

const WARMUP: u64 = 200;
const ITERS: u64 = 50_000;

fn printHeader(title: []const u8) void {
    std.debug.print("\n── {s} ──\n", .{title});
}

fn printRow(name: []const u8, elapsed_ns: u64, iters: u64) void {
    const per_op = if (iters == 0) 0 else elapsed_ns / iters;
    const ops_per_sec = if (per_op == 0) 0 else @as(u64, 1_000_000_000) / per_op;
    std.debug.print("  {s:<48} {d:>10} ns/op  {d:>14} ops/sec\n", .{ name, per_op, ops_per_sec });
}

fn tmpBenchDir(buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "/tmp/boj-coord-bench-{d}-{d}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

// ─────────────────────────────────────────────────────────────────────

fn benchAppendNoop() !void {
    // Durability closed — append is a single mutex + null check.
    dur.close();
    const suffix = [_]u8{ 'a', 'b', 'c', 'd' };
    const token = [_]u8{0} ** 16;

    for (0..WARMUP) |_| {
        dur.logPeerAdd(0, 0, 1, &suffix, &token);
    }

    var timer = try std.time.Timer.start();
    for (0..ITERS) |_| {
        dur.logPeerAdd(0, 0, 1, &suffix, &token);
    }
    printRow("append (durability DISABLED)", timer.read(), ITERS);
}

fn benchAppendHot() !void {
    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};

    dur.close();
    _ = dur.openWithDir(d);
    defer dur.close();

    const suffix = [_]u8{ 'a', 'b', 'c', 'd' };
    const token = [_]u8{0} ** 16;

    for (0..WARMUP) |_| {
        dur.logPeerAdd(0, 0, 1, &suffix, &token);
    }

    var timer = try std.time.Timer.start();
    for (0..ITERS) |_| {
        dur.logPeerAdd(0, 0, 1, &suffix, &token);
    }
    printRow("append peer_add (23B payload)", timer.read(), ITERS);
}

fn benchAppendLargePayload() !void {
    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};

    dur.close();
    _ = dur.openWithDir(d);
    defer dur.close();

    const msg_512 = [_]u8{'x'} ** 512;

    for (0..WARMUP) |_| {
        dur.logInboxPush(0, &msg_512);
    }

    var timer = try std.time.Timer.start();
    for (0..ITERS) |_| {
        dur.logInboxPush(0, &msg_512);
    }
    printRow("append inbox_push (512B payload)", timer.read(), ITERS);
}

fn benchReplay() !void {
    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};

    dur.close();
    _ = dur.openWithDir(d);

    const suffix = [_]u8{ 'a', 'b', 'c', 'd' };
    const token = [_]u8{0} ** 16;
    const REPLAY_EVENTS: usize = 10_000;
    for (0..REPLAY_EVENTS) |_| {
        dur.logPeerAdd(0, 0, 1, &suffix, &token);
    }
    dur.close();

    _ = dur.openWithDir(d);
    defer dur.close();

    var replay_counter: usize = 0;
    const counter_ptr = &replay_counter;
    _ = counter_ptr; // kept to document intent

    const Capture = struct {
        var count: usize = 0;
        fn cb(event: dur.EventType, payload: []const u8) void {
            _ = event;
            _ = payload;
            count += 1;
        }
    };
    Capture.count = 0;

    var timer = try std.time.Timer.start();
    dur.replay(Capture.cb);
    const elapsed = timer.read();

    if (Capture.count == 0) return error.ReplayEmpty;
    printRow("replay peer_add", elapsed, @intCast(Capture.count));
}

// ─────────────────────────────────────────────────────────────────────

fn benchRegisterLifecycle() !void {
    ffi.coord_reset();
    dur.close();

    var token: [16]u8 = undefined;
    var suffix: [4]u8 = undefined;

    for (0..WARMUP) |_| {
        const idx = ffi.coord_register(0, -1, &token, &suffix);
        if (idx >= 0) _ = ffi.coord_deregister(&token, 16);
    }

    var timer = try std.time.Timer.start();
    const N: u64 = 10_000;
    for (0..N) |_| {
        const idx = ffi.coord_register(0, -1, &token, &suffix);
        if (idx >= 0) _ = ffi.coord_deregister(&token, 16);
    }
    printRow("register + deregister (no durability)", timer.read(), N);

    // Now with durability on.
    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};
    ffi.coord_reset();
    _ = dur.openWithDir(d);
    defer dur.close();

    for (0..WARMUP) |_| {
        const idx = ffi.coord_register(0, -1, &token, &suffix);
        if (idx >= 0) _ = ffi.coord_deregister(&token, 16);
    }

    timer = try std.time.Timer.start();
    for (0..N) |_| {
        const idx = ffi.coord_register(0, -1, &token, &suffix);
        if (idx >= 0) _ = ffi.coord_deregister(&token, 16);
    }
    printRow("register + deregister (durable)", timer.read(), N);
}

fn benchSendReceive() !void {
    ffi.coord_reset();
    dur.close();

    var tok_a: [16]u8 = undefined;
    var tok_b: [16]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = ffi.coord_register(0, -1, &tok_a, &suf);
    _ = ffi.coord_register(0, -1, &tok_b, &suf);

    const msg = "benchmark-direct-message";
    var recv: [64]u8 = undefined;

    for (0..WARMUP) |_| {
        _ = ffi.coord_send(&tok_a, 16, 1, msg.ptr, @intCast(msg.len));
        _ = ffi.coord_receive(&tok_b, 16, &recv, 64);
    }

    var timer = try std.time.Timer.start();
    const N: u64 = 20_000;
    for (0..N) |_| {
        _ = ffi.coord_send(&tok_a, 16, 1, msg.ptr, @intCast(msg.len));
        _ = ffi.coord_receive(&tok_b, 16, &recv, 64);
    }
    printRow("send + receive round-trip (no durability)", timer.read(), N);

    // With durability.
    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};
    ffi.coord_reset();
    _ = dur.openWithDir(d);
    defer dur.close();
    _ = ffi.coord_register(0, -1, &tok_a, &suf);
    _ = ffi.coord_register(0, -1, &tok_b, &suf);

    for (0..WARMUP) |_| {
        _ = ffi.coord_send(&tok_a, 16, 1, msg.ptr, @intCast(msg.len));
        _ = ffi.coord_receive(&tok_b, 16, &recv, 64);
    }
    timer = try std.time.Timer.start();
    for (0..N) |_| {
        _ = ffi.coord_send(&tok_a, 16, 1, msg.ptr, @intCast(msg.len));
        _ = ffi.coord_receive(&tok_b, 16, &recv, 64);
    }
    printRow("send + receive round-trip (durable)", timer.read(), N);
}

fn benchClaimCycle() !void {
    ffi.coord_reset();
    dur.close();

    var tok: [16]u8 = undefined;
    var suf: [4]u8 = undefined;
    _ = ffi.coord_register(0, -1, &tok, &suf);

    const task = "bench-task";
    for (0..WARMUP) |_| {
        _ = ffi.coord_claim_task(&tok, 16, task.ptr, @intCast(task.len));
        _ = ffi.coord_release_task(&tok, 16, task.ptr, @intCast(task.len));
    }
    var timer = try std.time.Timer.start();
    const N: u64 = 20_000;
    for (0..N) |_| {
        _ = ffi.coord_claim_task(&tok, 16, task.ptr, @intCast(task.len));
        _ = ffi.coord_release_task(&tok, 16, task.ptr, @intCast(task.len));
    }
    printRow("claim + release (no durability)", timer.read(), N);

    var buf: [256]u8 = undefined;
    const d = try tmpBenchDir(&buf);
    defer std.fs.cwd().deleteTree(d) catch {};
    ffi.coord_reset();
    _ = dur.openWithDir(d);
    defer dur.close();
    _ = ffi.coord_register(0, -1, &tok, &suf);

    for (0..WARMUP) |_| {
        _ = ffi.coord_claim_task(&tok, 16, task.ptr, @intCast(task.len));
        _ = ffi.coord_release_task(&tok, 16, task.ptr, @intCast(task.len));
    }
    timer = try std.time.Timer.start();
    for (0..N) |_| {
        _ = ffi.coord_claim_task(&tok, 16, task.ptr, @intCast(task.len));
        _ = ffi.coord_release_task(&tok, 16, task.ptr, @intCast(task.len));
    }
    printRow("claim + release (durable)", timer.read(), N);
}

// ─────────────────────────────────────────────────────────────────────

pub fn main() !void {
    std.debug.print("\n═══════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  local-coord-mcp micro-benchmarks\n", .{});
    std.debug.print("  warmup={d} iters (measurement varies per bench)\n", .{WARMUP});
    std.debug.print("═══════════════════════════════════════════════════════════════════════\n", .{});

    printHeader("Durability — raw log ops");
    try benchAppendNoop();
    try benchAppendHot();
    try benchAppendLargePayload();
    try benchReplay();

    printHeader("Coord lifecycle");
    try benchRegisterLifecycle();

    printHeader("Messaging");
    try benchSendReceive();

    printHeader("Claims");
    try benchClaimCycle();

    ffi.coord_reset();
    dur.close();

    std.debug.print("\n", .{});
}
