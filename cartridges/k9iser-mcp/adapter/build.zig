// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k9iser-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/k9iser_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("k9iser_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("k9iser_ffi", ffi_mod);

    const adapter = b.addExecutable(.{
        .name = "k9iser_adapter",
        .root_module = adapter_mod,
    });
    b.installArtifact(adapter);
}
