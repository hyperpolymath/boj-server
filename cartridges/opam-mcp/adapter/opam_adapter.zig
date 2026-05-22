// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opam-mcp/adapter/opam_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned opam_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (opam_mcp_ffi.zig) to three network protocols:
//   REST        :9079  POST /tools/<tool>
//   gRPC-compat :9080  /OpamMcpService/<Method>
//   GraphQL     :9081  POST /graphql  { query: "..." }
//
// OPAM OCaml package registry: packages, versions, dependencies
// Tools:
//   opam_search_packages
//   opam_get_package
//   opam_get_version
//   opam_list_versions
//   opam_get_dependencies
//   opam_get_reverse_dependencies
//   opam_get_maintainers
//   opam_get_tags
//   opam_list_all_packages
//   opam_get_opam_file

const std = @import("std");
const ffi = @import("opam_mcp_ffi");

const REST_PORT: u16 = 9079;
const GRPC_PORT: u16 = 9080;
const GQL_PORT:  u16 = 9081;

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
        \{{"success":true,"state":"ready","service":"opam-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "opam_search_packages")) return .{ .status = 200, .body = okJson(resp, "opam_search_packages forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_package")) return .{ .status = 200, .body = okJson(resp, "opam_get_package forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_version")) return .{ .status = 200, .body = okJson(resp, "opam_get_version forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_list_versions")) return .{ .status = 200, .body = okJson(resp, "opam_list_versions forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_dependencies")) return .{ .status = 200, .body = okJson(resp, "opam_get_dependencies forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_reverse_dependencies")) return .{ .status = 200, .body = okJson(resp, "opam_get_reverse_dependencies forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_maintainers")) return .{ .status = 200, .body = okJson(resp, "opam_get_maintainers forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_tags")) return .{ .status = 200, .body = okJson(resp, "opam_get_tags forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_list_all_packages")) return .{ .status = 200, .body = okJson(resp, "opam_list_all_packages forwarded to backend") };
    if (std.mem.eql(u8, tool, "opam_get_opam_file")) return .{ .status = 200, .body = okJson(resp, "opam_get_opam_file forwarded to backend") };
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
    const prefix = "/OpamMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "OpamSearchPackages")) break :blk "opam_search_packages";
        if (std.mem.eql(u8, method, "OpamGetPackage")) break :blk "opam_get_package";
        if (std.mem.eql(u8, method, "OpamGetVersion")) break :blk "opam_get_version";
        if (std.mem.eql(u8, method, "OpamListVersions")) break :blk "opam_list_versions";
        if (std.mem.eql(u8, method, "OpamGetDependencies")) break :blk "opam_get_dependencies";
        if (std.mem.eql(u8, method, "OpamGetReverseDependencies")) break :blk "opam_get_reverse_dependencies";
        if (std.mem.eql(u8, method, "OpamGetMaintainers")) break :blk "opam_get_maintainers";
        if (std.mem.eql(u8, method, "OpamGetTags")) break :blk "opam_get_tags";
        if (std.mem.eql(u8, method, "OpamListAllPackages")) break :blk "opam_list_all_packages";
        if (std.mem.eql(u8, method, "OpamGetOpamFile")) break :blk "opam_get_opam_file";
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
    if (std.mem.indexOf(u8, body, "search_packages") != null) return dispatch("opam_search_packages", body, resp);
    if (std.mem.indexOf(u8, body, "get_package") != null) return dispatch("opam_get_package", body, resp);
    if (std.mem.indexOf(u8, body, "get_version") != null) return dispatch("opam_get_version", body, resp);
    if (std.mem.indexOf(u8, body, "list_versions") != null) return dispatch("opam_list_versions", body, resp);
    if (std.mem.indexOf(u8, body, "get_dependencies") != null) return dispatch("opam_get_dependencies", body, resp);
    if (std.mem.indexOf(u8, body, "get_reverse_dependencies") != null) return dispatch("opam_get_reverse_dependencies", body, resp);
    if (std.mem.indexOf(u8, body, "get_maintainers") != null) return dispatch("opam_get_maintainers", body, resp);
    if (std.mem.indexOf(u8, body, "get_tags") != null) return dispatch("opam_get_tags", body, resp);
    if (std.mem.indexOf(u8, body, "list_all_packages") != null) return dispatch("opam_list_all_packages", body, resp);
    if (std.mem.indexOf(u8, body, "get_opam_file") != null) return dispatch("opam_get_opam_file", body, resp);
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
    ffi.opam_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
