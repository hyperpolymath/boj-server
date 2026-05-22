// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// LSP-MCP Cartridge — adapter build configuration (Zig 0.14+).
//
// Builds the `lsp-adapter` binary: the unified REST/gRPC-compat/GraphQL server
// that wraps the lsp_ffi.zig session state machine.
//
// Usage:
//   zig build         -- build lsp-adapter binary
//   zig build run     -- build and run (REST :9016, gRPC-compat :9017, GraphQL :9018)
//   zig build test    -- run unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── lsp_ffi module (state machine from sibling directory) ──────────────
    // Imported directly by the adapter — no shared-library linking needed.
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/lsp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── lsp-adapter executable ─────────────────────────────────────────────
    const adapter = b.addExecutable(.{
        .name = "lsp-adapter",
        .root_source_file = b.path("lsp_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.root_module.addImport("lsp_ffi", ffi_mod);
    b.installArtifact(adapter);

    // ── run step ───────────────────────────────────────────────────────────
    const run_cmd  = b.addRunArtifact(adapter);
    const run_step = b.step("run", "Run lsp-adapter (REST :9016, gRPC :9017, GraphQL :9018)");
    run_step.dependOn(&run_cmd.step);

    // ── tests ──────────────────────────────────────────────────────────────
    const tests = b.addTest(.{
        .root_source_file = b.path("lsp_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("lsp_ffi", ffi_mod);

    const run_tests  = b.addRunArtifact(tests);
    const test_step  = b.step("test", "Run adapter unit tests");
    test_step.dependOn(&run_tests.step);
}
