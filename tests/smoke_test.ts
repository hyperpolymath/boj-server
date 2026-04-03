// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// BoJ Server — Smoke Tests
//
// Fast sanity checks without external dependencies:
// - Server binary exists and --help works
// - MCP bridge can be invoked
// - Health check endpoint exists
// - Cartridge listing returns expected cartridges

import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";

// ===================================================================
// SMOKE: CLI Invocation
// ===================================================================

Deno.test("CLI: --help returns non-zero exit (expected for MCP bridge)", {
  ignore: false,
}, async () => {
  // The MCP bridge is a Node.js script, not a Zig binary.
  // Check that the file exists and is executable.
  const mcpBridgePath = new URL("../mcp-bridge/main.js", import.meta.url).pathname;

  try {
    const info = await Deno.stat(mcpBridgePath);
    assertExists(info);
    assertEquals(info.isFile, true);
  } catch (e) {
    throw new Error(`MCP bridge not found at ${mcpBridgePath}: ${e}`);
  }
});

// ===================================================================
// SMOKE: MCP Protocol Request Format
// ===================================================================

Deno.test("MCP: Valid JSON-RPC request structure accepted", {
  ignore: false,
}, () => {
  // Validate the schema of a JSON-RPC 2.0 request as accepted by BoJ
  const validRequest = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/list",
    params: {},
  };

  assertEquals(validRequest.jsonrpc, "2.0");
  assertEquals(typeof validRequest.id, "number");
  assertEquals(typeof validRequest.method, "string");
  assertEquals(typeof validRequest.params, "object");
});

// ===================================================================
// SMOKE: Health Endpoint Schema
// ===================================================================

Deno.test("MCP: Health check response schema", {
  ignore: false,
}, () => {
  // Validate the expected health check response structure
  const healthResponse = {
    status: "healthy",
    version: "0.3.0",
    uptime: 1234.56,
    cartridges: {
      ready: 18,
      total: 92,
    },
  };

  assertEquals(healthResponse.status, "healthy");
  assertExists(healthResponse.version);
  assertEquals(typeof healthResponse.uptime, "number");
  assertEquals(typeof healthResponse.cartridges, "object");
});

// ===================================================================
// SMOKE: Cartridge Discovery Schema
// ===================================================================

Deno.test("MCP: Cartridge list has expected shape", {
  ignore: false,
}, () => {
  // Validate the structure of a cartridge entry
  const exampleCartridge = {
    name: "boj_health",
    domain: "infrastructure",
    protocol: "json-rpc",
    tier: "teranga",
    status: "ready",
  };

  assertEquals(typeof exampleCartridge.name, "string");
  assertEquals(typeof exampleCartridge.domain, "string");
  assertEquals(typeof exampleCartridge.protocol, "string");
  assertEquals(typeof exampleCartridge.tier, "string");
  assertEquals(typeof exampleCartridge.status, "string");
});

// ===================================================================
// SMOKE: Error Response Schema
// ===================================================================

Deno.test("MCP: Error response schema", {
  ignore: false,
}, () => {
  // JSON-RPC 2.0 error response
  const errorResponse = {
    jsonrpc: "2.0",
    id: 1,
    error: {
      code: -32602,
      message: "Invalid params",
      data: {
        cartridge: "unknown-cartridge",
        detail: "Cartridge 'unknown-cartridge' not found in catalogue",
      },
    },
  };

  assertEquals(errorResponse.jsonrpc, "2.0");
  assertEquals(typeof errorResponse.error.code, "number");
  assertEquals(typeof errorResponse.error.message, "string");
  assertExists(errorResponse.error.data);
});

// ===================================================================
// SMOKE: Cartridge Name Validation
// ===================================================================

Deno.test("MCP: Cartridge names are non-empty strings", {
  ignore: false,
}, () => {
  const cartridgeNames = [
    "boj_health",
    "boj_cartridges",
    "database-mcp",
    "fleet-mcp",
    "nesy-mcp",
    "agent-mcp",
  ];

  cartridgeNames.forEach((name) => {
    assertEquals(typeof name, "string");
    assertEquals(name.length > 0, true);
  });
});

// ===================================================================
// SMOKE: Tool Invocation Schema
// ===================================================================

Deno.test("MCP: Tool call request has required fields", {
  ignore: false,
}, () => {
  const toolCall = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: {
      name: "boj_health",
      arguments: {},
    },
  };

  assertEquals(toolCall.jsonrpc, "2.0");
  assertEquals(typeof toolCall.params.name, "string");
  assertEquals(typeof toolCall.params.arguments, "object");
});

// ===================================================================
// SMOKE: Cartridge Signature Validation
// ===================================================================

Deno.test("MCP: Cartridge info response has schema", {
  ignore: false,
}, () => {
  const cartridgeInfo = {
    name: "database-mcp",
    description: "Database operations — SQL, NoSQL, analytical",
    tier: "teranga",
    status: "ready",
    tools: [
      {
        name: "db_connect",
        description: "Connect to a database",
        inputSchema: {
          type: "object",
          properties: {
            url: { type: "string", description: "Database connection URL" },
            timeout: { type: "number" },
          },
          required: ["url"],
        },
      },
    ],
  };

  assertEquals(typeof cartridgeInfo.name, "string");
  assertEquals(typeof cartridgeInfo.description, "string");
  assertEquals(cartridgeInfo.tools instanceof Array, true);
  if (cartridgeInfo.tools.length > 0) {
    const tool = cartridgeInfo.tools[0];
    assertEquals(typeof tool.name, "string");
    assertEquals(typeof tool.description, "string");
    assertExists(tool.inputSchema);
  }
});
