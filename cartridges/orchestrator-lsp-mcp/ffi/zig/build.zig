// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// orchestrator-lsp-mcp — Zig FFI build configuration (Zig 0.15+).
//
// Produces: zig-out/lib/liborchestrator_lsp_mcp.so  (matches cartridge.json so_path)
//
// Usage:
//   zig build           — build the shared library
//   zig build test      — run unit tests
//   zig build lib       — alias for the default step

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Shared shim module (ADR-0006 invoke helpers) ──────────────────
    // Relative path: cartridges/orchestrator-lsp-mcp/ffi/zig/ → src/abi/
    const shim_mod = b.addModule("cartridge_shim", .{
        .root_source_file = b.path("../../../../ffi/zig/src/cartridge_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Main FFI module ───────────────────────────────────────────────
    const ffi_mod = b.addModule("orchestrator_lsp_ffi", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_mod.addImport("cartridge_shim", shim_mod);

    // ── Tests ─────────────────────────────────────────────────────────
    const tests = b.addTest(.{
        .root_module = ffi_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run orchestrator-lsp-mcp FFI tests");
    test_step.dependOn(&run_tests.step);

    // ── Shared library → zig-out/lib/liborchestrator_lsp_mcp.so ──────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("cartridge_shim", shim_mod);

    const lib = b.addLibrary(.{
        .name = "orchestrator_lsp_mcp",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build liborchestrator_lsp_mcp.so");
    lib_step.dependOn(&lib.step);
}
