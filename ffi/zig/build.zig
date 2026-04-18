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
    // Catalogue-only lib (used by V adapter for most symbols)
    const lib = b.addLibrary(.{
        .name = "boj_catalogue",
        .root_module = catalogue_mod,
    });
    b.installArtifact(lib);

    // Loader lib (adds boj_loader_verify, boj_loader_set_hash)
    // Built as object-only to avoid duplicate catalogue symbols when linking both
    const loader_lib = b.addLibrary(.{
        .name = "boj_loader",
        .root_module = loader_mod,
    });
    b.installArtifact(loader_lib);

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

    // --- boj-invoke CLI (skinny Phase 2 per ADR-0005) ---
    const invoke_mod = b.addModule("boj_invoke", .{
        .root_source_file = b.path("src/boj_invoke_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    invoke_mod.link_libc = true; // route std.DynLib through real dlopen(3)
    const invoke = b.addExecutable(.{
        .name = "boj-invoke",
        .root_module = invoke_mod,
    });
    const invoke_install = b.addInstallArtifact(invoke, .{});

    const invoke_step = b.step("invoke", "Build boj-invoke CLI for Elixir Invoker pool");
    invoke_step.dependOn(&invoke_install.step);

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

    // --- Guardian module (resource-aware failure tolerance) ---
    const guardian_mod = b.addModule("boj_guardian", .{
        .root_source_file = b.path("src/guardian.zig"),
        .target = target,
        .optimize = optimize,
    });

    const guardian_lib = b.addLibrary(.{
        .name = "boj_guardian",
        .root_module = guardian_mod,
    });
    b.installArtifact(guardian_lib);

    const guardian_tests = b.addTest(.{
        .root_module = guardian_mod,
    });
    const run_guardian_tests = b.addRunArtifact(guardian_tests);

    const guardian_step = b.step("guardian", "Run Guardian resource-awareness tests");
    guardian_step.dependOn(&run_guardian_tests.step);

    // --- Federation module (Umoja gossip protocol) ---
    const federation_mod = b.addModule("boj_federation", .{
        .root_source_file = b.path("src/federation.zig"),
        .target = target,
        .optimize = optimize,
    });

    const federation_lib = b.addLibrary(.{
        .name = "boj_federation",
        .root_module = federation_mod,
    });
    b.installArtifact(federation_lib);

    const federation_tests = b.addTest(.{
        .root_module = federation_mod,
    });
    const run_federation_tests = b.addRunArtifact(federation_tests);

    const federation_step = b.step("federation", "Run Umoja federation protocol tests");
    federation_step.dependOn(&run_federation_tests.step);

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

    // --- VeriSimDB backing store ---
    const verisimdb_mod = b.addModule("boj_verisimdb", .{
        .root_source_file = b.path("src/verisimdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    const verisimdb_tests = b.addTest(.{
        .root_module = verisimdb_mod,
    });
    const run_verisimdb_tests = b.addRunArtifact(verisimdb_tests);

    const verisimdb_step = b.step("verisimdb", "Run VeriSimDB backing store tests");
    verisimdb_step.dependOn(&run_verisimdb_tests.step);

    // --- Coprocessor dispatch module ---
    const coprocessor_mod = b.addModule("boj_coprocessor", .{
        .root_source_file = b.path("src/coprocessor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const coprocessor_lib = b.addLibrary(.{
        .name = "boj_coprocessor",
        .root_module = coprocessor_mod,
    });
    b.installArtifact(coprocessor_lib);

    const coprocessor_tests = b.addTest(.{
        .root_module = coprocessor_mod,
    });
    const run_coprocessor_tests = b.addRunArtifact(coprocessor_tests);

    const coprocessor_step = b.step("coprocessor", "Run coprocessor dispatch tests");
    coprocessor_step.dependOn(&run_coprocessor_tests.step);

    // --- SLA & Monitoring module ---
    const sla_mod = b.addModule("boj_sla", .{
        .root_source_file = b.path("src/sla.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sla_lib = b.addLibrary(.{
        .name = "boj_sla",
        .root_module = sla_mod,
    });
    b.installArtifact(sla_lib);

    const sla_tests = b.addTest(.{
        .root_module = sla_mod,
    });
    const run_sla_tests = b.addRunArtifact(sla_tests);

    const sla_step = b.step("sla", "Run SLA monitoring tests");
    sla_step.dependOn(&run_sla_tests.step);

    // --- Community cartridge submission module ---
    const community_mod = b.addModule("boj_community", .{
        .root_source_file = b.path("src/community.zig"),
        .target = target,
        .optimize = optimize,
    });

    const community_lib = b.addLibrary(.{
        .name = "boj_community",
        .root_module = community_mod,
    });
    b.installArtifact(community_lib);

    const community_tests = b.addTest(.{
        .root_module = community_mod,
    });
    const run_community_tests = b.addRunArtifact(community_tests);

    const community_step = b.step("community", "Run community cartridge submission tests");
    community_step.dependOn(&run_community_tests.step);

    // --- Safety module (C-ABI input validation for V-lang adapter) ---
    const safety_mod = b.addModule("boj_safety", .{
        .root_source_file = b.path("src/safety.zig"),
        .target = target,
        .optimize = optimize,
    });

    const safety_lib = b.addLibrary(.{
        .name = "boj_safety",
        .root_module = safety_mod,
    });
    b.installArtifact(safety_lib);

    const safety_tests = b.addTest(.{
        .root_module = safety_mod,
    });
    const run_safety_tests = b.addRunArtifact(safety_tests);

    const safety_step = b.step("safety", "Run safety input validation tests");
    safety_step.dependOn(&run_safety_tests.step);

    // --- Auto-SDP module ---
    const sdp_mod = b.addModule("boj_sdp", .{
        .root_source_file = b.path("src/sdp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sdp_lib = b.addLibrary(.{
        .name = "boj_sdp",
        .root_module = sdp_mod,
    });
    b.installArtifact(sdp_lib);

    const sdp_tests = b.addTest(.{
        .root_module = sdp_mod,
    });
    const run_sdp_tests = b.addRunArtifact(sdp_tests);

    const sdp_step = b.step("sdp", "Run Auto-SDP perimeter tests");
    sdp_step.dependOn(&run_sdp_tests.step);

    // --- Seam checks (panic-attack–style integration contract validation) ---
    const seams_mod = b.addModule("boj_seams", .{
        .root_source_file = b.path("src/seams.zig"),
        .target = target,
        .optimize = optimize,
    });
    seams_mod.addImport("catalogue", catalogue_mod);

    const seams_tests = b.addTest(.{
        .root_module = seams_mod,
    });
    const run_seams_tests = b.addRunArtifact(seams_tests);

    const seams_step = b.step("seams", "Run integration seam checks (panic-attack style)");
    seams_step.dependOn(&run_seams_tests.step);

    // --- End-to-end order-ticket tests ---
    const e2e_mod = b.addModule("boj_e2e_order", .{
        .root_source_file = b.path("src/e2e_order.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("catalogue", catalogue_mod);

    const e2e_tests = b.addTest(.{
        .root_module = e2e_mod,
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const e2e_step = b.step("e2e", "Run end-to-end order-ticket tests (no V server needed)");
    e2e_step.dependOn(&run_e2e_tests.step);

    // --- Test step runs all ---
    const test_step = b.step("test", "Run all FFI tests");
    test_step.dependOn(&run_catalogue_tests.step);
    test_step.dependOn(&run_loader_tests.step);
    test_step.dependOn(&run_readiness_tests.step);
    test_step.dependOn(&run_federation_tests.step);
    test_step.dependOn(&run_guardian_tests.step);
    test_step.dependOn(&run_e2e_tests.step);
    test_step.dependOn(&run_verisimdb_tests.step);
    test_step.dependOn(&run_coprocessor_tests.step);
    test_step.dependOn(&run_sla_tests.step);
    test_step.dependOn(&run_community_tests.step);
    test_step.dependOn(&run_sdp_tests.step);
    test_step.dependOn(&run_seams_tests.step);
}
