// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// boj-health cartridge FFI build — produces libboj_health.so
//
// link_libc = true: boj-invoke targets x86_64-linux-gnu (glibc) and uses
// DlDynLib (real dlopen). A glibc-linked .so is therefore fully compatible —
// dlopen loads it into the glibc process and resolves libc symbols against
// the already-loaded libc.so.6 with no duplication.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shim_mod = b.addModule("cartridge_shim", .{
        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("boj_health_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "boj_health",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_static = b.addLibrary(.{
        .name = "boj_health",
        .root_module = b.createModule(.{
            .root_source_file = b.path("boj_health_ffi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    lib_static.root_module.addImport("cartridge_shim", shim_mod);
    b.installArtifact(lib_static);

    // Unit tests for the shim helpers used here.
    const tests = b.addTest(.{ .root_module = ffi_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run boj-health FFI unit tests");
    test_step.dependOn(&run_tests.step);
}
