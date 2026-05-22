// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// linear-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/linear_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter = b.addExecutable(.{
        .name = "linear_mcp_adapter",
        .root_source_file = b.path("linear_mcp_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.root_module.addImport("linear_mcp_ffi", ffi_mod);
    b.installArtifact(adapter);
}
