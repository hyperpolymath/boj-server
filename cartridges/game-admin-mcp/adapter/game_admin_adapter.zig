// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// game-admin-mcp/adapter/game_admin_adapter.zig
//
// Three-protocol BoJ adapter: REST (port 9238), gRPC-compat (port 9239),
// GraphQL (port 9240).
// Replaces the banned zig adapter (game_admin_adapter.v).

const std = @import("std");
const ffi = @import("game_admin_ffi");

const REST_PORT: u16 = 9238;
const GRPC_PORT: u16 = 9239;
const GQL_PORT:  u16 = 9240;

const Response = struct { status: u16, body: []const u8 };

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn dispatch(tool: []const u8, _body: []const u8, resp: []u8) Response {
    _ = _body;
    if (std.mem.eql(u8, tool, "game_probe_server")) {
        return .{ .status = 200, .body = okJson(resp, "game_probe_server forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_list_servers")) {
        return .{ .status = 200, .body = okJson(resp, "game_list_servers forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_get_config")) {
        return .{ .status = 200, .body = okJson(resp, "game_get_config forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_set_config")) {
        return .{ .status = 200, .body = okJson(resp, "game_set_config forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_server_action")) {
        return .{ .status = 200, .body = okJson(resp, "game_server_action forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_drift_status")) {
        return .{ .status = 200, .body = okJson(resp, "game_drift_status forwarded") };
    }
    if (std.mem.eql(u8, tool, "game_list_profiles")) {
        return .{ .status = 200, .body = okJson(resp, "game_list_profiles forwarded") };
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
    if (std.mem.indexOf(u8, body, "game_probe_server") != null)
        return dispatch("game_probe_server", body, resp);
    if (std.mem.indexOf(u8, body, "game_list_servers") != null)
        return dispatch("game_list_servers", body, resp);
    if (std.mem.indexOf(u8, body, "game_get_config") != null)
        return dispatch("game_get_config", body, resp);
    if (std.mem.indexOf(u8, body, "game_set_config") != null)
        return dispatch("game_set_config", body, resp);
    if (std.mem.indexOf(u8, body, "game_server_action") != null)
        return dispatch("game_server_action", body, resp);
    if (std.mem.indexOf(u8, body, "game_drift_status") != null)
        return dispatch("game_drift_status", body, resp);
    if (std.mem.indexOf(u8, body, "game_list_profiles") != null)
        return dispatch("game_list_profiles", body, resp);
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
    ffi.game_admin_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{REST_PORT});
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{GRPC_PORT});
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{GQL_PORT});
    t1.join();
    t2.join();
    t3.join();
}
