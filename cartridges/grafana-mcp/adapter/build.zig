// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// grafana-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/grafana_mcp_ffi.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const adapter = b.addExecutable(.{
        .name = "grafana_adapter",
        .root_source_file = b.path("grafana_adapter.zig"),
        .target   = target,
        .optimize = optimize,
    });
    adapter.root_module.addImport("grafana_mcp_ffi", ffi_mod);
    b.installArtifact(adapter);

    const run_artifact = b.addRunArtifact(adapter);
    const run_step = b.step("run", "Run the grafana-mcp adapter");
    run_step.dependOn(&run_artifact.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("grafana_adapter.zig"),
        .target   = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("grafana_mcp_ffi", ffi_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run grafana-mcp adapter tests");
    test_step.dependOn(&run_tests.step);
}
