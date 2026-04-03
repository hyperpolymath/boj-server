// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// CodeSeeker-MCP Cartridge — Zig FFI build configuration (Zig 0.15+).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const codeseeker_mod = b.addModule("codeseeker_ffi", .{
        .root_source_file = b.path("codeseeker_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ────────────────────────────────────────────────────────
    const codeseeker_tests = b.addTest(.{
        .root_module = codeseeker_mod,
    });

    const run_tests = b.addRunArtifact(codeseeker_tests);

    const test_step = b.step("test", "Run codeseeker-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library ───────────────────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "codeseeker_mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codeseeker_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);
}
