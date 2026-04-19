// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-coord-mcp/adapter/local_coord_adapter.zig

const std = @import("std");
const ffi = @import("local_coord_ffi");

const BIND_ADDR = [4]u8{ 127, 0, 0, 1 };
const REST_PORT: u16 = 7745;

const Response = struct { status: u16, body: []const u8 };

fn okJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn errJson(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch buf[0..0];
}

fn kindName(kind: i32) []const u8 {
    return switch (kind) {
        0 => "claude",
        1 => "gemini",
        2 => "copilot",
        else => "custom",
    };
}

fn stateName(state: i32) []const u8 {
    return switch (state) {
        0 => "registering",
        1 => "active",
        2 => "departing",
        else => "gone",
    };
}

fn parseToken(token_hex: []const u8, out: *[16]u8) bool {
    if (token_hex.len != 32) return false;
    _ = std.fmt.hexToBytes(out, token_hex) catch return false;
    return true;
}

/// Render a peer_id into the caller buffer. Format is `<kind>-<4hex>` when
/// ctx is empty, `<kind>-<4hex>@<context>` when set. Returns the slice of
/// buf actually used.
fn renderPeerId(buf: []u8, kind_str: []const u8, suffix: []const u8, ctx: []const u8) ![]u8 {
    if (ctx.len == 0) {
        return try std.fmt.bufPrint(buf, "{s}-{s}", .{ kind_str, suffix });
    }
    return try std.fmt.bufPrint(buf, "{s}-{s}@{s}", .{ kind_str, suffix, ctx });
}

/// Extract the 4-char hex suffix from a target peer_id string. Format is
/// `<kind>-<4hex>` or `<kind>-<4hex>@<context>`. Returns null if malformed.
fn extractSuffix(target: []const u8) ?[]const u8 {
    // Find the last '-' before any '@' — the 4 hex chars follow it.
    const at_pos = std.mem.indexOfScalar(u8, target, '@') orelse target.len;
    const left = target[0..at_pos];
    const dash_pos = std.mem.lastIndexOfScalar(u8, left, '-') orelse return null;
    const suffix = left[dash_pos + 1 ..];
    if (suffix.len != 4) return null;
    return suffix;
}

fn dispatch(tool: []const u8, body: []const u8, resp: []u8, allocator: std.mem.Allocator) Response {
    if (std.mem.eql(u8, tool, "coord_register")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();

        const kind_val = parsed.value.object.get("client_kind") orelse return .{ .status = 400, .body = errJson(resp, "missing client_kind") };
        const kind_str = kind_val.string;
        var kind: i32 = 3;
        if (std.mem.eql(u8, kind_str, "claude")) kind = 0;
        if (std.mem.eql(u8, kind_str, "gemini")) kind = 1;
        if (std.mem.eql(u8, kind_str, "copilot")) kind = 2;

        // Optional context for per-window disambiguation.
        const ctx_str: []const u8 = blk: {
            const ctx_val = parsed.value.object.get("context") orelse break :blk "";
            break :blk ctx_val.string;
        };

        var token: [16]u8 = undefined;
        var suffix: [4]u8 = undefined;
        const idx = ffi.coord_register(kind, &token, &suffix);
        if (idx < 0) return .{ .status = 500, .body = errJson(resp, "registry full") };

        if (ctx_str.len > 0) {
            const set_rc = ffi.coord_set_context(&token, 16, ctx_str.ptr, @intCast(ctx_str.len));
            if (set_rc < 0) {
                // Rollback: deregister the half-registered peer so the caller can retry cleanly.
                _ = ffi.coord_deregister(&token, 16);
                return .{ .status = 400, .body = errJson(resp, "invalid context (alphanumeric/hyphen/underscore only, max 32 bytes)") };
            }
        }

        var token_hex: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (token, 0..) |b, i| {
            token_hex[i * 2] = hex_chars[b >> 4];
            token_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        var peer_id_buf: [96]u8 = undefined;
        const peer_id = renderPeerId(&peer_id_buf, kind_str, &suffix, ctx_str) catch return .{ .status = 500, .body = errJson(resp, "peer_id render overflow") };

        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"peer_id\":\"{s}\",\"token\":\"{s}\"}}", .{ peer_id, token_hex }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_list_peers")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        // FFI returns 12 bytes per peer: kind(i32) + suffix[4] + state(i32).
        // Cap at MAX_PEERS (16) * 12 = 192 bytes.
        var raw: [192]u8 = undefined;
        const count = ffi.coord_list_peers(&token, 16, &raw, @intCast(raw.len));
        if (count < 0) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };

        // Build JSON: {"success":true,"peers":[{"peer_id":"kind-xxxx","kind":"...","state":"...","status":"..."},...]}
        var stream = std.io.fixedBufferStream(resp);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"peers\":[") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };

        // The 12-byte records in `raw` are packed in peer-index-ascending order
        // (FFI iterates peers[] and writes only active ones). We scan the same
        // peer-index range and pair each active index with the next dense record.
        var i: i32 = 0;
        var written_idx: usize = 0;
        const cnt: usize = @intCast(count);
        while (i < 16 and written_idx < cnt) : (i += 1) {
            const kind_val = ffi.coord_read_peer_kind(i);
            if (kind_val < 0) continue;

            const rec_offset = written_idx * 12;
            const suffix = raw[rec_offset + 4 .. rec_offset + 8];
            const state_bytes = raw[rec_offset + 8 .. rec_offset + 12];
            const state: i32 = @bitCast([4]u8{ state_bytes[0], state_bytes[1], state_bytes[2], state_bytes[3] });

            var status_buf: [256]u8 = undefined;
            const status_len = ffi.coord_read_peer_status(i, &status_buf, @intCast(status_buf.len));
            const status_slice: []const u8 = if (status_len > 0) status_buf[0..@intCast(status_len)] else "";

            var ctx_buf: [32]u8 = undefined;
            const ctx_len = ffi.coord_read_peer_context(i, &ctx_buf, @intCast(ctx_buf.len));
            const ctx_slice: []const u8 = if (ctx_len > 0) ctx_buf[0..@intCast(ctx_len)] else "";

            var peer_id_buf: [96]u8 = undefined;
            const peer_id = renderPeerId(&peer_id_buf, kindName(kind_val), suffix, ctx_slice) catch return .{ .status = 500, .body = errJson(resp, "peer_id render overflow") };

            if (written_idx > 0) w.writeAll(",") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            std.fmt.format(w, "{{\"peer_id\":\"{s}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"context\":\"{s}\",\"status\":\"{s}\"}}", .{
                peer_id, kindName(kind_val), stateName(state), ctx_slice, status_slice,
            }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            written_idx += 1;
        }

        w.writeAll("]}") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = resp[0..stream.pos] };
    }

    if (std.mem.eql(u8, tool, "coord_send")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const target_val = parsed.value.object.get("target") orelse return .{ .status = 400, .body = errJson(resp, "missing target") };
        const msg_val = parsed.value.object.get("message") orelse return .{ .status = 400, .body = errJson(resp, "missing message") };

        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const target_str = target_val.string;
        var target_idx: i32 = -1;
        if (!std.mem.eql(u8, target_str, "*")) {
            // Peer ID format: "<kind>-<4hex>" or "<kind>-<4hex>@<context>".
            const suffix = extractSuffix(target_str) orelse return .{ .status = 400, .body = errJson(resp, "invalid target format — expected <kind>-<4hex>[@<context>]") };
            target_idx = ffi.coord_find_peer_by_suffix(suffix.ptr);
            if (target_idx < 0) return .{ .status = 404, .body = errJson(resp, "target peer not found") };
        }

        const msg = msg_val.string;
        const sent = ffi.coord_send(&token, 16, target_idx, msg.ptr, @intCast(msg.len));
        if (sent < 0) return .{ .status = 401, .body = errJson(resp, "unauthenticated or invalid target") };

        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"sent\":{d}}}", .{sent}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_receive")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        var msg_buf: [512]u8 = undefined;
        const mlen = ffi.coord_receive(&token, 16, &msg_buf, @intCast(msg_buf.len));
        if (mlen < 0) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };

        if (mlen == 0) {
            return .{ .status = 200, .body = std.fmt.bufPrint(resp, "{{\"success\":true,\"message\":null}}", .{}) catch resp[0..0] };
        }
        const msg_slice = msg_buf[0..@intCast(mlen)];
        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg_slice}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_status")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const status_val = parsed.value.object.get("status") orelse return .{ .status = 400, .body = errJson(resp, "missing status") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const status = status_val.string;
        const rc = ffi.coord_set_status(&token, 16, status.ptr, @intCast(status.len));
        if (rc < 0) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        return .{ .status = 200, .body = okJson(resp, "ok") };
    }

    if (std.mem.eql(u8, tool, "coord_claim_task")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_hex = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const task = parsed.value.object.get("task") orelse return .{ .status = 400, .body = errJson(resp, "missing task") };

        var token: [16]u8 = undefined;
        if (!parseToken(token_hex.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const result = ffi.coord_claim_task(&token, 16, task.string.ptr, @intCast(task.string.len));
        if (result == 0) return .{ .status = 200, .body = okJson(resp, "granted") };
        if (result == 1) return .{ .status = 200, .body = errJson(resp, "held") };
        return .{ .status = 500, .body = errJson(resp, "claim failed") };
    }

    return .{ .status = 404, .body = errJson(resp, "not implemented") };
}

fn handleConnection(stream: std.net.Stream, allocator: std.mem.Allocator) void {
    defer stream.close();
    var buf: [8192]u8 = undefined;
    var resp_buf: [8192]u8 = undefined;
    const n = stream.read(&buf) catch return;
    const req = buf[0..n];

    var lines = std.mem.splitScalar(u8, req, '\n');
    const first = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, first, "\r"), ' ');
    _ = parts.next(); 
    const path = parts.next() orelse return;

    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse 0;
    const body = if (body_start > 0) req[body_start + 4 ..] else "";

    const prefix = "/tools/";
    var result: Response = .{ .status = 404, .body = errJson(&resp_buf, "not found") };
    if (std.mem.startsWith(u8, path, prefix)) {
        const tool = path[prefix.len..];
        result = dispatch(tool, body, &resp_buf, allocator);
    }

    var http_resp: [512]u8 = undefined;
    const http = std.fmt.bufPrint(&http_resp,
        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
        .{ result.status, result.body.len }) catch return;
    _ = stream.write(http) catch {};
    _ = stream.write(result.body) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    _ = ffi.boj_cartridge_init();

    const addr = std.net.Address.initIp4(BIND_ADDR, REST_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        handleConnection(conn.stream, allocator);
    }
}
