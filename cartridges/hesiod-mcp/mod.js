// SPDX-License-Identifier: MPL-2.0
// Hesiod DNS Cartridge — Entry point for BoJ integration

/**
 * Cartridge metadata (populated from cartridge.json at runtime)
 */
export const cartridge = {
  name: "hesiod-mcp",
  version: "1.0.0",
  description: "DNS lookup cartridge",
  tools: [
    {
      id: "dns_lookup",
      name: "DNS Lookup",
      invoke: async (args) => {
        // Calls adapter/mod.ts which bridges to Zig FFI
        return await invokeTool("dns_lookup", args);
      },
    },
    {
      id: "dns_reverse_lookup",
      name: "Reverse DNS Lookup",
      invoke: async (args) => {
        return await invokeTool("dns_reverse_lookup", args);
      },
    },
    {
      id: "dns_bulk_lookup",
      name: "Bulk DNS Lookup",
      invoke: async (args) => {
        return await invokeTool("dns_bulk_lookup", args);
      },
    },
  ],
};

/**
 * Tool invocation handler
 * Routes MCP tool calls to the appropriate handler via the Deno adapter
 */
async function invokeTool(toolId, args) {
  try {
    // In BoJ context, this would call the actual Zig FFI
    // For now, returns a stub response
    return {
      success: true,
      tool: toolId,
      arguments: args,
      results: {
        message: `DNS lookup tool ${toolId} called`,
      },
    };
  } catch (error) {
    return {
      success: false,
      error: error.message,
    };
  }
}

/**
 * Cartridge health check
 */
export async function health() {
  return {
    status: "healthy",
    cartridge: "hesiod-mcp",
    loopback: "127.0.0.1:5173",
    tools: cartridge.tools.length,
  };
}

/**
 * Cartridge initialization hook
 */
export async function init() {
  console.log(`[hesiod-mcp] Initializing DNS lookup cartridge`);
  // Would load Zig FFI, validate loopback proof, etc.
  return { initialized: true };
}

/**
 * Cartridge teardown hook
 */
export async function cleanup() {
  console.log(`[hesiod-mcp] Shutting down`);
  return { cleaned: true };
}
