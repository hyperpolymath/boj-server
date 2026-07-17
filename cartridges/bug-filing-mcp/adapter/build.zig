// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// bug-filing-mcp/adapter/build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../ffi/bug_filing_mcp_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("bug_filing_mcp_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("bug_filing_mcp_ffi", ffi_mod);

    const adapter = b.addExecutable(.{
        .name = "bug_filing_mcp_adapter",
        .root_module = adapter_mod,
    });
    b.installArtifact(adapter);

    // Unified-adapter tests (classify/toolFor/dispatch -> one Zig ABI).
    const adapter_tests = b.addTest(.{ .root_module = adapter_mod });
    const run_tests = b.addRunArtifact(adapter_tests);
    const test_step = b.step("test", "Run bug-filing-mcp unified adapter tests");
    test_step.dependOn(&run_tests.step);
}
