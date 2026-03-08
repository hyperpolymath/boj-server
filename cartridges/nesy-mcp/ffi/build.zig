// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — Zig FFI build configuration (Zig 0.15+).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nesy_mod = b.addModule("nesy_ffi", .{
        .root_source_file = b.path("nesy_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ────────────────────────────────────────────────────────
    const nesy_tests = b.addTest(.{
        .root_module = nesy_mod,
    });

    const run_tests = b.addRunArtifact(nesy_tests);

    const test_step = b.step("test", "Run nesy-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library ──────────────────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "nesy_mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("nesy_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);
}
