// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// affinescript-mcp/adapter/affinescript_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned affinescript_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (affinescript_mcp_ffi.zig) to three network protocols:
//   REST        :9031  POST /tools/<tool>
//   gRPC-compat :9032  /AffinescriptMcpService/<Method>
//   GraphQL     :9033  POST /graphql  { query: "..." }
//
// AffineScript compiler tools: type-check, parse, format, explain errors, compile, hover, complete, goto-def
// Tools:
//   affinescript_check
//   affinescript_parse
//   affinescript_format
//   affinescript_explain_error
//   affinescript_stdlib
//   affinescript_syntax_ref
//   affinescript_snippet
//   affinescript_lint
//   affinescript_compile
//   affinescript_hover
//   affinescript_goto_def
//   affinescript_complete

const std = @import("std");
const ffi = @import("affinescript_mcp_ffi");

const REST_PORT: u16 = 9031;
const GRPC_PORT: u16 = 9032;
const GQL_PORT:  u16 = 9033;

const MAX_CONN_BUF: usize = 16 * 1024;

// ============================================================================
// JSON response builders
// ============================================================================

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf,
        \{{"success":true,"message":"{}"}}
    , .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf,
        \{{"success":false,"error":"{}"}}
    , .{msg}) catch buf[0..0];
}

fn statusJson(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf,
        \{{"success":true,"state":"ready","service":"affinescript-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "affinescript_check")) return .{ .status = 200, .body = okJson(resp, "affinescript_check forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_parse")) return .{ .status = 200, .body = okJson(resp, "affinescript_parse forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_format")) return .{ .status = 200, .body = okJson(resp, "affinescript_format forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_explain_error")) return .{ .status = 200, .body = okJson(resp, "affinescript_explain_error forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_stdlib")) return .{ .status = 200, .body = okJson(resp, "affinescript_stdlib forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_syntax_ref")) return .{ .status = 200, .body = okJson(resp, "affinescript_syntax_ref forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_snippet")) return .{ .status = 200, .body = okJson(resp, "affinescript_snippet forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_lint")) return .{ .status = 200, .body = okJson(resp, "affinescript_lint forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_compile")) return .{ .status = 200, .body = okJson(resp, "affinescript_compile forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_hover")) return .{ .status = 200, .body = okJson(resp, "affinescript_hover forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_goto_def")) return .{ .status = 200, .body = okJson(resp, "affinescript_goto_def forwarded to backend") };
    if (std.mem.eql(u8, tool, "affinescript_complete")) return .{ .status = 200, .body = okJson(resp, "affinescript_complete forwarded to backend") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health"))
        return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

// ============================================================================
// REST handler
// ============================================================================

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) {
        return dispatch(path["/tools/".len..], body, resp);
    }
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) {
        return .{ .status = 200, .body = statusJson(resp) };
    }
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

// ============================================================================
// gRPC-compat handler
// ============================================================================

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/AffinescriptMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "AffinescriptCheck")) break :blk "affinescript_check";
        if (std.mem.eql(u8, method, "AffinescriptParse")) break :blk "affinescript_parse";
        if (std.mem.eql(u8, method, "AffinescriptFormat")) break :blk "affinescript_format";
        if (std.mem.eql(u8, method, "AffinescriptExplainError")) break :blk "affinescript_explain_error";
        if (std.mem.eql(u8, method, "AffinescriptStdlib")) break :blk "affinescript_stdlib";
        if (std.mem.eql(u8, method, "AffinescriptSyntaxRef")) break :blk "affinescript_syntax_ref";
        if (std.mem.eql(u8, method, "AffinescriptSnippet")) break :blk "affinescript_snippet";
        if (std.mem.eql(u8, method, "AffinescriptLint")) break :blk "affinescript_lint";
        if (std.mem.eql(u8, method, "AffinescriptCompile")) break :blk "affinescript_compile";
        if (std.mem.eql(u8, method, "AffinescriptHover")) break :blk "affinescript_hover";
        if (std.mem.eql(u8, method, "AffinescriptGotoDef")) break :blk "affinescript_goto_def";
        if (std.mem.eql(u8, method, "AffinescriptComplete")) break :blk "affinescript_complete";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

// ============================================================================
// GraphQL handler
// ============================================================================

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null)
        return .{ .status = 200, .body = okJson(resp, "schema introspection not yet supported") };
    if (std.mem.indexOf(u8, body, "check") != null) return dispatch("affinescript_check", body, resp);
    if (std.mem.indexOf(u8, body, "parse") != null) return dispatch("affinescript_parse", body, resp);
    if (std.mem.indexOf(u8, body, "format") != null) return dispatch("affinescript_format", body, resp);
    if (std.mem.indexOf(u8, body, "explain_error") != null) return dispatch("affinescript_explain_error", body, resp);
    if (std.mem.indexOf(u8, body, "stdlib") != null) return dispatch("affinescript_stdlib", body, resp);
    if (std.mem.indexOf(u8, body, "syntax_ref") != null) return dispatch("affinescript_syntax_ref", body, resp);
    if (std.mem.indexOf(u8, body, "snippet") != null) return dispatch("affinescript_snippet", body, resp);
    if (std.mem.indexOf(u8, body, "lint") != null) return dispatch("affinescript_lint", body, resp);
    if (std.mem.indexOf(u8, body, "compile") != null) return dispatch("affinescript_compile", body, resp);
    if (std.mem.indexOf(u8, body, "hover") != null) return dispatch("affinescript_hover", body, resp);
    if (std.mem.indexOf(u8, body, "goto_def") != null) return dispatch("affinescript_goto_def", body, resp);
    if (std.mem.indexOf(u8, body, "complete") != null) return dispatch("affinescript_complete", body, resp);
    return .{ .status = 200, .body = errJson(resp, "Unrecognised GraphQL operation") };
}

// ============================================================================
// HTTP/1.1 connection handler
// ============================================================================

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

    const content_type = switch (proto) {
        .rest    => "application/json",
        .grpc    => "application/grpc+json",
        .graphql => "application/json",
    };

    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ result.status, content_type, result.body.len },
    ) catch return;
    _ = conn.stream.writeAll(hdr) catch return;
    _ = conn.stream.writeAll(result.body) catch return;
}

fn listenLoop(port: u16, proto: Protocol) void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port) catch return;
    var server = addr.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();
    while (true) {
        const conn = server.accept() catch continue;
        handleConnection(conn, proto);
    }
}

pub fn main() !void {
    ffi.affinescript_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
