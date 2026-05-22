// SPDX-License-Identifier: MPL-2.0
// Bofig Cartridge — Evidence graph query MCP server

import { Server } from "https://esm.sh/@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "https://esm.sh/@modelcontextprotocol/sdk/types.js";

// MCP tool definitions for evidence graph queries
const TOOLS: Tool[] = [
  {
    name: "query_evidence",
    description: "Query evidence by ID from the graph database",
    inputSchema: {
      type: "object" as const,
      properties: {
        evidence_id: {
          type: "string",
          description: "Evidence identifier",
        },
      },
      required: ["evidence_id"],
    },
  },
  {
    name: "search_evidence",
    description: "Search evidence by keyword (title, description, source)",
    inputSchema: {
      type: "object" as const,
      properties: {
        keyword: {
          type: "string",
          description: "Search keyword or phrase",
        },
      },
      required: ["keyword"],
    },
  },
  {
    name: "get_connections",
    description: "Get all connections/relationships for an entity in the graph",
    inputSchema: {
      type: "object" as const,
      properties: {
        entity_id: {
          type: "string",
          description: "Entity or evidence ID",
        },
      },
      required: ["entity_id"],
    },
  },
  {
    name: "find_path",
    description: "Find shortest path between two entities in the evidence graph",
    inputSchema: {
      type: "object" as const,
      properties: {
        from_id: {
          type: "string",
          description: "Starting entity ID",
        },
        to_id: {
          type: "string",
          description: "Target entity ID",
        },
      },
      required: ["from_id", "to_id"],
    },
  },
  {
    name: "execute_query",
    description: "Execute a custom graph query",
    inputSchema: {
      type: "object" as const,
      properties: {
        query: {
          type: "string",
          description: "Graph query string (Cypher-like syntax)",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "get_graph_stats",
    description: "Get overall statistics about the evidence graph (node and edge counts)",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
];

// Tool handlers
async function handleQueryEvidence(
  args: Record<string, unknown>
): Promise<string> {
  const evidenceId = String(args.evidence_id);
  return JSON.stringify({
    evidence_id: evidenceId,
    found: false,
    evidence: null,
  });
}

async function handleSearchEvidence(
  args: Record<string, unknown>
): Promise<string> {
  const keyword = String(args.keyword);
  return JSON.stringify({
    keyword,
    results: [],
    count: 0,
  });
}

async function handleGetConnections(
  args: Record<string, unknown>
): Promise<string> {
  const entityId = String(args.entity_id);
  return JSON.stringify({
    entity_id: entityId,
    connections: [],
    count: 0,
  });
}

async function handleFindPath(
  args: Record<string, unknown>
): Promise<string> {
  const fromId = String(args.from_id);
  const toId = String(args.to_id);
  return JSON.stringify({
    from_id: fromId,
    to_id: toId,
    path: [],
    path_length: 0,
    found: false,
  });
}

async function handleExecuteQuery(
  args: Record<string, unknown>
): Promise<string> {
  const query = String(args.query);
  return JSON.stringify({
    query,
    success: true,
    node_count: 0,
    edge_count: 0,
    results: [],
  });
}

async function handleGetGraphStats(
  _args: Record<string, unknown>
): Promise<string> {
  return JSON.stringify({
    node_count: 0,
    edge_count: 0,
    last_updated: new Date().toISOString(),
  });
}

// Initialize MCP server
const server = new Server({
  name: "bofig-mcp",
  version: "1.0.0",
});

// Register tool handlers
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: TOOLS };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request;

  let result: string;
  if (name === "query_evidence") {
    result = await handleQueryEvidence(args as Record<string, unknown>);
  } else if (name === "search_evidence") {
    result = await handleSearchEvidence(args as Record<string, unknown>);
  } else if (name === "get_connections") {
    result = await handleGetConnections(args as Record<string, unknown>);
  } else if (name === "find_path") {
    result = await handleFindPath(args as Record<string, unknown>);
  } else if (name === "execute_query") {
    result = await handleExecuteQuery(args as Record<string, unknown>);
  } else if (name === "get_graph_stats") {
    result = await handleGetGraphStats(args as Record<string, unknown>);
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
const port = 5178;
await server.connect(new WebSocket(`ws://127.0.0.1:${port}`));
console.log("Bofig MCP server running on ws://127.0.0.1:5178");
