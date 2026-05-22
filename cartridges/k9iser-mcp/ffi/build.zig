// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k9iser-mcp Cartridge — Zig FFI build configuration (Zig 0.15+).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared ADR-0006 invoke-shim module (relative path up to boj-server trunk).
    const shim_mod = b.addModule("cartridge_shim", .{
        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const k9_mod = b.addModule("k9iser_ffi", .{
        .root_source_file = b.path("k9iser_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    k9_mod.addImport("cartridge_shim", shim_mod);

    // ── Tests ────────────────────────────────────────────────────────
    const k9_tests = b.addTest(.{
        .root_module = k9_mod,
    });

    const run_tests = b.addRunArtifact(k9_tests);

    const test_step = b.step("test", "Run k9iser-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library ──────────────────────────────────────────────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("k9iser_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "k9iser_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);
}
