// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// 007-mcp / adapter / oo7_adapter.zig
//
// HTTP-REST bridge for the 007-mcp cartridge. Binds 127.0.0.1:1066 —
// loopback only; the Idris2 IsLoopback proof in abi/Oo7Mcp/SafeCli.idr
// is the source of truth and we honour it at runtime.
//
// Routes:
//   GET  /health                → 200 if ready/degraded, 503 if unreachable state
//   GET  /status                → current SessionState + peer_id
//   POST /on-enter              → run OnEnter lifecycle
//   POST /on-exit               → run OnExit lifecycle
//   POST /tools/<tool_name>     → invoke oo7 CLI recipe (body = JSON args)
//
// Body schema for /tools/<name>:
//   { "file": "…", "args": "…", "recipe": "…", … }
// Only keys matching the cartridge.ncl inputSchema for that tool are
// honoured; unknown keys are ignored.

const std = @import("std");
const ffi = @import("oo7_mcp_ffi");

const BIND_ADDR = ffi.BIND_ADDR;
const BIND_PORT = ffi.BIND_PORT;

const MAX_HEADER_BYTES: usize = 8 * 1024;
const MAX_BODY_BYTES: usize = 64 * 1024;

// ═══════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeJsonArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle response builders
// ═══════════════════════════════════════════════════════════════════════

fn respondOnEnter(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    session_hint: []const u8,
    out: *std.ArrayList(u8),
) !u16 {
    var result = ffi.onEnter(allocator, worktree, session_hint) catch |e| {
        try out.writer(allocator).print(
            "{{\"success\":false,\"error\":\"on_enter_failed\",\"detail\":\"{s}\"}}",
            .{@errorName(e)},
        );
        return 500;
    };
    defer result.deinit(allocator);

    var w = out.writer(allocator);
    try w.writeAll("{\"success\":true,\"peer_id\":");
    try writeJsonString(w, result.peer_id);
    try w.writeAll(",\"coord_state\":");
    try writeJsonString(w, result.coord_state);
    try w.writeAll(",\"methodology_files\":");
    try writeJsonArray(w, result.methodology_files);
    try w.writeAll(",\"memory_hits\":");
    try writeJsonArray(w, result.memory_hits);
    try w.writeByte('}');
    return 200;
}

fn respondOnExit(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    reason: []const u8,
    out: *std.ArrayList(u8),
) !u16 {
    var result = ffi.onExit(allocator, worktree, reason) catch |e| {
        try out.writer(allocator).print(
            "{{\"success\":false,\"error\":\"on_exit_failed\",\"detail\":\"{s}\"}}",
            .{@errorName(e)},
        );
        return 500;
    };
    defer result.deinit(allocator);

    var w = out.writer(allocator);
    try w.writeAll("{\"success\":true,\"coord_state\":");
    try writeJsonString(w, result.coord_state);
    try w.writeAll(",\"drift_findings\":");
    try writeJsonArray(w, result.drift_findings);
    try w.writeByte('}');
    return 200;
}

// ═══════════════════════════════════════════════════════════════════════
// Tool dispatch
// ═══════════════════════════════════════════════════════════════════════

/// Parse the `args` and `file` keys out of a minimal JSON body without
/// pulling in a full JSON parser. The body is trusted (loopback only).
fn extractKey(body: []const u8, key: []const u8, out: *[ffi.MAX_ARG_STRING]u8) ?[]const u8 {
    // Look for "<key>":"<value>" with simple escape handling.
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const i = std.mem.indexOf(u8, body, needle) orelse return null;
    var p = i + needle.len;
    while (p < body.len and (body[p] == ' ' or body[p] == ':')) : (p += 1) {}
    if (p >= body.len or body[p] != '"') return null;
    p += 1;
    var q = p;
    var len: usize = 0;
    while (q < body.len and body[q] != '"') : (q += 1) {
        if (len >= out.len) return null;
        if (body[q] == '\\' and q + 1 < body.len) {
            out[len] = switch (body[q + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => body[q + 1],
            };
            q += 1;
        } else {
            out[len] = body[q];
        }
        len += 1;
    }
    return out[0..len];
}

fn dispatchTool(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    tool: []const u8,
    body: []const u8,
    out: *std.ArrayList(u8),
) !u16 {
    // Lifecycle tools route to their dedicated handlers.
    if (std.mem.eql(u8, tool, "oo7_on_enter")) {
        var hint_buf: [ffi.MAX_ARG_STRING]u8 = undefined;
        const hint = extractKey(body, "session_hint", &hint_buf) orelse "";
        return respondOnEnter(allocator, worktree, hint, out);
    }
    if (std.mem.eql(u8, tool, "oo7_on_exit")) {
        var reason_buf: [ffi.MAX_ARG_STRING]u8 = undefined;
        const reason = extractKey(body, "reason", &reason_buf) orelse "";
        return respondOnExit(allocator, worktree, reason, out);
    }

    const recipe = ffi.recipeFor(tool) orelse {
        try out.writer(allocator).print(
            "{{\"success\":false,\"error\":\"unknown_tool\",\"tool\":\"{s}\"}}",
            .{tool},
        );
        return 404;
    };

    // Extract the two universal optional inputs: `file`, `args`.
    var file_buf: [ffi.MAX_ARG_STRING]u8 = undefined;
    var args_buf: [ffi.MAX_ARG_STRING]u8 = undefined;
    var pattern_buf: [ffi.MAX_ARG_STRING]u8 = undefined;
    var recipe_buf: [ffi.MAX_ARG_STRING]u8 = undefined;

    var extra_list = std.ArrayList([]const u8).initCapacity(allocator, 4) catch return error.OutOfMemory;
    defer extra_list.deinit(allocator);
    if (extractKey(body, "file", &file_buf)) |v| extra_list.appendAssumeCapacity(v);
    if (extractKey(body, "pattern", &pattern_buf)) |v| extra_list.appendAssumeCapacity(v);
    if (extractKey(body, "recipe", &recipe_buf)) |v| extra_list.appendAssumeCapacity(v);
    if (extractKey(body, "args", &args_buf)) |v| extra_list.appendAssumeCapacity(v);

    var inv = ffi.invokeRecipe(allocator, recipe, extra_list.items, worktree) catch |e| {
        try out.writer(allocator).print(
            "{{\"success\":false,\"error\":\"invoke_failed\",\"recipe\":\"{s}\",\"detail\":\"{s}\"}}",
            .{ recipe, @errorName(e) },
        );
        return 500;
    };
    defer inv.deinit(allocator);

    const cleaned_stderr = try stripKnownNoise(allocator, inv.stderr);
    defer if (cleaned_stderr.ptr != inv.stderr.ptr) allocator.free(cleaned_stderr);

    var w = out.writer(allocator);
    try w.writeAll("{\"success\":");
    try w.writeAll(if (inv.exit_code == 0) "true" else "false");
    try w.print(",\"exit_code\":{d},\"recipe\":", .{inv.exit_code});
    try writeJsonString(w, recipe);
    try w.writeAll(",\"stdout\":");
    try writeJsonString(w, inv.stdout);
    try w.writeAll(",\"stderr\":");
    try writeJsonString(w, cleaned_stderr);
    try w.writeByte('}');
    return 200;
}

fn isKnownNoiseLine(line: []const u8) bool {
    if (std.mem.eql(u8, line, "warning: profiles for the non root package will be ignored, specify profiles at the workspace root:")) {
        return true;
    }
    if (std.mem.startsWith(u8, line, "package:") and std.mem.indexOf(u8, line, "/linker/Cargo.toml") != null) {
        return true;
    }
    if (std.mem.startsWith(u8, line, "workspace:") and std.mem.indexOf(u8, line, "/Cargo.toml") != null) {
        return true;
    }
    return false;
}

/// Strip repetitive low-signal Cargo workspace-profile warnings from stderr.
/// Returns the original slice when no filtering was applied.
fn stripKnownNoise(allocator: std.mem.Allocator, stderr: []const u8) ![]const u8 {
    if (stderr.len == 0) return stderr;

    var out = std.ArrayList(u8).initCapacity(allocator, stderr.len) catch return stderr;
    defer out.deinit(allocator);

    var changed = false;
    var line_it = std.mem.splitScalar(u8, stderr, '\n');
    while (line_it.next()) |line| {
        if (isKnownNoiseLine(line)) {
            changed = true;
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    if (!changed) return stderr;
    return try out.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════
// Main — HTTP server
// ═══════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Worktree: cwd by default, or $OO7_WORKTREE if set.
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const worktree = env_map.get("OO7_WORKTREE") orelse ".";

    const addr = std.net.Address.initIp4(BIND_ADDR, BIND_PORT);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    std.log.info("007-mcp adapter listening on 127.0.0.1:{d} (worktree={s})", .{ BIND_PORT, worktree });

    while (true) {
        var conn = listener.accept() catch |e| {
            std.log.warn("accept failed: {}", .{e});
            continue;
        };
        handleConn(allocator, worktree, &conn) catch |e| {
            std.log.warn("connection handler failed: {}", .{e});
        };
        conn.stream.close();
    }
}

fn handleConn(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    conn: *std.net.Server.Connection,
) !void {
    var header_buf: [MAX_HEADER_BYTES]u8 = undefined;
    var total: usize = 0;
    // Read until we see the end of headers (\r\n\r\n).
    while (total < header_buf.len) {
        const n = try conn.stream.read(header_buf[total..]);
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, header_buf[0..total], "\r\n\r\n") != null) break;
    }
    const buf = header_buf[0..total];
    const eoh = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return;
    const head = buf[0..eoh];

    // Parse request line: METHOD PATH HTTP/1.1
    const first_crlf = std.mem.indexOf(u8, head, "\r\n") orelse return;
    const line = head[0..first_crlf];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const path = it.next() orelse return;

    // Extract body (already partly read; read more if Content-Length says so).
    const body_start = eoh + 4;

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var status: u16 = 404;

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
        try resp.writer(allocator).writeAll("{\"success\":true,\"health\":\"ok\"}");
        status = 200;
    } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/status")) {
        try resp.writer(allocator).print(
            "{{\"success\":true,\"state\":{d},\"peer_id\":\"{s}\"}}",
            .{ @intFromEnum(ffi.state()), ffi.peerId() },
        );
        status = 200;
    } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/tools/")) {
        const tool = path[7..];
        // Read full body if any.
        var body_buf: [MAX_BODY_BYTES]u8 = undefined;
        const body_len = buf.len - body_start;
        var bbuf_len: usize = 0;
        if (body_len > 0) {
            @memcpy(body_buf[0..body_len], buf[body_start..]);
            bbuf_len = body_len;
        }
        status = try dispatchTool(allocator, worktree, tool, body_buf[0..bbuf_len], &resp);
    } else {
        try resp.writer(allocator).writeAll("{\"success\":false,\"error\":\"not_found\"}");
    }

    try writeHttpResponse(conn.stream, status, resp.items);
}

fn writeHttpResponse(stream: std.net.Stream, status: u16, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const phrase = statusPhrase(status);
    const hdr = try std.fmt.bufPrint(
        &header,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, phrase, body.len },
    );
    _ = try stream.writeAll(hdr);
    _ = try stream.writeAll(body);
}

fn statusPhrase(s: u16) []const u8 {
    return switch (s) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };
}

test "extractKey pulls a simple string value" {
    var buf: [ffi.MAX_ARG_STRING]u8 = undefined;
    const body = "{\"file\":\"examples/hello.007\",\"args\":\"--verbose\"}";
    const v = extractKey(body, "file", &buf).?;
    try std.testing.expectEqualStrings("examples/hello.007", v);
}

test "statusPhrase maps common codes" {
    try std.testing.expectEqualStrings("OK", statusPhrase(200));
    try std.testing.expectEqualStrings("Not Found", statusPhrase(404));
    try std.testing.expectEqualStrings("Internal Server Error", statusPhrase(500));
}
