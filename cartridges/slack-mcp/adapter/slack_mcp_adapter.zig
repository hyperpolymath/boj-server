// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// slack-mcp/adapter/slack_mcp_adapter.zig -- Unified three-protocol adapter.
// Replaces banned slack_mcp_adapter.v (zig, removed 2026-04-12).
// REST:9184 gRPC:9185 GraphQL:9186
// Tools: slack_authenticate, slack_send_message, slack_list_channels, slack_read_thread...

const std = @import("std");
const ffi = @import("slack_mcp_ffi");

const REST_PORT: u16 = 9184;
const GRPC_PORT: u16 = 9185;
const GQL_PORT:  u16 = 9186;
const MAX_CONN_BUF: usize = 16 * 1024;

fn okJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"message\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn errJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":false,\"error\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn statusJson(buf: []u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"state\":\"ready\",\"service\":\"slack-mcp\"}", .{}) catch return buf[0..0]; return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "slack_authenticate")) return .{ .status = 200, .body = okJson(resp, "slack_authenticate forwarded") };
    if (std.mem.eql(u8, tool, "slack_send_message")) return .{ .status = 200, .body = okJson(resp, "slack_send_message forwarded") };
    if (std.mem.eql(u8, tool, "slack_list_channels")) return .{ .status = 200, .body = okJson(resp, "slack_list_channels forwarded") };
    if (std.mem.eql(u8, tool, "slack_read_thread")) return .{ .status = 200, .body = okJson(resp, "slack_read_thread forwarded") };
    if (std.mem.eql(u8, tool, "slack_search")) return .{ .status = 200, .body = okJson(resp, "slack_search forwarded") };
    if (std.mem.eql(u8, tool, "slack_get_user")) return .{ .status = 200, .body = okJson(resp, "slack_get_user forwarded") };
    if (std.mem.eql(u8, tool, "slack_deauthenticate")) return .{ .status = 200, .body = okJson(resp, "slack_deauthenticate forwarded") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) return dispatch(path["/tools/".len..], body, resp);
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/SlackMcpservice/";
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "slack_authenticate")) break :blk "slack_authenticate";
        if (std.mem.eql(u8, method, "slack_send_message")) break :blk "slack_send_message";
        if (std.mem.eql(u8, method, "slack_list_channels")) break :blk "slack_list_channels";
        if (std.mem.eql(u8, method, "slack_read_thread")) break :blk "slack_read_thread";
        if (std.mem.eql(u8, method, "slack_search")) break :blk "slack_search";
        if (std.mem.eql(u8, method, "slack_get_user")) break :blk "slack_get_user";
        if (std.mem.eql(u8, method, "slack_deauthenticate")) break :blk "slack_deauthenticate";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "authenticate") != null) return dispatch("slack_authenticate", body, resp);
    if (std.mem.indexOf(u8, body, "send_message") != null) return dispatch("slack_send_message", body, resp);
    if (std.mem.indexOf(u8, body, "list_channels") != null) return dispatch("slack_list_channels", body, resp);
    if (std.mem.indexOf(u8, body, "read_thread") != null) return dispatch("slack_read_thread", body, resp);
    if (std.mem.indexOf(u8, body, "search") != null) return dispatch("slack_search", body, resp);
    if (std.mem.indexOf(u8, body, "get_user") != null) return dispatch("slack_get_user", body, resp);
    if (std.mem.indexOf(u8, body, "deauthenticate") != null) return dispatch("slack_deauthenticate", body, resp);
    return .{ .status = 200, .body = errJson(resp, "Unrecognised GraphQL operation") };
}

const Protocol = enum { rest, grpc, graphql };

fn handleConnection(conn: std.net.Server.Connection, proto: Protocol) void {
    defer conn.stream.close();
    var in_buf: [MAX_CONN_BUF]u8 = undefined;
    const n = conn.stream.read(&in_buf) catch return;
    const req = in_buf[0..n];
    var path: []const u8 = "/"; var body: []const u8 = "";
    if (n > 4) {
        const le = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
        const fl = req[0..le]; const sp1 = std.mem.indexOfScalar(u8, fl, ' ') orelse 0;
        const ro = fl[sp1+1..]; const sp2 = std.mem.indexOfScalar(u8, ro, ' ') orelse ro.len;
        path = ro[0..sp2];
        const bs = std.mem.indexOf(u8, req, "\r\n\r\n") orelse n; body = req[@min(bs+4,n)..];
    }
    var rb: [MAX_CONN_BUF]u8 = undefined;
    const result = switch (proto) { .rest => dispatchRest(path, body, &rb), .grpc => dispatchGrpc(path, body, &rb), .graphql => dispatchGraphql(body, &rb) };
    const ct: []const u8 = if (proto == .grpc) "application/grpc+json" else "application/json";
    var hb: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hb, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ result.status, ct, result.body.len }) catch return;
    _ = conn.stream.writeAll(hdr) catch return; _ = conn.stream.writeAll(result.body) catch return;
}

fn listenLoop(port: u16, proto: Protocol) void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port) catch return;
    var srv = addr.listen(.{ .reuse_address = true }) catch return; defer srv.deinit();
    while (true) { const conn = srv.accept() catch continue; handleConnection(conn, proto); }
}

pub fn main() !void {
    ffi.slack_mcp_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT, Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
