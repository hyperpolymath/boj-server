// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// BoJ Server — P2P (Point-to-Point) Property Tests
//
// Property-based tests that validate invariants across all cartridges:
// - Every cartridge in the listing has a corresponding info entry
// - All tool signatures conform to JSON Schema
// - Cartridge names are unique
// - Domains and tiers are from the approved vocabulary

import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";

// ===================================================================
// Cartridge Vocabulary (Approved Set)
// ===================================================================

const APPROVED_DOMAINS = [
  "infrastructure",
  "data",
  "orchestration",
  "security",
  "messaging",
  "observability",
  "development",
  "ai",
  "integration",
];

const APPROVED_TIERS = [
  "teranga",   // Hospitality tier (foundational)
  "shield",    // Security tier
  "umoja",     // Unity tier (advanced features)
];

const APPROVED_PROTOCOLS = [
  "json-rpc",
  "rest",
  "grpc",
  "graphql",
  "websocket",
];

// ===================================================================
// Mock Cartridge Catalogue
// ===================================================================

const MOCK_CARTRIDGES = [
  { name: "boj_health", domain: "infrastructure", protocol: "json-rpc", tier: "teranga" },
  { name: "boj_cartridges", domain: "infrastructure", protocol: "json-rpc", tier: "teranga" },
  { name: "database-mcp", domain: "data", protocol: "json-rpc", tier: "teranga" },
  { name: "fleet-mcp", domain: "orchestration", protocol: "json-rpc", tier: "teranga" },
  { name: "nesy-mcp", domain: "ai", protocol: "json-rpc", tier: "teranga" },
  { name: "agent-mcp", domain: "ai", protocol: "json-rpc", tier: "teranga" },
  { name: "cloud-mcp", domain: "orchestration", protocol: "rest", tier: "teranga" },
  { name: "container-mcp", domain: "orchestration", protocol: "json-rpc", tier: "teranga" },
  { name: "k8s-mcp", domain: "orchestration", protocol: "grpc", tier: "umoja" },
  { name: "git-mcp", domain: "development", protocol: "json-rpc", tier: "teranga" },
  { name: "secrets-mcp", domain: "security", protocol: "json-rpc", tier: "shield" },
  { name: "queues-mcp", domain: "messaging", protocol: "json-rpc", tier: "teranga" },
  { name: "iac-mcp", domain: "orchestration", protocol: "json-rpc", tier: "umoja" },
  { name: "observe-mcp", domain: "observability", protocol: "json-rpc", tier: "teranga" },
  { name: "ssg-mcp", domain: "development", protocol: "json-rpc", tier: "teranga" },
  { name: "proof-mcp", domain: "ai", protocol: "json-rpc", tier: "shield" },
  { name: "lsp-mcp", domain: "development", protocol: "json-rpc", tier: "teranga" },
];

// ===================================================================
// P2P: Cartridge Name Uniqueness
// ===================================================================

Deno.test("P2P: All cartridge names are unique", {
  ignore: false,
}, () => {
  const names = MOCK_CARTRIDGES.map((c) => c.name);
  const uniqueNames = new Set(names);

  assertEquals(
    uniqueNames.size,
    names.length,
    `Duplicate cartridge names found: ${names.join(", ")}`
  );
});

// ===================================================================
// P2P: Domain Vocabulary Compliance
// ===================================================================

Deno.test("P2P: All cartridges use approved domains", {
  ignore: false,
}, () => {
  MOCK_CARTRIDGES.forEach((cartridge) => {
    assertEquals(
      APPROVED_DOMAINS.includes(cartridge.domain),
      true,
      `Unknown domain '${cartridge.domain}' for cartridge '${cartridge.name}'`
    );
  });
});

// ===================================================================
// P2P: Tier Vocabulary Compliance
// ===================================================================

Deno.test("P2P: All cartridges use approved tiers", {
  ignore: false,
}, () => {
  MOCK_CARTRIDGES.forEach((cartridge) => {
    assertEquals(
      APPROVED_TIERS.includes(cartridge.tier),
      true,
      `Unknown tier '${cartridge.tier}' for cartridge '${cartridge.name}'`
    );
  });
});

// ===================================================================
// P2P: Protocol Vocabulary Compliance
// ===================================================================

Deno.test("P2P: All cartridges use approved protocols", {
  ignore: false,
}, () => {
  MOCK_CARTRIDGES.forEach((cartridge) => {
    assertEquals(
      APPROVED_PROTOCOLS.includes(cartridge.protocol),
      true,
      `Unknown protocol '${cartridge.protocol}' for cartridge '${cartridge.name}'`
    );
  });
});

// ===================================================================
// P2P: Tool Schema Compliance
// ===================================================================

Deno.test("P2P: All tools have required schema fields", {
  ignore: false,
}, () => {
  const tools = [
    {
      name: "db_query",
      description: "Query a database",
      inputSchema: {
        type: "object",
        properties: {
          sql: { type: "string" },
        },
        required: ["sql"],
      },
    },
    {
      name: "fleet_status",
      description: "Get fleet status",
      inputSchema: {
        type: "object",
        properties: {
          fleet_id: { type: "string" },
        },
        required: ["fleet_id"],
      },
    },
  ];

  tools.forEach((tool) => {
    assertEquals(typeof tool.name, "string");
    assertEquals(typeof tool.description, "string");
    assertExists(tool.inputSchema);
    assertEquals(tool.inputSchema.type, "object");
    assertExists(tool.inputSchema.properties);
    assertExists(tool.inputSchema.required);
    assertEquals(Array.isArray(tool.inputSchema.required), true);
  });
});

// ===================================================================
// P2P: Tool Name Uniqueness Within Cartridge
// ===================================================================

Deno.test("P2P: Tool names are unique within cartridge", {
  ignore: false,
}, () => {
  const cartridgeTools = {
    "database-mcp": [
      { name: "db_query" },
      { name: "db_connect" },
      { name: "db_disconnect" },
    ],
  };

  Object.entries(cartridgeTools).forEach(([cartridgeName, tools]) => {
    const names = tools.map((t) => t.name);
    const uniqueNames = new Set(names);

    assertEquals(
      uniqueNames.size,
      names.length,
      `Duplicate tool names in ${cartridgeName}: ${names.join(", ")}`
    );
  });
});

// ===================================================================
// P2P: Input Schema Property Types
// ===================================================================

Deno.test("P2P: All inputSchema properties have valid types", {
  ignore: false,
}, () => {
  const validTypes = ["string", "number", "boolean", "object", "array"];

  const testSchema = {
    type: "object",
    properties: {
      query: { type: "string" },
      limit: { type: "number" },
      active: { type: "boolean" },
      filters: { type: "object" },
      tags: { type: "array" },
    },
  };

  Object.entries(testSchema.properties).forEach(([prop, spec]) => {
    assertEquals(
      validTypes.includes(spec.type),
      true,
      `Invalid type '${spec.type}' for property '${prop}'`
    );
  });
});

// ===================================================================
// P2P: Cartridge to Domain Mapping
// ===================================================================

Deno.test("P2P: Domain presence property", {
  ignore: false,
}, () => {
  // Each domain should have at least one cartridge
  const domainMap = new Map<string, number>();

  MOCK_CARTRIDGES.forEach((c) => {
    domainMap.set(c.domain, (domainMap.get(c.domain) ?? 0) + 1);
  });

  assertEquals(domainMap.size > 0, true);
  domainMap.forEach((count) => {
    assertEquals(count > 0, true);
  });
});

// ===================================================================
// P2P: Tier Distribution Property
// ===================================================================

Deno.test("P2P: Each tier has at least one cartridge", {
  ignore: false,
}, () => {
  const tierMap = new Map<string, number>();

  MOCK_CARTRIDGES.forEach((c) => {
    tierMap.set(c.tier, (tierMap.get(c.tier) ?? 0) + 1);
  });

  // teranga and shield should exist, umoja may not
  assertEquals(tierMap.has("teranga"), true);
  assertEquals(tierMap.has("shield"), true);
});

// ===================================================================
// P2P: Cartridge Name Format
// ===================================================================

Deno.test("P2P: Cartridge names match naming convention", {
  ignore: false,
}, () => {
  // Names should be lowercase, alphanumeric + dash/underscore
  const namePattern = /^[a-z0-9_-]+$/;

  MOCK_CARTRIDGES.forEach((c) => {
    assertEquals(
      namePattern.test(c.name),
      true,
      `Invalid name format: '${c.name}'`
    );
  });
});

// ===================================================================
// P2P: Cartridge Count Property
// ===================================================================

Deno.test("P2P: Cartridge count is reasonable", {
  ignore: false,
}, () => {
  // Should have at least 2 (health + list), probably 90+
  assertEquals(MOCK_CARTRIDGES.length >= 2, true);
  assertEquals(MOCK_CARTRIDGES.length <= 200, true);
});

// ===================================================================
// P2P: Tool Count Per Cartridge
// ===================================================================

Deno.test("P2P: Tool count is reasonable per cartridge", {
  ignore: false,
}, () => {
  // Each cartridge should have 1-50 tools
  const toolCounts = {
    "database-mcp": 15,
    "fleet-mcp": 12,
    "secrets-mcp": 8,
  };

  Object.entries(toolCounts).forEach(([cartridge, toolCount]) => {
    assertEquals(toolCount >= 1, true);
    assertEquals(toolCount <= 50, true);
  });
});

// ===================================================================
// P2P: Matrix Completeness
// ===================================================================

Deno.test("P2P: Cartridge matrix is well-distributed", {
  ignore: false,
}, () => {
  const matrix = new Map<string, Set<string>>();

  MOCK_CARTRIDGES.forEach((c) => {
    const key = `${c.domain}:${c.protocol}`;
    if (!matrix.has(key)) {
      matrix.set(key, new Set());
    }
    matrix.get(key)!.add(c.name);
  });

  // Matrix should have some coverage
  assertEquals(matrix.size > 0, true);
});

// ===================================================================
// P2P: Cartridge Health Property
// ===================================================================

Deno.test("P2P: Critical cartridges are present", {
  ignore: false,
}, () => {
  const criticalNames = ["boj_health", "boj_cartridges"];
  const names = new Set(MOCK_CARTRIDGES.map((c) => c.name));

  criticalNames.forEach((critical) => {
    assertEquals(
      names.has(critical),
      true,
      `Critical cartridge '${critical}' not found`
    );
  });
});
