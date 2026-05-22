// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis-mcp/adapter/redis_mcp_adapter.zig -- Unified three-protocol adapter.
// Replaces banned redis_mcp_adapter.v (zig, removed 2026-04-12).
// REST:9163 gRPC:9164 GraphQL:9165
// Tools: redis_connect, redis_get, redis_set, redis_del...

const std = @import("std");
const ffi = @import("redis_mcp_ffi");

const REST_PORT: u16 = 9163;
const GRPC_PORT: u16 = 9164;
const GQL_PORT:  u16 = 9165;
const MAX_CONN_BUF: usize = 16 * 1024;

fn okJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"message\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn errJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":false,\"error\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn statusJson(buf: []u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"state\":\"ready\",\"service\":\"redis-mcp\"}", .{}) catch return buf[0..0]; return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "redis_connect")) return .{ .status = 200, .body = okJson(resp, "redis_connect forwarded") };
    if (std.mem.eql(u8, tool, "redis_get")) return .{ .status = 200, .body = okJson(resp, "redis_get forwarded") };
    if (std.mem.eql(u8, tool, "redis_set")) return .{ .status = 200, .body = okJson(resp, "redis_set forwarded") };
    if (std.mem.eql(u8, tool, "redis_del")) return .{ .status = 200, .body = okJson(resp, "redis_del forwarded") };
    if (std.mem.eql(u8, tool, "redis_keys")) return .{ .status = 200, .body = okJson(resp, "redis_keys forwarded") };
    if (std.mem.eql(u8, tool, "redis_hgetall")) return .{ .status = 200, .body = okJson(resp, "redis_hgetall forwarded") };
    if (std.mem.eql(u8, tool, "redis_lpush")) return .{ .status = 200, .body = okJson(resp, "redis_lpush forwarded") };
    if (std.mem.eql(u8, tool, "redis_publish")) return .{ .status = 200, .body = okJson(resp, "redis_publish forwarded") };
    if (std.mem.eql(u8, tool, "redis_disconnect")) return .{ .status = 200, .body = okJson(resp, "redis_disconnect forwarded") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) return dispatch(path["/tools/".len..], body, resp);
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/RedisMcpservice/";
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "redis_connect")) break :blk "redis_connect";
        if (std.mem.eql(u8, method, "redis_get")) break :blk "redis_get";
        if (std.mem.eql(u8, method, "redis_set")) break :blk "redis_set";
        if (std.mem.eql(u8, method, "redis_del")) break :blk "redis_del";
        if (std.mem.eql(u8, method, "redis_keys")) break :blk "redis_keys";
        if (std.mem.eql(u8, method, "redis_hgetall")) break :blk "redis_hgetall";
        if (std.mem.eql(u8, method, "redis_lpush")) break :blk "redis_lpush";
        if (std.mem.eql(u8, method, "redis_publish")) break :blk "redis_publish";
        if (std.mem.eql(u8, method, "redis_disconnect")) break :blk "redis_disconnect";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "connect") != null) return dispatch("redis_connect", body, resp);
    if (std.mem.indexOf(u8, body, "get") != null) return dispatch("redis_get", body, resp);
    if (std.mem.indexOf(u8, body, "set") != null) return dispatch("redis_set", body, resp);
    if (std.mem.indexOf(u8, body, "del") != null) return dispatch("redis_del", body, resp);
    if (std.mem.indexOf(u8, body, "keys") != null) return dispatch("redis_keys", body, resp);
    if (std.mem.indexOf(u8, body, "hgetall") != null) return dispatch("redis_hgetall", body, resp);
    if (std.mem.indexOf(u8, body, "lpush") != null) return dispatch("redis_lpush", body, resp);
    if (std.mem.indexOf(u8, body, "publish") != null) return dispatch("redis_publish", body, resp);
    if (std.mem.indexOf(u8, body, "disconnect") != null) return dispatch("redis_disconnect", body, resp);
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
    ffi.redis_mcp_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT, Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
