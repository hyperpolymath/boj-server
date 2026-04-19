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

        // Optional role hint. Server rejects role=master here; callers
        // must promote via coord_promote_to_master with the env secret.
        // Old names (supervisor/executor/supervised) accepted as aliases
        // for one release per DD-32.
        const role_hint: i32 = blk: {
            const rv = parsed.value.object.get("role") orelse break :blk -1;
            const rs = rv.string;
            if (std.mem.eql(u8, rs, "master") or std.mem.eql(u8, rs, "supervisor")) break :blk 0;
            if (std.mem.eql(u8, rs, "journeyman") or std.mem.eql(u8, rs, "executor")) break :blk 1;
            if (std.mem.eql(u8, rs, "apprentice") or std.mem.eql(u8, rs, "supervised")) break :blk 2;
            break :blk -1;
        };

        var token: [16]u8 = undefined;
        var suffix: [4]u8 = undefined;
        const idx = ffi.coord_register(kind, role_hint, &token, &suffix);
        if (idx == -3) return .{ .status = 400, .body = errJson(resp, "master role must be obtained via coord_promote_to_master") };
        if (idx < 0) return .{ .status = 500, .body = errJson(resp, "registry full") };

        if (ctx_str.len > 0) {
            const set_rc = ffi.coord_set_context(&token, 16, ctx_str.ptr, @intCast(ctx_str.len));
            if (set_rc < 0) {
                // Rollback: deregister the half-registered peer so the caller can retry cleanly.
                _ = ffi.coord_deregister(&token, 16);
                return .{ .status = 400, .body = errJson(resp, "invalid context (alphanumeric/hyphen/underscore only, max 32 bytes)") };
            }
        }

        // Optional declared_affinities — an array of tag strings that the
        // peer self-reports as strengths. Stored as a CSV internally so the
        // reassignment engine (Task #14) can diff against track record.
        if (parsed.value.object.get("declared_affinities")) |decl_val| {
            if (decl_val == .array) {
                var csv_buf: [256]u8 = undefined;
                var csv_len: usize = 0;
                for (decl_val.array.items) |item| {
                    if (item != .string) continue;
                    const s = item.string;
                    if (csv_len > 0 and csv_len < csv_buf.len) {
                        csv_buf[csv_len] = ',';
                        csv_len += 1;
                    }
                    const to_copy: usize = @min(s.len, csv_buf.len - csv_len);
                    if (to_copy > 0) @memcpy(csv_buf[csv_len .. csv_len + to_copy], s[0..to_copy]);
                    csv_len += to_copy;
                }
                if (csv_len > 0) {
                    _ = ffi.coord_set_declared_affinities(&token, 16, &csv_buf, @intCast(csv_len));
                }
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

        // Optional Task #15 fields: confidence, dispatch_preference, task_difficulty.
        const confidence: i32 = blk: {
            const v = parsed.value.object.get("confidence") orelse break :blk -1;
            // Accept either a float in 0..1 or a percentage 0..100.
            switch (v) {
                .float => |f| break :blk @intFromFloat(@min(@max(f * 100.0, 0.0), 100.0)),
                .integer => |i| break :blk @intCast(i),
                else => break :blk -1,
            }
        };
        const dispatch_pref: i32 = blk: {
            const v = parsed.value.object.get("dispatch_preference") orelse break :blk -1;
            const s = v.string;
            if (std.mem.eql(u8, s, "deliberate")) break :blk 0;
            if (std.mem.eql(u8, s, "broadcast")) break :blk 1;
            if (std.mem.eql(u8, s, "auto")) break :blk 2;
            break :blk -1;
        };
        const difficulty: i32 = blk: {
            const v = parsed.value.object.get("task_difficulty") orelse break :blk -1;
            const s = v.string;
            if (std.mem.eql(u8, s, "trivial")) break :blk 0;
            if (std.mem.eql(u8, s, "routine")) break :blk 1;
            if (std.mem.eql(u8, s, "challenging")) break :blk 2;
            if (std.mem.eql(u8, s, "novel")) break :blk 3;
            break :blk -1;
        };

        const result = ffi.coord_claim_task_ex(
            &token, 16, task.string.ptr, @intCast(task.string.len),
            confidence, dispatch_pref, difficulty,
        );
        if (result == 0) return .{ .status = 200, .body = okJson(resp, "granted") };
        if (result == 1) return .{ .status = 200, .body = errJson(resp, "held") };
        if (result == -5) return .{ .status = 429, .body = errJson(resp, "cooldown: too many recent claim rejections for this client_kind — wait 30s") };
        return .{ .status = 500, .body = errJson(resp, "claim failed") };
    }

    // Old name accepted as alias per DD-32 backward-compat (one release).
    if (std.mem.eql(u8, tool, "coord_promote_to_master") or
        std.mem.eql(u8, tool, "coord_promote_to_supervisor"))
    {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const secret_val = parsed.value.object.get("secret") orelse return .{ .status = 400, .body = errJson(resp, "missing secret") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const secret = secret_val.string;
        const rc = ffi.coord_promote_to_master(&token, 16, secret.ptr, @intCast(secret.len));
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "promoted") };
        if (rc == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        if (rc == -2) return .{ .status = 409, .body = errJson(resp, "master already exists") };
        if (rc == -3) return .{ .status = 403, .body = errJson(resp, "master role not configured on this server") };
        if (rc == -4) return .{ .status = 403, .body = errJson(resp, "secret does not match") };
        return .{ .status = 500, .body = errJson(resp, "promotion failed") };
    }

    if (std.mem.eql(u8, tool, "coord_transfer_master")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const target_val = parsed.value.object.get("new_peer_id") orelse return .{ .status = 400, .body = errJson(resp, "missing new_peer_id") };
        const secret_val = parsed.value.object.get("secret") orelse return .{ .status = 400, .body = errJson(resp, "missing secret") };

        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const target_str = target_val.string;
        const suffix = extractSuffix(target_str) orelse return .{ .status = 400, .body = errJson(resp, "invalid new_peer_id format — expected <kind>-<4hex>[@<context>]") };
        const target_idx = ffi.coord_find_peer_by_suffix(suffix.ptr);
        if (target_idx < 0) return .{ .status = 404, .body = errJson(resp, "target peer not found") };

        const secret = secret_val.string;
        const rc = ffi.coord_transfer_master(&token, 16, target_idx, secret.ptr, @intCast(secret.len));
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "transferred") };
        if (rc == -1) return .{ .status = 401, .body = errJson(resp, "caller is not the current master") };
        if (rc == -2) return .{ .status = 404, .body = errJson(resp, "target peer not found or same as caller") };
        if (rc == -3) return .{ .status = 403, .body = errJson(resp, "secret does not match BOJ_MASTER_TOKEN") };
        if (rc == -4) return .{ .status = 403, .body = errJson(resp, "target is an apprentice — must be journeyman or master") };
        return .{ .status = 500, .body = errJson(resp, "transfer failed") };
    }

    if (std.mem.eql(u8, tool, "coord_send_gated")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const target_val = parsed.value.object.get("target") orelse return .{ .status = 400, .body = errJson(resp, "missing target") };
        const msg_val = parsed.value.object.get("message") orelse return .{ .status = 400, .body = errJson(resp, "missing message") };
        const tier_val = parsed.value.object.get("risk_tier") orelse return .{ .status = 400, .body = errJson(resp, "missing risk_tier") };

        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const target_str = target_val.string;
        var target_idx: i32 = -1;
        if (!std.mem.eql(u8, target_str, "*")) {
            const suffix = extractSuffix(target_str) orelse return .{ .status = 400, .body = errJson(resp, "invalid target format") };
            target_idx = ffi.coord_find_peer_by_suffix(suffix.ptr);
            if (target_idx < 0) return .{ .status = 404, .body = errJson(resp, "target peer not found") };
        }

        const msg = msg_val.string;
        const tier: i32 = @intCast(tier_val.integer);
        const rc = ffi.coord_send_gated(&token, 16, target_idx, msg.ptr, @intCast(msg.len), tier);

        if (rc >= 0) {
            const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"status\":\"delivered\",\"sent\":{d}}}", .{rc}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            return .{ .status = 200, .body = body_out };
        }
        if (rc < -1000) {
            const request_id: i64 = -(@as(i64, rc) + 1000);
            const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"status\":\"quarantined\",\"request_id\":{d}}}", .{request_id}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            return .{ .status = 200, .body = body_out };
        }
        if (rc == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        if (rc == -2) return .{ .status = 404, .body = errJson(resp, "target peer not found") };
        if (rc == -3) return .{ .status = 503, .body = errJson(resp, "target inbox full") };
        if (rc == -4) return .{ .status = 503, .body = errJson(resp, "quarantine queue full — spill to VeriSimDB not yet wired") };
        if (rc == -5) return .{ .status = 428, .body = errJson(resp, "no master registered — Tier 2+ from apprentice requires a master") };
        return .{ .status = 500, .body = errJson(resp, "gated send failed") };
    }

    if (std.mem.eql(u8, tool, "coord_review")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        // 32 entries max * 16 bytes per record = 512 bytes raw.
        var raw: [512]u8 = undefined;
        const count = ffi.coord_review(&token, 16, &raw, @intCast(raw.len));
        if (count < 0) return .{ .status = 403, .body = errJson(resp, "master role required") };

        var stream = std.io.fixedBufferStream(resp);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"entries\":[") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };

        var i: usize = 0;
        const cnt: usize = @intCast(count);
        while (i < cnt) : (i += 1) {
            const rec = raw[i * 16 ..][0..16];
            const rid_bytes: *const [4]u8 = rec[0..4];
            const rid: u32 = @bitCast(rid_bytes.*);
            const sender_idx: u8 = rec[4];
            const target_idx_sign: i8 = @bitCast(rec[5]);
            const risk_tier: u8 = rec[6];
            const mlen_bytes: *const [2]u8 = rec[7..9];
            const mlen: u16 = @bitCast(mlen_bytes.*);
            const preview_n: usize = @min(@as(usize, 7), @as(usize, mlen));
            const preview = rec[9 .. 9 + preview_n];

            if (i > 0) w.writeAll(",") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            // sender_idx = 0xFE indicates a server-origin (engine-generated)
            // entry from coord_scan_suggestions (Task #14).
            const origin: []const u8 = if (sender_idx == 0xFE) "server-engine" else "peer";
            std.fmt.format(w, "{{\"request_id\":{d},\"origin\":\"{s}\",\"sender_idx\":{d},\"target_idx\":{d},\"risk_tier\":{d},\"msg_len\":{d},\"preview\":\"{s}\"}}", .{
                rid, origin, sender_idx, target_idx_sign, risk_tier, mlen, preview,
            }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        }
        w.writeAll("]}") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = resp[0..stream.pos] };
    }

    if (std.mem.eql(u8, tool, "coord_review_entry")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const rid_val = parsed.value.object.get("request_id") orelse return .{ .status = 400, .body = errJson(resp, "missing request_id") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        var msg_buf: [512]u8 = undefined;
        const rc = ffi.coord_review_entry(&token, 16, @intCast(rid_val.integer), &msg_buf, @intCast(msg_buf.len));
        if (rc == -1) return .{ .status = 403, .body = errJson(resp, "master role required") };
        if (rc == -2) return .{ .status = 404, .body = errJson(resp, "request_id not found") };
        if (rc < 0) return .{ .status = 500, .body = errJson(resp, "review failed") };

        const msg_slice = msg_buf[0..@intCast(rc)];
        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"message\":\"{s}\"}}", .{msg_slice}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_approve")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const rid_val = parsed.value.object.get("request_id") orelse return .{ .status = 400, .body = errJson(resp, "missing request_id") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const rc = ffi.coord_approve(&token, 16, @intCast(rid_val.integer));
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "approved") };
        if (rc == -1) return .{ .status = 403, .body = errJson(resp, "master role required") };
        if (rc == -2) return .{ .status = 404, .body = errJson(resp, "request_id not found") };
        if (rc == -3) return .{ .status = 503, .body = errJson(resp, "target inbox full — retry") };
        return .{ .status = 500, .body = errJson(resp, "approve failed") };
    }

    if (std.mem.eql(u8, tool, "coord_report_outcome")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const tag_val = parsed.value.object.get("tag") orelse return .{ .status = 400, .body = errJson(resp, "missing tag") };
        const outcome_val = parsed.value.object.get("outcome") orelse return .{ .status = 400, .body = errJson(resp, "missing outcome") };
        const tier_val = parsed.value.object.get("risk_tier") orelse return .{ .status = 400, .body = errJson(resp, "missing risk_tier") };
        // duration_ms is optional; default 0.
        const duration_val: i64 = blk: {
            const v = parsed.value.object.get("duration_ms") orelse break :blk 0;
            break :blk v.integer;
        };
        // confidence is optional; accept 0..1 float or 0..100 integer, -1 if absent.
        const confidence: i32 = blk: {
            const v = parsed.value.object.get("confidence") orelse break :blk -1;
            switch (v) {
                .float => |f| break :blk @intFromFloat(@min(@max(f * 100.0, 0.0), 100.0)),
                .integer => |i| break :blk @intCast(i),
                else => break :blk -1,
            }
        };

        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const tag_str = tag_val.string;
        if (tag_str.len > 64) return .{ .status = 400, .body = errJson(resp, "tag exceeds 64 bytes") };

        // outcome may arrive as string ("success"/"fail") or integer (0/1).
        var outcome: i32 = -1;
        switch (outcome_val) {
            .string => |s| {
                if (std.mem.eql(u8, s, "success")) outcome = 1;
                if (std.mem.eql(u8, s, "fail")) outcome = 0;
            },
            .integer => |i| outcome = @intCast(i),
            else => {},
        }
        if (outcome != 0 and outcome != 1) return .{ .status = 400, .body = errJson(resp, "outcome must be 'success'/'fail' or 0/1") };

        const tier: i32 = @intCast(tier_val.integer);
        const duration: i32 = @intCast(duration_val);
        const rc = ffi.coord_report_outcome(&token, 16, tag_str.ptr, @intCast(tag_str.len), outcome, duration, tier, confidence);
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "recorded") };
        if (rc == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        if (rc == -2) return .{ .status = 400, .body = errJson(resp, "invalid args") };
        return .{ .status = 500, .body = errJson(resp, "report failed") };
    }

    if (std.mem.eql(u8, tool, "coord_set_declared_affinities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const tags_val = parsed.value.object.get("tags") orelse return .{ .status = 400, .body = errJson(resp, "missing tags") };
        if (tags_val != .array) return .{ .status = 400, .body = errJson(resp, "tags must be an array of strings") };

        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        var csv_buf: [256]u8 = undefined;
        var csv_len: usize = 0;
        for (tags_val.array.items) |item| {
            if (item != .string) continue;
            const s = item.string;
            if (csv_len > 0 and csv_len < csv_buf.len) {
                csv_buf[csv_len] = ',';
                csv_len += 1;
            }
            const to_copy: usize = @min(s.len, csv_buf.len - csv_len);
            if (to_copy > 0) @memcpy(csv_buf[csv_len .. csv_len + to_copy], s[0..to_copy]);
            csv_len += to_copy;
        }

        const rc = ffi.coord_set_declared_affinities(&token, 16, &csv_buf, @intCast(csv_len));
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "declared") };
        if (rc == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        if (rc == -2) return .{ .status = 400, .body = errJson(resp, "declared affinities CSV too long") };
        return .{ .status = 500, .body = errJson(resp, "set failed") };
    }

    if (std.mem.eql(u8, tool, "coord_scan_suggestions")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const n = ffi.coord_scan_suggestions(&token, 16);
        if (n == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        const body_out = std.fmt.bufPrint(resp, "{{\"success\":true,\"suggestions_queued\":{d},\"hint\":\"use coord_review to inspect, coord_approve/coord_reject to act\"}}", .{n}) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = body_out };
    }

    if (std.mem.eql(u8, tool, "coord_get_affinities")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        // Up to 64 aggregates * 64 bytes = 4096 bytes.
        var raw: [4096]u8 = undefined;
        const n = ffi.coord_get_affinities(&token, 16, &raw, @intCast(raw.len));
        if (n == -1) return .{ .status = 401, .body = errJson(resp, "unauthenticated") };
        if (n < -1000) return .{ .status = 500, .body = errJson(resp, "affinity buffer overflow — too many distinct (kind, tag) pairs") };
        if (n < 0) return .{ .status = 500, .body = errJson(resp, "affinity query failed") };

        var stream = std.io.fixedBufferStream(resp);
        const w = stream.writer();
        w.writeAll("{\"success\":true,\"affinities\":[") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };

        const REC_SIZE: usize = 64;
        const cnt: usize = @intCast(n);
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const rec = raw[i * REC_SIZE ..][0..REC_SIZE];
            const kind: u8 = rec[0];
            const attempts: u16 = @bitCast([2]u8{ rec[1], rec[2] });
            const successes: u16 = @bitCast([2]u8{ rec[3], rec[4] });
            const pct: u8 = rec[5];
            const tag_len: u8 = rec[6];
            const tag = rec[7 .. 7 + @min(@as(usize, tag_len), 57)];

            if (i > 0) w.writeAll(",") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };

            // affinity as decimal; 255 sentinel means no data.
            if (pct == 255) {
                std.fmt.format(w,
                    "{{\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity\":null}}",
                    .{ kindName(@intCast(kind)), tag, attempts, successes }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            } else {
                std.fmt.format(w,
                    "{{\"client_kind\":\"{s}\",\"tag\":\"{s}\",\"attempts\":{d},\"successes\":{d},\"effective_affinity\":{d}.{d:0>2}}}",
                    .{ kindName(@intCast(kind)), tag, attempts, successes, pct / 100, pct % 100 }) catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
            }
        }
        w.writeAll("]}") catch return .{ .status = 500, .body = errJson(resp, "buffer overflow") };
        return .{ .status = 200, .body = resp[0..stream.pos] };
    }

    if (std.mem.eql(u8, tool, "coord_reject")) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .{ .status = 400, .body = errJson(resp, "invalid json") };
        defer parsed.deinit();
        const token_val = parsed.value.object.get("token") orelse return .{ .status = 400, .body = errJson(resp, "missing token") };
        const rid_val = parsed.value.object.get("request_id") orelse return .{ .status = 400, .body = errJson(resp, "missing request_id") };
        const reason_val = parsed.value.object.get("reason") orelse return .{ .status = 400, .body = errJson(resp, "missing reason") };
        var token: [16]u8 = undefined;
        if (!parseToken(token_val.string, &token)) return .{ .status = 400, .body = errJson(resp, "invalid token hex") };

        const reason = reason_val.string;
        const rc = ffi.coord_reject(&token, 16, @intCast(rid_val.integer), reason.ptr, @intCast(reason.len));
        if (rc == 0) return .{ .status = 200, .body = okJson(resp, "rejected") };
        if (rc == -1) return .{ .status = 403, .body = errJson(resp, "master role required") };
        if (rc == -2) return .{ .status = 404, .body = errJson(resp, "request_id not found") };
        return .{ .status = 500, .body = errJson(resp, "reject failed") };
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
        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
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
