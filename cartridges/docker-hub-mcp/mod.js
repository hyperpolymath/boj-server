// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// docker-hub-mcp/mod.js -- Docker Hub container registry cartridge implementation.
//
// Provides MCP tool handlers for Docker Hub REST API v2:
//   - Image search (public, no auth required)
//   - Repository management (get, create, delete)
//   - Tag management (list, get, delete)
//   - Namespace and organization listing
//   - Manifest inspection (OCI manifests, digests, layers)
//   - Pull rate limit tracking (100 anon / 200 auth per 6h)
//   - Star/unstar repositories
//   - User profile lookup
//   - Dockerfile retrieval (automated builds)
//
// Auth: Two-phase JWT via POST /v2/users/login, then Bearer token.
// Credentials: DOCKER_HUB_USERNAME + DOCKER_HUB_TOKEN env vars or vault-mcp proxy.
// API docs: https://docs.docker.com/docker-hub/api/latest/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://hub.docker.com/v2";

// ---------------------------------------------------------------------------
// Auth helper — retrieves Docker Hub credentials from environment.
// Two-phase login: POST /v2/users/login with username + password/PAT -> JWT.
// For development, DOCKER_HUB_TOKEN can be set directly as a pre-obtained JWT.
// ---------------------------------------------------------------------------

let cachedJwt = null;

async function getJwt() {
  if (cachedJwt) return cachedJwt;

  // Try pre-set JWT token first
  const directToken = typeof Deno !== "undefined"
    ? Deno.env.get("DOCKER_HUB_TOKEN")
    : process.env.DOCKER_HUB_TOKEN;

  if (directToken && directToken.startsWith("eyJ")) {
    cachedJwt = directToken;
    return cachedJwt;
  }

  // Two-phase login with username + password/PAT
  const username = typeof Deno !== "undefined"
    ? Deno.env.get("DOCKER_HUB_USERNAME")
    : process.env.DOCKER_HUB_USERNAME;
  const password = directToken || (typeof Deno !== "undefined"
    ? Deno.env.get("DOCKER_HUB_PASSWORD")
    : process.env.DOCKER_HUB_PASSWORD);

  if (!username || !password) {
    throw new Error(
      "Docker Hub auth not configured. Set DOCKER_HUB_TOKEN (JWT) or " +
      "DOCKER_HUB_USERNAME + DOCKER_HUB_PASSWORD. Use vault-mcp in production."
    );
  }

  const response = await fetch(`${API_BASE}/users/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    throw new Error(`Docker Hub login failed: ${err.detail || response.status}`);
  }

  const data = await response.json();
  cachedJwt = data.token;
  return cachedJwt;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Docker Hub auth headers, error
// handling, pagination parameter forwarding, and rate-limit extraction.
// ---------------------------------------------------------------------------

async function dockerHubFetch(method, path, body, queryParams, requireAuth = true) {
  const url = new URL(`${API_BASE}${path}`);

  // Append query parameters (pagination, filters, sorting)
  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const options = {
    method,
    headers: {
      "Accept": "application/json",
      "User-Agent": "boj-server/docker-hub-mcp/0.2.0",
    },
  };

  // Attach JWT authorization header when required
  if (requireAuth) {
    const jwt = await getJwt();
    options.headers["Authorization"] = `Bearer ${jwt}`;
  }

  if (body && method !== "GET") {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  // Extract rate-limit headers (Docker Hub uses RateLimit-* headers)
  const rateLimit = {
    limit: response.headers.get("ratelimit-limit"),
    remaining: response.headers.get("ratelimit-remaining"),
    reset: response.headers.get("ratelimit-reset"),
  };

  // Handle 204 No Content (successful deletes, star/unstar)
  if (response.status === 204) {
    return { status: response.status, data: { success: true }, rateLimit };
  }

  const data = await response.json().catch(() => ({}));

  // Surface Docker Hub API errors clearly
  if (!response.ok) {
    const errorMessage = data.detail || data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data, rateLimit };
  }

  return { status: response.status, data, rateLimit };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Docker Hub API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results with rate-limit metadata.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Search (no auth required) ---

    case "dockerhub_search_images": {
      if (!args.query) return { error: "Missing required field: query" };
      const query = {
        q: args.query,
        page: args.page,
        page_size: args.page_size,
        is_official: args.is_official,
      };
      return dockerHubFetch("GET", "/search/repositories", null, query, false);
    }

    // --- Repositories ---

    case "dockerhub_get_repository": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      return dockerHubFetch("GET", `/repositories/${args.namespace}/${args.name}`);
    }

    case "dockerhub_create_repository": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      const body = {
        namespace: args.namespace,
        name: args.name,
      };
      if (args.description) body.description = args.description;
      if (args.full_description) body.full_description = args.full_description;
      if (args.is_private !== undefined) body.is_private = args.is_private;
      return dockerHubFetch("POST", `/repositories/${args.namespace}/${args.name}`, body);
    }

    case "dockerhub_delete_repository": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      return dockerHubFetch("DELETE", `/repositories/${args.namespace}/${args.name}`);
    }

    // --- Tags ---

    case "dockerhub_list_tags": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      const query = {
        page: args.page,
        page_size: args.page_size,
        ordering: args.ordering,
      };
      return dockerHubFetch("GET", `/repositories/${args.namespace}/${args.name}/tags`, null, query);
    }

    case "dockerhub_get_tag": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.tag) return { error: "Missing required field: tag" };
      return dockerHubFetch("GET", `/repositories/${args.namespace}/${args.name}/tags/${args.tag}`);
    }

    case "dockerhub_delete_tag": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.tag) return { error: "Missing required field: tag" };
      return dockerHubFetch("DELETE", `/repositories/${args.namespace}/${args.name}/tags/${args.tag}`);
    }

    // --- Manifest ---

    case "dockerhub_get_manifest": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.reference) return { error: "Missing required field: reference" };
      return dockerHubFetch(
        "GET",
        `/repositories/${args.namespace}/${args.name}/tags/${args.reference}`,
      );
    }

    // --- Namespaces and Orgs ---

    case "dockerhub_list_namespaces": {
      return dockerHubFetch("GET", "/repositories/namespaces");
    }

    case "dockerhub_list_orgs": {
      return dockerHubFetch("GET", "/user/orgs");
    }

    // --- Dockerfile ---

    case "dockerhub_get_dockerfile": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      return dockerHubFetch("GET", `/repositories/${args.namespace}/${args.name}/dockerfile`);
    }

    // --- Stars ---

    case "dockerhub_list_starred": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return dockerHubFetch("GET", "/user/starred", null, query);
    }

    case "dockerhub_star_repository": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      return dockerHubFetch("PUT", `/user/starred/${args.namespace}/${args.name}`);
    }

    case "dockerhub_unstar_repository": {
      if (!args.namespace) return { error: "Missing required field: namespace" };
      if (!args.name) return { error: "Missing required field: name" };
      return dockerHubFetch("DELETE", `/user/starred/${args.namespace}/${args.name}`);
    }

    // --- User ---

    case "dockerhub_get_user": {
      if (!args.username) return { error: "Missing required field: username" };
      return dockerHubFetch("GET", `/users/${args.username}`, null, null, false);
    }

    // --- Rate Limit ---

    case "dockerhub_get_rate_limit": {
      // HEAD request to registry to check rate limit headers
      const response = await fetch("https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest", {
        method: "HEAD",
        headers: { "Accept": "application/json" },
      });
      return {
        status: response.status,
        data: {
          limit: response.headers.get("ratelimit-limit"),
          remaining: response.headers.get("ratelimit-remaining"),
        },
      };
    }

    default:
      return { error: `Unknown docker-hub-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "docker-hub-mcp",
  version: "0.2.0",
  domain: "Container",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 16,
};
