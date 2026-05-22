// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// database-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{ .root_source_file = b.path("../ffi/database_ffi.zig"), .target = target, .optimize = optimize });
    const adapter = b.addExecutable(.{ .name = "database_adapter", .root_source_file = b.path("database_adapter.zig"), .target = target, .optimize = optimize });
    adapter.root_module.addImport("database_ffi", ffi_mod); b.installArtifact(adapter);
    const rs = b.step("run", "Run database-mcp adapter"); rs.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{ .root_source_file = b.path("database_adapter.zig"), .target = target, .optimize = optimize });
    tests.root_module.addImport("database_ffi", ffi_mod);
    const ts = b.step("test", "Test database-mcp adapter"); ts.dependOn(&b.addRunArtifact(tests).step);
}
