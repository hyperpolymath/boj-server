// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k8s-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{ .root_source_file = b.path("../ffi/k8s_ffi.zig"), .target = target, .optimize = optimize });
    const adapter = b.addExecutable(.{ .name = "k8s_adapter", .root_source_file = b.path("k8s_adapter.zig"), .target = target, .optimize = optimize });
    adapter.root_module.addImport("k8s_ffi", ffi_mod); b.installArtifact(adapter);
    const rs = b.step("run", "Run k8s-mcp adapter"); rs.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{ .root_source_file = b.path("k8s_adapter.zig"), .target = target, .optimize = optimize });
    tests.root_module.addImport("k8s_ffi", ffi_mod);
    const ts = b.step("test", "Test k8s-mcp adapter"); ts.dependOn(&b.addRunArtifact(tests).step);
}
