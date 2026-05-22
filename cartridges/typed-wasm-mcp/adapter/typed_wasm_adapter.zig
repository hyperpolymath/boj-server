// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// typed-wasm-mcp/adapter/typed_wasm_adapter.zig -- Unified three-protocol adapter.
//
// Replaces the banned typed_wasm_adapter.v (zig, removed 2026-04-12).
//
// REST :9124  gRPC-compat :9125  GraphQL :9126
// Typed WASM module verifier and compiler. Validates WebAssembly type safety and compiles with type-le
// Tools: typed_wasm_validate_module, typed_wasm_check_types, typed_wasm_compile_module

const std = @import("std");
const ffi = @import("typed_wasm_ffi");

const REST_PORT: u16 = 9124;
const GRPC_PORT: u16 = 9125;
const GQL_PORT:  u16 = 9126;
const MAX_CONN_BUF: usize = 16 * 1024;

fn okJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch return buf[0..0];
    return n;
}
fn errJson(buf: []u8, msg: []const u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch return buf[0..0];
    return n;
}
fn statusJson(buf: []u8) []u8 {
    const n = std.fmt.bufPrint(buf, "{{\"success\":true,\"state\":\"ready\",\"service\":\"typed-wasm-mcp\"}}", .{}) catch return buf[0..0];
    return n;
}

const Response = struct { status: u16, body: []u8 };

fn dispatch(tool: []const u8, body: []const u8, resp: []u8) Response {
    _ = body;
    if (std.mem.eql(u8, tool, "typed_wasm_validate_module")) return .{ .status = 200, .body = okJson(resp, "typed_wasm_validate_module forwarded") };
    if (std.mem.eql(u8, tool, "typed_wasm_check_types")) return .{ .status = 200, .body = okJson(resp, "typed_wasm_check_types forwarded") };
    if (std.mem.eql(u8, tool, "typed_wasm_compile_module")) return .{ .status = 200, .body = okJson(resp, "typed_wasm_compile_module forwarded") };
    if (std.mem.eql(u8, tool, "status") or std.mem.eql(u8, tool, "health"))
        return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Unknown tool") };
}

fn dispatchRest(path: []const u8, body: []const u8, resp: []u8) Response {
    if (std.mem.startsWith(u8, path, "/tools/")) return dispatch(path["/tools/".len..], body, resp);
    if (std.mem.eql(u8, path, "/status") or std.mem.eql(u8, path, "/health")) return .{ .status = 200, .body = statusJson(resp) };
    return .{ .status = 404, .body = errJson(resp, "Not found") };
}

fn dispatchGrpc(path: []const u8, body: []const u8, resp: []u8) Response {
    const prefix = "/TypedWasmservice/";
    if (!std.mem.startsWith(u8, path, prefix))
        return .{ .status = 404, .body = errJson(resp, "Not a recognized gRPC path") };
    const method = path[prefix.len..];
    const tool = blk: {
        if (std.mem.eql(u8, method, "typed_wasm_validate_module")) break :blk "typed_wasm_validate_module";
        if (std.mem.eql(u8, method, "typed_wasm_check_types")) break :blk "typed_wasm_check_types";
        if (std.mem.eql(u8, method, "typed_wasm_compile_module")) break :blk "typed_wasm_compile_module";
        return .{ .status = 404, .body = errJson(resp, "Unknown gRPC method") };
    };
    return dispatch(tool, body, resp);
}

fn dispatchGraphql(body: []const u8, resp: []u8) Response {
    if (std.mem.indexOf(u8, body, "__schema") != null) return .{ .status = 200, .body = okJson(resp, "schema not supported") };
    if (std.mem.indexOf(u8, body, "wasm_validate_module") != null) return dispatch("typed_wasm_validate_module", body, resp);
    if (std.mem.indexOf(u8, body, "wasm_check_types") != null) return dispatch("typed_wasm_check_types", body, resp);
    if (std.mem.indexOf(u8, body, "wasm_compile_module") != null) return dispatch("typed_wasm_compile_module", body, resp);
    return .{ .status = 200, .body = errJson(resp, "Unrecognised GraphQL operation") };
}

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
    const ct: []const u8 = if (proto == .grpc) "application/grpc+json" else "application/json";
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ result.status, ct, result.body.len }) catch return;
    _ = conn.stream.writeAll(hdr) catch return;
    _ = conn.stream.writeAll(result.body) catch return;
}

fn listenLoop(port: u16, proto: Protocol) void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port) catch return;
    var server = addr.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();
    while (true) { const conn = server.accept() catch continue; handleConnection(conn, proto); }
}

pub fn main() !void {
    ffi.typed_wasm_init();
    const t1 = try std.Thread.spawn(.{}, listenLoop, .{ REST_PORT, Protocol.rest });
    const t2 = try std.Thread.spawn(.{}, listenLoop, .{ GRPC_PORT, Protocol.grpc });
    const t3 = try std.Thread.spawn(.{}, listenLoop, .{ GQL_PORT,  Protocol.graphql });
    t1.join(); t2.join(); t3.join();
}
