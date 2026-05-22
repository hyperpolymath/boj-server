// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared ADR-0006 invoke-shim module (relative path up to boj-server trunk).

    const shim_mod = b.addModule("cartridge_shim", .{

        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),

        .target = target,

        .optimize = optimize,

    });

    const ffi_mod = b.addModule("cloudflare_mcp_ffi", .{
        .root_source_file = b.path("cloudflare_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    ffi_mod.addImport("cartridge_shim", shim_mod);
    const lib = b.addLibrary(.{
        .name = "cloudflare_mcp_ffi",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });

    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = ffi_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run FFI unit tests");
    test_step.dependOn(&run_tests.step);
}
