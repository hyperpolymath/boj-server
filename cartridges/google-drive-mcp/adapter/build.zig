// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// google-drive-mcp/adapter/build.zig
// Zig 0.15 module-based build (aligned with ffi/build.zig).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/google_drive_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("google_drive_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("google_drive_mcp_ffi", ffi_mod);

    const adapter = b.addExecutable(.{
        .name = "google_drive_adapter",
        .root_module = adapter_mod,
    });
    b.installArtifact(adapter);

    const run_artifact = b.addRunArtifact(adapter);
    const run_step = b.step("run", "Run the google-drive-mcp adapter");
    run_step.dependOn(&run_artifact.step);

    const tests = b.addTest(.{ .root_module = adapter_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run google-drive-mcp adapter tests");
    test_step.dependOn(&run_tests.step);
}
