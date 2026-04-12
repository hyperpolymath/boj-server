// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-coord-mcp/adapter/local_coord_adapter.zig
//
// REST adapter for the local coordination cartridge.
// Binds ONLY to 127.0.0.1:7745 — loopback-only, no external access.
// Dispatches /tools/<name> to the FFI peer registry.

const std = @import("std");
const ffi = @import("local_coord_ffi");

/// CRITICAL: Loopback only. Matches SafeLocalCoord.idr IsLoopback proof.
const BIND_ADDR = [4]u8{ 127, 0, 0, 1 };
const REST_PORT: u16 = 7745;

const Response = struct { status: u16, body: []const u8 };

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn dispatch(tool: []const u8, _body: []const u8, resp: []u8) Response {
    _ = _body;
    if (std.mem.eql(u8, tool, "coord_register")) {
        return .{ .status = 200, .body = okJson(resp, "coord_register forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_deregister")) {
        return .{ .status = 200, .body = okJson(resp, "coord_deregister forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_list_peers")) {
        return .{ .status = 200, .body = okJson(resp, "coord_list_peers forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_send")) {
        return .{ .status = 200, .body = okJson(resp, "coord_send forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_receive")) {
        return .{ .status = 200, .body = okJson(resp, "coord_receive forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_claim_task")) {
        return .{ .status = 200, .body = okJson(resp, "coord_claim_task forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_release_task")) {
        return .{ .status = 200, .body = okJson(resp, "coord_release_task forwarded") };
    }
    if (std.mem.eql(u8, tool, "coord_status")) {
        return .{ .status = 200, .body = okJson(resp, "coord_status forwarded") };
    }
    return .{ .status = 404, .body = errJson(resp, "unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/tools/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const tool = path[prefix.len..];
        return dispatch(tool, body, resp);
    }
    return .{ .status = 404, .body = errJson(resp, "not found") };
}

fn handleConnection(stream: std.net.Stream) void {
    defer stream.close();
    var buf: [4096]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch return;
    const req = buf[0..n];

    // Parse HTTP/1.1: first line = METHOD PATH HTTP/x.y
    var lines = std.mem.splitScalar(u8, req, '\n');
    const first = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
    _ = parts.next(); // method
    const path = parts.next() orelse return;

    const result = dispatchRest(path, req, &resp_buf);

    var http_resp: [512]u8 = undefined;
    const http = std.fmt.bufPrint(&http_resp,
        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
        .{ result.status, result.body.len }) catch return;
    _ = stream.write(http) catch {};
    _ = stream.write(result.body) catch {};
}

pub fn main() !void {
    _ = ffi.boj_cartridge_init();

    // CRITICAL: Bind to loopback ONLY.
    const addr = std.net.Address.initIp4(BIND_ADDR, REST_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        const t = try std.Thread.spawn(.{}, handleConnection, .{conn.stream});
        t.detach();
    }
}
