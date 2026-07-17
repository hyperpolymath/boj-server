// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// bug-filing-mcp/adapter/bug_filing_mcp_adapter.zig
//
// INTERNAL-ONLY unified adapter. This is NOT a public ingress. Per
// ADR-0004 the only governed public surface is the http-capability-gateway
// (tier-2) in front of the unified Zig core; cartridge adapters bind
// loopback and sit behind it. One listener, one port, protocol-routed
// (REST + SSE + GraphQL + gRPC-compat) into a SINGLE transaction-gated
// dispatch -> the one Zig ABI (ffi.boj_cartridge_invoke). Deliberately NOT
// N parallel servers and NOT a public listener.
//
//   POST /invoke            -> REST            (JSON in/out)
//   POST /sse               -> SSE             (text/event-stream)
//   POST /graphql           -> GraphQL         (op parsed from body)
//   POST /grpc/<Svc>/<Mthd> -> gRPC-compat     (tool = method)
//
// Every request passes the transaction gate (exposureGate, mirroring the
// Idris2 BugFilingMcp.SafeBugFiling.exposureSatisfied contract) BEFORE
// dispatch. No request reaches the ABI ungated — this boundary is not a
// gatekeeperless gateway (estate interface-safety policy).
//
// NOTE: the ABI this adapter fronts (../ffi/bug_filing_mcp_ffi.zig) answers
// every tool with a structured delegation notice -- the real dispatch path
// for this cartridge remains mod.js -> the feedback-o-tron engine's HTTP
// intake (see ../README.adoc). This adapter exists so the cartridge carries
// the estate-standard unified-adapter surface like every other cartridge;
// it inherits the FFI's honesty about what is and is not wired.

const std = @import("std");
const ffi = @import("bug_filing_mcp_ffi");

// Loopback-only by construction: this adapter is internal, fronted by the
// http-capability-gateway (ADR-0004). Never bind a routable interface.
const BIND_IP = [4]u8{ 127, 0, 0, 1 };
const PORT: u16 = 9391;

// -- Transaction gate (mirrors Idris2 SafeBugFiling.exposureSatisfied) ------
//
// Encoding matches BugFilingMcp.SafeBugFiling: 0=Public 1=Authenticated 2=Internal.
const Exposure = enum(u8) { public = 0, authenticated = 1, internal = 2 };

// bug-filing-mcp cartridge.json: auth.method = "none" -> requiredExposure = Public.
// (requiredExposure(authMethodIsNone=true) = Public, per the Idris2 contract.)
const REQUIRED_EXPOSURE: Exposure = .public;

/// Zig mirror of Idris2 `exposureSatisfied`. Cross-checked by the truth-table
/// test below; the Idris2 module is the source-of-truth contract.
fn exposureSatisfied(required: Exposure, presented: Exposure, is_local: bool) bool {
    if (is_local) return true; // loopback callers are locally trusted
    return switch (required) {
        .public => true,
        .authenticated => presented == .authenticated or presented == .internal,
        .internal => presented == .internal,
    };
}

/// Parse the `X-Trust-Level` request header the gateway/sidecar sets.
/// Missing/unknown -> Public (conservative). Case-insensitive header name.
fn presentedExposure(req: []const u8) Exposure {
    const val = headerValue(req, "x-trust-level") orelse return .public;
    if (eqIgnoreCase(val, "internal")) return .internal;
    if (eqIgnoreCase(val, "authenticated")) return .authenticated;
    return .public;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Case-insensitive single-header lookup over a raw HTTP/1.1 request.
fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, req, '\n');
    _ = lines.next(); // request line
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) break; // end of headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (eqIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

const Dispatch = struct { status: u16, body: []const u8 };

/// The single point where every protocol converges onto the one Zig ABI.
fn dispatch(tool: []const u8, args_json: []const u8, out: []u8) Dispatch {
    var tnbuf: [128]u8 = undefined;
    if (tool.len == 0 or tool.len >= tnbuf.len)
        return .{ .status = 400, .body = "{\"error\":\"bad-tool\"}" };
    @memcpy(tnbuf[0..tool.len], tool);
    tnbuf[tool.len] = 0;

    var abuf: [4096]u8 = undefined;
    const a = if (args_json.len == 0) "{}" else args_json;
    if (a.len >= abuf.len)
        return .{ .status = 413, .body = "{\"error\":\"args-too-large\"}" };
    @memcpy(abuf[0..a.len], a);
    abuf[a.len] = 0;

    var len: usize = out.len;
    // No @ptrCast needed (CWE-704 fix, matching #89's cartridge_shim.zig
    // pattern): [*c] parameters accept array/slice/scalar pointers via
    // Zig's own implicit C-pointer coercion.
    const rc = ffi.boj_cartridge_invoke(&tnbuf, &abuf, out.ptr, &len);
    return switch (rc) {
        0 => .{ .status = 200, .body = out[0..len] },
        -1 => .{ .status = 404, .body = "{\"error\":\"unknown-tool\"}" },
        -2 => .{ .status = 400, .body = "{\"error\":\"bad-args\"}" },
        -3 => .{ .status = 500, .body = "{\"error\":\"buffer-too-small\"}" },
        else => .{ .status = 500, .body = "{\"error\":\"invoke-failed\"}" },
    };
}

const Protocol = enum { rest, sse, graphql, grpc, unknown };

fn classify(path: []const u8) Protocol {
    if (std.mem.startsWith(u8, path, "/invoke")) return .rest;
    if (std.mem.startsWith(u8, path, "/sse")) return .sse;
    if (std.mem.startsWith(u8, path, "/graphql")) return .graphql;
    if (std.mem.startsWith(u8, path, "/grpc/")) return .grpc;
    return .unknown;
}

fn toolFor(proto: Protocol, path: []const u8, body: []const u8) ?[]const u8 {
    switch (proto) {
        .grpc => {
            var it = std.mem.splitScalar(u8, path, '/');
            _ = it.next(); // ""
            _ = it.next(); // "grpc"
            _ = it.next(); // service
            return it.next();
        },
        .rest, .sse => {
            if (std.mem.indexOf(u8, path, "tool=")) |q| {
                const rest = path[q + 5 ..];
                const end = std.mem.indexOfAny(u8, rest, "& ") orelse rest.len;
                if (end > 0) return rest[0..end];
            }
            return jsonStringField(body, "tool");
        },
        .graphql => {
            const tools = [_][]const u8{
                "research_feedback", "synthesize_feedback", "submit_feedback",
            };
            for (tools) |t| if (std.mem.indexOf(u8, body, t) != null) return t;
            return null;
        },
        .unknown => return null,
    }
}

fn jsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [64]u8 = undefined;
    if (key.len + 2 >= kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    const needle = kbuf[0 .. key.len + 2];
    const k = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = k + needle.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i > start) return body[start..i] else return null;
}

fn writeHttp(stream: std.net.Stream, status: u16, ctype: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    _ = stream.write(h) catch {};
    _ = stream.write(body) catch {};
}

fn writeSse(stream: std.net.Stream, d: Dispatch) void {
    const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
    _ = stream.write(head) catch {};
    _ = stream.write("event: open\ndata: {\"cartridge\":\"bug-filing-mcp\"}\n\n") catch {};
    var fb: [4608]u8 = undefined;
    const ev = if (d.status == 200) "result" else "error";
    const frame = std.fmt.bufPrint(&fb, "event: {s}\ndata: {s}\n\n", .{ ev, d.body }) catch "event: error\ndata: {}\n\n";
    _ = stream.write(frame) catch {};
    _ = stream.write("event: done\ndata: {}\n\n") catch {};
}

// Loopback-only listener => peers are local by construction. We still
// evaluate the gate every request (no gatekeeperless path); the
// non-local branch is exercised by exposureSatisfied's tests.
fn handleConnection(stream: std.net.Stream) void {
    defer stream.close();
    var buf: [8192]u8 = undefined;
    const n = stream.read(&buf) catch return;
    const req = buf[0..n];

    var lines = std.mem.splitScalar(u8, req, '\n');
    const first = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
    _ = parts.next(); // method
    const path = parts.next() orelse return;

    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n");
    const body = if (body_start) |bs| req[bs + 4 ..] else "";

    const proto = classify(path);
    if (proto == .unknown) {
        writeHttp(stream, 404, "application/json", "{\"error\":\"route-not-found\"}");
        return;
    }

    // -- TRANSACTION GATE -- runs before dispatch, every request --------
    const is_local = true; // loopback-bound (BIND_IP); see module header
    if (!exposureSatisfied(REQUIRED_EXPOSURE, presentedExposure(req), is_local)) {
        writeHttp(stream, 403, "application/json", "{\"error\":\"forbidden\",\"detail\":\"exposure-gate\"}");
        return;
    }

    const tool = toolFor(proto, path, body) orelse {
        writeHttp(stream, 400, "application/json", "{\"error\":\"missing-tool\"}");
        return;
    };

    var out: [4096]u8 = undefined;
    const d = dispatch(tool, body, &out);

    switch (proto) {
        .sse => writeSse(stream, d),
        .graphql => {
            var gb: [4352]u8 = undefined;
            const g = std.fmt.bufPrint(&gb, "{{\"data\":{{\"invoke\":{s}}}}}", .{d.body}) catch d.body;
            writeHttp(stream, d.status, "application/json", g);
        },
        else => writeHttp(stream, d.status, "application/json", d.body), // rest, grpc
    }
}

pub fn main() !void {
    _ = ffi.boj_cartridge_init();
    defer ffi.boj_cartridge_deinit();
    const addr = std.net.Address.initIp4(BIND_IP, PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    std.debug.print("bug-filing-mcp INTERNAL unified adapter on 127.0.0.1:{d} (behind http-capability-gateway; rest|sse|graphql|grpc; transaction-gated)\n", .{PORT});
    while (true) {
        const conn = try server.accept();
        const t = try std.Thread.spawn(.{}, handleConnection, .{conn.stream});
        t.detach();
    }
}

// ------------------------- tests -------------------------

test "classify routes each protocol to one surface" {
    try std.testing.expectEqual(Protocol.rest, classify("/invoke"));
    try std.testing.expectEqual(Protocol.sse, classify("/sse"));
    try std.testing.expectEqual(Protocol.graphql, classify("/graphql"));
    try std.testing.expectEqual(Protocol.grpc, classify("/grpc/BugFiling/submit_feedback"));
    try std.testing.expectEqual(Protocol.unknown, classify("/nope"));
}

test "toolFor extracts across protocols" {
    try std.testing.expectEqualStrings("submit_feedback", toolFor(.grpc, "/grpc/BugFiling/submit_feedback", "").?);
    try std.testing.expectEqualStrings("research_feedback", toolFor(.rest, "/invoke?tool=research_feedback", "").?);
    try std.testing.expectEqualStrings("synthesize_feedback", toolFor(.sse, "/sse", "{\"tool\":\"synthesize_feedback\"}").?);
    try std.testing.expectEqualStrings("submit_feedback", toolFor(.graphql, "/graphql", "{query: invoke(tool:\"submit_feedback\")}").?);
    try std.testing.expect(toolFor(.rest, "/invoke", "{}") == null);
}

test "dispatch funnels into the one Zig ABI" {
    var out: [512]u8 = undefined;
    const d = dispatch("submit_feedback", "{}", &out);
    try std.testing.expectEqual(@as(u16, 200), d.status);
    try std.testing.expect(std.mem.indexOf(u8, d.body, "delegated") != null);
    try std.testing.expectEqual(@as(u16, 404), dispatch("nope", "{}", &out).status);
}

// Transaction-gate truth table -- must match Idris2
// BugFilingMcp.SafeBugFiling.exposureSatisfied exactly.
test "exposureSatisfied mirrors the Idris2 contract" {
    // local caller: always permitted regardless of required/presented
    try std.testing.expect(exposureSatisfied(.internal, .public, true));
    // public requirement: any presented level passes
    try std.testing.expect(exposureSatisfied(.public, .public, false));
    // authenticated requirement
    try std.testing.expect(!exposureSatisfied(.authenticated, .public, false));
    try std.testing.expect(exposureSatisfied(.authenticated, .authenticated, false));
    try std.testing.expect(exposureSatisfied(.authenticated, .internal, false));
    // internal requirement
    try std.testing.expect(!exposureSatisfied(.internal, .authenticated, false));
    try std.testing.expect(exposureSatisfied(.internal, .internal, false));
}

test "presentedExposure parses X-Trust-Level (case-insensitive)" {
    const req = "POST /invoke HTTP/1.1\r\nHost: x\r\nX-Trust-Level: Internal\r\n\r\n{}";
    try std.testing.expectEqual(Exposure.internal, presentedExposure(req));
    try std.testing.expectEqual(Exposure.public, presentedExposure("POST / HTTP/1.1\r\n\r\n"));
}
