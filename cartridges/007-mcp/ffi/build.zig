// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// 007-mcp / ffi / build.zig — Zig 0.15+ build configuration.
//
// This build is self-contained on purpose: the cartridge source lives
// in 007-lang (DD-24) and must compile without depending on the
// boj-server tree. The install hook (see 007-lang's Justfile recipe
// `cartridge-install`) deploys built artefacts into
// boj-server/cartridges/007-mcp/ and boj-server handles its own
// ADR-0006 invoke-shim wiring there.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.addModule("oo7_mcp_ffi", .{
        .root_source_file = b.path("oo7_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ────────────────────────────────────────────────────────
    const ffi_tests = b.addTest(.{
        .root_module = ffi_mod,
    });
    const run_tests = b.addRunArtifact(ffi_tests);
    const test_step = b.step("test", "Run 007-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library (for future MCP-host embedding) ───────────────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("oo7_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "oo7_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build the 007-mcp FFI shared library");
    lib_step.dependOn(&lib.step);
}
