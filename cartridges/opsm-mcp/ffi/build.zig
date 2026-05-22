// SPDX-License-Identifier: MPL-2.0
// OPSM-MCP Cartridge — Zig FFI build configuration (Zig 0.15+).
//
// Bridges the Idris2 ABI (SafeRegistry state machine) to a C-compatible
// shared library that the zig adapter can call.

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

    const opsm_mod = b.addModule("opsm_ffi", .{
        .root_source_file = b.path("opsm_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    opsm_mod.addImport("cartridge_shim", shim_mod);

    // Tests
    const opsm_tests = b.addTest(.{
        .root_module = opsm_mod,
    });
    const run_tests = b.addRunArtifact(opsm_tests);
    const test_step = b.step("test", "Run opsm-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // Shared library (libopsm_mcp.so)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("opsm_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "opsm_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build shared library");
    lib_step.dependOn(&lib.step);
}
