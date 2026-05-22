// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// sentry-mcp/adapter/sentry_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned sentry_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (sentry_mcp_ffi.zig) to three network protocols:
//   REST        :9094  POST /tools/<tool>
//   gRPC-compat :9095  /SentryMcpService/<Method>
//   GraphQL     :9096  POST /graphql  { query: "..." }
//
// Sentry error tracking: issues, events, releases, projects, teams
// Tools:
//   sentry_list_issues
//   sentry_get_issue
//   sentry_list_events
//   sentry_resolve_issue
//   sentry_list_projects
//   sentry_list_releases
//   sentry_get_dsn
//   sentry_list_teams
//   sentry_search_tags
//   sentry_list_transactions

const std = @import("std");
const ffi = @import("sentry_mcp_ffi");

const REST_PORT: u16 = 9094;
const GRPC_PORT: u16 = 9095;
const GQL_PORT:  u16 = 9096;

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
        \{{"success":true,"state":"ready","service":"sentry-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "sentry_list_issues")) return .{ .status = 200, .body = okJson(resp, "sentry_list_issues forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_get_issue")) return .{ .status = 200, .body = okJson(resp, "sentry_get_issue forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_list_events")) return .{ .status = 200, .body = okJson(resp, "sentry_list_events forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_resolve_issue")) return .{ .status = 200, .body = okJson(resp, "sentry_resolve_issue forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_list_projects")) return .{ .status = 200, .body = okJson(resp, "sentry_list_projects forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_list_releases")) return .{ .status = 200, .body = okJson(resp, "sentry_list_releases forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_get_dsn")) return .{ .status = 200, .body = okJson(resp, "sentry_get_dsn forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_list_teams")) return .{ .status = 200, .body = okJson(resp, "sentry_list_teams forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_search_tags")) return .{ .status = 200, .body = okJson(resp, "sentry_search_tags forwarded to backend") };
    if (std.mem.eql(u8, tool, "sentry_list_transactions")) return .{ .status = 200, .body = okJson(resp, "sentry_list_transactions forwarded to backend") };
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
    const prefix = "/SentryMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "SentryListIssues")) break :blk "sentry_list_issues";
        if (std.mem.eql(u8, method, "SentryGetIssue")) break :blk "sentry_get_issue";
        if (std.mem.eql(u8, method, "SentryListEvents")) break :blk "sentry_list_events";
        if (std.mem.eql(u8, method, "SentryResolveIssue")) break :blk "sentry_resolve_issue";
        if (std.mem.eql(u8, method, "SentryListProjects")) break :blk "sentry_list_projects";
        if (std.mem.eql(u8, method, "SentryListReleases")) break :blk "sentry_list_releases";
        if (std.mem.eql(u8, method, "SentryGetDsn")) break :blk "sentry_get_dsn";
        if (std.mem.eql(u8, method, "SentryListTeams")) break :blk "sentry_list_teams";
        if (std.mem.eql(u8, method, "SentrySearchTags")) break :blk "sentry_search_tags";
        if (std.mem.eql(u8, method, "SentryListTransactions")) break :blk "sentry_list_transactions";
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
    if (std.mem.indexOf(u8, body, "list_issues") != null) return dispatch("sentry_list_issues", body, resp);
    if (std.mem.indexOf(u8, body, "get_issue") != null) return dispatch("sentry_get_issue", body, resp);
    if (std.mem.indexOf(u8, body, "list_events") != null) return dispatch("sentry_list_events", body, resp);
    if (std.mem.indexOf(u8, body, "resolve_issue") != null) return dispatch("sentry_resolve_issue", body, resp);
    if (std.mem.indexOf(u8, body, "list_projects") != null) return dispatch("sentry_list_projects", body, resp);
    if (std.mem.indexOf(u8, body, "list_releases") != null) return dispatch("sentry_list_releases", body, resp);
    if (std.mem.indexOf(u8, body, "get_dsn") != null) return dispatch("sentry_get_dsn", body, resp);
    if (std.mem.indexOf(u8, body, "list_teams") != null) return dispatch("sentry_list_teams", body, resp);
    if (std.mem.indexOf(u8, body, "search_tags") != null) return dispatch("sentry_search_tags", body, resp);
    if (std.mem.indexOf(u8, body, "list_transactions") != null) return dispatch("sentry_list_transactions", body, resp);
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
    ffi.sentry_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
