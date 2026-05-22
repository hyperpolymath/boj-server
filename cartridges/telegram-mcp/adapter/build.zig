// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// telegram-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); const optimize = b.standardOptimizeOption(.{});
    const ffi_mod = b.createModule(.{ .root_source_file = b.path("../ffi/telegram_mcp_ffi.zig"), .target = target, .optimize = optimize });
    const adapter = b.addExecutable(.{ .name = "telegram_mcp_adapter", .root_source_file = b.path("telegram_mcp_adapter.zig"), .target = target, .optimize = optimize });
    adapter.root_module.addImport("telegram_mcp_ffi", ffi_mod); b.installArtifact(adapter);
    const rs = b.step("run", "Run telegram-mcp adapter"); rs.dependOn(&b.addRunArtifact(adapter).step);
    const tests = b.addTest(.{ .root_source_file = b.path("telegram_mcp_adapter.zig"), .target = target, .optimize = optimize });
    tests.root_module.addImport("telegram_mcp_ffi", ffi_mod);
    const ts = b.step("test", "Test telegram-mcp adapter"); ts.dependOn(&b.addRunArtifact(tests).step);
}
