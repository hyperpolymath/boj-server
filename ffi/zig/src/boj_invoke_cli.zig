// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ cartridge invoker CLI (ADR-0006 compliant).
//
// Loads a cartridge shared library and calls one of the five standard
// symbols: init / deinit / name / version / invoke.
//
// Usage:
//     boj-invoke <cartridge-so-path> <verb> [args...]
//
// Verbs:
//     probe    — run init, read name+version, run deinit.
//     name     — read name only.
//     version  — read version only.
//     invoke   — call boj_cartridge_invoke <tool_name> <json_args>.
//                Usage: boj-invoke <so> invoke <tool> <args-json>

const std = @import("std");

const EXIT_OK: u8 = 0;
const EXIT_ARGS: u8 = 2;
const EXIT_OPEN: u8 = 3;
const EXIT_SYMBOL: u8 = 4;
const EXIT_INIT: u8 = 5;
const EXIT_RUNTIME: u8 = 7;

const Verb = enum { probe, name, version, invoke };

fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "probe")) return .probe;
    if (std.mem.eql(u8, s, "name")) return .name;
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "invoke")) return .invoke;
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

    if (argv.len < 3) {
        try emitJson(stderr, alloc,
            "{{\"ok\":false,\"error\":\"args\",\"expected\":\"<cartridge-so-path> <verb> [args...]\",\"got_argc\":{d}}}",
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

    if (verb == .invoke and argv.len != 5) {
        try emitJson(stderr, alloc,
            "{{\"ok\":false,\"error\":\"args\",\"expected\":\"invoke <tool_name> <json_args>\",\"got_argc\":{d}}}",
            .{argv.len});
        return EXIT_ARGS;
    }

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
    const InvokeFn = *const fn (
        tool_name: [*c]const u8,
        json_args: [*c]const u8,
        out_buf: [*c]u8,
        in_out_len: [*c]usize,
    ) callconv(.c) i32;

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
        .invoke => {
            const init_fn = lib.lookup(InitFn, "boj_cartridge_init") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_init\"}}", .{});
                return EXIT_SYMBOL;
            };
            const deinit_fn = lib.lookup(DeinitFn, "boj_cartridge_deinit") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_deinit\"}}", .{});
                return EXIT_SYMBOL;
            };
            const invoke_fn = lib.lookup(InvokeFn, "boj_cartridge_invoke") orelse {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"missing-symbol\",\"symbol\":\"boj_cartridge_invoke\"}}", .{});
                return EXIT_SYMBOL;
            };

            if (init_fn() != 0) {
                try emitJson(stderr, alloc, "{{\"ok\":false,\"error\":\"init-failed\"}}", .{});
                return EXIT_INIT;
            }
            defer deinit_fn();

            const tool_name = argv[3];
            const json_args = argv[4];

            var out_buf: [65536]u8 = undefined;
            var out_len: usize = out_buf.len;

            // Null-terminate the tool name and args for the C ABI
            const tool_z = try alloc.dupeZ(u8, tool_name);
            defer alloc.free(tool_z);
            const args_z = try alloc.dupeZ(u8, json_args);
            defer alloc.free(args_z);

            const rc = invoke_fn(tool_z.ptr, args_z.ptr, &out_buf, &out_len);

            if (rc == 0) {
                try stdout.writeAll(out_buf[0..out_len]);
                try stdout.writeAll("\n");
                return EXIT_OK;
            } else {
                try emitJson(stderr, alloc,
                    "{{\"ok\":false,\"error\":\"invoke-failed\",\"rc\":{d},\"required_len\":{d}}}",
                    .{ rc, out_len });
                return EXIT_RUNTIME;
            }
        },
    }
}
