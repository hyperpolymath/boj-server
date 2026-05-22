// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ums-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/ums_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter = b.addExecutable(.{
        .name = "ums_adapter",
        .root_source_file = b.path("ums_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.root_module.addImport("ums_ffi", ffi_mod);
    b.installArtifact(adapter);
}
