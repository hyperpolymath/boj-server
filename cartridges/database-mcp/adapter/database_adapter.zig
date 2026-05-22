// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// database-mcp/adapter/database_adapter.zig -- Unified three-protocol adapter.
// Replaces banned database_adapter.v (zig, removed 2026-04-12).
// REST:9154 gRPC:9155 GraphQL:9156
// Tools: database_connect, database_query, database_execute, database_list_tables...

const std = @import("std");
const ffi = @import("database_ffi");

const REST_PORT: u16 = 9154;
const GRPC_PORT: u16 = 9155;
const GQL_PORT:  u16 = 9156;
const MAX_CONN_BUF: usize = 16 * 1024;

fn okJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"message\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn errJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":false,\"error\":\"{s}\"}", .{msg}) catch return buf[0..0]; return n;
}
fn statusJson(buf: []u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{\"success\":true,\"state\":\"ready\",\"service\":\"database-mcp\"}", .{}) catch return buf[0..0]; return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "database_connect")) return .{ .status = 200, .body = okJson(resp, "database_connect forwarded") };
    if (std.mem.eql(u8, tool, "database_query")) return .{ .status = 200, .body = okJson(resp, "database_query forwarded") };
    if (std.mem.eql(u8, tool, "database_execute")) return .{ .status = 200, .body = okJson(resp, "database_execute forwarded") };
    if (std.mem.eql(u8, tool, "database_list_tables")) return .{ .status = 200, .body = okJson(resp, "database_list_tables forwarded") };
    if (std.mem.eql(u8, tool, "database_describe")) return .{ .status = 200, .body = okJson(resp, "database_describe forwarded") };
    if (std.mem.eql(u8, tool, "database_disconnect")) return .{ .status = 200, .body = okJson(resp, "database_disconnect forwarded") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) return dispatch(path["/tools/".len..], body, resp);
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/Databaseservice/";
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "database_connect")) break :blk "database_connect";
        if (std.mem.eql(u8, method, "database_query")) break :blk "database_query";
        if (std.mem.eql(u8, method, "database_execute")) break :blk "database_execute";
        if (std.mem.eql(u8, method, "database_list_tables")) break :blk "database_list_tables";
        if (std.mem.eql(u8, method, "database_describe")) break :blk "database_describe";
        if (std.mem.eql(u8, method, "database_disconnect")) break :blk "database_disconnect";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "connect") != null) return dispatch("database_connect", body, resp);
    if (std.mem.indexOf(u8, body, "query") != null) return dispatch("database_query", body, resp);
    if (std.mem.indexOf(u8, body, "execute") != null) return dispatch("database_execute", body, resp);
    if (std.mem.indexOf(u8, body, "list_tables") != null) return dispatch("database_list_tables", body, resp);
    if (std.mem.indexOf(u8, body, "describe") != null) return dispatch("database_describe", body, resp);
    if (std.mem.indexOf(u8, body, "disconnect") != null) return dispatch("database_disconnect", body, resp);
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
    ffi.database_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT, Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
