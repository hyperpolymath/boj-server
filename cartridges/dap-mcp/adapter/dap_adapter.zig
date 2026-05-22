// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// DAP-MCP Cartridge — Unified Zig adapter.
// Replaces the banned dap_adapter.v (zig removed 2026-04-10).
//
// Exposes the DAP session state machine from dap_ffi.zig via three protocols:
//   REST        port 9019  HTTP/1.1, JSON responses
//   gRPC-compat port 9020  HTTP/1.1 + proto-style paths, JSON bodies
//   GraphQL     port 9021  HTTP/1.1 POST /graphql, keyword dispatch
//
// Build: zig build  (build.zig in this directory)

const std = @import("std");
const ffi = @import("dap_ffi");

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

const VERSION  = "0.1.0";
const CARTRIDGE = "dap-mcp";
const REST_PORT: u16 = 9019;
const GRPC_PORT: u16 = 9020;
const GQL_PORT:  u16 = 9021;

const STATE_LABELS = [_][]const u8{
    "not_started", "launched", "configured", "running",
    "stopped", "terminated", "disconnected",
};

const BREAKPOINT_KIND_LABELS = [_][]const u8{
    "", "source", "function", "data", "instruction", "exception",
};

const STOP_REASON_LABELS = [_][]const u8{
    "", "breakpoint", "step", "exception", "pause", "entry", "goto_target",
};

const GRPC_PROTO =
    \\syntax = "proto3";
    \\package dap_mcp;
    \\
    \\service DapService {
    \\  rpc CreateSession      (Empty)               returns (SessionResponse);
    \\  rpc Launch             (SlotRequest)         returns (SessionResponse);
    \\  rpc Configure          (SlotRequest)         returns (SessionResponse);
    \\  rpc Continue           (SlotRequest)         returns (SessionResponse);
    \\  rpc Stopped            (StopRequest)         returns (SessionResponse);
    \\  rpc Terminate          (SlotRequest)         returns (SessionResponse);
    \\  rpc Disconnect         (SlotRequest)         returns (SessionResponse);
    \\  rpc AddBreakpoint      (BreakpointRequest)   returns (SessionResponse);
    \\  rpc GetState           (SlotRequest)         returns (SessionResponse);
    \\  rpc ReleaseSession     (SlotRequest)         returns (ReleaseResponse);
    \\  rpc Health             (Empty)               returns (HealthResponse);
    \\  rpc Types              (Empty)               returns (TypeInfoResponse);
    \\}
    \\
    \\message Empty              {}
    \\message SlotRequest        { int32 slot = 1; }
    \\message StopRequest        { int32 slot = 1; int32 reason = 2; }
    \\message BreakpointRequest  { int32 slot = 1; int32 kind = 2; }
    \\message SessionResponse    { int32 slot = 1; string state = 2; bool can_inspect = 3; }
    \\message ReleaseResponse    { int32 slot = 1; bool released = 2; }
    \\message HealthResponse     { string status = 1; string cartridge = 2; string version = 3; }
    \\message TypeInfoResponse   { repeated string states = 1; repeated string breakpoint_kinds = 2; repeated string stop_reasons = 3; }
;

const GRAPHQL_SCHEMA =
    \\type Query {
    \\  health: Health!
    \\  session(slot: Int!): Session
    \\  types: TypeInfo!
    \\}
    \\type Mutation {
    \\  createSession: Session!
    \\  launch(slot: Int!): Session!
    \\  configure(slot: Int!): Session!
    \\  continue(slot: Int!): Session!
    \\  stopped(slot: Int!, reason: Int!): Session!
    \\  terminate(slot: Int!): Session!
    \\  disconnect(slot: Int!): Session!
    \\  addBreakpoint(slot: Int!, kind: Int!): Session!
    \\  releaseSession(slot: Int!): ReleaseResult!
    \\}
    \\type Health       { status: String!  cartridge: String!  version: String! }
    \\type Session      { slot: Int!  state: String!  canInspect: Boolean! }
    \\type ReleaseResult { slot: Int!  released: Boolean! }
    \\type TypeInfo     { states: [String!]!  breakpointKinds: [String!]!  stopReasons: [String!]! }
;

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════════

fn stateLabel(s: c_int) []const u8 {
    if (s >= 0 and s < @as(c_int, STATE_LABELS.len)) return STATE_LABELS[@intCast(s)];
    return "unknown";
}

fn sessionJson(slot: c_int, buf: []u8) []const u8 {
    const state = ffi.dap_state(slot);
    const can_inspect = ffi.dap_can_inspect(slot);
    return std.fmt.bufPrint(buf,
        \\{{"slot":{d},"state":"{s}","can_inspect":{s}}}
    , .{ slot, stateLabel(state), if (can_inspect == 1) "true" else "false" }) catch buf[0..0];
}

fn errorJson(buf: []u8, msg: []const u8, code: c_int) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"error":"{s}","code":{d}}}
    , .{ msg, code }) catch buf[0..0];
}

fn healthJson(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"status":"ok","cartridge":"{s}","version":"{s}"}}
    , .{ CARTRIDGE, VERSION }) catch buf[0..0];
}

const TYPES_JSON =
    \\{"states":["not_started","launched","configured","running","stopped","terminated","disconnected"],
    \\"breakpoint_kinds":["source","function","data","instruction","exception"],
    \\"stop_reasons":["breakpoint","step","exception","pause","entry","goto_target"]}
;

// ═══════════════════════════════════════════════════════════════════════════
// JSON body parsers
// ═══════════════════════════════════════════════════════════════════════════

fn parseIntField(body: []const u8, field: []const u8) ?c_int {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const rest = std.mem.trimLeft(u8, body[idx + needle.len ..], " \t\r\n");
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return @intCast(std.fmt.parseInt(i32, rest[0..end], 10) catch return null);
}

fn pathSlot(target: []const u8) ?c_int {
    var it = std.mem.splitBackwardsScalar(u8, target, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        var all_digits = true;
        for (seg) |c| { if (c < '0' or c > '9') { all_digits = false; break; } }
        if (all_digits) return @intCast(std.fmt.parseInt(i32, seg, 10) catch return null);
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Response type
// ═══════════════════════════════════════════════════════════════════════════

const Response = struct {
    status: std.http.Status,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

// ═══════════════════════════════════════════════════════════════════════════
// REST dispatch
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchRest(method: std.http.Method, target: []const u8, body: []const u8, resp: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    if (method == .GET  and std.mem.eql(u8, target, "/health")) return .{ .status = ok, .body = healthJson(resp) };
    if (method == .GET  and std.mem.eql(u8, target, "/types"))  return .{ .status = ok, .body = TYPES_JSON };
    if (method == .POST and std.mem.eql(u8, target, "/sessions")) {
        const slot = ffi.dap_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }

    if (std.mem.startsWith(u8, target, "/sessions/")) {
        const slot_opt = pathSlot(std.mem.trimRight(u8, target, "/"));

        if (method == .GET  and std.mem.endsWith(u8, target, "/state")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/launch")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_launch(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/configure")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_configure(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/continue")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_continue(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/stop")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const reason = parseIntField(body, "reason") orelse 2; // default: step
            const r = ffi.dap_stopped(slot, reason);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/terminate")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_terminate(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/disconnect")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_disconnect(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/breakpoint")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const kind = parseIntField(body, "kind") orelse 1; // default: source
            const r = ffi.dap_add_breakpoint(slot, kind);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot set breakpoint (wrong state or limit reached)", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .DELETE) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.dap_release(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
            return .{
                .status = ok,
                .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0],
            };
        }
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "not found", -404) };
}

// ═══════════════════════════════════════════════════════════════════════════
// gRPC-compat dispatch
// ═══════════════════════════════════════════════════════════════════════════

const GRPC_PREFIX = "/dap_mcp.DapService/";

fn dispatchGrpc(target: []const u8, body: []const u8, resp: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    if (std.mem.eql(u8, target, "/proto")) return .{ .status = ok, .body = GRPC_PROTO, .content_type = "text/plain" };
    if (!std.mem.startsWith(u8, target, GRPC_PREFIX)) return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC path", -1) };

    const rpc = target[GRPC_PREFIX.len..];

    if (std.mem.eql(u8, rpc, "Health")) return .{ .status = ok, .body = healthJson(resp) };
    if (std.mem.eql(u8, rpc, "Types"))  return .{ .status = ok, .body = TYPES_JSON };
    if (std.mem.eql(u8, rpc, "CreateSession")) {
        const slot = ffi.dap_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }

    const slot = parseIntField(body, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };

    if (std.mem.eql(u8, rpc, "GetState"))   return .{ .status = ok, .body = sessionJson(slot, resp) };
    if (std.mem.eql(u8, rpc, "Launch"))     { const r = ffi.dap_launch(slot);    if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp) }; }
    if (std.mem.eql(u8, rpc, "Configure"))  { const r = ffi.dap_configure(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp) }; }
    if (std.mem.eql(u8, rpc, "Continue"))   { const r = ffi.dap_continue(slot);  if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp) }; }
    if (std.mem.eql(u8, rpc, "Terminate"))  { const r = ffi.dap_terminate(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp) }; }
    if (std.mem.eql(u8, rpc, "Disconnect")) { const r = ffi.dap_disconnect(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp) }; }
    if (std.mem.eql(u8, rpc, "Stopped")) {
        const reason = parseIntField(body, "reason") orelse 2;
        const r = ffi.dap_stopped(slot, reason);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }
    if (std.mem.eql(u8, rpc, "AddBreakpoint")) {
        const kind = parseIntField(body, "kind") orelse 1;
        const r = ffi.dap_add_breakpoint(slot, kind);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot set breakpoint", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }
    if (std.mem.eql(u8, rpc, "ReleaseSession")) {
        const r = ffi.dap_release(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0] };
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC method", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// GraphQL dispatch (keyword-based, same pattern as lsp_adapter.zig)
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchGraphql(q: []const u8, resp: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;
    const has = std.mem.indexOf;

    if (has(u8, q, "__schema") != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"__schema":{{"sdl":"{s}"}}}}}}, .{GRAPHQL_SCHEMA}) catch resp[0..0] };
    if (has(u8, q, "health") != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"health":{s}}}}}, .{healthJson(resp)}) catch resp[0..0] };
    if (has(u8, q, "types")  != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"types":{s}}}}}, .{TYPES_JSON}) catch resp[0..0] };
    if (has(u8, q, "createSession") != null) {
        const slot = ffi.dap_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"createSession":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] };
    }

    const slot = parseIntField(q, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "could not determine slot", -1) };

    if (has(u8, q, "addBreakpoint") != null) { const kind = parseIntField(q, "kind") orelse 1; const r = ffi.dap_add_breakpoint(slot, kind); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot set breakpoint", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"addBreakpoint":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "stopped")    != null) { const reason = parseIntField(q, "reason") orelse 2; const r = ffi.dap_stopped(slot, reason); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"stopped":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "configure")  != null) { const r = ffi.dap_configure(slot);  if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"configure":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "launch")     != null) { const r = ffi.dap_launch(slot);     if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"launch":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "terminate")  != null) { const r = ffi.dap_terminate(slot);  if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"terminate":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "disconnect") != null) { const r = ffi.dap_disconnect(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"disconnect":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "continue")   != null) { const r = ffi.dap_continue(slot);   if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"continue":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] }; }
    if (has(u8, q, "releaseSession") != null) { const r = ffi.dap_release(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"releaseSession":{{"slot":{d},"released":true}}}}}}, .{slot}) catch resp[0..0] }; }
    if (has(u8, q, "session")    != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"session":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] };

    return .{ .status = bad, .body = errorJson(resp, "unrecognised GraphQL operation", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP connection handler + listener loop (shared pattern with lsp_adapter)
// ═══════════════════════════════════════════════════════════════════════════

const Protocol = enum { rest, grpc, graphql };
const ListenerCtx = struct { listener: *std.net.Server, protocol: Protocol };

fn handleConnection(conn: std.net.Server.Connection, protocol: Protocol) void {
    defer conn.stream.close();
    var read_buf: [8192]u8 = undefined;
    var http_srv = std.http.Server.init(conn, &read_buf);
    var request = http_srv.receiveHead() catch return;

    var body_buf: [262144]u8 = undefined;
    var body_len: usize = 0;
    if (request.head.content_length) |cl| {
        const to_read: usize = @min(cl, body_buf.len);
        var reader = request.reader() catch return;
        body_len = reader.readAll(body_buf[0..to_read]) catch 0;
    }

    var resp_buf: [4096]u8 = undefined;
    const body = body_buf[0..body_len];

    const resp: Response = switch (protocol) {
        .rest    => dispatchRest(request.head.method, request.head.target, body, &resp_buf),
        .grpc    => dispatchGrpc(request.head.target, body, &resp_buf),
        .graphql => blk: {
            if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/graphql/schema"))
                break :blk .{ .status = .ok, .body = GRAPHQL_SCHEMA, .content_type = "text/plain" };
            break :blk dispatchGraphql(body, &resp_buf);
        },
    };

    const ct_header: std.http.Header = .{ .name = "content-type", .value = resp.content_type };
    const cors_header: std.http.Header = .{ .name = "access-control-allow-origin", .value = "*" };
    const grpc_status: std.http.Header = .{ .name = "grpc-status", .value = if (resp.status == .ok) "0" else "2" };

    if (protocol == .grpc) {
        request.respond(resp.body, .{ .status = resp.status, .extra_headers = &.{ ct_header, grpc_status } }) catch {};
    } else {
        request.respond(resp.body, .{ .status = resp.status, .extra_headers = &.{ ct_header, cors_header } }) catch {};
    }
}

fn listenLoop(ctx: ListenerCtx) void {
    while (true) {
        const conn = ctx.listener.accept() catch |err| {
            std.log.err("accept error on {s} listener: {}", .{ @tagName(ctx.protocol), err });
            continue;
        };
        handleConnection(conn, ctx.protocol);
    }
}

pub fn main() !void {
    _ = ffi.boj_cartridge_init();

    var rest_listener = try (try std.net.Address.parseIp4("0.0.0.0", REST_PORT)).listen(.{ .reuse_address = true });
    defer rest_listener.deinit();
    var grpc_listener = try (try std.net.Address.parseIp4("0.0.0.0", GRPC_PORT)).listen(.{ .reuse_address = true });
    defer grpc_listener.deinit();
    var gql_listener  = try (try std.net.Address.parseIp4("0.0.0.0", GQL_PORT)).listen(.{ .reuse_address = true });
    defer gql_listener.deinit();

    std.log.info("{s} REST :{d}  gRPC :{d}  GraphQL :{d}", .{ CARTRIDGE, REST_PORT, GRPC_PORT, GQL_PORT });

    const t_rest = try std.Thread.spawn(.{}, listenLoop, .{ ListenerCtx{ .listener = &rest_listener, .protocol = .rest } });
    const t_grpc = try std.Thread.spawn(.{}, listenLoop, .{ ListenerCtx{ .listener = &grpc_listener, .protocol = .grpc } });
    const t_gql  = try std.Thread.spawn(.{}, listenLoop, .{ ListenerCtx{ .listener = &gql_listener,  .protocol = .graphql } });

    t_rest.join();
    t_grpc.join();
    t_gql.join();
}
