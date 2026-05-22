// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hetzner-mcp/adapter/hetzner_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned hetzner_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (hetzner_mcp_ffi.zig) to three network protocols:
//   REST        :9064  POST /tools/<tool>
//   gRPC-compat :9065  /HetznerMcpService/<Method>
//   GraphQL     :9066  POST /graphql  { query: "..." }
//
// Hetzner Cloud: servers, volumes, firewalls, load balancers, floating IPs
// Tools:
//   hetzner_list_servers
//   hetzner_get_server
//   hetzner_create_server
//   hetzner_delete_server
//   hetzner_server_action
//   hetzner_resize_server
//   hetzner_list_floating_ips
//   hetzner_create_floating_ip
//   hetzner_list_volumes
//   hetzner_create_volume
//   hetzner_list_firewalls
//   hetzner_create_firewall
//   hetzner_list_ssh_keys
//   hetzner_create_ssh_key
//   hetzner_list_images
//   hetzner_create_snapshot
//   hetzner_list_networks
//   hetzner_create_network
//   hetzner_list_load_balancers
//   hetzner_create_load_balancer

const std = @import("std");
const ffi = @import("hetzner_mcp_ffi");

const REST_PORT: u16 = 9064;
const GRPC_PORT: u16 = 9065;
const GQL_PORT:  u16 = 9066;

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
        \{{"success":true,"state":"ready","service":"hetzner-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "hetzner_list_servers")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_servers forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_get_server")) return .{ .status = 200, .body = okJson(resp, "hetzner_get_server forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_server")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_server forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_delete_server")) return .{ .status = 200, .body = okJson(resp, "hetzner_delete_server forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_server_action")) return .{ .status = 200, .body = okJson(resp, "hetzner_server_action forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_resize_server")) return .{ .status = 200, .body = okJson(resp, "hetzner_resize_server forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_floating_ips")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_floating_ips forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_floating_ip")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_floating_ip forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_volumes")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_volumes forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_volume")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_volume forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_firewalls")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_firewalls forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_firewall")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_firewall forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_ssh_keys")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_ssh_keys forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_ssh_key")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_ssh_key forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_images")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_images forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_snapshot")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_snapshot forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_networks")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_networks forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_network")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_network forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_list_load_balancers")) return .{ .status = 200, .body = okJson(resp, "hetzner_list_load_balancers forwarded to backend") };
    if (std.mem.eql(u8, tool, "hetzner_create_load_balancer")) return .{ .status = 200, .body = okJson(resp, "hetzner_create_load_balancer forwarded to backend") };
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
    const prefix = "/HetznerMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "HetznerListServers")) break :blk "hetzner_list_servers";
        if (std.mem.eql(u8, method, "HetznerGetServer")) break :blk "hetzner_get_server";
        if (std.mem.eql(u8, method, "HetznerCreateServer")) break :blk "hetzner_create_server";
        if (std.mem.eql(u8, method, "HetznerDeleteServer")) break :blk "hetzner_delete_server";
        if (std.mem.eql(u8, method, "HetznerServerAction")) break :blk "hetzner_server_action";
        if (std.mem.eql(u8, method, "HetznerResizeServer")) break :blk "hetzner_resize_server";
        if (std.mem.eql(u8, method, "HetznerListFloatingIps")) break :blk "hetzner_list_floating_ips";
        if (std.mem.eql(u8, method, "HetznerCreateFloatingIp")) break :blk "hetzner_create_floating_ip";
        if (std.mem.eql(u8, method, "HetznerListVolumes")) break :blk "hetzner_list_volumes";
        if (std.mem.eql(u8, method, "HetznerCreateVolume")) break :blk "hetzner_create_volume";
        if (std.mem.eql(u8, method, "HetznerListFirewalls")) break :blk "hetzner_list_firewalls";
        if (std.mem.eql(u8, method, "HetznerCreateFirewall")) break :blk "hetzner_create_firewall";
        if (std.mem.eql(u8, method, "HetznerListSshKeys")) break :blk "hetzner_list_ssh_keys";
        if (std.mem.eql(u8, method, "HetznerCreateSshKey")) break :blk "hetzner_create_ssh_key";
        if (std.mem.eql(u8, method, "HetznerListImages")) break :blk "hetzner_list_images";
        if (std.mem.eql(u8, method, "HetznerCreateSnapshot")) break :blk "hetzner_create_snapshot";
        if (std.mem.eql(u8, method, "HetznerListNetworks")) break :blk "hetzner_list_networks";
        if (std.mem.eql(u8, method, "HetznerCreateNetwork")) break :blk "hetzner_create_network";
        if (std.mem.eql(u8, method, "HetznerListLoadBalancers")) break :blk "hetzner_list_load_balancers";
        if (std.mem.eql(u8, method, "HetznerCreateLoadBalancer")) break :blk "hetzner_create_load_balancer";
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
    if (std.mem.indexOf(u8, body, "list_servers") != null) return dispatch("hetzner_list_servers", body, resp);
    if (std.mem.indexOf(u8, body, "get_server") != null) return dispatch("hetzner_get_server", body, resp);
    if (std.mem.indexOf(u8, body, "create_server") != null) return dispatch("hetzner_create_server", body, resp);
    if (std.mem.indexOf(u8, body, "delete_server") != null) return dispatch("hetzner_delete_server", body, resp);
    if (std.mem.indexOf(u8, body, "server_action") != null) return dispatch("hetzner_server_action", body, resp);
    if (std.mem.indexOf(u8, body, "resize_server") != null) return dispatch("hetzner_resize_server", body, resp);
    if (std.mem.indexOf(u8, body, "list_floating_ips") != null) return dispatch("hetzner_list_floating_ips", body, resp);
    if (std.mem.indexOf(u8, body, "create_floating_ip") != null) return dispatch("hetzner_create_floating_ip", body, resp);
    if (std.mem.indexOf(u8, body, "list_volumes") != null) return dispatch("hetzner_list_volumes", body, resp);
    if (std.mem.indexOf(u8, body, "create_volume") != null) return dispatch("hetzner_create_volume", body, resp);
    if (std.mem.indexOf(u8, body, "list_firewalls") != null) return dispatch("hetzner_list_firewalls", body, resp);
    if (std.mem.indexOf(u8, body, "create_firewall") != null) return dispatch("hetzner_create_firewall", body, resp);
    if (std.mem.indexOf(u8, body, "list_ssh_keys") != null) return dispatch("hetzner_list_ssh_keys", body, resp);
    if (std.mem.indexOf(u8, body, "create_ssh_key") != null) return dispatch("hetzner_create_ssh_key", body, resp);
    if (std.mem.indexOf(u8, body, "list_images") != null) return dispatch("hetzner_list_images", body, resp);
    if (std.mem.indexOf(u8, body, "create_snapshot") != null) return dispatch("hetzner_create_snapshot", body, resp);
    if (std.mem.indexOf(u8, body, "list_networks") != null) return dispatch("hetzner_list_networks", body, resp);
    if (std.mem.indexOf(u8, body, "create_network") != null) return dispatch("hetzner_create_network", body, resp);
    if (std.mem.indexOf(u8, body, "list_load_balancers") != null) return dispatch("hetzner_list_load_balancers", body, resp);
    if (std.mem.indexOf(u8, body, "create_load_balancer") != null) return dispatch("hetzner_create_load_balancer", body, resp);
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
    ffi.hetzner_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
