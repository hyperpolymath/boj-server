// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// render-mcp/mod.js -- Render REST API v1 cartridge implementation.
//
// Provides MCP tool handlers for Render cloud platform:
//   - Service management (list, get, create, delete, suspend, resume)
//   - Deploy management (list, trigger, get)
//   - Environment groups (list, get)
//   - Custom domains (list, add)
//   - Jobs (list, create)
//   - Bandwidth monitoring
//
// Auth: Bearer token via RENDER_API_KEY env var or vault-mcp proxy.
// API docs: https://api-docs.render.com/reference/introduction
// Rate limit: 100 requests per minute.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.render.com/v1";

// ---------------------------------------------------------------------------
// Auth helper -- retrieves the Render API key from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, RENDER_API_KEY is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("RENDER_API_KEY")
    : process.env.RENDER_API_KEY;
  if (!token) {
    throw new Error("RENDER_API_KEY not set. Store in vault-mcp or export to environment.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP request helper -- wraps fetch with Render auth headers, error
// handling, pagination cursor support, and rate-limit extraction.
// Render uses cursor-based pagination, not page numbers.
// ---------------------------------------------------------------------------

async function renderFetch(method, path, body, queryParams) {
  const token = getToken();
  const url = new URL(`${API_BASE}${path}`);

  // Append query parameters (pagination cursors, filters)
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
      "Authorization": `Bearer ${token}`,
      "Accept": "application/json",
      "User-Agent": "boj-server/render-mcp/0.2.0",
    },
  };

  if (body && method !== "GET") {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  // Extract rate-limit headers for caller awareness
  const rateLimit = {
    limit: response.headers.get("ratelimit-limit"),
    remaining: response.headers.get("ratelimit-remaining"),
    reset: response.headers.get("ratelimit-reset"),
  };

  // Handle 204 No Content (successful deletes, suspend/resume)
  if (response.status === 204) {
    return { status: response.status, data: { success: true }, rateLimit };
  }

  const data = await response.json();

  // Surface Render API errors clearly
  if (!response.ok) {
    const errorMessage = data.message
      ? data.message
      : `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data, rateLimit };
  }

  return { status: response.status, data, rateLimit };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch -- maps MCP tool names to Render API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results with rate-limit metadata.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Services ---

    case "render_list_services": {
      const query = {
        cursor: args.cursor,
        limit: args.limit,
        name: args.name,
        type: args.type,
        region: args.region,
        suspended: args.suspended,
        env: args.env,
      };
      return renderFetch("GET", "/services", null, query);
    }

    case "render_get_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      return renderFetch("GET", `/services/${args.service_id}`);
    }

    case "render_create_service": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.type) return { error: "Missing required field: type" };
      const body = {
        name: args.name,
        type: args.type,
      };
      if (args.repo) body.repo = args.repo;
      if (args.branch) body.branch = args.branch;
      if (args.region) body.region = args.region;
      if (args.plan) body.plan = args.plan;
      if (args.env_vars) body.envVars = args.env_vars;
      if (args.build_command) body.buildCommand = args.build_command;
      if (args.start_command) body.startCommand = args.start_command;
      if (args.docker_image) body.image = { ownerId: "usr-owner", imagePath: args.docker_image };
      if (args.auto_deploy !== undefined) body.autoDeploy = args.auto_deploy ? "yes" : "no";
      if (args.health_check_path) body.healthCheckPath = args.health_check_path;
      return renderFetch("POST", "/services", body);
    }

    case "render_delete_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      return renderFetch("DELETE", `/services/${args.service_id}`);
    }

    // --- Deploys ---

    case "render_list_deploys": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const query = {
        cursor: args.cursor,
        limit: args.limit,
      };
      return renderFetch("GET", `/services/${args.service_id}/deploys`, null, query);
    }

    case "render_trigger_deploy": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const body = {};
      if (args.clear_cache) body.clearCache = "clear";
      return renderFetch("POST", `/services/${args.service_id}/deploys`, body);
    }

    case "render_get_deploy": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.deploy_id) return { error: "Missing required field: deploy_id" };
      return renderFetch("GET", `/services/${args.service_id}/deploys/${args.deploy_id}`);
    }

    // --- Environment Groups ---

    case "render_list_env_groups": {
      const query = {
        cursor: args.cursor,
        limit: args.limit,
        name: args.name,
      };
      return renderFetch("GET", "/env-groups", null, query);
    }

    case "render_get_env_group": {
      if (!args.env_group_id) return { error: "Missing required field: env_group_id" };
      return renderFetch("GET", `/env-groups/${args.env_group_id}`);
    }

    // --- Custom Domains ---

    case "render_list_custom_domains": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const query = {
        cursor: args.cursor,
        limit: args.limit,
      };
      return renderFetch("GET", `/services/${args.service_id}/custom-domains`, null, query);
    }

    case "render_add_custom_domain": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.name) return { error: "Missing required field: name" };
      return renderFetch("POST", `/services/${args.service_id}/custom-domains`, { name: args.name });
    }

    // --- Jobs ---

    case "render_list_jobs": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const query = {
        cursor: args.cursor,
        limit: args.limit,
        status: args.status,
      };
      return renderFetch("GET", `/services/${args.service_id}/jobs`, null, query);
    }

    case "render_create_job": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.start_command) return { error: "Missing required field: start_command" };
      const body = { startCommand: args.start_command };
      if (args.plan_id) body.planId = args.plan_id;
      return renderFetch("POST", `/services/${args.service_id}/jobs`, body);
    }

    // --- Suspend / Resume ---

    case "render_suspend_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      return renderFetch("POST", `/services/${args.service_id}/suspend`);
    }

    case "render_resume_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      return renderFetch("POST", `/services/${args.service_id}/resume`);
    }

    // --- Bandwidth ---

    case "render_get_bandwidth": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      return renderFetch("GET", `/services/${args.service_id}/metrics/bandwidth`);
    }

    default:
      return { error: `Unknown render-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export -- used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "render-mcp",
  version: "0.2.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 16,
};
