// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// build.zig -- Build configuration for redis-mcp FFI shared library.
//
// Links against hiredis for RESP protocol support.
// Produces libredis_mcp.so/.dylib/.dll for V-lang adapter consumption.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const ffi_mod = b.addModule("redis_mcp", .{
        .root_source_file = b.path("redis_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared library
    const lib = b.addLibrary(.{
        .name = "redis_mcp",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    // NOTE: linkSystemLibrary("hiredis") removed — stub implementation does not
    // actually call hiredis yet. Will be re-enabled when real bindings are wired.
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
