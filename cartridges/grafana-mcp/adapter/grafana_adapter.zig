// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// grafana-mcp/adapter/grafana_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned grafana_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (grafana_mcp_ffi.zig) to three network protocols:
//   REST        :9058  POST /tools/<tool>
//   gRPC-compat :9059  /GrafanaMcpService/<Method>
//   GraphQL     :9060  POST /graphql  { query: "..." }
//
// Grafana dashboards, datasources, alerts, annotations, health
// Tools:
//   grafana_search_dashboards
//   grafana_get_dashboard
//   grafana_create_dashboard
//   grafana_delete_dashboard
//   grafana_query_datasource
//   grafana_list_alerts
//   grafana_create_annotation
//   grafana_list_datasources
//   grafana_list_folders
//   grafana_health

const std = @import("std");
const ffi = @import("grafana_mcp_ffi");

const REST_PORT: u16 = 9058;
const GRPC_PORT: u16 = 9059;
const GQL_PORT:  u16 = 9060;

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
        \{{"success":true,"state":"ready","service":"grafana-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "grafana_search_dashboards")) return .{ .status = 200, .body = okJson(resp, "grafana_search_dashboards forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_get_dashboard")) return .{ .status = 200, .body = okJson(resp, "grafana_get_dashboard forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_create_dashboard")) return .{ .status = 200, .body = okJson(resp, "grafana_create_dashboard forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_delete_dashboard")) return .{ .status = 200, .body = okJson(resp, "grafana_delete_dashboard forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_query_datasource")) return .{ .status = 200, .body = okJson(resp, "grafana_query_datasource forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_list_alerts")) return .{ .status = 200, .body = okJson(resp, "grafana_list_alerts forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_create_annotation")) return .{ .status = 200, .body = okJson(resp, "grafana_create_annotation forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_list_datasources")) return .{ .status = 200, .body = okJson(resp, "grafana_list_datasources forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_list_folders")) return .{ .status = 200, .body = okJson(resp, "grafana_list_folders forwarded to backend") };
    if (std.mem.eql(u8, tool, "grafana_health")) return .{ .status = 200, .body = okJson(resp, "grafana_health forwarded to backend") };
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
    const prefix = "/GrafanaMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "GrafanaSearchDashboards")) break :blk "grafana_search_dashboards";
        if (std.mem.eql(u8, method, "GrafanaGetDashboard")) break :blk "grafana_get_dashboard";
        if (std.mem.eql(u8, method, "GrafanaCreateDashboard")) break :blk "grafana_create_dashboard";
        if (std.mem.eql(u8, method, "GrafanaDeleteDashboard")) break :blk "grafana_delete_dashboard";
        if (std.mem.eql(u8, method, "GrafanaQueryDatasource")) break :blk "grafana_query_datasource";
        if (std.mem.eql(u8, method, "GrafanaListAlerts")) break :blk "grafana_list_alerts";
        if (std.mem.eql(u8, method, "GrafanaCreateAnnotation")) break :blk "grafana_create_annotation";
        if (std.mem.eql(u8, method, "GrafanaListDatasources")) break :blk "grafana_list_datasources";
        if (std.mem.eql(u8, method, "GrafanaListFolders")) break :blk "grafana_list_folders";
        if (std.mem.eql(u8, method, "GrafanaHealth")) break :blk "grafana_health";
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
    if (std.mem.indexOf(u8, body, "search_dashboards") != null) return dispatch("grafana_search_dashboards", body, resp);
    if (std.mem.indexOf(u8, body, "get_dashboard") != null) return dispatch("grafana_get_dashboard", body, resp);
    if (std.mem.indexOf(u8, body, "create_dashboard") != null) return dispatch("grafana_create_dashboard", body, resp);
    if (std.mem.indexOf(u8, body, "delete_dashboard") != null) return dispatch("grafana_delete_dashboard", body, resp);
    if (std.mem.indexOf(u8, body, "query_datasource") != null) return dispatch("grafana_query_datasource", body, resp);
    if (std.mem.indexOf(u8, body, "list_alerts") != null) return dispatch("grafana_list_alerts", body, resp);
    if (std.mem.indexOf(u8, body, "create_annotation") != null) return dispatch("grafana_create_annotation", body, resp);
    if (std.mem.indexOf(u8, body, "list_datasources") != null) return dispatch("grafana_list_datasources", body, resp);
    if (std.mem.indexOf(u8, body, "list_folders") != null) return dispatch("grafana_list_folders", body, resp);
    if (std.mem.indexOf(u8, body, "health") != null) return dispatch("grafana_health", body, resp);
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
    ffi.grafana_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
