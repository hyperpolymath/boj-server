// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Benchmark — Measures cartridge lifecycle operation latency.
//
// Benchmarks:
//   1. Catalogue init/deinit cycle
//   2. Cartridge registration throughput
//   3. Mount/unmount latency (the critical path)
//   4. Query operations (count, status, is_mounted)
//   5. Hash verification throughput

const std = @import("std");
const catalogue = @import("catalogue");

const WARMUP_ITERS: u64 = 100;
const BENCH_ITERS: u64 = 100_000;

fn benchmarkFn(comptime name: []const u8, comptime func: anytype) void {
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        func();
    }

    // Measure
    var timer = std.time.Timer.start() catch {
        std.debug.print("Timer unavailable\n", .{});
        return;
    };

    for (0..BENCH_ITERS) |_| {
        func();
    }

    const elapsed_ns = timer.read();
    const per_op_ns = elapsed_ns / BENCH_ITERS;
    const ops_per_sec = if (per_op_ns > 0) @as(u64, 1_000_000_000) / per_op_ns else 0;

    std.debug.print("  {s:<40} {d:>8} ns/op    {d:>12} ops/sec\n", .{
        name,
        per_op_ns,
        ops_per_sec,
    });
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  BoJ Server Benchmarks\n", .{});
    std.debug.print("  Iterations: {d} (warmup: {d})\n", .{ BENCH_ITERS, WARMUP_ITERS });
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});

    // --- Lifecycle ---
    std.debug.print("Lifecycle:\n", .{});
    benchmarkFn("init + deinit", struct {
        fn f() void {
            _ = catalogue.boj_catalogue_init();
            catalogue.boj_catalogue_deinit();
        }
    }.f);

    // --- Registration ---
    std.debug.print("\nRegistration:\n", .{});

    // Setup: init catalogue for registration benchmarks
    _ = catalogue.boj_catalogue_init();

    benchmarkFn("register cartridge", struct {
        fn f() void {
            // Reset to avoid filling up
            _ = catalogue.boj_catalogue_init();
            const name = "bench-cartridge";
            const ver = "1.0.0";
            _ = catalogue.boj_catalogue_register(
                name.ptr,
                name.len,
                ver.ptr,
                ver.len,
                1, // ready
                0, // teranga
                3, // database
            );
        }
    }.f);

    benchmarkFn("register + add 3 protocols", struct {
        fn f() void {
            _ = catalogue.boj_catalogue_init();
            const name = "bench-multi";
            const ver = "1.0.0";
            _ = catalogue.boj_catalogue_register(
                name.ptr,
                name.len,
                ver.ptr,
                ver.len,
                1,
                0,
                3,
            );
            _ = catalogue.boj_catalogue_add_protocol(1); // MCP
            _ = catalogue.boj_catalogue_add_protocol(8); // gRPC
            _ = catalogue.boj_catalogue_add_protocol(9); // REST
        }
    }.f);

    // --- Mount/Unmount (critical path) ---
    std.debug.print("\nMount/Unmount (critical path):\n", .{});

    // Setup: register a ready cartridge for mount benchmarks
    _ = catalogue.boj_catalogue_init();
    {
        const name = "mount-bench";
        const ver = "1.0.0";
        _ = catalogue.boj_catalogue_register(
            name.ptr,
            name.len,
            ver.ptr,
            ver.len,
            1, // ready
            0,
            3,
        );
    }

    benchmarkFn("mount (ready cartridge)", struct {
        fn f() void {
            const r = catalogue.boj_catalogue_mount(0);
            std.mem.doNotOptimizeAway(r);
            _ = catalogue.boj_catalogue_unmount(0); // Reset for next iter
        }
    }.f);

    benchmarkFn("unmount", struct {
        fn f() void {
            _ = catalogue.boj_catalogue_mount(0);
            const r = catalogue.boj_catalogue_unmount(0);
            std.mem.doNotOptimizeAway(r);
        }
    }.f);

    benchmarkFn("mount (rejected: not ready)", struct {
        fn f() void {
            // Register a development cartridge
            _ = catalogue.boj_catalogue_init();
            const name = "dev-cart";
            const ver = "0.1.0";
            _ = catalogue.boj_catalogue_register(
                name.ptr,
                name.len,
                ver.ptr,
                ver.len,
                0, // development — not ready
                0,
                1,
            );
            _ = catalogue.boj_catalogue_mount(0); // Should be rejected
        }
    }.f);

    // --- Queries ---
    std.debug.print("\nQueries:\n", .{});

    // Setup: register 4 cartridges for query benchmarks
    _ = catalogue.boj_catalogue_init();
    {
        const names = [_][]const u8{ "db-cart", "fleet-cart", "nesy-cart", "agent-cart" };
        const ver = "1.0.0";
        for (names) |name| {
            _ = catalogue.boj_catalogue_register(
                name.ptr,
                name.len,
                ver.ptr,
                ver.len,
                1, // ready
                0,
                3,
            );
        }
        _ = catalogue.boj_catalogue_mount(0);
        _ = catalogue.boj_catalogue_mount(1);
    }

    benchmarkFn("count (total)", struct {
        fn f() void {
            std.mem.doNotOptimizeAway(catalogue.boj_catalogue_count());
        }
    }.f);

    benchmarkFn("count_ready", struct {
        fn f() void {
            std.mem.doNotOptimizeAway(catalogue.boj_catalogue_count_ready());
        }
    }.f);

    benchmarkFn("count_mounted", struct {
        fn f() void {
            std.mem.doNotOptimizeAway(catalogue.boj_catalogue_count_mounted());
        }
    }.f);

    benchmarkFn("status (by index)", struct {
        fn f() void {
            std.mem.doNotOptimizeAway(catalogue.boj_catalogue_status(0));
        }
    }.f);

    benchmarkFn("is_mounted (by index)", struct {
        fn f() void {
            std.mem.doNotOptimizeAway(catalogue.boj_catalogue_is_mounted(0));
        }
    }.f);

    // --- Hash operations ---
    std.debug.print("\nHash operations:\n", .{});

    _ = catalogue.boj_catalogue_init();
    {
        const name = "hash-cart";
        const ver = "1.0.0";
        _ = catalogue.boj_catalogue_register(
            name.ptr,
            name.len,
            ver.ptr,
            ver.len,
            1,
            0,
            3,
        );
    }

    benchmarkFn("set_hash (64-byte hex)", struct {
        fn f() void {
            const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            _ = catalogue.boj_catalogue_set_hash(0, hash.ptr, hash.len);
        }
    }.f);

    benchmarkFn("get_hash", struct {
        fn f() void {
            var buf: [64]u8 = undefined;
            _ = catalogue.boj_catalogue_get_hash(0, &buf);
        }
    }.f);

    // Cleanup
    catalogue.boj_catalogue_deinit();

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Benchmark complete.\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
}
