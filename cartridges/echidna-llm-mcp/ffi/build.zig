// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Zig FFI build configuration (Zig 0.15+).
// Builds shared library for V-lang adapter consumption.

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

    // Module definition
    const echidna_llm_mod = b.createModule(.{
        .root_source_file = b.path("echidna_llm_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    echidna_llm_mod.addImport("cartridge_shim", shim_mod);

    // Tests
    const echidna_llm_tests = b.addTest(.{
        .root_module = echidna_llm_mod,
    });

    const run_tests = b.addRunArtifact(echidna_llm_tests);
    const test_step = b.step("test", "Run echidna-llm FFI tests");
    test_step.dependOn(&run_tests.step);

    // Shared library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("echidna_llm_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "echidna_llm_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // Static library
    const lib_static_mod = b.createModule(.{
        .root_source_file = b.path("echidna_llm_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_static_mod.addImport("cartridge_shim", shim_mod);

    const lib_static = b.addLibrary(.{
        .name = "echidna_llm_mcp",
        .root_module = lib_static_mod,
        .linkage = .static,
    });
    b.installArtifact(lib_static);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);
}
