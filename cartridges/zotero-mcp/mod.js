// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// zotero-mcp/mod.js -- Zotero reference manager cartridge implementation.
//
// Provides MCP tool handlers for the Zotero Web API v3:
//   - Library search (full-text across titles, authors, tags)
//   - Item metadata retrieval by key
//   - Collection listing and browsing
//   - Collection item retrieval
//   - Tag listing with counts
//   - Tag-based item filtering
//   - Attachment metadata access
//   - Citation export (BibTeX, RIS, CSL JSON)
//   - Child note extraction
//   - Saved search listing
//   - Group library access
//   - Bibliography generation
//
// Auth: Bearer token via ZOTERO_API_KEY (required).
// API docs: https://www.zotero.org/support/dev/web_api/v3/start
// Note: User ID is derived from the API key via /keys/current endpoint.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.zotero.org";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Zotero API key from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("ZOTERO_API_KEY")
    : process.env.ZOTERO_API_KEY;
  return token || null;
}

// ---------------------------------------------------------------------------
// User ID cache — Zotero API requires /users/{userID}/ prefix.
// Resolved once via /keys/current then cached for session.
// ---------------------------------------------------------------------------

let cachedUserId = null;

async function getUserId(token) {
  if (cachedUserId) return cachedUserId;
  const response = await fetch(`${API_BASE}/keys/current`, {
    headers: {
      "Zotero-API-Key": token,
      "Zotero-API-Version": "3",
    },
  });
  if (!response.ok) return null;
  const data = await response.json();
  cachedUserId = data.userID;
  return cachedUserId;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Zotero API headers,
// API key auth, version header, and error normalization.
// ---------------------------------------------------------------------------

async function zoteroFetch(path, queryParams, acceptFormat) {
  const token = getToken();
  if (!token) {
    return { status: 401, error: "ZOTERO_API_KEY not set." };
  }

  const userId = await getUserId(token);
  if (!userId) {
    return { status: 401, error: "Could not resolve Zotero user ID from API key." };
  }

  const fullPath = path.startsWith("/users/") || path.startsWith("/groups/")
    ? path
    : `/users/${userId}${path}`;

  const url = new URL(`${API_BASE}${fullPath}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Zotero-API-Key": token,
    "Zotero-API-Version": "3",
    "User-Agent": "boj-server/zotero-mcp/0.2.0",
  };

  if (acceptFormat) {
    url.searchParams.set("format", acceptFormat);
  }

  const response = await fetch(url.toString(), { method: "GET", headers });

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  if (acceptFormat && acceptFormat !== "json") {
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
// Tool handler dispatch — maps MCP tool names to Zotero API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "zotero_search_items": {
      if (!args.query) return { error: "Missing required field: query" };
      return zoteroFetch("/items", {
        q: args.query,
        itemType: args.item_type,
        limit: args.limit,
        sort: args.sort,
      });
    }

    // --- Item metadata ---

    case "zotero_get_item": {
      if (!args.item_key) return { error: "Missing required field: item_key" };
      return zoteroFetch(`/items/${encodeURIComponent(args.item_key)}`);
    }

    // --- Collections ---

    case "zotero_list_collections": {
      const path = args.parent_key
        ? `/collections/${encodeURIComponent(args.parent_key)}/collections`
        : "/collections";
      return zoteroFetch(path);
    }

    case "zotero_get_collection_items": {
      if (!args.collection_key) return { error: "Missing required field: collection_key" };
      return zoteroFetch(`/collections/${encodeURIComponent(args.collection_key)}/items`, {
        limit: args.limit,
        sort: args.sort,
      });
    }

    // --- Tags ---

    case "zotero_list_tags": {
      return zoteroFetch("/tags", { limit: args.limit });
    }

    case "zotero_get_items_by_tag": {
      if (!args.tag) return { error: "Missing required field: tag" };
      return zoteroFetch("/items", {
        tag: args.tag,
        limit: args.limit,
      });
    }

    // --- Attachments ---

    case "zotero_get_attachments": {
      if (!args.item_key) return { error: "Missing required field: item_key" };
      return zoteroFetch(`/items/${encodeURIComponent(args.item_key)}/children`, {
        itemType: "attachment",
      });
    }

    // --- Citation export ---

    case "zotero_export_citation": {
      if (!args.item_key) return { error: "Missing required field: item_key" };
      const format = args.format || "bibtex";
      return zoteroFetch(`/items/${encodeURIComponent(args.item_key)}`, null, format);
    }

    // --- Notes ---

    case "zotero_get_notes": {
      if (!args.item_key) return { error: "Missing required field: item_key" };
      return zoteroFetch(`/items/${encodeURIComponent(args.item_key)}/children`, {
        itemType: "note",
      });
    }

    // --- Saved searches ---

    case "zotero_list_saved_searches": {
      return zoteroFetch("/searches");
    }

    // --- Group libraries ---

    case "zotero_get_group_libraries": {
      const token = getToken();
      if (!token) return { status: 401, error: "ZOTERO_API_KEY not set." };
      const userId = await getUserId(token);
      if (!userId) return { status: 401, error: "Could not resolve user ID." };
      return zoteroFetch(`/users/${userId}/groups`);
    }

    // --- Bibliography ---

    case "zotero_generate_bibliography": {
      if (!args.item_keys) return { error: "Missing required field: item_keys" };
      const style = args.style || "apa";
      const keys = args.item_keys.split(",").map((k) => k.trim());
      return zoteroFetch("/items", {
        itemKey: keys.join(","),
        format: "bib",
        style,
      });
    }

    default:
      return { error: `Unknown zotero-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "zotero-mcp",
  version: "0.2.0",
  domain: "Research",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
