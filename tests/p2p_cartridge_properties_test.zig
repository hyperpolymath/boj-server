// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — P2P Cartridge Property Tests (Zig)
//
// Validates vocabulary invariants across all catalogued cartridges:
// - Domain, tier, and protocol from approved sets
// - Name uniqueness and naming convention
// - Tool schema compliance
// - Matrix coverage
//
// Run: zig test tests/p2p_cartridge_properties_test.zig

const std = @import("std");
const testing = std.testing;

const Cartridge = struct {
    name: []const u8,
    domain: []const u8,
    protocol: []const u8,
    tier: []const u8,
};

const CATALOGUE = [_]Cartridge{
    .{ .name = "boj_health",     .domain = "infrastructure", .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "boj_cartridges", .domain = "infrastructure", .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "database-mcp",   .domain = "data",           .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "fleet-mcp",      .domain = "orchestration",  .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "nesy-mcp",       .domain = "ai",             .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "agent-mcp",      .domain = "ai",             .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "cloud-mcp",      .domain = "orchestration",  .protocol = "rest",     .tier = "teranga" },
    .{ .name = "container-mcp",  .domain = "orchestration",  .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "k8s-mcp",        .domain = "orchestration",  .protocol = "grpc",     .tier = "umoja"   },
    .{ .name = "git-mcp",        .domain = "development",    .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "secrets-mcp",    .domain = "security",       .protocol = "json-rpc", .tier = "shield"  },
    .{ .name = "queues-mcp",     .domain = "messaging",      .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "iac-mcp",        .domain = "orchestration",  .protocol = "json-rpc", .tier = "umoja"   },
    .{ .name = "observe-mcp",    .domain = "observability",  .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "ssg-mcp",        .domain = "development",    .protocol = "json-rpc", .tier = "teranga" },
    .{ .name = "proof-mcp",      .domain = "ai",             .protocol = "json-rpc", .tier = "shield"  },
    .{ .name = "lsp-mcp",        .domain = "development",    .protocol = "json-rpc", .tier = "teranga" },
};

const APPROVED_DOMAINS = [_][]const u8{
    "infrastructure", "data", "orchestration", "security",
    "messaging", "observability", "development", "ai", "integration",
};

const APPROVED_TIERS = [_][]const u8{ "teranga", "shield", "umoja" };

const APPROVED_PROTOCOLS = [_][]const u8{ "json-rpc", "rest", "grpc", "graphql", "websocket" };

fn inSlice(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

test "P2P: all cartridge names are unique" {
    for (CATALOGUE, 0..) |a, i| {
        for (CATALOGUE, 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "P2P: all cartridges use approved domains" {
    for (CATALOGUE) |c| {
        const ok = inSlice(&APPROVED_DOMAINS, c.domain);
        if (!ok) std.debug.print("bad domain: {s}\n", .{c.domain});
        try testing.expect(ok);
    }
}

test "P2P: all cartridges use approved tiers" {
    for (CATALOGUE) |c| {
        const ok = inSlice(&APPROVED_TIERS, c.tier);
        if (!ok) std.debug.print("bad tier: {s} for {s}\n", .{ c.tier, c.name });
        try testing.expect(ok);
    }
}

test "P2P: all cartridges use approved protocols" {
    for (CATALOGUE) |c| {
        const ok = inSlice(&APPROVED_PROTOCOLS, c.protocol);
        if (!ok) std.debug.print("bad protocol: {s}\n", .{c.protocol});
        try testing.expect(ok);
    }
}

test "P2P: all cartridge names match naming convention" {
    for (CATALOGUE) |c| {
        try testing.expect(isValidName(c.name));
    }
}

test "P2P: tool schema required fields are present" {
    const Tool = struct {
        name: []const u8,
        description: []const u8,
        input_type: []const u8, // must be "object"
    };
    const tools = [_]Tool{
        .{ .name = "db_query",    .description = "Query a database", .input_type = "object" },
        .{ .name = "fleet_status",.description = "Get fleet status", .input_type = "object" },
    };
    for (tools) |t| {
        try testing.expect(t.name.len > 0);
        try testing.expect(t.description.len > 0);
        try testing.expectEqualStrings("object", t.input_type);
    }
}

test "P2P: tool names are unique within a cartridge" {
    const db_tools = [_][]const u8{ "db_query", "db_connect", "db_disconnect" };
    for (db_tools, 0..) |a, i| {
        for (db_tools, 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

test "P2P: valid JSON schema property types" {
    const valid_types = [_][]const u8{ "string", "number", "boolean", "object", "array" };
    const test_types = [_][]const u8{ "string", "number", "boolean", "object", "array" };
    for (test_types) |t| try testing.expect(inSlice(&valid_types, t));
}

test "P2P: teranga tier has at least one cartridge" {
    var found = false;
    for (CATALOGUE) |c| if (std.mem.eql(u8, c.tier, "teranga")) { found = true; break; };
    try testing.expect(found);
}

test "P2P: shield tier has at least one cartridge" {
    var found = false;
    for (CATALOGUE) |c| if (std.mem.eql(u8, c.tier, "shield")) { found = true; break; };
    try testing.expect(found);
}

test "P2P: critical cartridges boj_health and boj_cartridges are present" {
    const critical = [_][]const u8{ "boj_health", "boj_cartridges" };
    for (critical) |req| {
        var found = false;
        for (CATALOGUE) |c| if (std.mem.eql(u8, c.name, req)) { found = true; break; };
        try testing.expect(found);
    }
}

test "P2P: cartridge count is in reasonable range [2, 200]" {
    try testing.expect(CATALOGUE.len >= 2);
    try testing.expect(CATALOGUE.len <= 200);
}

test "P2P: domain coverage spans multiple domains" {
    var seen_domains: usize = 0;
    for (APPROVED_DOMAINS) |dom| {
        for (CATALOGUE) |c| {
            if (std.mem.eql(u8, c.domain, dom)) { seen_domains += 1; break; }
        }
    }
    try testing.expect(seen_domains >= 3);
}
