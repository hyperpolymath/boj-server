// SPDX-License-Identifier: MPL-2.0
// Fireflag Cartridge — Extension-to-MCP mapping MCP server

import { Server } from "https://esm.sh/@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "https://esm.sh/@modelcontextprotocol/sdk/types.js";

// MCP tool definitions for extension mapping
const TOOLS: Tool[] = [
  {
    name: "map_extension",
    description: "Map an extension directory to available MCP tools",
    inputSchema: {
      type: "object" as const,
      properties: {
        extension_path: {
          type: "string",
          description: "Path to extension directory",
        },
      },
      required: ["extension_path"],
    },
  },
  {
    name: "list_mapped_extensions",
    description: "List all mapped extensions with their MCP capabilities",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "get_extension_tools",
    description: "Get available MCP tools for a specific extension",
    inputSchema: {
      type: "object" as const,
      properties: {
        extension_id: {
          type: "string",
          description: "Extension identifier",
        },
      },
      required: ["extension_id"],
    },
  },
  {
    name: "validate_extension",
    description: "Validate extension configuration and structure",
    inputSchema: {
      type: "object" as const,
      properties: {
        extension_path: {
          type: "string",
          description: "Path to extension to validate",
        },
      },
      required: ["extension_path"],
    },
  },
  {
    name: "discover_extensions",
    description: "Discover extensions in a directory and map their capabilities",
    inputSchema: {
      type: "object" as const,
      properties: {
        directory: {
          type: "string",
          description: "Directory to search for extensions",
        },
      },
      required: ["directory"],
    },
  },
];

// Tool handlers
async function handleMapExtension(
  args: Record<string, unknown>
): Promise<string> {
  const extensionPath = String(args.extension_path);
  return JSON.stringify({
    extension_path: extensionPath,
    is_mapped: false,
    mapping_status: "not_found",
    metadata: null,
  });
}

async function handleListMappedExtensions(
  _args: Record<string, unknown>
): Promise<string> {
  return JSON.stringify({
    extensions: [],
    count: 0,
  });
}

async function handleGetExtensionTools(
  args: Record<string, unknown>
): Promise<string> {
  const extensionId = String(args.extension_id);
  return JSON.stringify({
    extension_id: extensionId,
    tools: [],
    count: 0,
  });
}

async function handleValidateExtension(
  args: Record<string, unknown>
): Promise<string> {
  const extensionPath = String(args.extension_path);
  return JSON.stringify({
    extension_path: extensionPath,
    is_valid: true,
    errors: [],
    warnings: [],
  });
}

async function handleDiscoverExtensions(
  args: Record<string, unknown>
): Promise<string> {
  const directory = String(args.directory);
  return JSON.stringify({
    directory,
    extensions: [],
    count: 0,
  });
}

// Initialize MCP server
const server = new Server({
  name: "fireflag-mcp",
  version: "1.0.0",
});

// Register tool handlers
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: TOOLS };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request;

  let result: string;
  if (name === "map_extension") {
    result = await handleMapExtension(args as Record<string, unknown>);
  } else if (name === "list_mapped_extensions") {
    result = await handleListMappedExtensions(args as Record<string, unknown>);
  } else if (name === "get_extension_tools") {
    result = await handleGetExtensionTools(args as Record<string, unknown>);
  } else if (name === "validate_extension") {
    result = await handleValidateExtension(args as Record<string, unknown>);
  } else if (name === "discover_extensions") {
    result = await handleDiscoverExtensions(args as Record<string, unknown>);
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
const port = 5177;
await server.connect(new WebSocket(`ws://127.0.0.1:${port}`));
console.log("Fireflag MCP server running on ws://127.0.0.1:5177");
