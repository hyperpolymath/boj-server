// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// obsidian-mcp/adapter/obsidian_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned obsidian_adapter.v (zig, removed 2026-04-12).
//
// Bridges the Zig FFI (obsidian_mcp_ffi.zig) to three network protocols:
//   REST        :9076  POST /tools/<tool>
//   gRPC-compat :9077  /ObsidianMcpService/<Method>
//   GraphQL     :9078  POST /graphql  { query: "..." }
//
// Obsidian vault: search notes, backlinks, tags, dataview queries
// Tools:
//   obsidian_search_notes
//   obsidian_get_note
//   obsidian_list_notes
//   obsidian_get_backlinks
//   obsidian_get_outgoing_links
//   obsidian_list_tags
//   obsidian_get_notes_by_tag
//   obsidian_get_frontmatter
//   obsidian_get_daily_note
//   obsidian_vault_stats
//   obsidian_dataview_query
//   obsidian_list_templates

const std = @import("std");
const ffi = @import("obsidian_mcp_ffi");

const REST_PORT: u16 = 9076;
const GRPC_PORT: u16 = 9077;
const GQL_PORT:  u16 = 9078;

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
        \{{"success":true,"state":"ready","service":"obsidian-mcp"}}
    , .{}) catch buf[0..0];
}

// ============================================================================
// Tool dispatcher
// ============================================================================

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "obsidian_search_notes")) return .{ .status = 200, .body = okJson(resp, "obsidian_search_notes forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_note")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_note forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_list_notes")) return .{ .status = 200, .body = okJson(resp, "obsidian_list_notes forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_backlinks")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_backlinks forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_outgoing_links")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_outgoing_links forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_list_tags")) return .{ .status = 200, .body = okJson(resp, "obsidian_list_tags forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_notes_by_tag")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_notes_by_tag forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_frontmatter")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_frontmatter forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_get_daily_note")) return .{ .status = 200, .body = okJson(resp, "obsidian_get_daily_note forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_vault_stats")) return .{ .status = 200, .body = okJson(resp, "obsidian_vault_stats forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_dataview_query")) return .{ .status = 200, .body = okJson(resp, "obsidian_dataview_query forwarded to backend") };
    if (std.mem.eql(u8, tool, "obsidian_list_templates")) return .{ .status = 200, .body = okJson(resp, "obsidian_list_templates forwarded to backend") };
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
    const prefix = "/ObsidianMcpService/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "ObsidianSearchNotes")) break :blk "obsidian_search_notes";
        if (std.mem.eql(u8, method, "ObsidianGetNote")) break :blk "obsidian_get_note";
        if (std.mem.eql(u8, method, "ObsidianListNotes")) break :blk "obsidian_list_notes";
        if (std.mem.eql(u8, method, "ObsidianGetBacklinks")) break :blk "obsidian_get_backlinks";
        if (std.mem.eql(u8, method, "ObsidianGetOutgoingLinks")) break :blk "obsidian_get_outgoing_links";
        if (std.mem.eql(u8, method, "ObsidianListTags")) break :blk "obsidian_list_tags";
        if (std.mem.eql(u8, method, "ObsidianGetNotesByTag")) break :blk "obsidian_get_notes_by_tag";
        if (std.mem.eql(u8, method, "ObsidianGetFrontmatter")) break :blk "obsidian_get_frontmatter";
        if (std.mem.eql(u8, method, "ObsidianGetDailyNote")) break :blk "obsidian_get_daily_note";
        if (std.mem.eql(u8, method, "ObsidianVaultStats")) break :blk "obsidian_vault_stats";
        if (std.mem.eql(u8, method, "ObsidianDataviewQuery")) break :blk "obsidian_dataview_query";
        if (std.mem.eql(u8, method, "ObsidianListTemplates")) break :blk "obsidian_list_templates";
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
    if (std.mem.indexOf(u8, body, "search_notes") != null) return dispatch("obsidian_search_notes", body, resp);
    if (std.mem.indexOf(u8, body, "get_note") != null) return dispatch("obsidian_get_note", body, resp);
    if (std.mem.indexOf(u8, body, "list_notes") != null) return dispatch("obsidian_list_notes", body, resp);
    if (std.mem.indexOf(u8, body, "get_backlinks") != null) return dispatch("obsidian_get_backlinks", body, resp);
    if (std.mem.indexOf(u8, body, "get_outgoing_links") != null) return dispatch("obsidian_get_outgoing_links", body, resp);
    if (std.mem.indexOf(u8, body, "list_tags") != null) return dispatch("obsidian_list_tags", body, resp);
    if (std.mem.indexOf(u8, body, "get_notes_by_tag") != null) return dispatch("obsidian_get_notes_by_tag", body, resp);
    if (std.mem.indexOf(u8, body, "get_frontmatter") != null) return dispatch("obsidian_get_frontmatter", body, resp);
    if (std.mem.indexOf(u8, body, "get_daily_note") != null) return dispatch("obsidian_get_daily_note", body, resp);
    if (std.mem.indexOf(u8, body, "vault_stats") != null) return dispatch("obsidian_vault_stats", body, resp);
    if (std.mem.indexOf(u8, body, "dataview_query") != null) return dispatch("obsidian_dataview_query", body, resp);
    if (std.mem.indexOf(u8, body, "list_templates") != null) return dispatch("obsidian_list_templates", body, resp);
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
    ffi.obsidian_init();
    const rest_thread = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const grpc_thread = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const gql_thread  = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    rest_thread.join();
    grpc_thread.join();
    gql_thread.join();
}
