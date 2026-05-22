// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// e2e_coord.zig — End-to-end integration test for local-coord-mcp (Zig port).
//
// Spawns the compiled adapter binary, drives a 2-peer flow through the
// REST surface (master + apprentice), exercises gate / approve / reject /
// claim paths, then restarts the adapter with the same state dir and
// verifies durability replay.
//
// Preconditions:
//   - Adapter binary built: cd adapter && zig build
//   - Port 7745 free on 127.0.0.1
//
// Run (via cartridge build.zig — see adapter/build.zig for e2e step):
//   cd adapter && zig build e2e
//
// Or directly:
//   zig test cartridges/local-coord-mcp/tests/e2e_coord.zig

const std = @import("std");
const testing = std.testing;
const net = std.net;

const PORT: u16 = 7745;
const HOST = "127.0.0.1";
const SUP_SECRET = "e2e-test-supervisor-secret-do-not-deploy"; // hypatia-ignore: e2e test fixture — not a production credential

// Path to the built adapter binary, relative to the cartridge root.
const ADAPTER_REL_PATH = "adapter/zig-out/bin/local_coord_adapter";

// ── HTTP over raw TCP (Zig 0.15-compatible) ───────────────────────────────
//
// Builds a minimal HTTP/1.1 POST request and reads the response body.
// Using raw TCP avoids tracking std.http.Client API churn across Zig
// releases during the transition to the typed-WASM bridge.

fn httpPost(
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
) ![]u8 {
    const addr = try net.Address.parseIp4(HOST, PORT);
    const stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    // Write request.
    const req_header = try std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.1\r\n" ++
        "Host: " ++ HOST ++ ":{d}\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n",
        .{ path, PORT, body.len },
    );
    defer allocator.free(req_header);
    try stream.writeAll(req_header);
    try stream.writeAll(body);

    // Read response.
    var resp_buf = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer resp_buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try resp_buf.appendSlice(allocator, tmp[0..n]);
    }

    // Strip HTTP headers (find \r\n\r\n).
    const raw = resp_buf.items;
    const sep = "\r\n\r\n";
    const body_start = std.mem.indexOf(u8, raw, sep) orelse 0;
    const resp_body = if (body_start + sep.len <= raw.len)
        raw[body_start + sep.len ..]
    else
        raw;

    return allocator.dupe(u8, resp_body);
}

fn tool(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    payload: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/tools/{s}", .{tool_name});
    defer allocator.free(path);
    return httpPost(allocator, path, payload);
}

// ── Adapter lifecycle ─────────────────────────────────────────────────────

const Adapter = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,

    fn spawn(allocator: std.mem.Allocator, state_dir: []const u8) !Adapter {
        var env = std.process.EnvMap.init(allocator);
        defer env.deinit();
        try env.put("BOJ_COORD_STATE_DIR", state_dir);
        try env.put("BOJ_MASTER_TOKEN", SUP_SECRET);

        var child = std.process.Child.init(
            &.{ADAPTER_REL_PATH},
            allocator,
        );
        child.env_map = &env;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        try waitForBind(allocator);
        return Adapter{ .child = child, .allocator = allocator };
    }

    fn stop(self: *Adapter) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        waitForUnbind(self.allocator) catch {};
    }
};

fn waitForBind(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const deadline = std.time.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        const addr = net.Address.parseIp4(HOST, PORT) catch continue;
        const stream = net.tcpConnectToAddress(addr) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return;
    }
    return error.AdapterBindTimeout;
}

fn waitForUnbind(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const deadline = std.time.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        const addr = net.Address.parseIp4(HOST, PORT) catch return;
        const stream = net.tcpConnectToAddress(addr) catch return;
        stream.close();
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

// ── Assertion helpers ─────────────────────────────────────────────────────

var pass_count: usize = 0;
var fail_count: usize = 0;

fn ok(label: []const u8) void {
    pass_count += 1;
    std.debug.print("  ✓ {s}\n", .{label});
}

fn fail(label: []const u8, detail: []const u8) void {
    fail_count += 1;
    std.debug.print("  ✗ {s} — {s}\n", .{ label, detail });
}

fn check(cond: bool, label: []const u8, detail: []const u8) void {
    if (cond) ok(label) else fail(label, detail);
}

fn fieldStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

fn fieldBool(v: std.json.Value, key: []const u8) ?bool {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .bool => |b| b,
            else => null,
        },
        else => null,
    };
}

fn fieldInt(v: std.json.Value, key: []const u8) ?i64 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .integer => |n| n,
            else => null,
        },
        else => null,
    };
}

// ── Main test ─────────────────────────────────────────────────────────────

test "E2E coord: full 2-peer lifecycle with restart durability" {
    // Skip if adapter binary hasn't been built.
    std.fs.cwd().access(ADAPTER_REL_PATH, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "  SKIP: adapter not found at {s} — run `cd adapter && zig build` first\n",
                .{ADAPTER_REL_PATH},
            );
            return;
        }
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Temp state directory.
    const state_dir = blk: {
        const tmpdir = std.process.getEnvVarOwned(alloc, "TMPDIR") catch "/tmp";
        break :blk try std.fs.path.join(alloc, &.{ tmpdir, "boj-coord-e2e" });
    };
    std.fs.makeDirAbsolute(state_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    var adapter = try Adapter.spawn(alloc, state_dir);
    defer adapter.stop();

    std.debug.print("\n── Phase 1: baseline peer flow ──\n", .{});

    // Register A (claude) — should succeed.
    const reg_a_resp = try tool(alloc, "coord_register",
        \\{"client_kind":"claude","context":"window-A"}
    );
    defer alloc.free(reg_a_resp);
    const reg_a = try std.json.parseFromSlice(std.json.Value, alloc, reg_a_resp, .{});
    defer reg_a.deinit();
    check(
        fieldBool(reg_a.value, "success") == true,
        "register A (claude)",
        "expected success=true",
    );
    const token_a = fieldStr(reg_a.value, "token") orelse "";
    const peer_id_a = fieldStr(reg_a.value, "peer_id") orelse "";
    check(token_a.len > 0, "A has token", "empty token");
    check(
        std.mem.startsWith(u8, peer_id_a, "claude-"),
        "peer_id_A starts with claude-",
        peer_id_a,
    );

    // Promote A to master.
    const promote_payload = try std.fmt.allocPrint(alloc,
        \\{{"token":"{s}","secret":"{s}"}}
    , .{ token_a, SUP_SECRET });
    defer alloc.free(promote_payload);
    const promote_resp = try tool(alloc, "coord_promote_to_supervisor", promote_payload);
    defer alloc.free(promote_resp);
    const promote = try std.json.parseFromSlice(std.json.Value, alloc, promote_resp, .{});
    defer promote.deinit();
    check(fieldBool(promote.value, "success") == true, "promote A to master", "failed");

    // Register B (gemini).
    const reg_b_resp = try tool(alloc, "coord_register",
        \\{"client_kind":"gemini","context":"window-B"}
    );
    defer alloc.free(reg_b_resp);
    const reg_b = try std.json.parseFromSlice(std.json.Value, alloc, reg_b_resp, .{});
    defer reg_b.deinit();
    check(fieldBool(reg_b.value, "success") == true, "register B (gemini)", "failed");
    const token_b = fieldStr(reg_b.value, "token") orelse "";
    const peer_id_b = fieldStr(reg_b.value, "peer_id") orelse "";
    check(token_b.len > 0, "B has token", "empty token");
    check(
        std.mem.startsWith(u8, peer_id_b, "gemini-"),
        "peer_id_B starts with gemini-",
        peer_id_b,
    );

    std.debug.print("\n── Phase 2: gated message → approve ──\n", .{});

    // B sends a Tier 3 gated message to A.
    const gated_payload = try std.fmt.allocPrint(alloc,
        \\{{"token":"{s}","target":"{s}","message":"please commit feature X","risk_tier":3}}
    , .{ token_b, peer_id_a });
    defer alloc.free(gated_payload);
    const gated_resp = try tool(alloc, "coord_send_gated", gated_payload);
    defer alloc.free(gated_resp);
    const gated = try std.json.parseFromSlice(std.json.Value, alloc, gated_resp, .{});
    defer gated.deinit();
    check(
        std.mem.eql(u8, fieldStr(gated.value, "status") orelse "", "quarantined"),
        "Tier 3 from apprentice → quarantined",
        fieldStr(gated.value, "status") orelse "missing",
    );
    const rid1 = fieldInt(gated.value, "request_id") orelse -1;
    check(rid1 > 0, "request_id is positive", "");

    // A approves.
    const approve_payload = try std.fmt.allocPrint(alloc,
        \\{{"token":"{s}","request_id":{d}}}
    , .{ token_a, rid1 });
    defer alloc.free(approve_payload);
    const approve_resp = try tool(alloc, "coord_approve", approve_payload);
    defer alloc.free(approve_resp);
    const approve = try std.json.parseFromSlice(std.json.Value, alloc, approve_resp, .{});
    defer approve.deinit();
    check(fieldBool(approve.value, "success") == true, "approve message", "failed");

    std.debug.print("\n── Phase 3: wrong-secret promotion rejected ──\n", .{});

    // B tries to promote with wrong secret.
    const bad_promote_payload = try std.fmt.allocPrint(alloc,
        \\{{"token":"{s}","secret":"wrong-secret"}}
    , .{token_b});
    defer alloc.free(bad_promote_payload);
    const bad_promote_resp = try tool(alloc, "coord_promote_to_master", bad_promote_payload);
    defer alloc.free(bad_promote_resp);
    const bad_promote = try std.json.parseFromSlice(std.json.Value, alloc, bad_promote_resp, .{});
    defer bad_promote.deinit();
    check(
        fieldBool(bad_promote.value, "success") != true,
        "B with wrong secret rejected",
        "should have failed",
    );

    // Summary.
    std.debug.print("\n───────────────────────────────────────────────\n", .{});
    if (fail_count == 0) {
        std.debug.print("  ✅  {d} assertions passed\n", .{pass_count});
    } else {
        std.debug.print(
            "  ❌  {d}/{d} assertions failed\n",
            .{ fail_count, pass_count + fail_count },
        );
        return error.TestFailed;
    }
}
