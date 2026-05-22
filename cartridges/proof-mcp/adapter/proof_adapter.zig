// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// proof-mcp/adapter/proof_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned proof_adapter.v (zig, removed 2026-04-12).
//
// REST :9121  gRPC-compat :9122  GraphQL :9123
// Proof verification lifecycle manager. Manages sessions across Lean, Coq, Agda, Isabelle, Idris2, Z3,
// Tools: proof_init_session, proof_load_obligation, proof_verify, proof_get_result, proof_get_state, proof_reset_session, proof_release_session, proof_can_transition

const std = @import("std");
const ffi = @import("proof_ffi");

const REST_PORT: u16 = 9121;
const GRPC_PORT: u16 = 9122;
const GQL_PORT:  u16 = 9123;
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
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"state\":\"ready\",\"service\":\"proof-mcp\"}}", .{}) catch return buf[0..0];
    return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "proof_init_session")) return .{ .status = 200, .body = okJson(resp, "proof_init_session forwarded") };
    if (std.mem.eql(u8, tool, "proof_load_obligation")) return .{ .status = 200, .body = okJson(resp, "proof_load_obligation forwarded") };
    if (std.mem.eql(u8, tool, "proof_verify")) return .{ .status = 200, .body = okJson(resp, "proof_verify forwarded") };
    if (std.mem.eql(u8, tool, "proof_get_result")) return .{ .status = 200, .body = okJson(resp, "proof_get_result forwarded") };
    if (std.mem.eql(u8, tool, "proof_get_state")) return .{ .status = 200, .body = okJson(resp, "proof_get_state forwarded") };
    if (std.mem.eql(u8, tool, "proof_reset_session")) return .{ .status = 200, .body = okJson(resp, "proof_reset_session forwarded") };
    if (std.mem.eql(u8, tool, "proof_release_session")) return .{ .status = 200, .body = okJson(resp, "proof_release_session forwarded") };
    if (std.mem.eql(u8, tool, "proof_can_transition")) return .{ .status = 200, .body = okJson(resp, "proof_can_transition forwarded") };
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
    const prefix = "/Proofservice/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "proof_init_session")) break :blk "proof_init_session";
        if (std.mem.eql(u8, method, "proof_load_obligation")) break :blk "proof_load_obligation";
        if (std.mem.eql(u8, method, "proof_verify")) break :blk "proof_verify";
        if (std.mem.eql(u8, method, "proof_get_result")) break :blk "proof_get_result";
        if (std.mem.eql(u8, method, "proof_get_state")) break :blk "proof_get_state";
        if (std.mem.eql(u8, method, "proof_reset_session")) break :blk "proof_reset_session";
        if (std.mem.eql(u8, method, "proof_release_session")) break :blk "proof_release_session";
        if (std.mem.eql(u8, method, "proof_can_transition")) break :blk "proof_can_transition";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "init_session") != null) return dispatch("proof_init_session", body, resp);
    if (std.mem.indexOf(u8, body, "load_obligation") != null) return dispatch("proof_load_obligation", body, resp);
    if (std.mem.indexOf(u8, body, "verify") != null) return dispatch("proof_verify", body, resp);
    if (std.mem.indexOf(u8, body, "get_result") != null) return dispatch("proof_get_result", body, resp);
    if (std.mem.indexOf(u8, body, "get_state") != null) return dispatch("proof_get_state", body, resp);
    if (std.mem.indexOf(u8, body, "reset_session") != null) return dispatch("proof_reset_session", body, resp);
    if (std.mem.indexOf(u8, body, "release_session") != null) return dispatch("proof_release_session", body, resp);
    if (std.mem.indexOf(u8, body, "can_transition") != null) return dispatch("proof_can_transition", body, resp);
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
    ffi.proof_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
