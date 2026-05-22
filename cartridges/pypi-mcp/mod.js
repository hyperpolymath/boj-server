// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pypi-mcp/mod.js -- PyPI registry cartridge implementation.
//
// Provides MCP tool handlers for the PyPI JSON API and Warehouse API:
//   - Package search (text query, classifier filters)
//   - Package metadata (full info, specific versions)
//   - Version listing with timestamps and yanked status
//   - Download statistics via pypistats.org
//   - Dependency inspection (requires_dist)
//   - Release file listing (sdist, wheels, digests)
//   - Maintainer/author information
//   - Trove classifier listing
//   - Vulnerability advisory queries
//   - Project URL extraction
//
// Auth: Optional Bearer token via PYPI_TOKEN. Read-only operations
//       are fully public. Token required only for upload/manage.
// API docs: https://warehouse.pypa.io/api-reference/json.html
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://pypi.org/pypi";
const STATS_BASE = "https://pypistats.org/api";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the PyPI auth token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, PYPI_TOKEN is read directly. Optional for reads.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("PYPI_TOKEN")
    : process.env.PYPI_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with PyPI headers, error handling,
// and response normalization.
// ---------------------------------------------------------------------------

async function pypiFetch(url, queryParams) {
  const target = new URL(url);

  // Append query parameters if provided
  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        target.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/pypi-mcp/0.2.0 (https://github.com/hyperpolymath/boj-server)",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const response = await fetch(target.toString(), { method: "GET", headers });

  // Handle rate limiting
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by PyPI. Retry after ${retryAfter || "unknown"} seconds.`,
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
// Tool handler dispatch — maps MCP tool names to PyPI API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "pypi_search_packages": {
      if (!args.query) return { error: "Missing required field: query" };
      // PyPI JSON API doesn't have a search endpoint; use XMLRPC or scrape.
      // We use the warehouse search API with query params.
      return pypiFetch("https://pypi.org/search/", {
        q: args.query,
        page: args.page,
        c: args.classifier,
      });
    }

    // --- Package metadata ---

    case "pypi_get_package": {
      if (!args.name) return { error: "Missing required field: name" };
      return pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/json`);
    }

    case "pypi_get_version": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/${args.version}/json`);
    }

    case "pypi_list_versions": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/json`);
      if (result.error) return result;
      const releases = result.data.releases || {};
      return {
        status: result.status,
        data: {
          name: args.name,
          versions: Object.keys(releases).map((ver) => ({
            version: ver,
            files: (releases[ver] || []).length,
            yanked: (releases[ver] || []).some((f) => f.yanked),
            upload_time: (releases[ver] || [])[0]?.upload_time || null,
          })),
        },
      };
    }

    // --- Downloads ---

    case "pypi_get_downloads": {
      if (!args.name) return { error: "Missing required field: name" };
      const period = args.period || "last-month";
      return pypiFetch(`${STATS_BASE}/packages/${encodeURIComponent(args.name)}/recent`);
    }

    // --- Dependencies ---

    case "pypi_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/${args.version}/json`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          requires_dist: result.data.info?.requires_dist || [],
          requires_python: result.data.info?.requires_python || null,
        },
      };
    }

    // --- Release files ---

    case "pypi_get_release_files": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/${args.version}/json`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          files: (result.data.urls || []).map((f) => ({
            filename: f.filename,
            packagetype: f.packagetype,
            size: f.size,
            digests: f.digests,
            requires_python: f.requires_python,
            upload_time: f.upload_time,
          })),
        },
      };
    }

    // --- Maintainers ---

    case "pypi_get_maintainers": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/json`);
      if (result.error) return result;
      const info = result.data.info || {};
      return {
        status: result.status,
        data: {
          name: args.name,
          author: info.author,
          author_email: info.author_email,
          maintainer: info.maintainer,
          maintainer_email: info.maintainer_email,
        },
      };
    }

    // --- Classifiers ---

    case "pypi_get_classifiers": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/json`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          classifiers: result.data.info?.classifiers || [],
        },
      };
    }

    // --- Vulnerabilities ---

    case "pypi_get_vulnerabilities": {
      if (!args.name) return { error: "Missing required field: name" };
      const version = args.version || null;
      const url = version
        ? `${API_BASE}/${encodeURIComponent(args.name)}/${version}/json`
        : `${API_BASE}/${encodeURIComponent(args.name)}/json`;
      const result = await pypiFetch(url);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: version || result.data.info?.version,
          vulnerabilities: result.data.vulnerabilities || [],
        },
      };
    }

    // --- Project URLs ---

    case "pypi_get_project_urls": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await pypiFetch(`${API_BASE}/${encodeURIComponent(args.name)}/json`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          project_urls: result.data.info?.project_urls || {},
          home_page: result.data.info?.home_page || null,
        },
      };
    }

    default:
      return { error: `Unknown pypi-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "pypi-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 11,
};
