// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{ .root_source_file = b.path("../ffi/redis_mcp_ffi.zig"), .target = target, .optimize = optimize });
    const adapter = b.addExecutable(.{ .name = "redis_mcp_adapter", .root_source_file = b.path("redis_mcp_adapter.zig"), .target = target, .optimize = optimize });
    adapter.root_module.addImport("redis_mcp_ffi", ffi_mod); b.installArtifact(adapter);
    const rs = b.step("run", "Run redis-mcp adapter"); rs.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{ .root_source_file = b.path("redis_mcp_adapter.zig"), .target = target, .optimize = optimize });
    tests.root_module.addImport("redis_mcp_ffi", ffi_mod);
    const ts = b.step("test", "Test redis-mcp adapter"); ts.dependOn(&b.addRunArtifact(tests).step);
}
