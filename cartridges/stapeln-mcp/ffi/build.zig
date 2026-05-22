// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shim_mod = b.addModule("cartridge_shim", .{
        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_mod = b.addModule("stapeln_mcp", .{
        .root_source_file = b.path("stapeln_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "stapeln_mcp",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = ffi_mod });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_tests.step);
}

