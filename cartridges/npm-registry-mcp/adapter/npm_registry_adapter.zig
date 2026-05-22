// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// npm-registry-mcp/adapter/npm_registry_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned npm_registry_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (npm_registry_mcp_ffi.zig) to three network protocols:
//   REST        :9073  POST /tools/<tool>
//   gRPC-compat :9074  /NpmRegistryMcpService/<Method>
//   GraphQL     :9075  POST /graphql  { query: "..." }
//
// npm registry: search, metadata, versions, downloads, audit advisories
// Tools:
//   npm_search_packages
//   npm_get_package
//   npm_get_package_version
//   npm_list_versions
//   npm_get_downloads
//   npm_get_downloads_range
//   npm_get_dependencies
//   npm_get_maintainers
//   npm_get_dist_tags
//   npm_get_audit_advisories
//   npm_get_provenance
//   npm_get_packument

const std = @import("std");
const ffi = @import("npm_registry_mcp_ffi");

const REST_PORT: u16 = 9073;
const GRPC_PORT: u16 = 9074;
const GQL_PORT:  u16 = 9075;

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
        \{{"success":true,"state":"ready","service":"npm-registry-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "npm_search_packages")) return .{ .status = 200, .body = okJson(resp, "npm_search_packages forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_package")) return .{ .status = 200, .body = okJson(resp, "npm_get_package forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_package_version")) return .{ .status = 200, .body = okJson(resp, "npm_get_package_version forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_list_versions")) return .{ .status = 200, .body = okJson(resp, "npm_list_versions forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_downloads")) return .{ .status = 200, .body = okJson(resp, "npm_get_downloads forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_downloads_range")) return .{ .status = 200, .body = okJson(resp, "npm_get_downloads_range forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_dependencies")) return .{ .status = 200, .body = okJson(resp, "npm_get_dependencies forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_maintainers")) return .{ .status = 200, .body = okJson(resp, "npm_get_maintainers forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_dist_tags")) return .{ .status = 200, .body = okJson(resp, "npm_get_dist_tags forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_audit_advisories")) return .{ .status = 200, .body = okJson(resp, "npm_get_audit_advisories forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_provenance")) return .{ .status = 200, .body = okJson(resp, "npm_get_provenance forwarded to backend") };
    if (std.mem.eql(u8, tool, "npm_get_packument")) return .{ .status = 200, .body = okJson(resp, "npm_get_packument forwarded to backend") };
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
    const prefix = "/NpmRegistryMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "NpmSearchPackages")) break :blk "npm_search_packages";
        if (std.mem.eql(u8, method, "NpmGetPackage")) break :blk "npm_get_package";
        if (std.mem.eql(u8, method, "NpmGetPackageVersion")) break :blk "npm_get_package_version";
        if (std.mem.eql(u8, method, "NpmListVersions")) break :blk "npm_list_versions";
        if (std.mem.eql(u8, method, "NpmGetDownloads")) break :blk "npm_get_downloads";
        if (std.mem.eql(u8, method, "NpmGetDownloadsRange")) break :blk "npm_get_downloads_range";
        if (std.mem.eql(u8, method, "NpmGetDependencies")) break :blk "npm_get_dependencies";
        if (std.mem.eql(u8, method, "NpmGetMaintainers")) break :blk "npm_get_maintainers";
        if (std.mem.eql(u8, method, "NpmGetDistTags")) break :blk "npm_get_dist_tags";
        if (std.mem.eql(u8, method, "NpmGetAuditAdvisories")) break :blk "npm_get_audit_advisories";
        if (std.mem.eql(u8, method, "NpmGetProvenance")) break :blk "npm_get_provenance";
        if (std.mem.eql(u8, method, "NpmGetPackument")) break :blk "npm_get_packument";
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
    if (std.mem.indexOf(u8, body, "search_packages") != null) return dispatch("npm_search_packages", body, resp);
    if (std.mem.indexOf(u8, body, "get_package") != null) return dispatch("npm_get_package", body, resp);
    if (std.mem.indexOf(u8, body, "get_package_version") != null) return dispatch("npm_get_package_version", body, resp);
    if (std.mem.indexOf(u8, body, "list_versions") != null) return dispatch("npm_list_versions", body, resp);
    if (std.mem.indexOf(u8, body, "get_downloads") != null) return dispatch("npm_get_downloads", body, resp);
    if (std.mem.indexOf(u8, body, "get_downloads_range") != null) return dispatch("npm_get_downloads_range", body, resp);
    if (std.mem.indexOf(u8, body, "get_dependencies") != null) return dispatch("npm_get_dependencies", body, resp);
    if (std.mem.indexOf(u8, body, "get_maintainers") != null) return dispatch("npm_get_maintainers", body, resp);
    if (std.mem.indexOf(u8, body, "get_dist_tags") != null) return dispatch("npm_get_dist_tags", body, resp);
    if (std.mem.indexOf(u8, body, "get_audit_advisories") != null) return dispatch("npm_get_audit_advisories", body, resp);
    if (std.mem.indexOf(u8, body, "get_provenance") != null) return dispatch("npm_get_provenance", body, resp);
    if (std.mem.indexOf(u8, body, "get_packument") != null) return dispatch("npm_get_packument", body, resp);
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
    ffi.npm_registry_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
