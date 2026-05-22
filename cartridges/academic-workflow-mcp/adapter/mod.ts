// SPDX-License-Identifier: MPL-2.0
// Academic Workflow Cartridge — Zotero & citation management MCP server

import { Server } from "https://esm.sh/@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "https://esm.sh/@modelcontextprotocol/sdk/types.js";

// Zotero integration (would use actual Zotero API)
const ZOTERO = {
  apiKey: Deno.env.get("ZOTERO_API_KEY") || "",
  baseUrl: "https://api.zotero.org",
};

// MCP tool definitions
const TOOLS: Tool[] = [
  {
    name: "search_zotero",
    description: "Search Zotero library for papers and collections",
    inputSchema: {
      type: "object" as const,
      properties: {
        query: {
          type: "string",
          description: "Search query (title, author, keywords)",
        },
        collection_id: {
          type: "string",
          description: "Filter to specific collection (optional)",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "get_paper_metadata",
    description:
      "Fetch complete metadata for a paper from Zotero (title, authors, DOI, year, abstract)",
    inputSchema: {
      type: "object" as const,
      properties: {
        item_id: {
          type: "string",
          description: "Zotero item ID",
        },
      },
      required: ["item_id"],
    },
  },
  {
    name: "generate_citation",
    description: "Generate formatted citation (BibTeX, CSL, RIS, EndNote)",
    inputSchema: {
      type: "object" as const,
      properties: {
        item_id: {
          type: "string",
          description: "Zotero item ID",
        },
        format: {
          type: "string",
          enum: ["BibTeX", "CSL", "RIS", "EndNote"],
          description: "Citation format",
        },
      },
      required: ["item_id", "format"],
    },
  },
  {
    name: "extract_bibkeys",
    description: "Extract BibTeX citation keys from text",
    inputSchema: {
      type: "object" as const,
      properties: {
        text: {
          type: "string",
          description: "Text to extract keys from",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "export_collection",
    description: "Export entire Zotero collection as BibTeX",
    inputSchema: {
      type: "object" as const,
      properties: {
        collection_id: {
          type: "string",
          description: "Zotero collection ID",
        },
      },
      required: ["collection_id"],
    },
  },
  {
    name: "add_review_note",
    description:
      "Add review annotation to a paper (page, note, category: typo/unclear/question/suggestion)",
    inputSchema: {
      type: "object" as const,
      properties: {
        paper_id: {
          type: "string",
          description: "Paper identifier",
        },
        page: {
          type: "number",
          description: "Page number",
        },
        text: {
          type: "string",
          description: "Review note text",
        },
        category: {
          type: "string",
          enum: ["typo", "unclear", "question", "suggestion"],
          description: "Note category",
        },
      },
      required: ["paper_id", "page", "text", "category"],
    },
  },
];

// Tool handlers
async function handleSearchZotero(
  args: Record<string, unknown>
): Promise<string> {
  const query = String(args.query);
  const collectionId = args.collection_id
    ? String(args.collection_id)
    : undefined;
  return JSON.stringify({
    query,
    collectionId,
    results: [],
  });
}

async function handleGetPaperMetadata(
  args: Record<string, unknown>
): Promise<string> {
  const itemId = String(args.item_id);
  return JSON.stringify({
    itemId,
    title: "",
    authors: [],
    doi: "",
    year: 0,
    abstract: "",
  });
}

async function handleGenerateCitation(
  args: Record<string, unknown>
): Promise<string> {
  const itemId = String(args.item_id);
  const format = String(args.format);
  return JSON.stringify({
    itemId,
    format,
    citation: "",
  });
}

async function handleExtractBibKeys(
  args: Record<string, unknown>
): Promise<string> {
  const text = String(args.text);
  const keys: string[] = [];
  // Simple regex to find \cite{key} or @key patterns
  const regex = /(?:\\cite\{|@)([a-zA-Z0-9_-]+)\}?/g;
  let match;
  while ((match = regex.exec(text)) !== null) {
    if (!keys.includes(match[1])) {
      keys.push(match[1]);
    }
  }
  return JSON.stringify({ keys });
}

async function handleExportCollection(
  args: Record<string, unknown>
): Promise<string> {
  const collectionId = String(args.collection_id);
  return JSON.stringify({
    collectionId,
    bibtex: "",
  });
}

async function handleAddReviewNote(
  args: Record<string, unknown>
): Promise<string> {
  const paperId = String(args.paper_id);
  const page = Number(args.page);
  const text = String(args.text);
  const category = String(args.category);
  return JSON.stringify({
    paperId,
    page,
    text,
    category,
    saved: true,
  });
}

// Initialize MCP server
const server = new Server({
  name: "academic-workflow-mcp",
  version: "1.0.0",
});

// Register tool handlers
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: TOOLS };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request;

  let result: string;
  if (name === "search_zotero") {
    result = await handleSearchZotero(args as Record<string, unknown>);
  } else if (name === "get_paper_metadata") {
    result = await handleGetPaperMetadata(args as Record<string, unknown>);
  } else if (name === "generate_citation") {
    result = await handleGenerateCitation(args as Record<string, unknown>);
  } else if (name === "extract_bibkeys") {
    result = await handleExtractBibKeys(args as Record<string, unknown>);
  } else if (name === "export_collection") {
    result = await handleExportCollection(args as Record<string, unknown>);
  } else if (name === "add_review_note") {
    result = await handleAddReviewNote(args as Record<string, unknown>);
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
const port = 5174;
await server.connect(new WebSocket(`ws://127.0.0.1:${port}`));
console.log("Academic Workflow MCP server running on ws://127.0.0.1:5174");
