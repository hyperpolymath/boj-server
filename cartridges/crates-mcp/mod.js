// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// crates-mcp/mod.js -- crates.io registry cartridge implementation.
//
// Provides MCP tool handlers for the crates.io REST API v1:
//   - Crate search (text query, category/keyword filters, sorting)
//   - Crate metadata (full info, specific versions, features)
//   - Version listing with timestamps and yanked status
//   - Download statistics (total and per-version)
//   - Dependency tree inspection for specific versions
//   - Reverse dependency lookup (who depends on this crate?)
//   - Owner listing (users and teams)
//   - Category and keyword browsing
//   - User profile lookup
//
// Auth: Optional Bearer token via CRATES_IO_TOKEN. Read-only operations
//       are fully public. Token required only for owner management.
// API docs: https://crates.io/policies
// User-Agent: Required by crates.io policy.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://crates.io/api/v1";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the crates.io auth token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, CRATES_IO_TOKEN is read directly. Optional for reads.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("CRATES_IO_TOKEN")
    : process.env.CRATES_IO_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with crates.io headers, User-Agent
// (required by policy), error handling, and pagination forwarding.
// ---------------------------------------------------------------------------

async function cratesFetch(path, queryParams) {
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
    // crates.io requires a descriptive User-Agent per their crawling policy
    "User-Agent": "boj-server/crates-mcp/0.2.0 (https://github.com/hyperpolymath/boj-server)",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = token;
  }

  const response = await fetch(url.toString(), { method: "GET", headers });

  // Handle rate limiting (crates.io returns 429)
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by crates.io. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.errors
      ? data.errors.map((e) => e.detail).join("; ")
      : `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to crates.io API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "crates_search": {
      if (!args.query) return { error: "Missing required field: query" };
      const query = {
        q: args.query,
        page: args.page,
        per_page: args.per_page,
        sort: args.sort,
        category: args.category,
      };
      return cratesFetch("/crates", query);
    }

    // --- Crate metadata ---

    case "crates_get_crate": {
      if (!args.name) return { error: "Missing required field: name" };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}`);
    }

    case "crates_get_version": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}/${args.version}`);
    }

    case "crates_list_versions": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await cratesFetch(`/crates/${encodeURIComponent(args.name)}/versions`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          versions: (result.data.versions || []).map((v) => ({
            num: v.num,
            created_at: v.created_at,
            downloads: v.downloads,
            yanked: v.yanked,
            license: v.license,
            rust_version: v.rust_version,
          })),
        },
      };
    }

    // --- Downloads ---

    case "crates_get_downloads": {
      if (!args.name) return { error: "Missing required field: name" };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}/downloads`);
    }

    // --- Dependencies ---

    case "crates_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}/${args.version}/dependencies`);
    }

    // --- Reverse dependencies ---

    case "crates_get_reverse_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      const query = {
        page: args.page,
        per_page: args.per_page,
      };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}/reverse_dependencies`, query);
    }

    // --- Owners ---

    case "crates_get_owners": {
      if (!args.name) return { error: "Missing required field: name" };
      return cratesFetch(`/crates/${encodeURIComponent(args.name)}/owners`);
    }

    // --- Categories ---

    case "crates_list_categories": {
      const query = { sort: args.sort };
      return cratesFetch("/categories", query);
    }

    case "crates_get_category": {
      if (!args.slug) return { error: "Missing required field: slug" };
      return cratesFetch(`/categories/${encodeURIComponent(args.slug)}`);
    }

    // --- Keywords ---

    case "crates_list_keywords": {
      const query = {
        sort: args.sort,
        page: args.page,
        per_page: args.per_page,
      };
      return cratesFetch("/keywords", query);
    }

    // --- Users ---

    case "crates_get_user": {
      if (!args.login) return { error: "Missing required field: login" };
      return cratesFetch(`/users/${encodeURIComponent(args.login)}`);
    }

    // --- Features ---

    case "crates_get_features": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await cratesFetch(`/crates/${encodeURIComponent(args.name)}/${args.version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          features: result.data.version?.features || {},
        },
      };
    }

    default:
      return { error: `Unknown crates-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "crates-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 13,
};
