// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BSP-MCP Cartridge — Unified Zig adapter.
// Replaces the banned bsp_adapter.v (zig removed 2026-04-10).
//
// Exposes the BSP session state machine from bsp_ffi.zig via three protocols:
//   REST        port 9025  HTTP/1.1, JSON responses
//   gRPC-compat port 9026  HTTP/1.1 + proto-style paths, JSON bodies
//   GraphQL     port 9027  HTTP/1.1 POST /graphql, keyword dispatch
//
// Build: zig build  (build.zig in this directory)

const std = @import("std");
const ffi = @import("bsp_ffi");

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

const VERSION   = "0.1.0";
const CARTRIDGE = "bsp-mcp";
const REST_PORT: u16 = 9025;
const GRPC_PORT: u16 = 9026;
const GQL_PORT:  u16 = 9027;

const STATE_LABELS = [_][]const u8{
    "uninitialized", "initializing", "ready", "building", "shutting_down", "exited",
};

/// Capability labels, 1-indexed (slot 0 unused).
const CAP_LABELS = [_][]const u8{
    "",
    "compile", "test", "run", "debug", "clean_cache",
    "dependency_sources", "resources", "output_paths", "jvm_test_env",
};

const TARGET_KIND_LABELS = [_][]const u8{
    "",
    "library", "application", "test_target", "benchmark",
    "integration_test", "documentation",
};

const GRPC_PROTO =
    \\syntax = "proto3";
    \\package bsp_mcp;
    \\
    \\service BspService {
    \\  rpc CreateSession      (Empty)               returns (SessionResponse);
    \\  rpc Initialize         (SlotRequest)         returns (SessionResponse);
    \\  rpc RegisterCapability (CapabilityRequest)   returns (SessionResponse);
    \\  rpc Ready              (SlotRequest)         returns (SessionResponse);
    \\  rpc Build              (SlotRequest)         returns (SessionResponse);
    \\  rpc BuildDone          (SlotRequest)         returns (SessionResponse);
    \\  rpc AddTarget          (TargetRequest)       returns (SessionResponse);
    \\  rpc Shutdown           (SlotRequest)         returns (SessionResponse);
    \\  rpc Exit               (SlotRequest)         returns (SessionResponse);
    \\  rpc GetState           (SlotRequest)         returns (SessionResponse);
    \\  rpc ReleaseSession     (SlotRequest)         returns (ReleaseResponse);
    \\  rpc Health             (Empty)               returns (HealthResponse);
    \\  rpc Types              (Empty)               returns (TypeInfoResponse);
    \\}
    \\
    \\message Empty              {}
    \\message SlotRequest        { int32 slot = 1; }
    \\message CapabilityRequest  { int32 slot = 1; int32 capability = 2; }
    \\message TargetRequest      { int32 slot = 1; int32 kind = 2; }
    \\message SessionResponse    { int32 slot = 1; string state = 2; bool can_build = 3; bool is_building = 4; repeated string capabilities = 5; }
    \\message ReleaseResponse    { int32 slot = 1; bool released = 2; }
    \\message HealthResponse     { string status = 1; string cartridge = 2; string version = 3; }
    \\message TypeInfoResponse   { repeated string states = 1; repeated string capabilities = 2; repeated string target_kinds = 3; }
;

const GRAPHQL_SCHEMA =
    \\type Query {
    \\  health: Health!
    \\  session(slot: Int!): Session
    \\  types: TypeInfo!
    \\}
    \\type Mutation {
    \\  createSession: Session!
    \\  initialize(slot: Int!): Session!
    \\  registerCapability(slot: Int!, capability: Int!): Session!
    \\  ready(slot: Int!): Session!
    \\  build(slot: Int!): Session!
    \\  buildDone(slot: Int!): Session!
    \\  addTarget(slot: Int!, kind: Int!): Session!
    \\  shutdown(slot: Int!): Session!
    \\  exit(slot: Int!): Session!
    \\  releaseSession(slot: Int!): ReleaseResult!
    \\}
    \\type Health        { status: String!  cartridge: String!  version: String! }
    \\type Session       { slot: Int!  state: String!  canBuild: Boolean!  isBuilding: Boolean!  capabilities: [String!]! }
    \\type ReleaseResult { slot: Int!  released: Boolean! }
    \\type TypeInfo      { states: [String!]!  capabilities: [String!]!  targetKinds: [String!]! }
;

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════════

fn stateLabel(s: c_int) []const u8 {
    if (s >= 0 and s < @as(c_int, STATE_LABELS.len)) return STATE_LABELS[@intCast(s)];
    return "unknown";
}

fn capabilitiesJson(slot: c_int, buf: []u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '['; pos += 1;
    var first = true;
    var cap: c_int = 1;
    while (cap <= 9) : (cap += 1) {
        if (ffi.bsp_has_capability(slot, cap) == 1) {
            if (!first) { buf[pos] = ','; pos += 1; }
            buf[pos] = '"'; pos += 1;
            const label = CAP_LABELS[@intCast(cap)];
            @memcpy(buf[pos..][0..label.len], label);
            pos += label.len;
            buf[pos] = '"'; pos += 1;
            first = false;
        }
    }
    buf[pos] = ']'; pos += 1;
    return buf[0..pos];
}

fn sessionJson(slot: c_int, resp: []u8, cap: []u8) []const u8 {
    const state = ffi.bsp_state(slot);
    const can_build   = ffi.bsp_can_build(slot);
    const is_building = ffi.bsp_is_building(slot);
    const caps = capabilitiesJson(slot, cap);
    return std.fmt.bufPrint(resp,
        \\{{"slot":{d},"state":"{s}","can_build":{s},"is_building":{s},"capabilities":{s}}}
    , .{
        slot,
        stateLabel(state),
        if (can_build == 1) "true" else "false",
        if (is_building == 1) "true" else "false",
        caps,
    }) catch resp[0..0];
}

fn errorJson(buf: []u8, msg: []const u8, code: c_int) []const u8 {
    return std.fmt.bufPrint(buf, \\{{"error":"{s}","code":{d}}}, .{ msg, code }) catch buf[0..0];
}

fn healthJson(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, \\{{"status":"ok","cartridge":"{s}","version":"{s}"}}, .{ CARTRIDGE, VERSION }) catch buf[0..0];
}

const TYPES_JSON =
    \\{"states":["uninitialized","initializing","ready","building","shutting_down","exited"],
    \\"capabilities":["compile","test","run","debug","clean_cache","dependency_sources","resources","output_paths","jvm_test_env"],
    \\"target_kinds":["library","application","test_target","benchmark","integration_test","documentation"]}
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

fn dispatchRest(method: std.http.Method, target: []const u8, body: []const u8, resp: []u8, cap: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    if (method == .GET  and std.mem.eql(u8, target, "/health")) return .{ .status = ok, .body = healthJson(resp) };
    if (method == .GET  and std.mem.eql(u8, target, "/types"))  return .{ .status = ok, .body = TYPES_JSON };
    if (method == .POST and std.mem.eql(u8, target, "/sessions")) {
        const slot = ffi.bsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }

    if (std.mem.startsWith(u8, target, "/sessions/")) {
        const slot_opt = pathSlot(std.mem.trimRight(u8, target, "/"));

        inline for (.{
            .{ "/state",       .GET,  null },
        }) |entry| {
            _ = entry;
        }

        if (method == .GET  and std.mem.endsWith(u8, target, "/state"))      { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/initialize")) { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_start_init(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/ready"))      { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_ready(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/build"))      { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_build(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/build-done")) { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_build_done(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/shutdown"))   { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_shutdown(slot);   if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
        if (method == .POST and std.mem.endsWith(u8, target, "/exit"))       { const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) }; const r = ffi.bsp_exit(slot);       if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }

        if (method == .POST and std.mem.endsWith(u8, target, "/capability")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const c = parseIntField(body, "capability") orelse return .{ .status = bad, .body = errorJson(resp, "missing capability", -1) };
            const r = ffi.bsp_register_capability(slot, c);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/target")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const kind = parseIntField(body, "kind") orelse return .{ .status = bad, .body = errorJson(resp, "missing kind", -1) };
            const r = ffi.bsp_add_target(slot, kind);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot add target (wrong state or limit reached)", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        if (method == .DELETE) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.bsp_release(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
            return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0] };
        }
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "not found", -404) };
}

// ═══════════════════════════════════════════════════════════════════════════
// gRPC-compat dispatch
// ═══════════════════════════════════════════════════════════════════════════

const GRPC_PREFIX = "/bsp_mcp.BspService/";

fn dispatchGrpc(target: []const u8, body: []const u8, resp: []u8, cap: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    if (std.mem.eql(u8, target, "/proto")) return .{ .status = ok, .body = GRPC_PROTO, .content_type = "text/plain" };
    if (!std.mem.startsWith(u8, target, GRPC_PREFIX)) return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC path", -1) };

    const rpc = target[GRPC_PREFIX.len..];

    if (std.mem.eql(u8, rpc, "Health")) return .{ .status = ok, .body = healthJson(resp) };
    if (std.mem.eql(u8, rpc, "Types"))  return .{ .status = ok, .body = TYPES_JSON };
    if (std.mem.eql(u8, rpc, "CreateSession")) {
        const slot = ffi.bsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }

    const slot = parseIntField(body, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };

    if (std.mem.eql(u8, rpc, "GetState"))  return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    if (std.mem.eql(u8, rpc, "Initialize")) { const r = ffi.bsp_start_init(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
    if (std.mem.eql(u8, rpc, "Ready"))      { const r = ffi.bsp_ready(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
    if (std.mem.eql(u8, rpc, "Build"))      { const r = ffi.bsp_build(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
    if (std.mem.eql(u8, rpc, "BuildDone")) { const r = ffi.bsp_build_done(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
    if (std.mem.eql(u8, rpc, "Shutdown"))  { const r = ffi.bsp_shutdown(slot);   if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }
    if (std.mem.eql(u8, rpc, "Exit"))      { const r = ffi.bsp_exit(slot);       if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = sessionJson(slot, resp, cap) }; }

    if (std.mem.eql(u8, rpc, "RegisterCapability")) {
        const c = parseIntField(body, "capability") orelse return .{ .status = bad, .body = errorJson(resp, "missing capability", -1) };
        const r = ffi.bsp_register_capability(slot, c);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "AddTarget")) {
        const kind = parseIntField(body, "kind") orelse return .{ .status = bad, .body = errorJson(resp, "missing kind", -1) };
        const r = ffi.bsp_add_target(slot, kind);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot add target", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "ReleaseSession")) {
        const r = ffi.bsp_release(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0] };
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC method", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// GraphQL dispatch
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchGraphql(q: []const u8, resp: []u8, cap: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;
    const has = std.mem.indexOf;

    if (has(u8, q, "__schema") != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"__schema":{{"sdl":"{s}"}}}}}}, .{GRAPHQL_SCHEMA}) catch resp[0..0] };
    if (has(u8, q, "health") != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"health":{s}}}}}, .{healthJson(resp)}) catch resp[0..0] };
    if (has(u8, q, "types")  != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"types":{s}}}}}, .{TYPES_JSON}) catch resp[0..0] };
    if (has(u8, q, "createSession") != null) {
        const slot = ffi.bsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"createSession":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] };
    }

    const slot = parseIntField(q, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "could not determine slot", -1) };

    if (has(u8, q, "registerCapability") != null) { const c = parseIntField(q, "capability") orelse return .{ .status = bad, .body = errorJson(resp, "missing capability", -1) }; const r = ffi.bsp_register_capability(slot, c); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"registerCapability":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "addTarget")   != null) { const kind = parseIntField(q, "kind") orelse return .{ .status = bad, .body = errorJson(resp, "missing kind", -1) }; const r = ffi.bsp_add_target(slot, kind); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "cannot add target", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"addTarget":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "initialize")  != null) { const r = ffi.bsp_start_init(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"initialize":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "buildDone")   != null) { const r = ffi.bsp_build_done(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"buildDone":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "shutdown")    != null) { const r = ffi.bsp_shutdown(slot);   if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"shutdown":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "exit")        != null) { const r = ffi.bsp_exit(slot);       if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"exit":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "ready")       != null) { const r = ffi.bsp_ready(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"ready":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "build")       != null) { const r = ffi.bsp_build(slot);      if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"build":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] }; }
    if (has(u8, q, "releaseSession") != null) { const r = ffi.bsp_release(slot); if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) }; return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"releaseSession":{{"slot":{d},"released":true}}}}}}, .{slot}) catch resp[0..0] }; }
    if (has(u8, q, "session")     != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"session":{s}}}}}, .{sessionJson(slot, resp, cap)}) catch resp[0..0] };

    return .{ .status = bad, .body = errorJson(resp, "unrecognised GraphQL operation", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP connection handler + listener loop
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
    var cap_buf:  [512]u8  = undefined;
    const body = body_buf[0..body_len];

    const resp: Response = switch (protocol) {
        .rest    => dispatchRest(request.head.method, request.head.target, body, &resp_buf, &cap_buf),
        .grpc    => dispatchGrpc(request.head.target, body, &resp_buf, &cap_buf),
        .graphql => blk: {
            if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/graphql/schema"))
                break :blk .{ .status = .ok, .body = GRAPHQL_SCHEMA, .content_type = "text/plain" };
            break :blk dispatchGraphql(body, &resp_buf, &cap_buf);
        },
    };

    const ct: std.http.Header = .{ .name = "content-type", .value = resp.content_type };
    const cors: std.http.Header = .{ .name = "access-control-allow-origin", .value = "*" };
    const gs: std.http.Header   = .{ .name = "grpc-status", .value = if (resp.status == .ok) "0" else "2" };

    if (protocol == .grpc) {
        request.respond(resp.body, .{ .status = resp.status, .extra_headers = &.{ ct, gs } }) catch {};
    } else {
        request.respond(resp.body, .{ .status = resp.status, .extra_headers = &.{ ct, cors } }) catch {};
    }
}

fn listenLoop(ctx: ListenerCtx) void {
    while (true) {
        const conn = ctx.listener.accept() catch |err| {
            std.log.err("accept error on {s}: {}", .{ @tagName(ctx.protocol), err });
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
