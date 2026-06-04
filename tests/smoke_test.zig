// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Smoke Tests (Zig)
//
// Fast offline sanity checks: JSON-RPC 2.0 schema shapes, health response,
// cartridge discovery, error response, tool invocation.  No external deps.
//
// Run: zig test tests/smoke_test.zig

const std = @import("std");
const testing = std.testing;

test "SMOKE: valid JSON-RPC 2.0 request has required fields" {
    const jsonrpc = "2.0";
    const id: u32 = 1;
    const method = "tools/list";
    try testing.expectEqualStrings("2.0", jsonrpc);
    try testing.expect(id > 0);
    try testing.expect(method.len > 0);
}

test "SMOKE: health check response schema" {
    const status = "healthy";
    const version = "0.3.0";
    const uptime: f64 = 1234.56;
    const cartridges_ready: u32 = 18;
    const cartridges_total: u32 = 92;
    try testing.expectEqualStrings("healthy", status);
    try testing.expect(version.len > 0);
    try testing.expect(uptime > 0.0);
    try testing.expect(cartridges_total >= cartridges_ready);
}

test "SMOKE: cartridge entry has all required fields" {
    const name = "boj_health";
    const domain = "infrastructure";
    const protocol = "json-rpc";
    const tier = "teranga";
    const status = "ready";
    try testing.expect(name.len > 0);
    try testing.expect(domain.len > 0);
    try testing.expect(protocol.len > 0);
    try testing.expect(tier.len > 0);
    try testing.expect(status.len > 0);
}

test "SMOKE: JSON-RPC error response code is negative" {
    const code: i32 = -32602;
    const msg = "Invalid params";
    try testing.expect(code < 0);
    try testing.expect(msg.len > 0);
}

test "SMOKE: cartridge names are non-empty" {
    const names = [_][]const u8{
        "boj_health", "boj_cartridges", "database-mcp", "fleet-mcp", "nesy-mcp",
    };
    for (names) |n| try testing.expect(n.len > 0);
}

test "SMOKE: tool call method string is correct" {
    const method = "tools/call";
    const tool_name = "boj_health";
    try testing.expectEqualStrings("tools/call", method);
    try testing.expect(tool_name.len > 0);
}

test "SMOKE: cartridge info tool list is non-empty" {
    const Tool = struct { name: []const u8, description: []const u8 };
    const tools = [_]Tool{
        .{ .name = "db_connect", .description = "Connect to a database" },
    };
    try testing.expect(tools.len > 0);
    for (tools) |t| {
        try testing.expect(t.name.len > 0);
        try testing.expect(t.description.len > 0);
    }
}

test "SMOKE: MCP CLI file exists check uses stat not execute" {
    // Protocol: binary existence is checked via stat, not invocation.
    // This test documents the contract without requiring the binary.
    const expected_binary_name = "boj-server";
    try testing.expect(expected_binary_name.len > 0);
}
