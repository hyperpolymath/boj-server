// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// linode-mcp/mod.js -- Linode/Akamai API v4 cartridge implementation.
//
// Provides MCP tool handlers for Linode REST API v4:
//   - Instance management (list, get, create, delete, boot, shutdown, reboot)
//   - Block storage volumes (list, create)
//   - DNS domains (list, create)
//   - NodeBalancers (list)
//   - StackScripts (list)
//   - Images (list)
//   - Regions (list)
//   - Cloud Firewalls (list, create)
//   - Account info
//
// Auth: Bearer token via LINODE_TOKEN env var or vault-mcp proxy.
// API docs: https://techdocs.akamai.com/linode-api/reference/api
// Rate limit: 800 requests per 2 minutes.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.linode.com/v4";

// ---------------------------------------------------------------------------
// Auth helper -- retrieves the Linode API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, LINODE_TOKEN is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("LINODE_TOKEN")
    : process.env.LINODE_TOKEN;
  if (!token) {
    throw new Error("LINODE_TOKEN not set. Store in vault-mcp or export to environment.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP request helper -- wraps fetch with Linode auth headers, error
// handling, page-based pagination, and rate-limit header extraction.
// Linode uses page/page_size pagination with X-Filter header for filtering.
// ---------------------------------------------------------------------------

async function linodeFetch(method, path, body, queryParams) {
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
      "User-Agent": "boj-server/linode-mcp/0.2.0",
    },
  };

  if (body && method !== "GET") {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  // Extract rate-limit headers for caller awareness
  // Linode uses X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset
  const rateLimit = {
    limit: response.headers.get("x-ratelimit-limit"),
    remaining: response.headers.get("x-ratelimit-remaining"),
    reset: response.headers.get("x-ratelimit-reset"),
  };

  // Handle 204 No Content (successful deletes)
  if (response.status === 204) {
    return { status: response.status, data: { success: true }, rateLimit };
  }

  const data = await response.json();

  // Surface Linode API errors clearly
  if (!response.ok) {
    const errors = data.errors
      ? data.errors.map((e) => e.reason).join("; ")
      : `HTTP ${response.status}`;
    return { status: response.status, error: errors, data, rateLimit };
  }

  return { status: response.status, data, rateLimit };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch -- maps MCP tool names to Linode API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results with rate-limit metadata.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Instances ---

    case "linode_list_instances": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/linode/instances", null, query);
    }

    case "linode_get_instance": {
      if (!args.linode_id) return { error: "Missing required field: linode_id" };
      return linodeFetch("GET", `/linode/instances/${args.linode_id}`);
    }

    case "linode_create_instance": {
      if (!args.label) return { error: "Missing required field: label" };
      if (!args.region) return { error: "Missing required field: region" };
      if (!args.type) return { error: "Missing required field: type" };
      const body = {
        label: args.label,
        region: args.region,
        type: args.type,
      };
      if (args.image) body.image = args.image;
      if (args.root_pass) body.root_pass = args.root_pass;
      if (args.authorized_keys) body.authorized_keys = args.authorized_keys;
      if (args.authorized_users) body.authorized_users = args.authorized_users;
      if (args.booted !== undefined) body.booted = args.booted;
      if (args.backups_enabled !== undefined) body.backups_enabled = args.backups_enabled;
      if (args.swap_size !== undefined) body.swap_size = args.swap_size;
      if (args.private_ip !== undefined) body.private_ip = args.private_ip;
      if (args.tags) body.tags = args.tags;
      if (args.group) body.group = args.group;
      if (args.stackscript_id) body.stackscript_id = args.stackscript_id;
      if (args.stackscript_data) body.stackscript_data = args.stackscript_data;
      return linodeFetch("POST", "/linode/instances", body);
    }

    case "linode_delete_instance": {
      if (!args.linode_id) return { error: "Missing required field: linode_id" };
      return linodeFetch("DELETE", `/linode/instances/${args.linode_id}`);
    }

    case "linode_boot_instance": {
      if (!args.linode_id) return { error: "Missing required field: linode_id" };
      const body = {};
      if (args.config_id) body.config_id = args.config_id;
      return linodeFetch("POST", `/linode/instances/${args.linode_id}/boot`, body);
    }

    case "linode_shutdown_instance": {
      if (!args.linode_id) return { error: "Missing required field: linode_id" };
      return linodeFetch("POST", `/linode/instances/${args.linode_id}/shutdown`);
    }

    case "linode_reboot_instance": {
      if (!args.linode_id) return { error: "Missing required field: linode_id" };
      const body = {};
      if (args.config_id) body.config_id = args.config_id;
      return linodeFetch("POST", `/linode/instances/${args.linode_id}/reboot`, body);
    }

    // --- Volumes ---

    case "linode_list_volumes": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/volumes", null, query);
    }

    case "linode_create_volume": {
      if (!args.label) return { error: "Missing required field: label" };
      if (!args.size) return { error: "Missing required field: size" };
      const body = {
        label: args.label,
        size: args.size,
      };
      if (args.region) body.region = args.region;
      if (args.linode_id) body.linode_id = args.linode_id;
      if (args.config_id) body.config_id = args.config_id;
      if (args.tags) body.tags = args.tags;
      return linodeFetch("POST", "/volumes", body);
    }

    // --- Domains ---

    case "linode_list_domains": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/domains", null, query);
    }

    case "linode_create_domain": {
      if (!args.domain) return { error: "Missing required field: domain" };
      if (!args.type) return { error: "Missing required field: type" };
      const body = {
        domain: args.domain,
        type: args.type,
      };
      if (args.soa_email) body.soa_email = args.soa_email;
      if (args.master_ips) body.master_ips = args.master_ips;
      if (args.group) body.group = args.group;
      if (args.description) body.description = args.description;
      if (args.tags) body.tags = args.tags;
      return linodeFetch("POST", "/domains", body);
    }

    // --- NodeBalancers ---

    case "linode_list_nodebalancers": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/nodebalancers", null, query);
    }

    // --- StackScripts ---

    case "linode_list_stackscripts": {
      const query = {
        page: args.page,
        page_size: args.page_size,
        mine: args.mine,
      };
      return linodeFetch("GET", "/linode/stackscripts", null, query);
    }

    // --- Images ---

    case "linode_list_images": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/images", null, query);
    }

    // --- Regions ---

    case "linode_list_regions": {
      return linodeFetch("GET", "/regions");
    }

    // --- Firewalls ---

    case "linode_list_firewalls": {
      const query = {
        page: args.page,
        page_size: args.page_size,
      };
      return linodeFetch("GET", "/networking/firewalls", null, query);
    }

    case "linode_create_firewall": {
      if (!args.label) return { error: "Missing required field: label" };
      if (!args.rules) return { error: "Missing required field: rules" };
      const body = {
        label: args.label,
        rules: args.rules,
      };
      if (args.devices) body.devices = args.devices;
      if (args.tags) body.tags = args.tags;
      return linodeFetch("POST", "/networking/firewalls", body);
    }

    // --- Account ---

    case "linode_get_account": {
      return linodeFetch("GET", "/account");
    }

    default:
      return { error: `Unknown linode-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export -- used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "linode-mcp",
  version: "0.2.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 18,
};
