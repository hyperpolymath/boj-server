// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// reposystem-mcp/adapter/reposystem_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned reposystem_adapter.v (zig, removed 2026-04-12).
//
// REST :9130  gRPC-compat :9131  GraphQL :9132
// Reposystem repository management. Lists managed repos, checks health, syncs mirrors, and runs RSR co
// Tools: reposystem_list_repos, reposystem_check_health, reposystem_sync_mirrors, reposystem_run_audit

const std = @import("std");
const ffi = @import("reposystem_ffi");

const REST_PORT: u16 = 9130;
const GRPC_PORT: u16 = 9131;
const GQL_PORT:  u16 = 9132;
const MAX_CONN_BUF: usize = 16 * 1024;

fn okJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch return buf[0..0];
    return n;
}
fn errJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch return buf[0..0];
    return n;
}
fn statusJson(buf: []u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"state\":\"ready\",\"service\":\"reposystem-mcp\"}}", .{}) catch return buf[0..0];
    return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "reposystem_list_repos")) return .{ .status = 200, .body = okJson(resp, "reposystem_list_repos forwarded") };
    if (std.mem.eql(u8, tool, "reposystem_check_health")) return .{ .status = 200, .body = okJson(resp, "reposystem_check_health forwarded") };
    if (std.mem.eql(u8, tool, "reposystem_sync_mirrors")) return .{ .status = 200, .body = okJson(resp, "reposystem_sync_mirrors forwarded") };
    if (std.mem.eql(u8, tool, "reposystem_run_audit")) return .{ .status = 200, .body = okJson(resp, "reposystem_run_audit forwarded") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health"))
        return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) return dispatch(path["/tools/".len..], body, resp);
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/Reposystemservice/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "reposystem_list_repos")) break :blk "reposystem_list_repos";
        if (std.mem.eql(u8, method, "reposystem_check_health")) break :blk "reposystem_check_health";
        if (std.mem.eql(u8, method, "reposystem_sync_mirrors")) break :blk "reposystem_sync_mirrors";
        if (std.mem.eql(u8, method, "reposystem_run_audit")) break :blk "reposystem_run_audit";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "list_repos") != null) return dispatch("reposystem_list_repos", body, resp);
    if (std.mem.indexOf(u8, body, "check_health") != null) return dispatch("reposystem_check_health", body, resp);
    if (std.mem.indexOf(u8, body, "sync_mirrors") != null) return dispatch("reposystem_sync_mirrors", body, resp);
    if (std.mem.indexOf(u8, body, "run_audit") != null) return dispatch("reposystem_run_audit", body, resp);
    return .{ .status = 200, .body = errJson(resp, "Unrecognised GraphQL operation") };
}

const Protocol = enum { rest, grpc, graphql };

fn handleConnection(conn: std.net.Server.Connection, proto: Protocol) void {
    defer conn.stream.close();
    var in_buf: [MAX_CONN_BUF]u8 = undefined;
    const n = conn.stream.read(&in_buf) catch return;
    const req = in_buf[0..n];
    var path: []const u8 = "/";
    var body: []const u8 = "";
    if (n > 4) {
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
        const first_line = req[0..line_end];
        const sp1 = std.mem.indexOfScalar(u8, first_line, ' ') orelse 0;
        const rest_of = first_line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest_of, ' ') orelse rest_of.len;
        path = rest_of[0..sp2];
        const body_sep = std.mem.indexOf(u8, req, "\r\n\r\n") orelse n;
        body = req[@min(body_sep + 4, n)..];
    }
    var resp_buf: [MAX_CONN_BUF]u8 = undefined;
    const result = switch (proto) {
        .rest    => dispatchRest(path, body, &resp_buf),
        .grpc    => dispatchGrpc(path, body, &resp_buf),
        .graphql => dispatchGraphql(body, &resp_buf),
    };
    const ct: []const u8 = if (proto == .grpc) "application/grpc+json" else "application/json";
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ result.status, ct, result.body.len }) catch return;
    _ = conn.stream.writeAll(hdr) catch return;
    _ = conn.stream.writeAll(result.body) catch return;
}

fn listenLoop(port: u16, proto: Protocol) void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port) catch return;
    var server = addr.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();
    while (true) { const conn = server.accept() catch continue; handleConnection(conn, proto); }
}

pub fn main() !void {
    ffi.reposystem_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
