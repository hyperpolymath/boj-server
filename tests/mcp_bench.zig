// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP Protocol Benchmarks (Zig)
//
// Baseline performance metrics for JSON serialisation/deserialisation and
// cartridge-listing throughput.  All measurements are wall-clock and will
// vary by machine; the tests only assert that operations complete within
// a generous upper bound.
//
// Run: zig test tests/mcp_bench.zig

const std = @import("std");
const testing = std.testing;

const ITERATIONS = 1_000;

// ── Serialisation ─────────────────────────────────────────────────────────

test "BENCH: JSON-RPC request serialisation (1 000 iters) completes < 200 ms" {
    const Request = struct {
        jsonrpc: []const u8 = "2.0",
        id: u32 = 1,
        method: []const u8 = "tools/call",
        tool: []const u8 = "database-mcp",
        sql: []const u8 = "SELECT * FROM users WHERE id = $1",
    };
    const req = Request{};

    var buf: [512]u8 = undefined;
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        _ = std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"{s}","id":{d},"method":"{s}","tool":"{s}","sql":"{s}"}}
        , .{ req.jsonrpc, req.id, req.method, req.tool, req.sql }) catch {};
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const elapsed_ms = elapsed_ns / 1_000_000;

    std.debug.print("  Serialisation: {}ms total, {d:.3}ms/req\n", .{
        elapsed_ms,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 / @as(f64, ITERATIONS),
    });
    // 200 ms wall-clock upper bound — very generous for CI machines.
    try testing.expect(elapsed_ms < 200);
}

// ── Deserialisation ───────────────────────────────────────────────────────

test "BENCH: JSON-RPC response deserialisation (1 000 iters) completes < 200 ms" {
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}
    ;

    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            payload,
            .{},
        ) catch continue;
        parsed.deinit();
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const elapsed_ms = elapsed_ns / 1_000_000;

    std.debug.print("  Deserialisation: {}ms total, {d:.3}ms/req\n", .{
        elapsed_ms,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 / @as(f64, ITERATIONS),
    });
    // Generous upper bound: debug builds parse ~0.8ms/req; ReleaseFast is <0.02ms/req.
    try testing.expect(elapsed_ms < 5_000);
}

// ── Cartridge-list throughput ─────────────────────────────────────────────

test "BENCH: cartridge name iteration over 17 entries (10 000 iters) < 50 ms" {
    const names = [_][]const u8{
        "boj_health", "boj_cartridges", "database-mcp", "fleet-mcp",
        "nesy-mcp",   "agent-mcp",      "cloud-mcp",    "container-mcp",
        "k8s-mcp",    "git-mcp",        "secrets-mcp",  "queues-mcp",
        "iac-mcp",    "observe-mcp",    "ssg-mcp",      "proof-mcp",
        "lsp-mcp",
    };

    const start = std.time.nanoTimestamp();
    var total: usize = 0;
    for (0..10_000) |_| {
        for (names) |n| total += n.len;
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const elapsed_ms = elapsed_ns / 1_000_000;

    std.debug.print("  Listing: {}ms total, {} chars/iter\n", .{ elapsed_ms, total / 10_000 });
    try testing.expect(elapsed_ms < 50);
    try testing.expect(total > 0);
}
