// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hackage-mcp/mod.js -- Hackage registry cartridge implementation.
//
// Provides MCP tool handlers for the Hackage REST API:
//   - Package search (text query)
//   - Package metadata (full info, specific versions)
//   - Version listing with upload timestamps
//   - Download statistics
//   - Dependency inspection (build-depends)
//   - Reverse dependency lookup
//   - Maintainer listing
//   - Deprecation status and replacement suggestions
//   - Raw .cabal file retrieval
//   - Full package listing
//   - User profile lookup
//
// Auth: Optional Basic auth via HACKAGE_CREDENTIALS. Read-only operations
//       are fully public. Auth required only for uploads/edits.
// API docs: https://hackage.haskell.org/api
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://hackage.haskell.org";

// ---------------------------------------------------------------------------
// Auth helper — retrieves Hackage credentials from environment.
// Format: "username:password" base64-encoded for Basic auth.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getCredentials() {
  const creds = typeof Deno !== "undefined"
    ? Deno.env.get("HACKAGE_CREDENTIALS")
    : process.env.HACKAGE_CREDENTIALS;
  return creds || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Hackage headers, error handling,
// and response normalization. Supports both JSON and plain-text responses.
// ---------------------------------------------------------------------------

async function hackageFetch(path, queryParams, acceptText) {
  const url = new URL(`${API_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": acceptText ? "text/plain" : "application/json",
    "User-Agent": "boj-server/hackage-mcp/0.2.0 (https://github.com/hyperpolymath/boj-server)",
  };

  const creds = getCredentials();
  if (creds) {
    headers["Authorization"] = `Basic ${btoa(creds)}`;
  }

  const response = await fetch(url.toString(), { method: "GET", headers });

  // Handle rate limiting
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by Hackage. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  if (acceptText) {
    const text = await response.text().catch(() => "");
    if (!response.ok) {
      return { status: response.status, error: `HTTP ${response.status}`, data: text };
    }
    return { status: response.status, data: text };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Hackage API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "hackage_search_packages": {
      if (!args.query) return { error: "Missing required field: query" };
      return hackageFetch("/packages/search", {
        terms: args.query,
        page: args.page,
      });
    }

    // --- Package metadata ---

    case "hackage_get_package": {
      if (!args.name) return { error: "Missing required field: name" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}.json`);
    }

    case "hackage_get_version": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}-${args.version}.json`);
    }

    case "hackage_list_versions": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await hackageFetch(`/package/${encodeURIComponent(args.name)}.json`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          versions: Object.keys(result.data || {}).filter((k) => /^\d/.test(k)),
        },
      };
    }

    // --- Downloads ---

    case "hackage_get_downloads": {
      if (!args.name) return { error: "Missing required field: name" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}/downloads.json`);
    }

    // --- Dependencies ---

    case "hackage_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}-${args.version}/dependencies.json`);
    }

    // --- Reverse dependencies ---

    case "hackage_get_reverse_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}/reverse.json`);
    }

    // --- Maintainers ---

    case "hackage_get_maintainers": {
      if (!args.name) return { error: "Missing required field: name" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}/maintainers.json`);
    }

    // --- Deprecation ---

    case "hackage_get_deprecated": {
      if (!args.name) return { error: "Missing required field: name" };
      return hackageFetch(`/package/${encodeURIComponent(args.name)}/deprecated.json`);
    }

    // --- Cabal file ---

    case "hackage_get_cabal_file": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return hackageFetch(
        `/package/${encodeURIComponent(args.name)}-${args.version}/${args.name}.cabal`,
        null,
        true, // Accept text/plain
      );
    }

    // --- List all ---

    case "hackage_list_all_packages": {
      return hackageFetch("/packages/", { page: args.page });
    }

    // --- Users ---

    case "hackage_get_user": {
      if (!args.username) return { error: "Missing required field: username" };
      return hackageFetch(`/user/${encodeURIComponent(args.username)}.json`);
    }

    default:
      return { error: `Unknown hackage-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "hackage-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
