// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opam-mcp/mod.js -- opam registry cartridge implementation.
//
// Provides MCP tool handlers for the opam.ocaml.org API:
//   - Package search (text query, tags)
//   - Package metadata (full info, specific versions)
//   - Version listing
//   - Dependency inspection (depends, depopts, conflicts)
//   - Reverse dependency lookup
//   - Maintainer/author information
//   - Tag listing
//   - Full package listing
//   - Raw opam file retrieval
//
// Auth: None required — the opam repository is fully public.
// API docs: https://opam.ocaml.org/doc/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net mod.js

const API_BASE = "https://opam.ocaml.org";

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with opam.ocaml.org headers,
// error handling, and response normalization.
// ---------------------------------------------------------------------------

async function opamFetch(path, queryParams, acceptHtml) {
  const url = new URL(`${API_BASE}${path}`);

  // Append query parameters if provided
  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": acceptHtml ? "text/html" : "application/json",
    "User-Agent": "boj-server/opam-mcp/0.2.0 (https://github.com/hyperpolymath/boj-server)",
  };

  const response = await fetch(url.toString(), { method: "GET", headers });

  // Handle rate limiting
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by opam.ocaml.org. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  if (acceptHtml) {
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
// Tool handler dispatch — maps MCP tool names to opam API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "opam_search_packages": {
      if (!args.query) return { error: "Missing required field: query" };
      return opamFetch("/api/packages/search", {
        q: args.query,
        page: args.page,
      });
    }

    // --- Package metadata ---

    case "opam_get_package": {
      if (!args.name) return { error: "Missing required field: name" };
      return opamFetch(`/api/packages/${encodeURIComponent(args.name)}`);
    }

    case "opam_get_version": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return opamFetch(`/api/packages/${encodeURIComponent(args.name)}/${args.version}`);
    }

    case "opam_list_versions": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await opamFetch(`/api/packages/${encodeURIComponent(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          versions: result.data.versions || [],
        },
      };
    }

    // --- Dependencies ---

    case "opam_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await opamFetch(`/api/packages/${encodeURIComponent(args.name)}/${args.version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          depends: result.data.depends || [],
          depopts: result.data.depopts || [],
          conflicts: result.data.conflicts || [],
        },
      };
    }

    // --- Reverse dependencies ---

    case "opam_get_reverse_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      return opamFetch(`/api/packages/${encodeURIComponent(args.name)}/revdeps`, {
        page: args.page,
      });
    }

    // --- Maintainers ---

    case "opam_get_maintainers": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await opamFetch(`/api/packages/${encodeURIComponent(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          maintainers: result.data.maintainers || [],
          authors: result.data.authors || [],
        },
      };
    }

    // --- Tags ---

    case "opam_get_tags": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await opamFetch(`/api/packages/${encodeURIComponent(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          tags: result.data.tags || [],
        },
      };
    }

    // --- List all ---

    case "opam_list_all_packages": {
      return opamFetch("/api/packages", {
        page: args.page,
        per_page: args.per_page,
      });
    }

    // --- Raw opam file ---

    case "opam_get_opam_file": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return opamFetch(`/api/packages/${encodeURIComponent(args.name)}/${args.version}/opam`);
    }

    default:
      return { error: `Unknown opam-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "opam-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
