// SPDX-License-Identifier: MPL-2.0
// Hesiod DNS Cartridge — MCP Server adapter for DNS lookups

import { Server } from "https://esm.sh/@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
  TextContent,
  ToolUseBlock,
} from "https://esm.sh/@modelcontextprotocol/sdk/types.js";

// Import Zig FFI bindings
// In real implementation, would load compiled .wasm or .so
const FFI = {
  lookup: async (hostname: string, rectype: number): Promise<any> => {
    // Placeholder: would call Zig FFI via Deno.ffi
    return { success: true, records: [] };
  },
  reverseLookup: async (address: string): Promise<any> => {
    return { success: true, hostname: "" };
  },
  bulkLookup: async (
    hostnames: string[],
    rectype: number
  ): Promise<any[]> => {
    return hostnames.map(() => ({ success: true, records: [] }));
  },
};

// MCP tool definitions
const TOOLS: Tool[] = [
  {
    name: "dns_lookup",
    description:
      "Query DNS records for a hostname (A, AAAA, CNAME, MX, NS, TXT, SRV)",
    inputSchema: {
      type: "object" as const,
      properties: {
        hostname: {
          type: "string",
          description: "Domain name to query",
        },
        record_type: {
          type: "string",
          enum: ["A", "AAAA", "CNAME", "MX", "NS", "SOA", "TXT", "SRV"],
          description: "DNS record type to retrieve",
        },
        timeout_seconds: {
          type: "number",
          description: "Query timeout in seconds (default: 5)",
          default: 5,
        },
      },
      required: ["hostname", "record_type"],
    },
  },
  {
    name: "dns_reverse_lookup",
    description: "Reverse DNS lookup — resolve IP address to hostname",
    inputSchema: {
      type: "object" as const,
      properties: {
        address: {
          type: "string",
          description: "IPv4 or IPv6 address to reverse lookup",
        },
        timeout_seconds: {
          type: "number",
          description: "Query timeout in seconds (default: 5)",
          default: 5,
        },
      },
      required: ["address"],
    },
  },
  {
    name: "dns_bulk_lookup",
    description:
      "Batch DNS lookups for multiple hostnames (same record type)",
    inputSchema: {
      type: "object" as const,
      properties: {
        hostnames: {
          type: "array",
          items: { type: "string" },
          description: "List of domains to query",
        },
        record_type: {
          type: "string",
          enum: ["A", "AAAA", "CNAME", "MX", "NS", "SOA", "TXT", "SRV"],
          description: "DNS record type for all lookups",
        },
        timeout_seconds: {
          type: "number",
          description: "Per-query timeout in seconds (default: 5)",
          default: 5,
        },
      },
      required: ["hostnames", "record_type"],
    },
  },
];

async function handleDNSLookup(args: Record<string, unknown>): Promise<string> {
  const hostname = String(args.hostname);
  const recordType = String(args.record_type || "A");

  const result = await FFI.lookup(hostname, recordTypeToCode(recordType));
  return JSON.stringify(result, null, 2);
}

async function handleReverseLookup(
  args: Record<string, unknown>
): Promise<string> {
  const address = String(args.address);
  const result = await FFI.reverseLookup(address);
  return JSON.stringify(result, null, 2);
}

async function handleBulkLookup(args: Record<string, unknown>): Promise<string> {
  const hostnames = Array.isArray(args.hostnames)
    ? args.hostnames.map(String)
    : [];
  const recordType = String(args.record_type || "A");

  const results = await FFI.bulkLookup(hostnames, recordTypeToCode(recordType));
  return JSON.stringify(results, null, 2);
}

function recordTypeToCode(type: string): number {
  const codes: Record<string, number> = {
    A: 0,
    AAAA: 1,
    CNAME: 2,
    MX: 3,
    NS: 4,
    SOA: 5,
    TXT: 6,
    SRV: 7,
  };
  return codes[type] || 0;
}

// Initialize MCP server
const server = new Server({
  name: "hesiod-mcp",
  version: "1.0.0",
});

// Register tool handlers
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: TOOLS };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request;

  let result: string;
  if (name === "dns_lookup") {
    result = await handleDNSLookup(args as Record<string, unknown>);
  } else if (name === "dns_reverse_lookup") {
    result = await handleReverseLookup(args as Record<string, unknown>);
  } else if (name === "dns_bulk_lookup") {
    result = await handleBulkLookup(args as Record<string, unknown>);
  } else {
    return {
      content: [
        {
          type: "text" as const,
          text: `Unknown tool: ${name}`,
        },
      ],
      isError: true,
    };
  }

  return {
    content: [
      {
        type: "text" as const,
        text: result,
      },
    ],
  };
});

// Start server on loopback
const port = 5173;
await server.connect(new WebSocket(`ws://127.0.0.1:${port}`));
console.log("Hesiod DNS MCP server running on ws://127.0.0.1:5173");
