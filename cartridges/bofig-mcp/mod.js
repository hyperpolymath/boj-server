// SPDX-License-Identifier: MPL-2.0
export const cartridge = {
  name: "bofig-mcp",
  version: "1.0.0",
  description: "Bofig cartridge — evidence graph queries",
  tools: [
    { id: "query_evidence", name: "Query Evidence" },
    { id: "search_evidence", name: "Search Evidence" },
    { id: "get_connections", name: "Get Connections" },
    { id: "find_path", name: "Find Path" },
    { id: "execute_query", name: "Execute Query" },
    { id: "get_graph_stats", name: "Get Graph Stats" },
  ],
};

export async function health() {
  return { status: "healthy", cartridge: "bofig-mcp" };
}

export async function init() {
  console.log("[bofig-mcp] Initializing");
  return { initialized: true };
}

export async function cleanup() {
  console.log("[bofig-mcp] Shutting down");
  return { cleaned: true };
}
