// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Zig FFI build configuration (Zig 0.15+).
// Builds the catalogue FFI layer and runs tests.

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

    // --- Tests ---
    const catalogue_tests = b.addTest(.{
        .root_module = catalogue_mod,
    });

    const run_tests = b.addRunArtifact(catalogue_tests);

    const test_step = b.step("test", "Run catalogue FFI tests");
    test_step.dependOn(&run_tests.step);
}
