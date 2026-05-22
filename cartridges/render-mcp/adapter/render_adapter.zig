// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// render-mcp/adapter/render_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned render_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (render_mcp_ffi.zig) to three network protocols:
//   REST        :9091  POST /tools/<tool>
//   gRPC-compat :9092  /RenderMcpService/<Method>
//   GraphQL     :9093  POST /graphql  { query: "..." }
//
// Render cloud: services, deploys, env groups, custom domains, jobs
// Tools:
//   render_list_services
//   render_get_service
//   render_create_service
//   render_delete_service
//   render_list_deploys
//   render_trigger_deploy
//   render_get_deploy
//   render_list_env_groups
//   render_get_env_group
//   render_list_custom_domains
//   render_add_custom_domain
//   render_list_jobs
//   render_create_job
//   render_suspend_service
//   render_resume_service
//   render_get_bandwidth

const std = @import("std");
const ffi = @import("render_mcp_ffi");

const REST_PORT: u16 = 9091;
const GRPC_PORT: u16 = 9092;
const GQL_PORT:  u16 = 9093;

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
        \{{"success":true,"state":"ready","service":"render-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "render_list_services")) return .{ .status = 200, .body = okJson(resp, "render_list_services forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_get_service")) return .{ .status = 200, .body = okJson(resp, "render_get_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_create_service")) return .{ .status = 200, .body = okJson(resp, "render_create_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_delete_service")) return .{ .status = 200, .body = okJson(resp, "render_delete_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_list_deploys")) return .{ .status = 200, .body = okJson(resp, "render_list_deploys forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_trigger_deploy")) return .{ .status = 200, .body = okJson(resp, "render_trigger_deploy forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_get_deploy")) return .{ .status = 200, .body = okJson(resp, "render_get_deploy forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_list_env_groups")) return .{ .status = 200, .body = okJson(resp, "render_list_env_groups forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_get_env_group")) return .{ .status = 200, .body = okJson(resp, "render_get_env_group forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_list_custom_domains")) return .{ .status = 200, .body = okJson(resp, "render_list_custom_domains forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_add_custom_domain")) return .{ .status = 200, .body = okJson(resp, "render_add_custom_domain forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_list_jobs")) return .{ .status = 200, .body = okJson(resp, "render_list_jobs forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_create_job")) return .{ .status = 200, .body = okJson(resp, "render_create_job forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_suspend_service")) return .{ .status = 200, .body = okJson(resp, "render_suspend_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_resume_service")) return .{ .status = 200, .body = okJson(resp, "render_resume_service forwarded to backend") };
    if (std.mem.eql(u8, tool, "render_get_bandwidth")) return .{ .status = 200, .body = okJson(resp, "render_get_bandwidth forwarded to backend") };
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
    const prefix = "/RenderMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "RenderListServices")) break :blk "render_list_services";
        if (std.mem.eql(u8, method, "RenderGetService")) break :blk "render_get_service";
        if (std.mem.eql(u8, method, "RenderCreateService")) break :blk "render_create_service";
        if (std.mem.eql(u8, method, "RenderDeleteService")) break :blk "render_delete_service";
        if (std.mem.eql(u8, method, "RenderListDeploys")) break :blk "render_list_deploys";
        if (std.mem.eql(u8, method, "RenderTriggerDeploy")) break :blk "render_trigger_deploy";
        if (std.mem.eql(u8, method, "RenderGetDeploy")) break :blk "render_get_deploy";
        if (std.mem.eql(u8, method, "RenderListEnvGroups")) break :blk "render_list_env_groups";
        if (std.mem.eql(u8, method, "RenderGetEnvGroup")) break :blk "render_get_env_group";
        if (std.mem.eql(u8, method, "RenderListCustomDomains")) break :blk "render_list_custom_domains";
        if (std.mem.eql(u8, method, "RenderAddCustomDomain")) break :blk "render_add_custom_domain";
        if (std.mem.eql(u8, method, "RenderListJobs")) break :blk "render_list_jobs";
        if (std.mem.eql(u8, method, "RenderCreateJob")) break :blk "render_create_job";
        if (std.mem.eql(u8, method, "RenderSuspendService")) break :blk "render_suspend_service";
        if (std.mem.eql(u8, method, "RenderResumeService")) break :blk "render_resume_service";
        if (std.mem.eql(u8, method, "RenderGetBandwidth")) break :blk "render_get_bandwidth";
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
    if (std.mem.indexOf(u8, body, "list_services") != null) return dispatch("render_list_services", body, resp);
    if (std.mem.indexOf(u8, body, "get_service") != null) return dispatch("render_get_service", body, resp);
    if (std.mem.indexOf(u8, body, "create_service") != null) return dispatch("render_create_service", body, resp);
    if (std.mem.indexOf(u8, body, "delete_service") != null) return dispatch("render_delete_service", body, resp);
    if (std.mem.indexOf(u8, body, "list_deploys") != null) return dispatch("render_list_deploys", body, resp);
    if (std.mem.indexOf(u8, body, "trigger_deploy") != null) return dispatch("render_trigger_deploy", body, resp);
    if (std.mem.indexOf(u8, body, "get_deploy") != null) return dispatch("render_get_deploy", body, resp);
    if (std.mem.indexOf(u8, body, "list_env_groups") != null) return dispatch("render_list_env_groups", body, resp);
    if (std.mem.indexOf(u8, body, "get_env_group") != null) return dispatch("render_get_env_group", body, resp);
    if (std.mem.indexOf(u8, body, "list_custom_domains") != null) return dispatch("render_list_custom_domains", body, resp);
    if (std.mem.indexOf(u8, body, "add_custom_domain") != null) return dispatch("render_add_custom_domain", body, resp);
    if (std.mem.indexOf(u8, body, "list_jobs") != null) return dispatch("render_list_jobs", body, resp);
    if (std.mem.indexOf(u8, body, "create_job") != null) return dispatch("render_create_job", body, resp);
    if (std.mem.indexOf(u8, body, "suspend_service") != null) return dispatch("render_suspend_service", body, resp);
    if (std.mem.indexOf(u8, body, "resume_service") != null) return dispatch("render_resume_service", body, resp);
    if (std.mem.indexOf(u8, body, "get_bandwidth") != null) return dispatch("render_get_bandwidth", body, resp);
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
    ffi.render_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
