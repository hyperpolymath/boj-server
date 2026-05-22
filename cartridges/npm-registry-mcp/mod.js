// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// npm-registry-mcp/mod.js -- npm registry cartridge implementation.
//
// Provides MCP tool handlers for the npm registry REST API:
//   - Package search (text query, weighted scoring)
//   - Package metadata (full packument, specific versions, dist-tags)
//   - Download statistics (point-in-time and per-day ranges)
//   - Dependency tree inspection
//   - Maintainer listing
//   - Security audit advisories
//   - SLSA build provenance attestation
//
// Auth: Bearer token via NPM_TOKEN env var or vault-mcp proxy.
//       Read-only operations work without auth; publish/unpublish require auth.
// API docs: https://github.com/npm/registry/blob/master/docs/REGISTRY-API.md
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const REGISTRY_BASE = "https://registry.npmjs.org";
const SEARCH_BASE = "https://registry.npmjs.org/-/v1/search";
const DOWNLOADS_BASE = "https://api.npmjs.org/downloads";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the npm auth token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, NPM_TOKEN is read directly. Optional for read-only ops.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("NPM_TOKEN")
    : process.env.NPM_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helpers — wraps fetch with npm registry auth headers, error
// handling, and structured response formatting.
// ---------------------------------------------------------------------------

/**
 * Fetch from the main npm registry (registry.npmjs.org).
 * Supports abbreviated metadata via Accept header.
 */
async function registryFetch(path, queryParams, abbreviated = false) {
  const url = new URL(`${REGISTRY_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": abbreviated
      ? "application/vnd.npm.install-v1+json"
      : "application/json",
    "User-Agent": "boj-server/npm-registry-mcp/0.2.0",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const response = await fetch(url.toString(), { method: "GET", headers });
  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

/**
 * Fetch from the npm downloads API (api.npmjs.org/downloads).
 * No auth required; fully public endpoint.
 */
async function downloadsFetch(path) {
  const url = `${DOWNLOADS_BASE}${path}`;
  const response = await fetch(url, {
    method: "GET",
    headers: {
      "Accept": "application/json",
      "User-Agent": "boj-server/npm-registry-mcp/0.2.0",
    },
  });

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Encode scoped package names for URL paths.
// '@scope/name' -> '%40scope%2Fname'
// ---------------------------------------------------------------------------

function encodePkgName(name) {
  return name.replaceAll("/", "%2f");
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to npm registry API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search ---

    case "npm_search_packages": {
      if (!args.query) return { error: "Missing required field: query" };
      const query = {
        text: args.query,
        size: args.size,
        from: args.from,
        quality: args.quality,
        popularity: args.popularity,
        maintenance: args.maintenance,
      };
      const url = new URL(SEARCH_BASE);
      for (const [key, value] of Object.entries(query)) {
        if (value !== undefined && value !== null) {
          url.searchParams.set(key, String(value));
        }
      }
      const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
          "Accept": "application/json",
          "User-Agent": "boj-server/npm-registry-mcp/0.2.0",
        },
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        return { status: response.status, error: data.error || `HTTP ${response.status}`, data };
      }
      return { status: response.status, data };
    }

    // --- Package metadata ---

    case "npm_get_package": {
      if (!args.name) return { error: "Missing required field: name" };
      return registryFetch(`/${encodePkgName(args.name)}`);
    }

    case "npm_get_package_version": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      return registryFetch(`/${encodePkgName(args.name)}/${args.version}`);
    }

    case "npm_list_versions": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await registryFetch(`/${encodePkgName(args.name)}`);
      if (result.error) return result;
      // Extract version list with timestamps from the time field
      const versions = Object.keys(result.data.versions || {});
      const time = result.data.time || {};
      return {
        status: result.status,
        data: {
          name: args.name,
          version_count: versions.length,
          versions: versions.map((v) => ({ version: v, published: time[v] || null })),
          dist_tags: result.data["dist-tags"] || {},
        },
      };
    }

    case "npm_get_packument": {
      if (!args.name) return { error: "Missing required field: name" };
      return registryFetch(`/${encodePkgName(args.name)}`, null, true);
    }

    // --- Downloads ---

    case "npm_get_downloads": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.period) return { error: "Missing required field: period" };
      return downloadsFetch(`/point/${args.period}/${encodePkgName(args.name)}`);
    }

    case "npm_get_downloads_range": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.start) return { error: "Missing required field: start" };
      if (!args.end) return { error: "Missing required field: end" };
      return downloadsFetch(`/range/${args.start}:${args.end}/${encodePkgName(args.name)}`);
    }

    // --- Dependencies ---

    case "npm_get_dependencies": {
      if (!args.name) return { error: "Missing required field: name" };
      const version = args.version || "latest";
      const result = await registryFetch(`/${encodePkgName(args.name)}/${version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: result.data.version,
          dependencies: result.data.dependencies || {},
          devDependencies: result.data.devDependencies || {},
          peerDependencies: result.data.peerDependencies || {},
          optionalDependencies: result.data.optionalDependencies || {},
        },
      };
    }

    // --- Maintainers ---

    case "npm_get_maintainers": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await registryFetch(`/${encodePkgName(args.name)}/latest`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          maintainers: result.data.maintainers || [],
        },
      };
    }

    // --- Dist-tags ---

    case "npm_get_dist_tags": {
      if (!args.name) return { error: "Missing required field: name" };
      const result = await registryFetch(`/${encodePkgName(args.name)}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          "dist-tags": result.data["dist-tags"] || {},
        },
      };
    }

    // --- Security ---

    case "npm_get_audit_advisories": {
      if (!args.name) return { error: "Missing required field: name" };
      // Use the npm audit advisory API (public)
      const url = `https://registry.npmjs.org/-/npm/v1/security/advisories?package=${encodeURIComponent(args.name)}`;
      const response = await fetch(url, {
        method: "GET",
        headers: {
          "Accept": "application/json",
          "User-Agent": "boj-server/npm-registry-mcp/0.2.0",
        },
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        return { status: response.status, error: data.error || `HTTP ${response.status}`, data };
      }
      return { status: response.status, data };
    }

    // --- Provenance ---

    case "npm_get_provenance": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.version) return { error: "Missing required field: version" };
      // Get the version-specific metadata which includes attestations
      const result = await registryFetch(`/${encodePkgName(args.name)}/${args.version}`);
      if (result.error) return result;
      return {
        status: result.status,
        data: {
          name: args.name,
          version: args.version,
          dist: result.data.dist || {},
          _attestations: result.data._attestations || null,
        },
      };
    }

    default:
      return { error: `Unknown npm-registry-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "npm-registry-mcp",
  version: "0.2.0",
  domain: "Registry",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
