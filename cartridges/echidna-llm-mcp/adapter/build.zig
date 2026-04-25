// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The FFI module uses C allocator + libc memory functions, so its
    // module needs `link_libc = true`; that propagates to consumers.
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/echidna_llm_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Zig 0.15 dropped `.root_source_file` from ExecutableOptions; the
    // canonical pattern is now to build the executable's root module first
    // and pass it via `.root_module`. Mirrors the sibling ffi/build.zig.
    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("echidna_llm_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    adapter_mod.addImport("echidna_llm_ffi", ffi_mod);

    const adapter = b.addExecutable(.{
        .name = "echidna_llm_adapter",
        .root_module = adapter_mod,
    });
    b.installArtifact(adapter);
}
