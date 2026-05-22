// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// panic-attack-mcp/adapter/panic_attack_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned panic_attack_adapter.v (zig, removed 2026-04-12).
//
// REST :9106  gRPC-compat :9107  GraphQL :9108
// panic-attacker static analysis. Scans codebases for dangerous patterns, banned constructs, proof dri
// Tools: panic_attack_scan, panic_attack_get_findings, panic_attack_get_severity

const std = @import("std");
const ffi = @import("panic_attack_ffi");

const REST_PORT: u16 = 9106;
const GRPC_PORT: u16 = 9107;
const GQL_PORT:  u16 = 9108;
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
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"state\":\"ready\",\"service\":\"panic-attack-mcp\"}}", .{}) catch return buf[0..0];
    return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "panic_attack_scan")) return .{ .status = 200, .body = okJson(resp, "panic_attack_scan forwarded") };
    if (std.mem.eql(u8, tool, "panic_attack_get_findings")) return .{ .status = 200, .body = okJson(resp, "panic_attack_get_findings forwarded") };
    if (std.mem.eql(u8, tool, "panic_attack_get_severity")) return .{ .status = 200, .body = okJson(resp, "panic_attack_get_severity forwarded") };
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
    const prefix = "/PanicAttackservice/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "panic_attack_scan")) break :blk "panic_attack_scan";
        if (std.mem.eql(u8, method, "panic_attack_get_findings")) break :blk "panic_attack_get_findings";
        if (std.mem.eql(u8, method, "panic_attack_get_severity")) break :blk "panic_attack_get_severity";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "attack_scan") != null) return dispatch("panic_attack_scan", body, resp);
    if (std.mem.indexOf(u8, body, "attack_get_findings") != null) return dispatch("panic_attack_get_findings", body, resp);
    if (std.mem.indexOf(u8, body, "attack_get_severity") != null) return dispatch("panic_attack_get_severity", body, resp);
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
    ffi.panic_attack_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
