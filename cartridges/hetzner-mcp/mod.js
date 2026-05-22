// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hetzner-mcp/mod.js -- Hetzner Cloud API cartridge implementation.
//
// Provides MCP tool handlers for Hetzner Cloud REST API v1:
//   - Server management (list, get, create, delete, power actions, resize, snapshots)
//   - Floating IPs (list, create)
//   - Volumes (list, create)
//   - Firewalls (list, create)
//   - SSH keys (list, create)
//   - Images (list)
//   - Networks (list, create)
//   - Load balancers (list, create)
//
// Auth: Bearer token via HETZNER_API_TOKEN env var or vault-mcp proxy.
// API docs: https://docs.hetzner.cloud/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.hetzner.cloud/v1";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Hetzner API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, HETZNER_API_TOKEN is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("HETZNER_API_TOKEN")
    : process.env.HETZNER_API_TOKEN;
  if (!token) {
    throw new Error("HETZNER_API_TOKEN not set. Store in vault-mcp or export to environment.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Hetzner auth headers, error
// handling, pagination parameter forwarding, and rate-limit extraction.
// ---------------------------------------------------------------------------

async function hetznerFetch(method, path, body, queryParams) {
  const token = getToken();
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
      "Authorization": `Bearer ${token}`,
      "Accept": "application/json",
      "User-Agent": "boj-server/hetzner-mcp/0.2.0",
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

  // Surface Hetzner API errors clearly
  if (!response.ok) {
    const errorMessage = data.error
      ? `${data.error.code}: ${data.error.message}`
      : `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data, rateLimit };
  }

  return { status: response.status, data, rateLimit };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Hetzner API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results with rate-limit metadata.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Servers ---

    case "hetzner_list_servers": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        sort: args.sort,
        status: args.status,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/servers", null, query);
    }

    case "hetzner_get_server": {
      if (!args.server_id) return { error: "Missing required field: server_id" };
      return hetznerFetch("GET", `/servers/${args.server_id}`);
    }

    case "hetzner_create_server": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.server_type) return { error: "Missing required field: server_type" };
      if (!args.image) return { error: "Missing required field: image" };
      const body = {
        name: args.name,
        server_type: args.server_type,
        image: args.image,
      };
      if (args.location) body.location = args.location;
      if (args.ssh_keys) body.ssh_keys = args.ssh_keys;
      if (args.labels) body.labels = args.labels;
      if (args.user_data) body.user_data = args.user_data;
      if (args.firewalls) body.firewalls = args.firewalls;
      if (args.networks) body.networks = args.networks;
      if (args.public_net) body.public_net = args.public_net;
      return hetznerFetch("POST", "/servers", body);
    }

    case "hetzner_delete_server": {
      if (!args.server_id) return { error: "Missing required field: server_id" };
      return hetznerFetch("DELETE", `/servers/${args.server_id}`);
    }

    case "hetzner_server_action": {
      if (!args.server_id) return { error: "Missing required field: server_id" };
      if (!args.action) return { error: "Missing required field: action" };
      const validActions = ["poweron", "poweroff", "reboot", "shutdown", "reset", "rebuild"];
      if (!validActions.includes(args.action)) {
        return { error: `Invalid action '${args.action}'. Must be one of: ${validActions.join(", ")}` };
      }
      const body = {};
      if (args.action === "rebuild") {
        if (!args.image) return { error: "Missing required field: image (required for rebuild)" };
        body.image = args.image;
      }
      return hetznerFetch("POST", `/servers/${args.server_id}/actions/${args.action}`, body);
    }

    case "hetzner_resize_server": {
      if (!args.server_id) return { error: "Missing required field: server_id" };
      if (!args.server_type) return { error: "Missing required field: server_type" };
      const body = {
        server_type: args.server_type,
        upgrade_disk: args.upgrade_disk || false,
      };
      return hetznerFetch("POST", `/servers/${args.server_id}/actions/change_type`, body);
    }

    // --- Floating IPs ---

    case "hetzner_list_floating_ips": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/floating_ips", null, query);
    }

    case "hetzner_create_floating_ip": {
      if (!args.type) return { error: "Missing required field: type" };
      if (!args.home_location) return { error: "Missing required field: home_location" };
      const body = {
        type: args.type,
        home_location: args.home_location,
      };
      if (args.server) body.server = args.server;
      if (args.description) body.description = args.description;
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", "/floating_ips", body);
    }

    // --- Volumes ---

    case "hetzner_list_volumes": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
        status: args.status,
      };
      return hetznerFetch("GET", "/volumes", null, query);
    }

    case "hetzner_create_volume": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.size) return { error: "Missing required field: size" };
      const body = {
        name: args.name,
        size: args.size,
      };
      if (args.location) body.location = args.location;
      if (args.server) body.server = args.server;
      if (args.format) body.format = args.format;
      if (args.labels) body.labels = args.labels;
      if (args.automount !== undefined) body.automount = args.automount;
      return hetznerFetch("POST", "/volumes", body);
    }

    // --- Firewalls ---

    case "hetzner_list_firewalls": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/firewalls", null, query);
    }

    case "hetzner_create_firewall": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.rules) return { error: "Missing required field: rules" };
      const body = {
        name: args.name,
        rules: args.rules,
      };
      if (args.apply_to) body.apply_to = args.apply_to;
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", "/firewalls", body);
    }

    // --- SSH Keys ---

    case "hetzner_list_ssh_keys": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/ssh_keys", null, query);
    }

    case "hetzner_create_ssh_key": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.public_key) return { error: "Missing required field: public_key" };
      const body = {
        name: args.name,
        public_key: args.public_key,
      };
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", "/ssh_keys", body);
    }

    // --- Images ---

    case "hetzner_list_images": {
      const query = {
        type: args.type,
        status: args.status,
        sort: args.sort,
        page: args.page,
        per_page: args.per_page,
      };
      return hetznerFetch("GET", "/images", null, query);
    }

    case "hetzner_create_snapshot": {
      if (!args.server_id) return { error: "Missing required field: server_id" };
      const body = {};
      if (args.description) body.description = args.description;
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", `/servers/${args.server_id}/actions/create_image`, body);
    }

    // --- Networks ---

    case "hetzner_list_networks": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/networks", null, query);
    }

    case "hetzner_create_network": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.ip_range) return { error: "Missing required field: ip_range" };
      const body = {
        name: args.name,
        ip_range: args.ip_range,
      };
      if (args.subnets) body.subnets = args.subnets;
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", "/networks", body);
    }

    // --- Load Balancers ---

    case "hetzner_list_load_balancers": {
      const query = {
        page: args.page,
        per_page: args.per_page,
        label_selector: args.label_selector,
      };
      return hetznerFetch("GET", "/load_balancers", null, query);
    }

    case "hetzner_create_load_balancer": {
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.load_balancer_type) return { error: "Missing required field: load_balancer_type" };
      const body = {
        name: args.name,
        load_balancer_type: args.load_balancer_type,
      };
      if (args.location) body.location = args.location;
      if (args.algorithm) body.algorithm = args.algorithm;
      if (args.services) body.services = args.services;
      if (args.targets) body.targets = args.targets;
      if (args.labels) body.labels = args.labels;
      return hetznerFetch("POST", "/load_balancers", body);
    }

    default:
      return { error: `Unknown hetzner-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "hetzner-mcp",
  version: "0.2.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 20,
};
