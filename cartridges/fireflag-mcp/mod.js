// SPDX-License-Identifier: MPL-2.0
export const cartridge = {
  name: "fireflag-mcp",
  version: "1.0.0",
  description: "Fireflag cartridge — extension-to-MCP mapping",
  tools: [
    { id: "map_extension", name: "Map Extension" },
    { id: "list_mapped_extensions", name: "List Mapped Extensions" },
    { id: "get_extension_tools", name: "Get Extension Tools" },
    { id: "validate_extension", name: "Validate Extension" },
    { id: "discover_extensions", name: "Discover Extensions" },
  ],
};

export async function health() {
  return { status: "healthy", cartridge: "fireflag-mcp" };
}

export async function init() {
  console.log("[fireflag-mcp] Initializing");
  return { initialized: true };
}

export async function cleanup() {
  console.log("[fireflag-mcp] Shutting down");
  return { cleaned: true };
}
