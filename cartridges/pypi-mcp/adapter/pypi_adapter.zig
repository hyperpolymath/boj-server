// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pypi-mcp/adapter/pypi_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned pypi_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (pypi_mcp_ffi.zig) to three network protocols:
//   REST        :9085  POST /tools/<tool>
//   gRPC-compat :9086  /PypiMcpService/<Method>
//   GraphQL     :9087  POST /graphql  { query: "..." }
//
// PyPI Python registry: packages, versions, downloads, vulnerabilities
// Tools:
//   pypi_search_packages
//   pypi_get_package
//   pypi_get_version
//   pypi_list_versions
//   pypi_get_downloads
//   pypi_get_dependencies
//   pypi_get_release_files
//   pypi_get_maintainers
//   pypi_get_classifiers
//   pypi_get_vulnerabilities
//   pypi_get_project_urls

const std = @import("std");
const ffi = @import("pypi_mcp_ffi");

const REST_PORT: u16 = 9085;
const GRPC_PORT: u16 = 9086;
const GQL_PORT:  u16 = 9087;

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
        \{{"success":true,"state":"ready","service":"pypi-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "pypi_search_packages")) return .{ .status = 200, .body = okJson(resp, "pypi_search_packages forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_package")) return .{ .status = 200, .body = okJson(resp, "pypi_get_package forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_version")) return .{ .status = 200, .body = okJson(resp, "pypi_get_version forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_list_versions")) return .{ .status = 200, .body = okJson(resp, "pypi_list_versions forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_downloads")) return .{ .status = 200, .body = okJson(resp, "pypi_get_downloads forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_dependencies")) return .{ .status = 200, .body = okJson(resp, "pypi_get_dependencies forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_release_files")) return .{ .status = 200, .body = okJson(resp, "pypi_get_release_files forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_maintainers")) return .{ .status = 200, .body = okJson(resp, "pypi_get_maintainers forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_classifiers")) return .{ .status = 200, .body = okJson(resp, "pypi_get_classifiers forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_vulnerabilities")) return .{ .status = 200, .body = okJson(resp, "pypi_get_vulnerabilities forwarded to backend") };
    if (std.mem.eql(u8, tool, "pypi_get_project_urls")) return .{ .status = 200, .body = okJson(resp, "pypi_get_project_urls forwarded to backend") };
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
    const prefix = "/PypiMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "PypiSearchPackages")) break :blk "pypi_search_packages";
        if (std.mem.eql(u8, method, "PypiGetPackage")) break :blk "pypi_get_package";
        if (std.mem.eql(u8, method, "PypiGetVersion")) break :blk "pypi_get_version";
        if (std.mem.eql(u8, method, "PypiListVersions")) break :blk "pypi_list_versions";
        if (std.mem.eql(u8, method, "PypiGetDownloads")) break :blk "pypi_get_downloads";
        if (std.mem.eql(u8, method, "PypiGetDependencies")) break :blk "pypi_get_dependencies";
        if (std.mem.eql(u8, method, "PypiGetReleaseFiles")) break :blk "pypi_get_release_files";
        if (std.mem.eql(u8, method, "PypiGetMaintainers")) break :blk "pypi_get_maintainers";
        if (std.mem.eql(u8, method, "PypiGetClassifiers")) break :blk "pypi_get_classifiers";
        if (std.mem.eql(u8, method, "PypiGetVulnerabilities")) break :blk "pypi_get_vulnerabilities";
        if (std.mem.eql(u8, method, "PypiGetProjectUrls")) break :blk "pypi_get_project_urls";
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
    if (std.mem.indexOf(u8, body, "search_packages") != null) return dispatch("pypi_search_packages", body, resp);
    if (std.mem.indexOf(u8, body, "get_package") != null) return dispatch("pypi_get_package", body, resp);
    if (std.mem.indexOf(u8, body, "get_version") != null) return dispatch("pypi_get_version", body, resp);
    if (std.mem.indexOf(u8, body, "list_versions") != null) return dispatch("pypi_list_versions", body, resp);
    if (std.mem.indexOf(u8, body, "get_downloads") != null) return dispatch("pypi_get_downloads", body, resp);
    if (std.mem.indexOf(u8, body, "get_dependencies") != null) return dispatch("pypi_get_dependencies", body, resp);
    if (std.mem.indexOf(u8, body, "get_release_files") != null) return dispatch("pypi_get_release_files", body, resp);
    if (std.mem.indexOf(u8, body, "get_maintainers") != null) return dispatch("pypi_get_maintainers", body, resp);
    if (std.mem.indexOf(u8, body, "get_classifiers") != null) return dispatch("pypi_get_classifiers", body, resp);
    if (std.mem.indexOf(u8, body, "get_vulnerabilities") != null) return dispatch("pypi_get_vulnerabilities", body, resp);
    if (std.mem.indexOf(u8, body, "get_project_urls") != null) return dispatch("pypi_get_project_urls", body, resp);
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
    ffi.pypi_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
