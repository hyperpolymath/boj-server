// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-coord-mcp/adapter/local_coord_adapter.zig

const std = @import("std");
const ffi = @import("local_coord_ffi");

const BIND_ADDR = [4]u8{ 127, 0, 0, 1 };
const REST_PORT: u16 = 7745;

const Response = struct { status: u16, body: []const u8 };

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn dispatch(tool: []const u8, body: []const u8, resp: []u8, allocator: std.mem.Allocator) Response {
    if (std.mem.eql(u8, tool, "coord_register")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        
        const kind_val = parsed.value.object.get("client_kind") orelse return .{ .status = 400, .body = errJson(resp, "missing client_kind") };
        const kind_str = kind_val.string;
        var kind: i32 = 3; 
        if (std.mem.eql(u8, kind_str, "claude")) kind = 0;
        if (std.mem.eql(u8, kind_str, "gemini")) kind = 1;
        if (std.mem.eql(u8, kind_str, "copilot")) kind = 2;

        var token: [16]u8 = undefined;
        var suffix: [4]u8 = undefined;
        const idx = ffi.coord_register(kind, &token, &suffix);
        if (idx < 0) return .{ .status = 500, .body = errJson(resp, "registry full") };

        var token_hex: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (token, 0..) |b, i| {
            token_hex[i * 2] = hex_chars[b >> 4];
            token_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        
        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"peer_id\":\"{s}-{s}\",\"token\":\"{s}\"}}", .{ kind_str, suffix, token_hex }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_list_peers")) {
        return .{ .status = 200, .body = okJson(resp, "peers list placeholder") };
    }

    if (std.mem.eql(u8, tool, "coord_claim_task")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_hex = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const task = parsed.value.object.get("task") orelse return .{ .status = 400, .body = errJson(resp, "missing task") };

        var token: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&token, token_hex.string) catch return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const result = ffi.coord_claim_task(&token, 16, task.string.ptr, @intCast(task.string.len));
        if (result == 0) return .{ .status = 200, .body = okJson(resp, "granted") };
        if (result == 1) return .{ .status = 200, .body = errJson(resp, "held") };
        return .{ .status = 500, .body = errJson(resp, "claim failed") };
    }

    return .{ .status = 404, .body = errJson(resp, "not implemented") };
}

fn handleConnection(stream: std.net.Stream, allocator: std.mem.Allocator) void {
    defer stream.close();
    var buf: [8192]u8 = undefined;
    var resp_buf: [8192]u8 = undefined;
    const n = stream.read(&buf) catch return;
    const req = buf[0..n];

    var lines = std.mem.splitScalar(u8, req, '\n');
    const first = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
    _ = parts.next(); 
    const path = parts.next() orelse return;

    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse 0;
    const body = if (body_start > 0) req[body_start + 4 ..] else "";

    const prefix = "/tools/";
    var result: Response = .{ .status = 404, .body = errJson(&resp_buf, "not found") };
    if (std.mem.startsWith(u8, path, prefix)) {
        const tool = path[prefix.len..];
        result = dispatch(tool, body, &resp_buf, allocator);
    }

    var http_resp: [512]u8 = undefined;
    const http = std.fmt.bufPrint(&http_resp,
        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
        .{ result.status, result.body.len }) catch return;
    _ = stream.write(http) catch {};
    _ = stream.write(result.body) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    _ = ffi.boj_cartridge_init();

    const addr = std.net.Address.initIp4(BIND_ADDR, REST_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        handleConnection(conn.stream, allocator);
    }
}
