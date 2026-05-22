// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// obsidian-mcp/mod.js -- Obsidian vault cartridge implementation.
//
// Provides MCP tool handlers for the Obsidian Local REST API:
//   - Note search (full-text across titles and content)
//   - Note content retrieval by path
//   - Note listing (folder, recursive)
//   - Backlink analysis (incoming links)
//   - Outgoing link analysis
//   - Tag listing with counts
//   - Tag-based note filtering
//   - YAML frontmatter extraction
//   - Daily note retrieval
//   - Vault statistics
//   - Dataview query execution
//   - Template listing
//
// Auth: Bearer token via OBSIDIAN_REST_API_KEY (required — local API).
// API docs: https://github.com/coddingtonbear/obsidian-local-rest-api
// Note: Connects to localhost (127.0.0.1:27124) with self-signed HTTPS.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env --unsafely-ignore-certificate-errors mod.js

const API_BASE = "https://127.0.0.1:27124";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Obsidian REST API key from environment.
// This is a local API, so auth is always required.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("OBSIDIAN_REST_API_KEY")
    : process.env.OBSIDIAN_REST_API_KEY;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Obsidian REST API headers,
// bearer auth, self-signed cert handling, and error normalization.
// ---------------------------------------------------------------------------

async function obsidianFetch(path, queryParams, acceptText) {
  const url = new URL(`${API_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": acceptText ? "text/markdown" : "application/json",
    "User-Agent": "boj-server/obsidian-mcp/0.2.0",
  };

  const token = getToken();
  if (!token) {
    return { status: 401, error: "OBSIDIAN_REST_API_KEY not set. Local REST API requires auth." };
  }
  headers["Authorization"] = `Bearer ${token}`;

  const response = await fetch(url.toString(), { method: "GET", headers });

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited. Retry after ${retryAfter || "unknown"} seconds.`,
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
    const errorMessage = data.message || data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Obsidian REST API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "obsidian_search_notes": {
      if (!args.query) return { error: "Missing required field: query" };
      return obsidianFetch("/search/simple/", {
        query: args.query,
        contextLength: args.context_length,
      });
    }

    // --- Note content ---

    case "obsidian_get_note": {
      if (!args.path) return { error: "Missing required field: path" };
      return obsidianFetch(`/vault/${encodeURIComponent(args.path)}`, null, true);
    }

    // --- Note listing ---

    case "obsidian_list_notes": {
      const folder = args.folder || "/";
      return obsidianFetch(`/vault/${encodeURIComponent(folder)}`, {
        recursive: args.recursive !== false ? "true" : "false",
      });
    }

    // --- Backlinks ---

    case "obsidian_get_backlinks": {
      if (!args.path) return { error: "Missing required field: path" };
      return obsidianFetch(`/vault/${encodeURIComponent(args.path)}/backlinks`);
    }

    // --- Outgoing links ---

    case "obsidian_get_outgoing_links": {
      if (!args.path) return { error: "Missing required field: path" };
      return obsidianFetch(`/vault/${encodeURIComponent(args.path)}/outgoing-links`);
    }

    // --- Tags ---

    case "obsidian_list_tags": {
      return obsidianFetch("/tags/");
    }

    case "obsidian_get_notes_by_tag": {
      if (!args.tag) return { error: "Missing required field: tag" };
      const tag = args.tag.startsWith("#") ? args.tag.slice(1) : args.tag;
      return obsidianFetch(`/tags/${encodeURIComponent(tag)}`);
    }

    // --- Frontmatter ---

    case "obsidian_get_frontmatter": {
      if (!args.path) return { error: "Missing required field: path" };
      return obsidianFetch(`/vault/${encodeURIComponent(args.path)}/frontmatter`);
    }

    // --- Daily notes ---

    case "obsidian_get_daily_note": {
      const date = args.date || new Date().toISOString().split("T")[0];
      return obsidianFetch(`/periodic/daily/${date}`, null, true);
    }

    // --- Vault stats ---

    case "obsidian_vault_stats": {
      return obsidianFetch("/vault/stats");
    }

    // --- Dataview ---

    case "obsidian_dataview_query": {
      if (!args.query) return { error: "Missing required field: query" };
      // Dataview queries use POST
      const token = getToken();
      if (!token) {
        return { status: 401, error: "OBSIDIAN_REST_API_KEY not set." };
      }
      const response = await fetch(`${API_BASE}/dataview/`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({ query: args.query }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        return { status: response.status, error: data.message || `HTTP ${response.status}`, data };
      }
      return { status: response.status, data };
    }

    // --- Templates ---

    case "obsidian_list_templates": {
      return obsidianFetch("/templates/");
    }

    default:
      return { error: `Unknown obsidian-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "obsidian-mcp",
  version: "0.2.0",
  domain: "Knowledge",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
