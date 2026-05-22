// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hex-mcp/mod.js -- Hex.pm registry cartridge implementation.
//
// Provides MCP tool handlers for the Hex.pm REST API:
//   - Package search (text query, sort order)
//   - Package metadata (full info, specific releases)
//   - Release listing with timestamps, downloads, retirement status
//   - Download statistics (total and per-release)
//   - Dependency inspection (requirements)
//   - Owner listing
//   - Retirement status checks
//   - User profile and package listing
//
// Auth: Optional API key via HEX_API_KEY. Read-only operations
//       are fully public. Key required only for publish/manage.
// API docs: https://github.com/hexpm/hex/blob/main/doc/API.md
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://hex.pm/api";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Hex API key from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, HEX_API_KEY is read directly. Optional for reads.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("HEX_API_KEY")
    : process.env.HEX_API_KEY;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Hex API headers, error handling,
// and response normalization.
// ---------------------------------------------------------------------------

async function hexFetch(path, queryParams) {
  const url = new URL(`${API_BASE}${path}`);

  // Append query parameters (pagination, filters, sorting)
  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/hex-mcp/0.2.0 (https://github.com/hyperpolymath/boj-server)",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = token;
  }

  const response = await fetch(url.toString(), { method: "GET", headers });

  // Handle rate limiting
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by Hex.pm. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Hex API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "hex_search_packages": {
      if (!args.query) return { error: "Missing required field: query" };
      const query = {
        search: args.query,
        page: args.page,
        sort: args.sort,
      };
      return hexFetch("/packages", query);
    }

    // --- Package metadata ---

    case "hex_get_package": {
      if (!args.name) return { error: "Missing required field: name" };
      return hexFetch(`/packages/${encodeURIComponent(args.name)}`);
    }

    case "hex_get_release": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return hexFetch(`/packages/${encodeURIComponent(args.name)}/releases/${args.version}`);
    }

    case "hex_list_releases": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await hexFetch(`/packages/${encodeURIComponent(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          releases: (result.data.releases || []).map((r) => ({
            version: r.version,
            inserted_at: r.inserted_at,
            updated_at: r.updated_at,
            retirement: r.retirement || null,
          })),
        },
      };
    }

    // --- Downloads ---

    case "hex_get_downloads": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await hexFetch(`/packages/${encodeURIComponent(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          downloads: result.data.downloads || {},
        },
      };
    }

    // --- Dependencies ---

    case "hex_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await hexFetch(`/packages/${encodeURIComponent(args.name)}/releases/${args.version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          requirements: result.data.requirements || {},
        },
      };
    }

    // --- Owners ---

    case "hex_get_owners": {
      if (!args.name) return { error: "Missing required field: name" };
      return hexFetch(`/packages/${encodeURIComponent(args.name)}/owners`);
    }

    // --- Retirement ---

    case "hex_get_retirement": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await hexFetch(`/packages/${encodeURIComponent(args.name)}/releases/${args.version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          retirement: result.data.retirement || null,
          retired: !!result.data.retirement,
        },
      };
    }

    // --- Users ---

    case "hex_get_user": {
      if (!args.username) return { error: "Missing required field: username" };
      return hexFetch(`/users/${encodeURIComponent(args.username)}`);
    }

    case "hex_list_user_packages": {
      if (!args.username) return { error: "Missing required field: username" };
      return hexFetch(`/users/${encodeURIComponent(args.username)}/packages`);
    }

    default:
      return { error: `Unknown hex-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "hex-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
