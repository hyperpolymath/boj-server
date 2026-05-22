// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// LSP-MCP Cartridge — Unified Zig adapter.
// Replaces the banned lsp_adapter.v (zig removed 2026-04-10).
//
// Exposes the LSP lifecycle state machine from lsp_ffi.zig via three protocols
// on separate threads:
//
//   REST       port 9016  HTTP/1.1, JSON responses
//   gRPC-compat port 9017  HTTP/1.1 transcoding — gRPC method paths, JSON bodies
//   GraphQL    port 9018  HTTP/1.1 POST /graphql, keyword-dispatched
//
// The adapter is a standalone binary; build with:
//   zig build -p zig-out       (from this directory's build.zig)
//
// The lsp_ffi module (../ffi/lsp_ffi.zig) is imported directly via Zig's
// module system — no shared-library linking required.

const std = @import("std");

// ffi module alias — re-exported functions from lsp_ffi.zig
const ffi = @import("lsp_ffi");

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

const VERSION = "0.1.0";
const CARTRIDGE = "lsp-mcp";

const REST_PORT: u16 = 9016;
const GRPC_PORT: u16 = 9017;
const GQL_PORT:  u16 = 9018;

/// State labels ordered by LspState integer encoding.
const STATE_LABELS = [_][]const u8{
    "uninitialized", "initializing", "running", "shutting_down", "exited",
};

/// Capability labels, 1-indexed (slot 0 unused to match FFI encoding).
const CAP_LABELS = [_][]const u8{
    "",               // 0 — unused
    "text_doc_sync",  // 1
    "completion",     // 2
    "hover",          // 3
    "signature_help", // 4
    "definition",     // 5
    "references",     // 6
    "document_symbol",// 7
    "code_action",    // 8
    "diagnostics",    // 9
    "formatting",     // 10
    "rename",         // 11
    "semantic_tokens",// 12
};

/// Proto schema (for gRPC introspection endpoint).
const GRPC_PROTO =
    \\syntax = "proto3";
    \\package lsp_mcp;
    \\
    \\service LspService {
    \\  rpc CreateSession        (Empty)              returns (SessionResponse);
    \\  rpc Initialize           (SlotRequest)        returns (SessionResponse);
    \\  rpc Initialized          (SlotRequest)        returns (SessionResponse);
    \\  rpc Shutdown             (SlotRequest)        returns (SessionResponse);
    \\  rpc Exit                 (SlotRequest)        returns (SessionResponse);
    \\  rpc GetState             (SlotRequest)        returns (SessionResponse);
    \\  rpc RegisterCapability   (CapabilityRequest)  returns (SessionResponse);
    \\  rpc ReleaseSession       (SlotRequest)        returns (ReleaseResponse);
    \\  rpc Health               (Empty)              returns (HealthResponse);
    \\  rpc Types                (Empty)              returns (TypeInfoResponse);
    \\}
    \\
    \\message Empty                {}
    \\message SlotRequest          { int32 slot = 1; }
    \\message CapabilityRequest    { int32 slot = 1; int32 capability = 2; }
    \\message SessionResponse      { int32 slot = 1; string state = 2; repeated string capabilities = 3; }
    \\message ReleaseResponse      { int32 slot = 1; bool released = 2; }
    \\message HealthResponse       { string status = 1; string cartridge = 2; string version = 3; }
    \\message TypeInfoResponse     { repeated string states = 1; repeated string capabilities = 2; }
;

/// GraphQL SDL schema (for /graphql/schema endpoint).
const GRAPHQL_SCHEMA =
    \\type Query {
    \\  health: Health!
    \\  session(slot: Int!): Session
    \\  types: TypeInfo!
    \\}
    \\type Mutation {
    \\  createSession: Session!
    \\  initialize(slot: Int!): Session!
    \\  initialized(slot: Int!): Session!
    \\  shutdown(slot: Int!): Session!
    \\  exit(slot: Int!): Session!
    \\  registerCapability(slot: Int!, capability: Int!): Session!
    \\  releaseSession(slot: Int!): ReleaseResult!
    \\}
    \\type Health        { status: String!  cartridge: String!  version: String! }
    \\type Session       { slot: Int!  state: String!  capabilities: [String!]! }
    \\type ReleaseResult { slot: Int!  released: Boolean! }
    \\type TypeInfo      { states: [String!]!  capabilities: [String!]! }
;

// ═══════════════════════════════════════════════════════════════════════════
// JSON serialisation helpers
// All helpers write into caller-owned fixed buffers — no heap allocation.
// ═══════════════════════════════════════════════════════════════════════════

fn stateLabel(s: c_int) []const u8 {
    if (s >= 0 and s < @as(c_int, STATE_LABELS.len)) {
        return STATE_LABELS[@intCast(s)];
    }
    return "unknown";
}

/// Write a JSON array of capability strings for the given slot into `buf`.
/// Returns a slice into `buf`.
fn capabilitiesJson(slot: c_int, buf: []u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    var first = true;
    var cap: c_int = 1;
    while (cap <= 12) : (cap += 1) {
        if (ffi.lsp_has_capability(slot, cap) == 1) {
            if (!first) {
                buf[pos] = ',';
                pos += 1;
            }
            buf[pos] = '"';
            pos += 1;
            const label = CAP_LABELS[@intCast(cap)];
            @memcpy(buf[pos..][0..label.len], label);
            pos += label.len;
            buf[pos] = '"';
            pos += 1;
            first = false;
        }
    }
    buf[pos] = ']';
    pos += 1;
    return buf[0..pos];
}

/// Serialise a full session object: {slot, state, capabilities}.
/// `resp_buf` and `cap_buf` must be distinct slices.
fn sessionJson(slot: c_int, resp_buf: []u8, cap_buf: []u8) []const u8 {
    const state = ffi.lsp_state(slot);
    const caps = capabilitiesJson(slot, cap_buf);
    return std.fmt.bufPrint(
        resp_buf,
        \\{{"slot":{d},"state":"{s}","capabilities":{s}}}
    ,
        .{ slot, stateLabel(state), caps },
    ) catch resp_buf[0..0];
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

/// Static types response (no slot required).
const TYPES_JSON =
    \\{"states":["uninitialized","initializing","running","shutting_down","exited"],
    \\"capabilities":["text_doc_sync","completion","hover","signature_help","definition",
    \\"references","document_symbol","code_action","diagnostics","formatting","rename","semantic_tokens"]}
;

// ═══════════════════════════════════════════════════════════════════════════
// Minimal JSON body field parsers
// ═══════════════════════════════════════════════════════════════════════════

/// Extract the integer value of `"slot":N` from a JSON body.
fn parseSlot(body: []const u8) ?c_int {
    const needle = "\"slot\":";
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const rest = std.mem.trimLeft(u8, body[idx + needle.len ..], " \t\r\n");
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return @intCast(std.fmt.parseInt(i32, rest[0..end], 10) catch return null);
}

/// Extract the integer value of `"capability":N` from a JSON body.
fn parseCapability(body: []const u8) ?c_int {
    const needle = "\"capability\":";
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const rest = std.mem.trimLeft(u8, body[idx + needle.len ..], " \t\r\n");
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return @intCast(std.fmt.parseInt(i32, rest[0..end], 10) catch return null);
}

/// Extract the integer segment immediately before the last named path segment.
/// E.g. "/sessions/3/state" → 3.  "/sessions/3" → 3.
fn pathSlot(target: []const u8) ?c_int {
    // Walk path segments from right; return the first all-digit segment found.
    var it = std.mem.splitBackwardsScalar(u8, target, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        var all_digits = true;
        for (seg) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            return @intCast(std.fmt.parseInt(i32, seg, 10) catch return null);
        }
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
// REST dispatch — method + path routing for port 9016
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchRest(
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    resp: []u8,
    cap: []u8,
) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    // GET /health
    if (method == .GET and std.mem.eql(u8, target, "/health")) {
        return .{ .status = ok, .body = healthJson(resp) };
    }
    // GET /types
    if (method == .GET and std.mem.eql(u8, target, "/types")) {
        return .{ .status = ok, .body = TYPES_JSON };
    }
    // POST /sessions — allocate a new session slot
    if (method == .POST and std.mem.eql(u8, target, "/sessions")) {
        const slot = ffi.lsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }

    if (std.mem.startsWith(u8, target, "/sessions/")) {
        const slot_opt = pathSlot(std.mem.trimRight(u8, target, "/"));

        // GET /sessions/:slot/state
        if (method == .GET and std.mem.endsWith(u8, target, "/state")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // POST /sessions/:slot/initialize
        if (method == .POST and std.mem.endsWith(u8, target, "/initialize")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lsp_start_init(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // POST /sessions/:slot/initialized
        if (method == .POST and std.mem.endsWith(u8, target, "/initialized")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lsp_initialized(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // POST /sessions/:slot/shutdown
        if (method == .POST and std.mem.endsWith(u8, target, "/shutdown")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lsp_shutdown(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // POST /sessions/:slot/exit
        if (method == .POST and std.mem.endsWith(u8, target, "/exit")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lsp_exit(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // POST /sessions/:slot/capability
        if (method == .POST and std.mem.endsWith(u8, target, "/capability")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const c = parseCapability(body) orelse return .{ .status = bad, .body = errorJson(resp, "missing capability", -1) };
            const r = ffi.lsp_register_capability(slot, c);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
        }
        // DELETE /sessions/:slot
        if (method == .DELETE) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lsp_release(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
            return .{
                .status = ok,
                .body = std.fmt.bufPrint(resp,
                    \\{{"slot":{d},"released":true}}
                , .{slot}) catch resp[0..0],
            };
        }
    }

    return .{
        .status = std.http.Status.not_found,
        .body = errorJson(resp, "not found", -404),
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// gRPC-compat dispatch — HTTP/1.1 + gRPC method paths for port 9017
//
// Each RPC maps to POST /lsp_mcp.LspService/<MethodName>.
// Bodies and responses are JSON (not protobuf wire format); the proto schema
// is served at GET /proto for documentation and client generation tooling.
// ═══════════════════════════════════════════════════════════════════════════

const GRPC_PREFIX = "/lsp_mcp.LspService/";

fn dispatchGrpc(
    target: []const u8,
    body: []const u8,
    resp: []u8,
    cap: []u8,
) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    // Schema introspection
    if (std.mem.eql(u8, target, "/proto")) {
        return .{ .status = ok, .body = GRPC_PROTO, .content_type = "text/plain" };
    }

    if (!std.mem.startsWith(u8, target, GRPC_PREFIX)) {
        return .{
            .status = std.http.Status.not_found,
            .body = errorJson(resp, "unknown gRPC path", -1),
        };
    }

    const rpc = target[GRPC_PREFIX.len..];

    // No-argument RPCs
    if (std.mem.eql(u8, rpc, "Health")) return .{ .status = ok, .body = healthJson(resp) };
    if (std.mem.eql(u8, rpc, "Types"))  return .{ .status = ok, .body = TYPES_JSON };
    if (std.mem.eql(u8, rpc, "CreateSession")) {
        const slot = ffi.lsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }

    // Slot-required RPCs
    const slot = parseSlot(body) orelse
        return .{ .status = bad, .body = errorJson(resp, "missing slot in body", -1) };

    if (std.mem.eql(u8, rpc, "GetState")) {
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "Initialize")) {
        const r = ffi.lsp_start_init(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "Initialized")) {
        const r = ffi.lsp_initialized(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "Shutdown")) {
        const r = ffi.lsp_shutdown(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "Exit")) {
        const r = ffi.lsp_exit(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "RegisterCapability")) {
        const c = parseCapability(body) orelse
            return .{ .status = bad, .body = errorJson(resp, "missing capability in body", -1) };
        const r = ffi.lsp_register_capability(slot, c);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp, cap) };
    }
    if (std.mem.eql(u8, rpc, "ReleaseSession")) {
        const r = ffi.lsp_release(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"slot":{d},"released":true}}
            , .{slot}) catch resp[0..0],
        };
    }

    return .{
        .status = std.http.Status.not_found,
        .body = errorJson(resp, "unknown gRPC method", -1),
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// GraphQL dispatch — POST /graphql on port 9018
//
// Production-quality GraphQL parsing would require a full parser.  This
// implementation uses keyword detection on the raw query string, which is
// sufficient for the small fixed schema.  The slot/capability values are
// parsed from the variables object (same JSON field names as REST).
//
// Supported:
//   query  { health { ... } }
//   query  { types { ... } }
//   query  { session(slot: N) { ... } }
//   mutation { createSession { ... } }
//   mutation { initialize(slot: N) { ... } }
//   mutation { initialized(slot: N) { ... } }
//   mutation { shutdown(slot: N) { ... } }
//   mutation { exit(slot: N) { ... } }
//   mutation { registerCapability(slot: N, capability: N) { ... } }
//   mutation { releaseSession(slot: N) { ... } }
//   introspection: __schema / __type
//
// GET /graphql/schema returns the SDL.
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchGraphql(
    query_body: []const u8,
    resp: []u8,
    cap: []u8,
) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;
    const has = std.mem.indexOf;

    // Introspection
    if (has(u8, query_body, "__schema") != null or has(u8, query_body, "__type") != null) {
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"__schema":{{"description":"{s}"}}}}}}
            , .{GRAPHQL_SCHEMA}) catch resp[0..0],
        };
    }

    // health query (no slot)
    if (has(u8, query_body, "health") != null and has(u8, query_body, "mutation") == null) {
        const h = healthJson(cap);
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"health":{s}}}}}
            , .{h}) catch resp[0..0],
        };
    }

    // types query (no slot)
    if (has(u8, query_body, "types") != null and has(u8, query_body, "mutation") == null) {
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"types":{s}}}}}
            , .{TYPES_JSON}) catch resp[0..0],
        };
    }

    // createSession mutation (no slot)
    if (has(u8, query_body, "createSession") != null) {
        const slot = ffi.lsp_init();
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"createSession":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    // All remaining operations need a slot
    const slot = parseSlot(query_body) orelse
        return .{ .status = bad, .body = errorJson(resp, "could not determine slot from query", -1) };

    // registerCapability — check before "initialize" to avoid prefix confusion
    if (has(u8, query_body, "registerCapability") != null) {
        const c = parseCapability(query_body) orelse
            return .{ .status = bad, .body = errorJson(resp, "missing capability in query", -1) };
        const r = ffi.lsp_register_capability(slot, c);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid capability or state", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"registerCapability":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    // initialized — check before "initialize" (prefix ordering)
    if (has(u8, query_body, "initialized") != null) {
        const r = ffi.lsp_initialized(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"initialized":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    if (has(u8, query_body, "initialize") != null) {
        const r = ffi.lsp_start_init(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"initialize":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    if (has(u8, query_body, "shutdown") != null) {
        const r = ffi.lsp_shutdown(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"shutdown":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    if (has(u8, query_body, "exit") != null) {
        const r = ffi.lsp_exit(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "invalid transition", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"exit":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    if (has(u8, query_body, "releaseSession") != null) {
        const r = ffi.lsp_release(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "release failed", r) };
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"releaseSession":{{"slot":{d},"released":true}}}}}}
            , .{slot}) catch resp[0..0],
        };
    }

    if (has(u8, query_body, "session") != null) {
        return .{
            .status = ok,
            .body = std.fmt.bufPrint(resp,
                \\{{"data":{{"session":{s}}}}}
            , .{sessionJson(slot, cap, cap)}) catch resp[0..0],
        };
    }

    return .{ .status = bad, .body = errorJson(resp, "unrecognised GraphQL operation", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP connection handler — shared by all three listeners.
// Reads one request from `conn`, dispatches, writes response, closes.
// ═══════════════════════════════════════════════════════════════════════════

const Protocol = enum { rest, grpc, graphql };

fn handleConnection(conn: std.net.Server.Connection, protocol: Protocol) void {
    defer conn.stream.close();

    var read_buf: [8192]u8 = undefined;
    var http_srv = std.http.Server.init(conn, &read_buf);

    var request = http_srv.receiveHead() catch return;

    // Read body up to 256 KiB
    var body_buf: [262144]u8 = undefined;
    var body_len: usize = 0;
    if (request.head.content_length) |cl| {
        const to_read: usize = @min(cl, body_buf.len);
        var reader = request.reader() catch return;
        body_len = reader.readAll(body_buf[0..to_read]) catch 0;
    }

    var resp_buf: [4096]u8 = undefined;
    var cap_buf: [512]u8 = undefined;

    const resp: Response = switch (protocol) {
        .rest => blk: {
            // Schema SDL shortcut for REST
            if (request.head.method == .GET and
                std.mem.eql(u8, request.head.target, "/graphql/schema"))
            {
                break :blk .{ .status = .ok, .body = GRAPHQL_SCHEMA, .content_type = "text/plain" };
            }
            break :blk dispatchRest(
                request.head.method,
                request.head.target,
                body_buf[0..body_len],
                &resp_buf,
                &cap_buf,
            );
        },
        .grpc => dispatchGrpc(
            request.head.target,
            body_buf[0..body_len],
            &resp_buf,
            &cap_buf,
        ),
        .graphql => blk: {
            if (request.head.method == .GET and
                std.mem.eql(u8, request.head.target, "/graphql/schema"))
            {
                break :blk .{ .status = .ok, .body = GRAPHQL_SCHEMA, .content_type = "text/plain" };
            }
            break :blk dispatchGraphql(body_buf[0..body_len], &resp_buf, &cap_buf);
        },
    };

    // gRPC adds grpc-status header; others just content-type + CORS
    const grpc_status: std.http.Header = .{
        .name = "grpc-status",
        .value = if (resp.status == .ok) "0" else "2",
    };
    const ct_header: std.http.Header = .{ .name = "content-type", .value = resp.content_type };
    const cors_header: std.http.Header = .{ .name = "access-control-allow-origin", .value = "*" };

    if (protocol == .grpc) {
        request.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{ ct_header, grpc_status },
        }) catch {};
    } else {
        request.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{ ct_header, cors_header },
        }) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Per-protocol listener loops (run on separate threads)
// ═══════════════════════════════════════════════════════════════════════════

const ListenerCtx = struct {
    listener: *std.net.Server,
    protocol: Protocol,
};

fn listenLoop(ctx: ListenerCtx) void {
    while (true) {
        const conn = ctx.listener.accept() catch |err| {
            std.log.err("accept error on {s} listener: {}", .{ @tagName(ctx.protocol), err });
            continue;
        };
        handleConnection(conn, ctx.protocol);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    // Initialise the FFI session table
    _ = ffi.boj_cartridge_init();

    const rest_addr = try std.net.Address.parseIp4("0.0.0.0", REST_PORT);
    const grpc_addr = try std.net.Address.parseIp4("0.0.0.0", GRPC_PORT);
    const gql_addr  = try std.net.Address.parseIp4("0.0.0.0", GQL_PORT);

    var rest_listener = try rest_addr.listen(.{ .reuse_address = true });
    defer rest_listener.deinit();
    var grpc_listener = try grpc_addr.listen(.{ .reuse_address = true });
    defer grpc_listener.deinit();
    var gql_listener  = try gql_addr.listen(.{ .reuse_address = true });
    defer gql_listener.deinit();

    std.log.info("{s} REST     :{d}", .{ CARTRIDGE, REST_PORT });
    std.log.info("{s} gRPC-compat :{d}", .{ CARTRIDGE, GRPC_PORT });
    std.log.info("{s} GraphQL  :{d}", .{ CARTRIDGE, GQL_PORT });

    const t_rest = try std.Thread.spawn(.{}, listenLoop, .{
        ListenerCtx{ .listener = &rest_listener, .protocol = .rest },
    });
    const t_grpc = try std.Thread.spawn(.{}, listenLoop, .{
        ListenerCtx{ .listener = &grpc_listener, .protocol = .grpc },
    });
    const t_gql = try std.Thread.spawn(.{}, listenLoop, .{
        ListenerCtx{ .listener = &gql_listener, .protocol = .graphql },
    });

    t_rest.join();
    t_grpc.join();
    t_gql.join();
}
