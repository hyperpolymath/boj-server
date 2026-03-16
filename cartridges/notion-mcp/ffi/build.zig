// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const ffi_mod = b.addModule("notion_mcp", .{
        .root_source_file = b.path("notion_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared library
    const lib = b.addLibrary(.{
        .name = "notion_mcp",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_module = ffi_mod,
    });
    tests.linkLibC();

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_tests.step);
}
