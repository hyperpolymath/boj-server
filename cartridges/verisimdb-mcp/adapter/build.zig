// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verisimdb-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/verisimdb_ffi.zig"),
        .target = target, .optimize = optimize,
    });
    const adapter = b.addExecutable(.{
        .name = "verisimdb_adapter",
        .root_source_file = b.path("verisimdb_adapter.zig"),
        .target = target, .optimize = optimize,
    });
    adapter.root_module.addImport("verisimdb_ffi", ffi_mod);
    b.installArtifact(adapter);
    const run_step = b.step("run", "Run the verisimdb-mcp adapter");
    run_step.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{
        .root_source_file = b.path("verisimdb_adapter.zig"),
        .target = target, .optimize = optimize,
    });
    tests.root_module.addImport("verisimdb_ffi", ffi_mod);
    const test_step = b.step("test", "Run verisimdb-mcp adapter tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
