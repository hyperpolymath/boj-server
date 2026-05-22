// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Lang-MCP Cartridge — adapter build configuration (Zig 0.14+).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/lang_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter = b.addExecutable(.{
        .name = "lang-adapter",
        .root_source_file = b.path("lang_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.root_module.addImport("lang_ffi", ffi_mod);
    b.installArtifact(adapter);

    const run_cmd  = b.addRunArtifact(adapter);
    const run_step = b.step("run", "Run lang-adapter (REST :9022, gRPC :9023, GraphQL :9024)");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("lang_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("lang_ffi", ffi_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run adapter unit tests");
    test_step.dependOn(&run_tests.step);
}
