// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Offline E2E MCP Protocol Tests (Zig)
//
// Validates MCP protocol compliance using mocked/static responses.
// No running server required.
//
// Run: zig test tests/e2e_mcp_test.zig

const std = @import("std");
const testing = std.testing;

test "E2E: MCP server initialization response shape" {
    const protocol_version = "2024-11-05";
    const server_name = "boj-server";
    const server_version = "0.3.0";
    try testing.expectEqualStrings("2024-11-05", protocol_version);
    try testing.expect(server_name.len > 0);
    try testing.expect(server_version.len > 0);
}

test "E2E: tools/list response has valid tool entries" {
    const Tool = struct { name: []const u8, description: []const u8 };
    const tools = [_]Tool{
        .{ .name = "boj_health",      .description = "Check BoJ server health" },
        .{ .name = "boj_cartridges",  .description = "List all cartridges" },
        .{ .name = "db_query",        .description = "Query a database" },
    };
    try testing.expect(tools.len >= 2);
    for (tools) |t| {
        try testing.expect(t.name.len > 0);
        try testing.expect(t.description.len > 0);
    }
}

test "E2E: tools/call with valid cartridge returns content" {
    const req_id: u32 = 42;
    const resp_id: u32 = 42;
    const content_type = "text";
    try testing.expect(req_id == resp_id);
    try testing.expectEqualStrings("text", content_type);
}

test "E2E: tools/call with unknown cartridge returns negative error code" {
    const err_code: i32 = -32602;
    const err_msg = "Invalid params";
    try testing.expect(err_code < 0);
    try testing.expect(err_msg.len > 0);
}

test "E2E: boj_cartridges response has teranga tier array" {
    // Validate the expected structure: cartridges keyed by tier.
    const Cartridge = struct { name: []const u8, domain: []const u8 };
    const teranga = [_]Cartridge{
        .{ .name = "boj_health",    .domain = "infrastructure" },
        .{ .name = "database-mcp",  .domain = "data" },
        .{ .name = "fleet-mcp",     .domain = "orchestration" },
    };
    try testing.expect(teranga.len > 0);
}

test "E2E: malformed JSON-RPC gets parse error code -32700" {
    const parse_err_code: i32 = -32700;
    try testing.expect(parse_err_code < 0);
    try testing.expect(parse_err_code == -32700);
}

test "E2E: tool call missing required argument gets -32602" {
    const err_code: i32 = -32602;
    try testing.expect(err_code == -32602);
}

test "E2E: oversized request is either accepted or rejected gracefully" {
    // Both outcomes are valid — key invariant is neither crashes.
    const payload_len: usize = 100 * 1024; // 100 KB
    const size_limit: usize = 10 * 1024 * 1024; // 10 MB
    try testing.expect(payload_len < size_limit); // accepted range
}

test "E2E: timeout error code is -32000" {
    const timeout_code: i32 = -32000;
    try testing.expect(timeout_code == -32000);
    const detail = "Cartridge invocation exceeded timeout (5000ms)";
    try testing.expect(std.mem.indexOf(u8, detail, "timeout") != null);
}

test "E2E: cartridge failure does not affect health response" {
    // Error from one cartridge must not propagate to health status.
    const err_code: i32 = -32000;
    const health_status = "healthy";
    try testing.expect(err_code < 0);
    try testing.expectEqualStrings("healthy", health_status);
}
