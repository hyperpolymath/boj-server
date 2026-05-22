// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cloudflare-mcp/mod.js -- Cloudflare API v4 cartridge implementation.
//
// Provides MCP tool handlers for the Cloudflare API v4:
//   - Zone management (list, get)
//   - DNS record CRUD (list, get, create, update, patch, delete)
//   - Zone settings (get, update) -- SSL mode, TLS version, always_use_https, IPv6
//   - Cache purge
//
// Auth: Bearer token via CF_API_TOKEN env var or vault-mcp proxy.
// API docs: https://developers.cloudflare.com/api/
//
// Key design notes:
//   - All responses follow Cloudflare's standard envelope:
//     { success: bool, result: T, errors: [...], messages: [...] }
//   - proxied=true (orange cloud) enables DDoS protection, IPv6 for any record
//     type, and Cloudflare TLS termination. proxied=false (grey cloud) is
//     required for Fly.io custom cert ACME validation; switch back to proxied
//     after cert issuance.
//   - For IPv6 on proxied origins: A record + proxied=true is sufficient.
//     No AAAA needed unless the zone is unproxied.
//
// Usage: import { handleTool } from "./mod.js";

const CF_API_BASE = "https://api.cloudflare.com/client/v4";

// ---------------------------------------------------------------------------
// Auth helper
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("CF_API_TOKEN")
    : process.env.CF_API_TOKEN;
  if (!token) {
    throw new Error(
      "CF_API_TOKEN not set. Create an API token at https://dash.cloudflare.com/profile/api-tokens " +
      "with Zone:DNS:Edit and Zone:Settings:Edit permissions."
    );
  }
  return token;
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

async function cfFetch(method, path, body) {
  const token = getToken();
  const url = `${CF_API_BASE}${path}`;

  const options = {
    method,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "boj-server/cloudflare-mcp/0.1.0",
    },
  };

  if (body !== undefined) {
    options.body = JSON.stringify(body);
  }

  const resp = await fetch(url, options);
  const data = await resp.json();

  if (!data.success) {
    const errs = (data.errors || []).map(e => `[${e.code}] ${e.message}`).join("; ");
    throw new Error(`Cloudflare API error: ${errs}`);
  }

  return data.result;
}

function buildQuery(params) {
  const entries = Object.entries(params).filter(([, v]) => v !== undefined && v !== null);
  if (entries.length === 0) return "";
  return "?" + entries.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

async function cfListZones({ name, status, page, per_page }) {
  const q = buildQuery({ name, status: status ?? "active", page, per_page });
  const zones = await cfFetch("GET", `/zones${q}`);
  return zones.map(z => ({
    id: z.id,
    name: z.name,
    status: z.status,
    name_servers: z.name_servers,
    original_name_servers: z.original_name_servers,
    paused: z.paused,
    type: z.type,
    created_on: z.created_on,
    modified_on: z.modified_on,
  }));
}

async function cfGetZone({ zone_id }) {
  return cfFetch("GET", `/zones/${zone_id}`);
}

async function cfListDnsRecords({ zone_id, type, name, content, proxied, page, per_page }) {
  const q = buildQuery({ type, name, content, proxied, page, per_page });
  return cfFetch("GET", `/zones/${zone_id}/dns_records${q}`);
}

async function cfGetDnsRecord({ zone_id, record_id }) {
  return cfFetch("GET", `/zones/${zone_id}/dns_records/${record_id}`);
}

async function cfCreateDnsRecord({ zone_id, type, name, content, ttl, proxied, priority, comment }) {
  const body = {
    type,
    name,
    content,
    ttl: ttl ?? 1,
    proxied: proxied ?? false,
  };
  if (priority !== undefined) body.priority = priority;
  if (comment !== undefined) body.comment = comment;
  return cfFetch("POST", `/zones/${zone_id}/dns_records`, body);
}

async function cfUpdateDnsRecord({ zone_id, record_id, type, name, content, ttl, proxied, comment }) {
  const body = { type, name, content, ttl: ttl ?? 1, proxied: proxied ?? false };
  if (comment !== undefined) body.comment = comment;
  return cfFetch("PUT", `/zones/${zone_id}/dns_records/${record_id}`, body);
}

async function cfPatchDnsRecord({ zone_id, record_id, proxied, content, ttl, comment }) {
  const body = {};
  if (proxied !== undefined) body.proxied = proxied;
  if (content !== undefined) body.content = content;
  if (ttl !== undefined) body.ttl = ttl;
  if (comment !== undefined) body.comment = comment;
  return cfFetch("PATCH", `/zones/${zone_id}/dns_records/${record_id}`, body);
}

async function cfDeleteDnsRecord({ zone_id, record_id }) {
  return cfFetch("DELETE", `/zones/${zone_id}/dns_records/${record_id}`);
}

async function cfGetZoneSetting({ zone_id, setting_id }) {
  return cfFetch("GET", `/zones/${zone_id}/settings/${setting_id}`);
}

async function cfUpdateZoneSetting({ zone_id, setting_id, value }) {
  return cfFetch("PATCH", `/zones/${zone_id}/settings/${setting_id}`, { value });
}

async function cfPurgeCache({ zone_id, purge_everything, files }) {
  if (!purge_everything && (!files || files.length === 0)) {
    throw new Error("Provide either purge_everything: true or a non-empty files array.");
  }
  const body = purge_everything ? { purge_everything: true } : { files };
  return cfFetch("POST", `/zones/${zone_id}/purge_cache`, body);
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

const HANDLERS = {
  cf_list_zones: cfListZones,
  cf_get_zone: cfGetZone,
  cf_list_dns_records: cfListDnsRecords,
  cf_get_dns_record: cfGetDnsRecord,
  cf_create_dns_record: cfCreateDnsRecord,
  cf_update_dns_record: cfUpdateDnsRecord,
  cf_patch_dns_record: cfPatchDnsRecord,
  cf_delete_dns_record: cfDeleteDnsRecord,
  cf_get_zone_setting: cfGetZoneSetting,
  cf_update_zone_setting: cfUpdateZoneSetting,
  cf_purge_cache: cfPurgeCache,
};

export async function handleTool(name, args) {
  const handler = HANDLERS[name];
  if (!handler) {
    throw new Error(`Unknown tool: ${name}. Available: ${Object.keys(HANDLERS).join(", ")}`);
  }
  return handler(args ?? {});
}
