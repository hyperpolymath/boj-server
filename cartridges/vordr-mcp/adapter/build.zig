// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vordr-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/vordr_ffi.zig"),
        .target = target, .optimize = optimize,
    });
    const adapter = b.addExecutable(.{
        .name = "vordr_adapter",
        .root_source_file = b.path("vordr_adapter.zig"),
        .target = target, .optimize = optimize,
    });
    adapter.root_module.addImport("vordr_ffi", ffi_mod);
    b.installArtifact(adapter);
    const run_step = b.step("run", "Run the vordr-mcp adapter");
    run_step.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{
        .root_source_file = b.path("vordr_adapter.zig"),
        .target = target, .optimize = optimize,
    });
    tests.root_module.addImport("vordr_ffi", ffi_mod);
    const test_step = b.step("test", "Run vordr-mcp adapter tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
