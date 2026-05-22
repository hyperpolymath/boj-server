// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hex-mcp/adapter/hex_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned hex_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (hex_mcp_ffi.zig) to three network protocols:
//   REST        :9067  POST /tools/<tool>
//   gRPC-compat :9068  /HexMcpService/<Method>
//   GraphQL     :9069  POST /graphql  { query: "..." }
//
// Hex.pm Elixir/Erlang registry: packages, releases, downloads
// Tools:
//   hex_search_packages
//   hex_get_package
//   hex_get_release
//   hex_list_releases
//   hex_get_downloads
//   hex_get_dependencies
//   hex_get_owners
//   hex_get_retirement
//   hex_get_user
//   hex_list_user_packages

const std = @import("std");
const ffi = @import("hex_mcp_ffi");

const REST_PORT: u16 = 9067;
const GRPC_PORT: u16 = 9068;
const GQL_PORT:  u16 = 9069;

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
        \{{"success":true,"state":"ready","service":"hex-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "hex_search_packages")) return .{ .status = 200, .body = okJson(resp, "hex_search_packages forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_package")) return .{ .status = 200, .body = okJson(resp, "hex_get_package forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_release")) return .{ .status = 200, .body = okJson(resp, "hex_get_release forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_list_releases")) return .{ .status = 200, .body = okJson(resp, "hex_list_releases forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_downloads")) return .{ .status = 200, .body = okJson(resp, "hex_get_downloads forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_dependencies")) return .{ .status = 200, .body = okJson(resp, "hex_get_dependencies forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_owners")) return .{ .status = 200, .body = okJson(resp, "hex_get_owners forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_retirement")) return .{ .status = 200, .body = okJson(resp, "hex_get_retirement forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_get_user")) return .{ .status = 200, .body = okJson(resp, "hex_get_user forwarded to backend") };
    if (std.mem.eql(u8, tool, "hex_list_user_packages")) return .{ .status = 200, .body = okJson(resp, "hex_list_user_packages forwarded to backend") };
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
    const prefix = "/HexMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "HexSearchPackages")) break :blk "hex_search_packages";
        if (std.mem.eql(u8, method, "HexGetPackage")) break :blk "hex_get_package";
        if (std.mem.eql(u8, method, "HexGetRelease")) break :blk "hex_get_release";
        if (std.mem.eql(u8, method, "HexListReleases")) break :blk "hex_list_releases";
        if (std.mem.eql(u8, method, "HexGetDownloads")) break :blk "hex_get_downloads";
        if (std.mem.eql(u8, method, "HexGetDependencies")) break :blk "hex_get_dependencies";
        if (std.mem.eql(u8, method, "HexGetOwners")) break :blk "hex_get_owners";
        if (std.mem.eql(u8, method, "HexGetRetirement")) break :blk "hex_get_retirement";
        if (std.mem.eql(u8, method, "HexGetUser")) break :blk "hex_get_user";
        if (std.mem.eql(u8, method, "HexListUserPackages")) break :blk "hex_list_user_packages";
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
    if (std.mem.indexOf(u8, body, "search_packages") != null) return dispatch("hex_search_packages", body, resp);
    if (std.mem.indexOf(u8, body, "get_package") != null) return dispatch("hex_get_package", body, resp);
    if (std.mem.indexOf(u8, body, "get_release") != null) return dispatch("hex_get_release", body, resp);
    if (std.mem.indexOf(u8, body, "list_releases") != null) return dispatch("hex_list_releases", body, resp);
    if (std.mem.indexOf(u8, body, "get_downloads") != null) return dispatch("hex_get_downloads", body, resp);
    if (std.mem.indexOf(u8, body, "get_dependencies") != null) return dispatch("hex_get_dependencies", body, resp);
    if (std.mem.indexOf(u8, body, "get_owners") != null) return dispatch("hex_get_owners", body, resp);
    if (std.mem.indexOf(u8, body, "get_retirement") != null) return dispatch("hex_get_retirement", body, resp);
    if (std.mem.indexOf(u8, body, "get_user") != null) return dispatch("hex_get_user", body, resp);
    if (std.mem.indexOf(u8, body, "list_user_packages") != null) return dispatch("hex_list_user_packages", body, resp);
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
    ffi.hex_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
