// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ cartridge invoker CLI (skinny Phase 2 per ADR-0005).
//
// Loads a cartridge shared library and calls one of the four standard
// symbols the loader already requires: init / deinit / name / version.
// Tool-level dispatch is deferred to Phase 2.1 (ADR-0006).
//
// Usage:
//     boj-invoke <cartridge-so-path> <verb>
//
// Verbs:
//     probe    — run boj_cartridge_init, read name+version, run boj_cartridge_deinit,
//                emit {"ok":true,"name":"...","version":"..."} on stdout.
//     name     — read boj_cartridge_name only.
//     version  — read boj_cartridge_version only.
//
// Exit codes (mirrored into the Elixir invoker's error classification):
//     0   success, JSON on stdout
//     2   argument error (wrong argc / unknown verb)
//     3   cartridge .so not found / cannot open
//     4   missing required symbol in the .so
//     5   cartridge init returned non-zero
//     6   tool dispatch not yet wired (reserved for Phase 2.1)
//
// This binary is intentionally single-process: fork-per-invocation is
// acceptable for the skeleton, and the Elixir side will move to a
// long-lived Port pool in a follow-up once the ABI stabilises.

const std = @import("std");

const EXIT_OK: u8 = 0;
const EXIT_ARGS: u8 = 2;
const EXIT_OPEN: u8 = 3;
const EXIT_SYMBOL: u8 = 4;
const EXIT_INIT: u8 = 5;
const EXIT_UNWIRED: u8 = 6;

const Verb = enum { probe, name, version };

fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "probe")) return .probe;
    if (std.mem.eql(u8, s, "name")) return .name;
    if (std.mem.eql(u8, s, "version")) return .version;
    return null;
}

fn emitJson(file: std.fs.File, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(alloc, fmt ++ "\n", args);
    defer alloc.free(line);
    try file.writeAll(line);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const stderr = std.fs.File.stderr();
    const stdout = std.fs.File.stdout();

    if (argv.len != 3) {
        try emitJson(stderr, alloc,
            "{{\"ok\":false,\"error\":\"args\",\"expected\":\"<cartridge-so-path> <verb>\",\"got_argc\":{d}}}",
            .{argv.len});
        return EXIT_ARGS;
    }

    const so_path = argv[1];
    const verb = parseVerb(argv[2]) orelse {
        try emitJson(stderr, alloc,
            "{{\"ok\":false,\"error\":\"unknown-verb\",\"verb\":\"{s}\"}}",
            .{argv[2]});
        return EXIT_ARGS;
    };

    var lib = std.DynLib.open(so_path) catch |err| {
        try emitJson(stderr, alloc,
            "{{\"ok\":false,\"error\":\"open\",\"path\":\"{s}\",\"cause\":\"{s}\"}}",
            .{ so_path, @errorName(err) });
        return EXIT_OPEN;
    };
    defer lib.close();

    const NameFn = *const fn () callconv(.c) [*:0]const u8;
    const VersionFn = *const fn () callconv(.c) [*:0]const u8;
    const InitFn = *const fn () callconv(.c) c_int;
    const DeinitFn = *const fn () callconv(.c) void;

    switch (verb) {
        .name => {
            const name_fn = lib.lookup(NameFn, "boj_cartridge_name") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_name\"}}", .{});
                return EXIT_SYMBOL;
            };
            const n = std.mem.span(name_fn());
            try emitJson(stdout, alloc, "{{\"ok\":true,\"name\":\"{s}\"}}", .{n});
            return EXIT_OK;
        },
        .version => {
            const version_fn = lib.lookup(VersionFn, "boj_cartridge_version") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_version\"}}", .{});
                return EXIT_SYMBOL;
            };
            const v = std.mem.span(version_fn());
            try emitJson(stdout, alloc, "{{\"ok\":true,\"version\":\"{s}\"}}", .{v});
            return EXIT_OK;
        },
        .probe => {
            const init_fn = lib.lookup(InitFn, "boj_cartridge_init") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_init\"}}", .{});
                return EXIT_SYMBOL;
            };
            const deinit_fn = lib.lookup(DeinitFn, "boj_cartridge_deinit") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_deinit\"}}", .{});
                return EXIT_SYMBOL;
            };
            const name_fn = lib.lookup(NameFn, "boj_cartridge_name") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_name\"}}", .{});
                return EXIT_SYMBOL;
            };
            const version_fn = lib.lookup(VersionFn, "boj_cartridge_version") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_version\"}}", .{});
                return EXIT_SYMBOL;
            };

            const rc = init_fn();
            if (rc != 0) {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"init-returned\",\"rc\":{d}}}", .{rc});
                return EXIT_INIT;
            }
            defer deinit_fn();

            const n = std.mem.span(name_fn());
            const v = std.mem.span(version_fn());
            try emitJson(stdout, alloc, "{{\"ok\":true,\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ n, v });
            return EXIT_OK;
        },
    }
}

// Suppress "unused" warning for EXIT_UNWIRED — reserved for Phase 2.1.
comptime {
    _ = EXIT_UNWIRED;
}
