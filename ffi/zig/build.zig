// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Zig FFI build configuration (Zig 0.15+).
// Builds the catalogue and loader FFI layers, static library, and tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Catalogue module ---
    const catalogue_mod = b.addModule("boj_catalogue", .{
        .root_source_file = b.path("src/catalogue.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Loader module ---
    const loader_mod = b.addModule("boj_loader", .{
        .root_source_file = b.path("src/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    loader_mod.addImport("catalogue", catalogue_mod);

    // --- Static library (for V-lang adapter linking) ---
    const lib = b.addLibrary(.{
        .name = "boj_catalogue",
        .root_module = catalogue_mod,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build static library for V-lang linking");
    lib_step.dependOn(&lib.step);

    // --- Benchmark binary ---
    const bench_mod = b.addModule("boj_bench", .{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("catalogue", catalogue_mod);
    const bench = b.addExecutable(.{
        .name = "boj_bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run cartridge mount/unmount benchmarks");
    bench_step.dependOn(&bench_run.step);

    // --- Catalogue tests ---
    const catalogue_tests = b.addTest(.{
        .root_module = catalogue_mod,
    });
    const run_catalogue_tests = b.addRunArtifact(catalogue_tests);

    // --- Loader tests ---
    const loader_tests = b.addTest(.{
        .root_module = loader_mod,
    });
    const run_loader_tests = b.addRunArtifact(loader_tests);

    // --- Readiness tests ---
    const readiness_mod = b.addModule("boj_readiness", .{
        .root_source_file = b.path("src/readiness.zig"),
        .target = target,
        .optimize = optimize,
    });
    readiness_mod.addImport("catalogue", catalogue_mod);
    const readiness_tests = b.addTest(.{
        .root_module = readiness_mod,
    });
    const run_readiness_tests = b.addRunArtifact(readiness_tests);

    const readiness_step = b.step("readiness", "Run Component Readiness Grade tests");
    readiness_step.dependOn(&run_readiness_tests.step);

    // --- Test step runs all ---
    const test_step = b.step("test", "Run all FFI tests");
    test_step.dependOn(&run_catalogue_tests.step);
    test_step.dependOn(&run_loader_tests.step);
    test_step.dependOn(&run_readiness_tests.step);
}
