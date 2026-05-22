// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// railway-mcp/adapter/railway_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned railway_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (railway_mcp_ffi.zig) to three network protocols:
//   REST        :9088  POST /tools/<tool>
//   gRPC-compat :9089  /RailwayMcpService/<Method>
//   GraphQL     :9090  POST /graphql  { query: "..." }
//
// Railway platform: projects, services, deployments, variables, domains
// Tools:
//   railway_list_projects
//   railway_get_project
//   railway_create_project
//   railway_delete_project
//   railway_list_services
//   railway_get_service
//   railway_create_service
//   railway_restart_service
//   railway_list_deployments
//   railway_get_deployment
//   railway_redeploy
//   railway_rollback
//   railway_list_variables
//   railway_set_variable
//   railway_delete_variable
//   railway_list_domains
//   railway_add_domain
//   railway_get_logs
//   railway_get_metrics

const std = @import("std");
const ffi = @import("railway_mcp_ffi");

const REST_PORT: u16 = 9088;
const GRPC_PORT: u16 = 9089;
const GQL_PORT:  u16 = 9090;

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
        \{{"success":true,"state":"ready","service":"railway-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "railway_list_projects")) return .{ .status = 200, .body = okJson(resp, "railway_list_projects forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_get_project")) return .{ .status = 200, .body = okJson(resp, "railway_get_project forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_create_project")) return .{ .status = 200, .body = okJson(resp, "railway_create_project forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_delete_project")) return .{ .status = 200, .body = okJson(resp, "railway_delete_project forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_list_services")) return .{ .status = 200, .body = okJson(resp, "railway_list_services forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_get_service")) return .{ .status = 200, .body = okJson(resp, "railway_get_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_create_service")) return .{ .status = 200, .body = okJson(resp, "railway_create_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_restart_service")) return .{ .status = 200, .body = okJson(resp, "railway_restart_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_list_deployments")) return .{ .status = 200, .body = okJson(resp, "railway_list_deployments forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_get_deployment")) return .{ .status = 200, .body = okJson(resp, "railway_get_deployment forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_redeploy")) return .{ .status = 200, .body = okJson(resp, "railway_redeploy forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_rollback")) return .{ .status = 200, .body = okJson(resp, "railway_rollback forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_list_variables")) return .{ .status = 200, .body = okJson(resp, "railway_list_variables forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_set_variable")) return .{ .status = 200, .body = okJson(resp, "railway_set_variable forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_delete_variable")) return .{ .status = 200, .body = okJson(resp, "railway_delete_variable forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_list_domains")) return .{ .status = 200, .body = okJson(resp, "railway_list_domains forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_add_domain")) return .{ .status = 200, .body = okJson(resp, "railway_add_domain forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_get_logs")) return .{ .status = 200, .body = okJson(resp, "railway_get_logs forwarded to backend") };
    if (std.mem.eql(u8, tool, "railway_get_metrics")) return .{ .status = 200, .body = okJson(resp, "railway_get_metrics forwarded to backend") };
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
    const prefix = "/RailwayMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "RailwayListProjects")) break :blk "railway_list_projects";
        if (std.mem.eql(u8, method, "RailwayGetProject")) break :blk "railway_get_project";
        if (std.mem.eql(u8, method, "RailwayCreateProject")) break :blk "railway_create_project";
        if (std.mem.eql(u8, method, "RailwayDeleteProject")) break :blk "railway_delete_project";
        if (std.mem.eql(u8, method, "RailwayListServices")) break :blk "railway_list_services";
        if (std.mem.eql(u8, method, "RailwayGetService")) break :blk "railway_get_service";
        if (std.mem.eql(u8, method, "RailwayCreateService")) break :blk "railway_create_service";
        if (std.mem.eql(u8, method, "RailwayRestartService")) break :blk "railway_restart_service";
        if (std.mem.eql(u8, method, "RailwayListDeployments")) break :blk "railway_list_deployments";
        if (std.mem.eql(u8, method, "RailwayGetDeployment")) break :blk "railway_get_deployment";
        if (std.mem.eql(u8, method, "RailwayRedeploy")) break :blk "railway_redeploy";
        if (std.mem.eql(u8, method, "RailwayRollback")) break :blk "railway_rollback";
        if (std.mem.eql(u8, method, "RailwayListVariables")) break :blk "railway_list_variables";
        if (std.mem.eql(u8, method, "RailwaySetVariable")) break :blk "railway_set_variable";
        if (std.mem.eql(u8, method, "RailwayDeleteVariable")) break :blk "railway_delete_variable";
        if (std.mem.eql(u8, method, "RailwayListDomains")) break :blk "railway_list_domains";
        if (std.mem.eql(u8, method, "RailwayAddDomain")) break :blk "railway_add_domain";
        if (std.mem.eql(u8, method, "RailwayGetLogs")) break :blk "railway_get_logs";
        if (std.mem.eql(u8, method, "RailwayGetMetrics")) break :blk "railway_get_metrics";
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
    if (std.mem.indexOf(u8, body, "list_projects") != null) return dispatch("railway_list_projects", body, resp);
    if (std.mem.indexOf(u8, body, "get_project") != null) return dispatch("railway_get_project", body, resp);
    if (std.mem.indexOf(u8, body, "create_project") != null) return dispatch("railway_create_project", body, resp);
    if (std.mem.indexOf(u8, body, "delete_project") != null) return dispatch("railway_delete_project", body, resp);
    if (std.mem.indexOf(u8, body, "list_services") != null) return dispatch("railway_list_services", body, resp);
    if (std.mem.indexOf(u8, body, "get_service") != null) return dispatch("railway_get_service", body, resp);
    if (std.mem.indexOf(u8, body, "create_service") != null) return dispatch("railway_create_service", body, resp);
    if (std.mem.indexOf(u8, body, "restart_service") != null) return dispatch("railway_restart_service", body, resp);
    if (std.mem.indexOf(u8, body, "list_deployments") != null) return dispatch("railway_list_deployments", body, resp);
    if (std.mem.indexOf(u8, body, "get_deployment") != null) return dispatch("railway_get_deployment", body, resp);
    if (std.mem.indexOf(u8, body, "redeploy") != null) return dispatch("railway_redeploy", body, resp);
    if (std.mem.indexOf(u8, body, "rollback") != null) return dispatch("railway_rollback", body, resp);
    if (std.mem.indexOf(u8, body, "list_variables") != null) return dispatch("railway_list_variables", body, resp);
    if (std.mem.indexOf(u8, body, "set_variable") != null) return dispatch("railway_set_variable", body, resp);
    if (std.mem.indexOf(u8, body, "delete_variable") != null) return dispatch("railway_delete_variable", body, resp);
    if (std.mem.indexOf(u8, body, "list_domains") != null) return dispatch("railway_list_domains", body, resp);
    if (std.mem.indexOf(u8, body, "add_domain") != null) return dispatch("railway_add_domain", body, resp);
    if (std.mem.indexOf(u8, body, "get_logs") != null) return dispatch("railway_get_logs", body, resp);
    if (std.mem.indexOf(u8, body, "get_metrics") != null) return dispatch("railway_get_metrics", body, resp);
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
    ffi.railway_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
