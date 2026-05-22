// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-coord-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // FFI re-exports `cartridge_shim` via its ADR-0006 invoke dispatch,
    // so the adapter must wire that module transitively. Same source as
    // the FFI's own build.zig (see ../ffi/build.zig).
    const shim_mod = b.addModule("cartridge_shim", .{
        .root_source_file = b.path("../../../ffi/zig/src/cartridge_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/local_coord_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_mod.addImport("cartridge_shim", shim_mod);

    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("local_coord_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("local_coord_ffi", ffi_mod);

    const adapter = b.addExecutable(.{
        .name = "local_coord_adapter",
        .root_module = adapter_mod,
    });
    b.installArtifact(adapter);
}
