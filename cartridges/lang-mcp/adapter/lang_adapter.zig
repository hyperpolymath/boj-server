// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Lang-MCP Cartridge — Unified Zig adapter.
// Replaces the banned lang_adapter.v (zig removed 2026-04-10).
//
// Manages language runtime sessions for all nextgen-languages:
//   Eclexia, AffineScript, BetLang, Ephapax, MyLang, WokeLang,
//   Anvomidav, Phronesis, Error-lang, Julia-the-Viper, Me-dialect, Oblibeny.
//
// Exposes the lang_ffi.zig state machine via:
//   REST        port 9022  HTTP/1.1, JSON responses
//   gRPC-compat port 9023  HTTP/1.1 + proto-style paths, JSON bodies
//   GraphQL     port 9024  HTTP/1.1 POST /graphql, keyword dispatch
//
// Note: lang_typecheck and lang_eval pass caller source via pointer+len;
//       their output is written to a stack-allocated buffer and returned
//       in the JSON response body.
//
// Build: zig build  (build.zig in this directory)

const std = @import("std");
const ffi = @import("lang_ffi");

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

const VERSION   = "0.1.0";
const CARTRIDGE = "lang-mcp";
const REST_PORT: u16 = 9022;
const GRPC_PORT: u16 = 9023;
const GQL_PORT:  u16 = 9024;

const STATE_LABELS = [_][]const u8{ "idle", "compiling", "checked", "evaluating", "err" };

/// Language ID labels, 1-indexed (0 unused).
const LANG_LABELS = [_][]const u8{
    "",
    "eclexia",         // 1
    "affinescript",    // 2
    "betlang",         // 3
    "ephapax",         // 4
    "mylang",          // 5
    "wokelang",        // 6
    "anvomidav",       // 7
    "phronesis",       // 8
    "error_lang",      // 9
    "julia_the_viper", // 10
    "me_dialect",      // 11
    "oblibeny",        // 12
    // 13..98 reserved
    // 99 = custom
};

const DIALECT_MODE_LABELS = [_][]const u8{ "pure", "jtv" };

const GRPC_PROTO =
    \\syntax = "proto3";
    \\package lang_mcp;
    \\
    \\service LangService {
    \\  rpc CreateSession    (CreateSessionRequest) returns (SessionResponse);
    \\  rpc SetUrl           (SetUrlRequest)        returns (SessionResponse);
    \\  rpc GetState         (SlotRequest)          returns (SessionResponse);
    \\  rpc Typecheck        (SourceRequest)        returns (SourceResponse);
    \\  rpc Eval             (SourceRequest)        returns (SourceResponse);
    \\  rpc EndSession       (SlotRequest)          returns (ReleaseResponse);
    \\  rpc Health           (Empty)                returns (HealthResponse);
    \\  rpc Types            (Empty)                returns (TypeInfoResponse);
    \\}
    \\
    \\message Empty                {}
    \\message SlotRequest          { int32 slot = 1; }
    \\message CreateSessionRequest { int32 lang_id = 1; int32 dialect_mode = 2; string name = 3; }
    \\message SetUrlRequest        { int32 slot = 1; string url = 2; }
    \\message SourceRequest        { int32 slot = 1; string source = 2; }
    \\message SessionResponse      { int32 slot = 1; string state = 2; string language = 3; string dialect = 4; }
    \\message SourceResponse       { int32 slot = 1; bool success = 2; string output = 3; }
    \\message ReleaseResponse      { int32 slot = 1; bool released = 2; }
    \\message HealthResponse       { string status = 1; string cartridge = 2; string version = 3; }
    \\message TypeInfoResponse     { repeated string states = 1; repeated string languages = 2; repeated string dialect_modes = 3; }
;

const GRAPHQL_SCHEMA =
    \\type Query {
    \\  health: Health!
    \\  session(slot: Int!): Session
    \\  types: TypeInfo!
    \\}
    \\type Mutation {
    \\  createSession(langId: Int!, dialectMode: Int, name: String!): Session!
    \\  setUrl(slot: Int!, url: String!): Session!
    \\  typecheck(slot: Int!, source: String!): SourceResult!
    \\  eval(slot: Int!, source: String!): SourceResult!
    \\  endSession(slot: Int!): ReleaseResult!
    \\}
    \\type Health       { status: String!  cartridge: String!  version: String! }
    \\type Session      { slot: Int!  state: String!  language: String!  dialect: String! }
    \\type SourceResult { slot: Int!  success: Boolean!  output: String! }
    \\type ReleaseResult { slot: Int!  released: Boolean! }
    \\type TypeInfo     { states: [String!]!  languages: [String!]!  dialectModes: [String!]! }
;

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════════

fn stateLabel(s: c_int) []const u8 {
    if (s >= 0 and s < @as(c_int, STATE_LABELS.len)) return STATE_LABELS[@intCast(s)];
    return "unknown";
}

fn langLabel(l: c_int) []const u8 {
    if (l > 0 and l < @as(c_int, LANG_LABELS.len)) return LANG_LABELS[@intCast(l)];
    if (l == 99) return "custom";
    return "unknown";
}

fn dialectLabel(d: c_int) []const u8 {
    if (d >= 0 and d < @as(c_int, DIALECT_MODE_LABELS.len)) return DIALECT_MODE_LABELS[@intCast(d)];
    return "pure";
}

fn sessionJson(slot: c_int, buf: []u8) []const u8 {
    const state   = ffi.lang_session_state(slot);
    const lang    = ffi.lang_session_language(slot);
    const dialect = ffi.lang_session_dialect(slot);
    return std.fmt.bufPrint(buf,
        \\{{"slot":{d},"state":"{s}","language":"{s}","dialect":"{s}"}}
    , .{ slot, stateLabel(state), langLabel(lang), dialectLabel(dialect) }) catch buf[0..0];
}

fn sourceResponseJson(slot: c_int, success: bool, output: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"slot":{d},"success":{s},"output":{s}}}
    , .{ slot, if (success) "true" else "false", output }) catch buf[0..0];
}

fn errorJson(buf: []u8, msg: []const u8, code: c_int) []const u8 {
    return std.fmt.bufPrint(buf, \\{{"error":"{s}","code":{d}}}, .{ msg, code }) catch buf[0..0];
}

fn healthJson(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, \\{{"status":"ok","cartridge":"{s}","version":"{s}"}}, .{ CARTRIDGE, VERSION }) catch buf[0..0];
}

const TYPES_JSON =
    \\{"states":["idle","compiling","checked","evaluating","err"],
    \\"languages":["eclexia","affinescript","betlang","ephapax","mylang","wokelang","anvomidav","phronesis","error_lang","julia_the_viper","me_dialect","oblibeny","custom"],
    \\"dialect_modes":["pure","jtv"]}
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

/// Extract a JSON string value from body: "field":"value" → value slice.
/// Returns a slice into `body`.
fn parseStringField(body: []const u8, field: []const u8, key_buf: []u8) ?[]const u8 {
    const needle = std.fmt.bufPrint(key_buf, "\"{s}\":\"", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const start = idx + needle.len;
    var end = start;
    while (end < body.len and body[end] != '"') : (end += 1) {
        if (body[end] == '\\') end += 1; // skip escaped char
    }
    return body[start..end];
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

/// Quote a raw output string into a JSON string literal, writing into `out`.
/// Escapes backslashes and double-quotes; newlines are preserved as \n sequences.
fn jsonQuote(s: []const u8, out: []u8) []const u8 {
    var pos: usize = 0;
    if (pos < out.len) { out[pos] = '"'; pos += 1; }
    for (s) |c| {
        if (pos + 2 > out.len) break;
        switch (c) {
            '"'  => { out[pos] = '\\'; pos += 1; out[pos] = '"';  pos += 1; },
            '\\' => { out[pos] = '\\'; pos += 1; out[pos] = '\\'; pos += 1; },
            '\n' => { out[pos] = '\\'; pos += 1; out[pos] = 'n';  pos += 1; },
            '\r' => { out[pos] = '\\'; pos += 1; out[pos] = 'r';  pos += 1; },
            else => { out[pos] = c; pos += 1; },
        }
    }
    if (pos < out.len) { out[pos] = '"'; pos += 1; }
    return out[0..pos];
}

// ═══════════════════════════════════════════════════════════════════════════
// Source operation helper — calls lang_typecheck or lang_eval,
// returns a JSON SourceResponse.
// ═══════════════════════════════════════════════════════════════════════════

fn runSourceOp(
    slot: c_int,
    source: []const u8,
    comptime op: enum { typecheck, eval },
    resp: []u8,
) Response {
    var out_raw: [131072]u8 = undefined; // 128 KiB output buffer
    var quoted:  [196608]u8 = undefined; // worst-case quoted: 1.5x

    const written: i32 = switch (op) {
        .typecheck => ffi.lang_typecheck(slot, source.ptr, source.len, &out_raw, out_raw.len),
        .eval      => ffi.lang_eval(slot, source.ptr, source.len, &out_raw, out_raw.len),
    };

    if (written < 0) {
        return .{ .status = std.http.Status.bad_request, .body = errorJson(resp, "operation failed", written) };
    }

    const output = out_raw[0..@intCast(written)];
    const quoted_output = jsonQuote(output, &quoted);
    const body = sourceResponseJson(slot, written >= 0, quoted_output, resp);
    return .{ .status = std.http.Status.ok, .body = body };
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

    // POST /sessions — create language session
    if (method == .POST and std.mem.eql(u8, target, "/sessions")) {
        const lang_id = parseIntField(body, "lang_id") orelse 2; // default: affinescript
        const dialect = parseIntField(body, "dialect_mode") orelse 0; // default: pure

        var key_buf: [32]u8 = undefined;
        const name = parseStringField(body, "name", &key_buf) orelse "session";

        const slot = ffi.lang_session_start_dialect(lang_id, dialect, name.ptr, name.len);
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }

    if (std.mem.startsWith(u8, target, "/sessions/")) {
        const slot_opt = pathSlot(std.mem.trimRight(u8, target, "/"));

        if (method == .GET and std.mem.endsWith(u8, target, "/state")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/url")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            var key_buf: [16]u8 = undefined;
            const url = parseStringField(body, "url", &key_buf) orelse return .{ .status = bad, .body = errorJson(resp, "missing url", -1) };
            const r = ffi.lang_session_set_url(slot, url.ptr, url.len);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "set url failed", r) };
            return .{ .status = ok, .body = sessionJson(slot, resp) };
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/typecheck")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            var key_buf: [16]u8 = undefined;
            const source = parseStringField(body, "source", &key_buf) orelse body; // body IS source if no JSON wrapper
            return runSourceOp(slot, source, .typecheck, resp);
        }
        if (method == .POST and std.mem.endsWith(u8, target, "/eval")) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            var key_buf: [16]u8 = undefined;
            const source = parseStringField(body, "source", &key_buf) orelse body;
            return runSourceOp(slot, source, .eval, resp);
        }
        if (method == .DELETE) {
            const slot = slot_opt orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };
            const r = ffi.lang_session_end(slot);
            if (r < 0) return .{ .status = bad, .body = errorJson(resp, "end session failed", r) };
            return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0] };
        }
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "not found", -404) };
}

// ═══════════════════════════════════════════════════════════════════════════
// gRPC-compat dispatch
// ═══════════════════════════════════════════════════════════════════════════

const GRPC_PREFIX = "/lang_mcp.LangService/";

fn dispatchGrpc(target: []const u8, body: []const u8, resp: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;

    if (std.mem.eql(u8, target, "/proto")) return .{ .status = ok, .body = GRPC_PROTO, .content_type = "text/plain" };
    if (!std.mem.startsWith(u8, target, GRPC_PREFIX)) return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC path", -1) };

    const rpc = target[GRPC_PREFIX.len..];

    if (std.mem.eql(u8, rpc, "Health")) return .{ .status = ok, .body = healthJson(resp) };
    if (std.mem.eql(u8, rpc, "Types"))  return .{ .status = ok, .body = TYPES_JSON };

    if (std.mem.eql(u8, rpc, "CreateSession")) {
        const lang_id = parseIntField(body, "lang_id") orelse 2;
        const dialect = parseIntField(body, "dialect_mode") orelse 0;
        var key_buf: [32]u8 = undefined;
        const name = parseStringField(body, "name", &key_buf) orelse "session";
        const slot = ffi.lang_session_start_dialect(lang_id, dialect, name.ptr, name.len);
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }

    const slot = parseIntField(body, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "missing slot", -1) };

    if (std.mem.eql(u8, rpc, "GetState")) return .{ .status = ok, .body = sessionJson(slot, resp) };

    if (std.mem.eql(u8, rpc, "SetUrl")) {
        var key_buf: [16]u8 = undefined;
        const url = parseStringField(body, "url", &key_buf) orelse return .{ .status = bad, .body = errorJson(resp, "missing url", -1) };
        const r = ffi.lang_session_set_url(slot, url.ptr, url.len);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "set url failed", r) };
        return .{ .status = ok, .body = sessionJson(slot, resp) };
    }
    if (std.mem.eql(u8, rpc, "Typecheck")) {
        var key_buf: [16]u8 = undefined;
        const source = parseStringField(body, "source", &key_buf) orelse "";
        return runSourceOp(slot, source, .typecheck, resp);
    }
    if (std.mem.eql(u8, rpc, "Eval")) {
        var key_buf: [16]u8 = undefined;
        const source = parseStringField(body, "source", &key_buf) orelse "";
        return runSourceOp(slot, source, .eval, resp);
    }
    if (std.mem.eql(u8, rpc, "EndSession")) {
        const r = ffi.lang_session_end(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "end session failed", r) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"slot":{d},"released":true}}, .{slot}) catch resp[0..0] };
    }

    return .{ .status = std.http.Status.not_found, .body = errorJson(resp, "unknown gRPC method", -1) };
}

// ═══════════════════════════════════════════════════════════════════════════
// GraphQL dispatch
// ═══════════════════════════════════════════════════════════════════════════

fn dispatchGraphql(q: []const u8, resp: []u8) Response {
    const ok  = std.http.Status.ok;
    const bad = std.http.Status.bad_request;
    const has = std.mem.indexOf;

    if (has(u8, q, "__schema") != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"__schema":{{"sdl":"{s}"}}}}}}, .{GRAPHQL_SCHEMA}) catch resp[0..0] };
    if (has(u8, q, "health") != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"health":{s}}}}}, .{healthJson(resp)}) catch resp[0..0] };
    if (has(u8, q, "types")  != null and has(u8, q, "mutation") == null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"types":{s}}}}}, .{TYPES_JSON}) catch resp[0..0] };

    if (has(u8, q, "createSession") != null) {
        const lang_id = parseIntField(q, "langId") orelse 2;
        const dialect = parseIntField(q, "dialectMode") orelse 0;
        var key_buf: [32]u8 = undefined;
        const name = parseStringField(q, "name", &key_buf) orelse "session";
        const slot = ffi.lang_session_start_dialect(lang_id, dialect, name.ptr, name.len);
        if (slot < 0) return .{ .status = bad, .body = errorJson(resp, "no slots available", slot) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"createSession":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] };
    }

    const slot = parseIntField(q, "slot") orelse return .{ .status = bad, .body = errorJson(resp, "could not determine slot", -1) };

    if (has(u8, q, "setUrl") != null) {
        var key_buf: [16]u8 = undefined;
        const url = parseStringField(q, "url", &key_buf) orelse return .{ .status = bad, .body = errorJson(resp, "missing url", -1) };
        const r = ffi.lang_session_set_url(slot, url.ptr, url.len);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "set url failed", r) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"setUrl":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] };
    }
    if (has(u8, q, "typecheck") != null) {
        var key_buf: [16]u8 = undefined;
        const source = parseStringField(q, "source", &key_buf) orelse "";
        const r = runSourceOp(slot, source, .typecheck, resp);
        return .{ .status = r.status, .body = std.fmt.bufPrint(resp, \\{{"data":{{"typecheck":{s}}}}}, .{r.body}) catch resp[0..0] };
    }
    if (has(u8, q, "eval") != null) {
        var key_buf: [16]u8 = undefined;
        const source = parseStringField(q, "source", &key_buf) orelse "";
        const r = runSourceOp(slot, source, .eval, resp);
        return .{ .status = r.status, .body = std.fmt.bufPrint(resp, \\{{"data":{{"eval":{s}}}}}, .{r.body}) catch resp[0..0] };
    }
    if (has(u8, q, "endSession") != null) {
        const r = ffi.lang_session_end(slot);
        if (r < 0) return .{ .status = bad, .body = errorJson(resp, "end session failed", r) };
        return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"endSession":{{"slot":{d},"released":true}}}}}}, .{slot}) catch resp[0..0] };
    }
    if (has(u8, q, "session") != null) return .{ .status = ok, .body = std.fmt.bufPrint(resp, \\{{"data":{{"session":{s}}}}}, .{sessionJson(slot, resp)}) catch resp[0..0] };

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
