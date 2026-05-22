// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// fly-mcp/mod.js -- Fly.io Machines API v1 cartridge implementation.
//
// Provides MCP tool handlers for the Fly.io Machines REST API:
//   - App management (list, get, create, destroy)
//   - Machine management (list, get, create, start, stop, restart, destroy)
//   - Volumes (list, create)
//   - Secrets (list, set, delete)
//   - Certificates (list, add)
//   - Regions (list)
//   - IP allocation (allocate, release)
//
// Auth: Bearer token via FLY_API_TOKEN env var or vault-mcp proxy.
// API docs: https://fly.io/docs/machines/api/
//
// The Fly.io API uses two base URLs:
//   - Machines API: https://api.machines.dev/v1
//   - Platform API: https://api.fly.io (for secrets, certs, IPs via GraphQL)
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const MACHINES_API_BASE = "https://api.machines.dev/v1";
const PLATFORM_API_BASE = "https://api.fly.io";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Fly.io API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, FLY_API_TOKEN is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("FLY_API_TOKEN")
    : process.env.FLY_API_TOKEN;
  if (!token) {
    throw new Error("FLY_API_TOKEN not set. Run 'fly auth token' or export FLY_API_TOKEN.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP request helpers — wraps fetch for both Machines API and Platform API
// with auth headers, error handling, and structured responses.
// ---------------------------------------------------------------------------

async function machinesFetch(method, path, body) {
  const token = getToken();
  const url = `${MACHINES_API_BASE}${path}`;

  const options = {
    method,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Accept": "application/json",
      "User-Agent": "boj-server/fly-mcp/0.1.0",
    },
  };

  if (body && method !== "GET") {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url, options);

  // Handle 204 No Content (successful actions like stop/start)
  if (response.status === 204) {
    return { status: response.status, data: { success: true } };
  }

  // Handle empty responses
  const text = await response.text();
  if (!text) {
    return { status: response.status, data: { success: response.ok } };
  }

  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return { status: response.status, error: `Non-JSON response: ${text.slice(0, 200)}` };
  }

  if (!response.ok) {
    const errorMessage = data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// Platform API uses GraphQL for secrets, certificates, and IPs
async function platformGraphQL(query, variables) {
  const token = getToken();

  const response = await fetch(`${PLATFORM_API_BASE}/graphql`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "boj-server/fly-mcp/0.1.0",
    },
    body: JSON.stringify({ query, variables: variables || {} }),
  });

  const data = await response.json();

  if (data.errors) {
    return { status: response.status, error: data.errors[0].message, data };
  }

  return { status: response.status, data: data.data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Fly.io API operations.
// Each handler validates required arguments, builds the API request,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Apps ---

    case "fly_list_apps": {
      const orgSlug = args.org_slug || "personal";
      return machinesFetch("GET", `/apps?org_slug=${encodeURIComponent(orgSlug)}`);
    }

    case "fly_get_app": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      return machinesFetch("GET", `/apps/${encodeURIComponent(args.app_name)}`);
    }

    case "fly_create_app": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      const body = {
        app_name: args.app_name,
        org_slug: args.org_slug || "personal",
      };
      if (args.network) body.network = args.network;
      return machinesFetch("POST", "/apps", body);
    }

    case "fly_destroy_app": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      return machinesFetch("DELETE", `/apps/${encodeURIComponent(args.app_name)}`);
    }

    // --- Machines ---

    case "fly_list_machines": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      let path = `/apps/${encodeURIComponent(args.app_name)}/machines`;
      const params = [];
      if (args.include_deleted) params.push("include_deleted=true");
      if (args.region) params.push(`region=${encodeURIComponent(args.region)}`);
      if (params.length > 0) path += `?${params.join("&")}`;
      return machinesFetch("GET", path);
    }

    case "fly_get_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.machine_id) return { error: "Missing required field: machine_id" };
      return machinesFetch("GET",
        `/apps/${encodeURIComponent(args.app_name)}/machines/${encodeURIComponent(args.machine_id)}`);
    }

    case "fly_create_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.config) return { error: "Missing required field: config" };
      const body = { config: args.config };
      if (args.name) body.name = args.name;
      if (args.region) body.region = args.region;
      return machinesFetch("POST",
        `/apps/${encodeURIComponent(args.app_name)}/machines`, body);
    }

    case "fly_start_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.machine_id) return { error: "Missing required field: machine_id" };
      return machinesFetch("POST",
        `/apps/${encodeURIComponent(args.app_name)}/machines/${encodeURIComponent(args.machine_id)}/start`);
    }

    case "fly_stop_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.machine_id) return { error: "Missing required field: machine_id" };
      const body = {};
      if (args.signal) body.signal = args.signal;
      return machinesFetch("POST",
        `/apps/${encodeURIComponent(args.app_name)}/machines/${encodeURIComponent(args.machine_id)}/stop`, body);
    }

    case "fly_restart_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.machine_id) return { error: "Missing required field: machine_id" };
      let path = `/apps/${encodeURIComponent(args.app_name)}/machines/${encodeURIComponent(args.machine_id)}/restart`;
      if (args.timeout) path += `?timeout=${encodeURIComponent(args.timeout)}`;
      return machinesFetch("POST", path);
    }

    case "fly_destroy_machine": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.machine_id) return { error: "Missing required field: machine_id" };
      let path = `/apps/${encodeURIComponent(args.app_name)}/machines/${encodeURIComponent(args.machine_id)}`;
      if (args.force) path += "?force=true";
      return machinesFetch("DELETE", path);
    }

    // --- Volumes ---

    case "fly_list_volumes": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      return machinesFetch("GET",
        `/apps/${encodeURIComponent(args.app_name)}/volumes`);
    }

    case "fly_create_volume": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.name) return { error: "Missing required field: name" };
      if (!args.region) return { error: "Missing required field: region" };
      if (!args.size_gb) return { error: "Missing required field: size_gb" };
      const body = {
        name: args.name,
        region: args.region,
        size_gb: args.size_gb,
      };
      if (args.encrypted !== undefined) body.encrypted = args.encrypted;
      if (args.snapshot_id) body.snapshot_id = args.snapshot_id;
      return machinesFetch("POST",
        `/apps/${encodeURIComponent(args.app_name)}/volumes`, body);
    }

    // --- Secrets (via Platform GraphQL API) ---

    case "fly_list_secrets": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      const query = `
        query($appName: String!) {
          app(name: $appName) {
            secrets {
              name
              digest
              createdAt
            }
          }
        }
      `;
      return platformGraphQL(query, { appName: args.app_name });
    }

    case "fly_set_secrets": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.secrets) return { error: "Missing required field: secrets" };
      // Convert object map to array of {key, value} pairs for the GraphQL mutation
      const secretInputs = Object.entries(args.secrets).map(([key, value]) => ({
        key,
        value,
      }));
      const query = `
        mutation($input: SetSecretsInput!) {
          setSecrets(input: $input) {
            app { name }
            release { id version }
          }
        }
      `;
      return platformGraphQL(query, {
        input: { appId: args.app_name, secrets: secretInputs },
      });
    }

    case "fly_delete_secret": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.key) return { error: "Missing required field: key" };
      const query = `
        mutation($input: UnsetSecretsInput!) {
          unsetSecrets(input: $input) {
            app { name }
            release { id version }
          }
        }
      `;
      return platformGraphQL(query, {
        input: { appId: args.app_name, keys: [args.key] },
      });
    }

    // --- Certificates (via Platform GraphQL API) ---

    case "fly_list_certificates": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      const query = `
        query($appName: String!) {
          app(name: $appName) {
            certificates {
              nodes {
                id
                hostname
                createdAt
                source
                clientStatus
                issued {
                  nodes { type expiresAt }
                }
              }
            }
          }
        }
      `;
      return platformGraphQL(query, { appName: args.app_name });
    }

    case "fly_add_certificate": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.hostname) return { error: "Missing required field: hostname" };
      const query = `
        mutation($appId: ID!, $hostname: String!) {
          addCertificate(appId: $appId, hostname: $hostname) {
            certificate {
              id
              hostname
              createdAt
              source
              clientStatus
            }
          }
        }
      `;
      return platformGraphQL(query, {
        appId: args.app_name,
        hostname: args.hostname,
      });
    }

    // --- Regions ---

    case "fly_list_regions": {
      // Platform API endpoint for region listing
      const token = getToken();
      const response = await fetch(`${PLATFORM_API_BASE}/graphql`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
          "User-Agent": "boj-server/fly-mcp/0.1.0",
        },
        body: JSON.stringify({
          query: `{ platform { regions { code name gatewayAvailable requiresPaidPlan } } }`,
        }),
      });
      const data = await response.json();
      if (data.errors) {
        return { status: response.status, error: data.errors[0].message, data };
      }
      return { status: response.status, data: data.data };
    }

    // --- IP Allocation (via Platform GraphQL API) ---

    case "fly_allocate_ip": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      const ipType = args.type === "v4" ? "v4" : "v6";
      const query = `
        mutation($input: AllocateIPAddressInput!) {
          allocateIpAddress(input: $input) {
            ipAddress {
              id
              address
              type
              region
              createdAt
            }
          }
        }
      `;
      const input = { appId: args.app_name, type: ipType };
      if (args.region) input.region = args.region;
      return platformGraphQL(query, { input });
    }

    case "fly_release_ip": {
      if (!args.app_name) return { error: "Missing required field: app_name" };
      if (!args.ip_address_id) return { error: "Missing required field: ip_address_id" };
      const query = `
        mutation($input: ReleaseIPAddressInput!) {
          releaseIpAddress(input: $input) {
            app { name }
          }
        }
      `;
      return platformGraphQL(query, {
        input: { appId: args.app_name, ipAddressId: args.ip_address_id },
      });
    }

    default:
      return { error: `Unknown fly-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "fly-mcp",
  version: "0.1.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 21,
};
