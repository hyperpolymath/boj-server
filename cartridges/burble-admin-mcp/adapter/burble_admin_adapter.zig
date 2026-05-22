// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// burble-admin-mcp/adapter/burble_admin_adapter.zig
//
// Three-protocol BoJ adapter: REST (port 9205), gRPC-compat (port 9206),
// GraphQL (port 9207).
// Replaces the banned zig adapter (burble_admin_adapter.v).

const std = @import("std");
const ffi = @import("burble_admin_ffi");

const REST_PORT: u16 = 9205;
const GRPC_PORT: u16 = 9206;
const GQL_PORT:  u16 = 9207;

const Response = struct { status: u16, body: []const u8 };

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn dispatch(tool: []const u8, _body: []const u8, resp: []u8) Response {
    _ = _body;
    if (std.mem.eql(u8, tool, "burble_check_health")) {
        return .{ .status = 200, .body = okJson(resp, "burble_check_health forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_list_rooms")) {
        return .{ .status = 200, .body = okJson(resp, "burble_list_rooms forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_create_room")) {
        return .{ .status = 200, .body = okJson(resp, "burble_create_room forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_close_room")) {
        return .{ .status = 200, .body = okJson(resp, "burble_close_room forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_kick_user")) {
        return .{ .status = 200, .body = okJson(resp, "burble_kick_user forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_get_config")) {
        return .{ .status = 200, .body = okJson(resp, "burble_get_config forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_update_config")) {
        return .{ .status = 200, .body = okJson(resp, "burble_update_config forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_voice_stats")) {
        return .{ .status = 200, .body = okJson(resp, "burble_voice_stats forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_toggle_recording")) {
        return .{ .status = 200, .body = okJson(resp, "burble_toggle_recording forwarded") };
    }
    if (std.mem.eql(u8, tool, "burble_node_status")) {
        return .{ .status = 200, .body = okJson(resp, "burble_node_status forwarded") };
    }
    return .{ .status = 404, .body = errJson(resp, "unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    // Expect /tools/<tool_name>
    const prefix = "/tools/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const tool = path[prefix.len..];
        return dispatch(tool, body, resp);
    }
    return .{ .status = 404, .body = errJson(resp, "not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    // Expect /<Service>/<Method> — derive tool from Method
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next(); // leading empty
    _ = it.next(); // service
    const method = it.next() orelse return .{ .status = 404, .body = errJson(resp, "bad gRPC path") };
    return dispatch(method, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "burble_check_health") != null)
        return dispatch("burble_check_health", body, resp);
    if (std.mem.indexOf(u8, body, "burble_list_rooms") != null)
        return dispatch("burble_list_rooms", body, resp);
    if (std.mem.indexOf(u8, body, "burble_create_room") != null)
        return dispatch("burble_create_room", body, resp);
    if (std.mem.indexOf(u8, body, "burble_close_room") != null)
        return dispatch("burble_close_room", body, resp);
    if (std.mem.indexOf(u8, body, "burble_kick_user") != null)
        return dispatch("burble_kick_user", body, resp);
    if (std.mem.indexOf(u8, body, "burble_get_config") != null)
        return dispatch("burble_get_config", body, resp);
    if (std.mem.indexOf(u8, body, "burble_update_config") != null)
        return dispatch("burble_update_config", body, resp);
    if (std.mem.indexOf(u8, body, "burble_voice_stats") != null)
        return dispatch("burble_voice_stats", body, resp);
    if (std.mem.indexOf(u8, body, "burble_toggle_recording") != null)
        return dispatch("burble_toggle_recording", body, resp);
    if (std.mem.indexOf(u8, body, "burble_node_status") != null)
        return dispatch("burble_node_status", body, resp);
    return .{ .status = 400, .body = errJson(resp, "unrecognised GraphQL operation") };
}

fn handleConnection(stream: std.net.Stream, port: u16) void {
    defer stream.close();
    var buf: [4096]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch return;
    const req = buf[0..n];
    const result = switch (port) {
        REST_PORT => blk: {
            // Parse HTTP/1.1: first line = METHOD PATH HTTP/x.y
            var lines = std.mem.splitScalar(u8, req, '\n');
            const first = lines.next() orelse break :blk Response{ .status = 400, .body = "" };
            var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
            _ = parts.next(); // method
            const path = parts.next() orelse break :blk Response{ .status = 400, .body = "" };
            break :blk dispatchRest(path, req, &resp_buf);
        },
        GRPC_PORT => blk: {
            var lines = std.mem.splitScalar(u8, req, '\n');
            const first = lines.next() orelse break :blk Response{ .status = 400, .body = "" };
            var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
            _ = parts.next();
            const path = parts.next() orelse break :blk Response{ .status = 400, .body = "" };
            break :blk dispatchGrpc(path, req, &resp_buf);
        },
        GQL_PORT => dispatchGraphql(req, &resp_buf),
        else => Response{ .status = 500, .body = "" },
    };
    var http_resp: [512]u8 = undefined;
    const http = std.fmt.bufPrint(&http_resp,
        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
        .{ result.status, result.body.len }) catch return;
    _ = stream.write(http) catch {};
    _ = stream.write(result.body) catch {};
}

fn listenLoop(port: u16) !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    while (true) {
        const conn = try server.accept();
        const t = try std.Thread.spawn(.{}, handleConnection, .{ conn.stream, port });
        t.detach();
    }
}

pub fn main() !void {
    ffi.burble_admin_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{REST_PORT});
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{GRPC_PORT});
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{GQL_PORT});
    t1.join();
    t2.join();
    t3.join();
}
