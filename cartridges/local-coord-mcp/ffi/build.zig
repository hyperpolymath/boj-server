// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Local-Coord MCP Cartridge — Zig FFI build configuration (Zig 0.15+).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared ADR-0006 invoke-shim module (relative path up to boj-server trunk).

    const shim_mod = b.addModule("cartridge_shim", .{

        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),

        .target = target,

        .optimize = optimize,

    });

    const coord_mod = b.addModule("local_coord_ffi", .{
        .root_source_file = b.path("local_coord_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    coord_mod.addImport("cartridge_shim", shim_mod);

    // ── Tests ────────────────────────────────────────────────────────
    const coord_tests = b.addTest(.{
        .root_module = coord_mod,
    });

    const run_tests = b.addRunArtifact(coord_tests);

    const test_step = b.step("test", "Run local-coord-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library ──────────────────────────────────────────────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("local_coord_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "local_coord_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);

    // ── Benchmarks ──────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench_coord.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("cartridge_shim", shim_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench_coord",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run local-coord-mcp benchmarks");
    bench_step.dependOn(&run_bench.step);
}
