// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// digitalocean-mcp/mod.js -- DigitalOcean API v2 cartridge implementation.
//
// Provides MCP tool handlers for DigitalOcean REST API v2:
//   - Droplet management (list, get, create, delete, power actions)
//   - Block storage volumes (list, create)
//   - DNS domains (list, create)
//   - SSH keys (list)
//   - Snapshots (list, create)
//   - Managed databases (list)
//   - Firewalls (list, create)
//   - Load balancers (list)
//   - Account info and billing
//
// Auth: Bearer token via DIGITALOCEAN_TOKEN env var or vault-mcp proxy.
// API docs: https://docs.digitalocean.com/reference/api/api-reference/
// Rate limit: 5000 requests per hour.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.digitalocean.com/v2";

// ---------------------------------------------------------------------------
// Auth helper -- retrieves the DigitalOcean API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, DIGITALOCEAN_TOKEN is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("DIGITALOCEAN_TOKEN")
    : process.env.DIGITALOCEAN_TOKEN;
  if (!token) {
    throw new Error("DIGITALOCEAN_TOKEN not set. Store in vault-mcp or export to environment.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP request helper -- wraps fetch with DigitalOcean auth headers, error
// handling, pagination, and rate-limit header extraction.
// DigitalOcean uses page-based pagination with link headers.
// ---------------------------------------------------------------------------

async function doFetch(method, path, body, queryParams) {
  const token = getToken();
  const url = new URL(`${API_BASE}${path}`);

  // Append query parameters (pagination, filters)
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
      "User-Agent": "boj-server/digitalocean-mcp/0.2.0",
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

  // Handle 204 No Content (successful deletes)
  if (response.status === 204) {
    return { status: response.status, data: { success: true }, rateLimit };
  }

  const data = await response.json();

  // Surface DigitalOcean API errors clearly
  if (!response.ok) {
    const errorMessage = data.message
      ? data.message
      : `HTTP ${response.status}: ${data.id || "unknown_error"}`;
    return { status: response.status, error: errorMessage, data, rateLimit };
  }

  return { status: response.status, data, rateLimit };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch -- maps MCP tool names to DigitalOcean API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results with rate-limit metadata.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Droplets ---

    case "digitalocean_list_droplets": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        tag_name: args.tag_name,
        name: args.name,
      };
      return doFetch("GET", "/droplets", null, query);
    }

    case "digitalocean_get_droplet": {
      if (!args.droplet_id) return { error: "Missing required field: droplet_id" };
      return doFetch("GET", `/droplets/${args.droplet_id}`);
    }

    case "digitalocean_create_droplet": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.region) return { error: "Missing required field: region" };
      if (!args.size) return { error: "Missing required field: size" };
      if (!args.image) return { error: "Missing required field: image" };
      const body = {
        name: args.name,
        region: args.region,
        size: args.size,
        image: args.image,
      };
      if (args.ssh_keys) body.ssh_keys = args.ssh_keys;
      if (args.backups !== undefined) body.backups = args.backups;
      if (args.ipv6 !== undefined) body.ipv6 = args.ipv6;
      if (args.monitoring !== undefined) body.monitoring = args.monitoring;
      if (args.user_data) body.user_data = args.user_data;
      if (args.tags) body.tags = args.tags;
      if (args.vpc_uuid) body.vpc_uuid = args.vpc_uuid;
      if (args.volumes) body.volumes = args.volumes;
      return doFetch("POST", "/droplets", body);
    }

    case "digitalocean_delete_droplet": {
      if (!args.droplet_id) return { error: "Missing required field: droplet_id" };
      return doFetch("DELETE", `/droplets/${args.droplet_id}`);
    }

    case "digitalocean_droplet_action": {
      if (!args.droplet_id) return { error: "Missing required field: droplet_id" };
      if (!args.type) return { error: "Missing required field: type" };
      const validTypes = ["power_on", "power_off", "reboot", "shutdown", "power_cycle", "rebuild", "resize", "rename"];
      if (!validTypes.includes(args.type)) {
        return { error: `Invalid action type '${args.type}'. Must be one of: ${validTypes.join(", ")}` };
      }
      const body = { type: args.type };
      if (args.type === "rebuild" && args.image) body.image = args.image;
      if (args.type === "resize" && args.size) body.size = args.size;
      if (args.type === "rename" && args.name) body.name = args.name;
      return doFetch("POST", `/droplets/${args.droplet_id}/actions`, body);
    }

    // --- Volumes ---

    case "digitalocean_list_volumes": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        region: args.region,
        name: args.name,
      };
      return doFetch("GET", "/volumes", null, query);
    }

    case "digitalocean_create_volume": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.size_gigabytes) return { error: "Missing required field: size_gigabytes" };
      if (!args.region) return { error: "Missing required field: region" };
      const body = {
        name: args.name,
        size_gigabytes: args.size_gigabytes,
        region: args.region,
      };
      if (args.description) body.description = args.description;
      if (args.filesystem_type) body.filesystem_type = args.filesystem_type;
      if (args.tags) body.tags = args.tags;
      if (args.snapshot_id) body.snapshot_id = args.snapshot_id;
      return doFetch("POST", "/volumes", body);
    }

    // --- Domains ---

    case "digitalocean_list_domains": {
      const query = {
        page: args.page,
        per_page: args.per_page,
      };
      return doFetch("GET", "/domains", null, query);
    }

    case "digitalocean_create_domain": {
      if (!args.name) return { error: "Missing required field: name" };
      const body = { name: args.name };
      if (args.ip_address) body.ip_address = args.ip_address;
      return doFetch("POST", "/domains", body);
    }

    // --- SSH Keys ---

    case "digitalocean_list_ssh_keys": {
      const query = {
        page: args.page,
        per_page: args.per_page,
      };
      return doFetch("GET", "/account/keys", null, query);
    }

    // --- Snapshots ---

    case "digitalocean_list_snapshots": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        resource_type: args.resource_type,
      };
      return doFetch("GET", "/snapshots", null, query);
    }

    case "digitalocean_create_snapshot": {
      if (!args.droplet_id) return { error: "Missing required field: droplet_id" };
      if (!args.name) return { error: "Missing required field: name" };
      return doFetch("POST", `/droplets/${args.droplet_id}/actions`, {
        type: "snapshot",
        name: args.name,
      });
    }

    // --- Databases ---

    case "digitalocean_list_databases": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        tag_name: args.tag_name,
      };
      return doFetch("GET", "/databases", null, query);
    }

    // --- Firewalls ---

    case "digitalocean_list_firewalls": {
      const query = {
        page: args.page,
        per_page: args.per_page,
      };
      return doFetch("GET", "/firewalls", null, query);
    }

    case "digitalocean_create_firewall": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.inbound_rules) return { error: "Missing required field: inbound_rules" };
      if (!args.outbound_rules) return { error: "Missing required field: outbound_rules" };
      const body = {
        name: args.name,
        inbound_rules: args.inbound_rules,
        outbound_rules: args.outbound_rules,
      };
      if (args.droplet_ids) body.droplet_ids = args.droplet_ids;
      if (args.tags) body.tags = args.tags;
      return doFetch("POST", "/firewalls", body);
    }

    // --- Load Balancers ---

    case "digitalocean_list_load_balancers": {
      const query = {
        page: args.page,
        per_page: args.per_page,
      };
      return doFetch("GET", "/load_balancers", null, query);
    }

    // --- Account ---

    case "digitalocean_get_account": {
      return doFetch("GET", "/account");
    }

    case "digitalocean_get_balance": {
      return doFetch("GET", "/customers/my/balance");
    }

    default:
      return { error: `Unknown digitalocean-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export -- used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "digitalocean-mcp",
  version: "0.2.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 18,
};
