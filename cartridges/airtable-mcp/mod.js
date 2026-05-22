// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// airtable-mcp/mod.js -- Airtable cartridge implementation.
//
// Provides MCP tool handlers for the Airtable REST API:
//   - Base listing
//   - Table schema retrieval
//   - Record listing with filtering and sorting
//   - Single record retrieval
//   - Record creation
//   - Record update (PATCH)
//   - Field listing
//   - View browsing
//   - Webhook management
//   - Record comment access
//
// Auth: Bearer token via AIRTABLE_API_KEY (personal access token, required).
// API docs: https://airtable.com/developers/web/api/introduction
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.airtable.com/v0";
const META_API_BASE = "https://api.airtable.com/v0/meta";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Airtable personal access token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("AIRTABLE_API_KEY")
    : process.env.AIRTABLE_API_KEY;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Airtable API headers,
// bearer auth, and error normalization.
// ---------------------------------------------------------------------------

async function airtableFetch(path, queryParams, method, body, useMeta) {
  const base = useMeta ? META_API_BASE : API_BASE;
  const url = new URL(`${base}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        if (Array.isArray(value)) {
          for (const v of value) url.searchParams.append(key, v);
        } else {
          url.searchParams.set(key, String(value));
        }
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/airtable-mcp/0.2.0",
  };

  const token = getToken();
  if (!token) {
    return { status: 401, error: "AIRTABLE_API_KEY not set." };
  }
  headers["Authorization"] = `Bearer ${token}`;

  const fetchOpts = { method: method || "GET", headers };

  if (body) {
    headers["Content-Type"] = "application/json";
    fetchOpts.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), fetchOpts);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited. Retry after ${retryAfter || "30"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.error?.message || data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Airtable API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Base listing ---

    case "airtable_list_bases": {
      const params = {};
      if (args.offset) params.offset = args.offset;
      return airtableFetch("/bases", params, "GET", null, true);
    }

    // --- Schema ---

    case "airtable_get_base_schema": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      return airtableFetch(`/bases/${encodeURIComponent(args.base_id)}/tables`, null, "GET", null, true);
    }

    // --- Record listing ---

    case "airtable_list_records": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      const params = {};
      if (args.filter_formula) params.filterByFormula = args.filter_formula;
      if (args.max_records) params.maxRecords = args.max_records;
      if (args.view) params.view = args.view;
      if (args.sort_field) {
        params["sort[0][field]"] = args.sort_field;
        params["sort[0][direction]"] = args.sort_direction || "asc";
      }
      if (args.fields) {
        const fieldList = args.fields.split(",").map((f) => f.trim());
        for (let i = 0; i < fieldList.length; i++) {
          params[`fields[${i}]`] = fieldList[i];
        }
      }
      return airtableFetch(`/${encodeURIComponent(args.base_id)}/${encodeURIComponent(args.table_name)}`, params);
    }

    // --- Single record ---

    case "airtable_get_record": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      if (!args.record_id) return { error: "Missing required field: record_id" };
      return airtableFetch(
        `/${encodeURIComponent(args.base_id)}/${encodeURIComponent(args.table_name)}/${encodeURIComponent(args.record_id)}`,
      );
    }

    // --- Create record ---

    case "airtable_create_record": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      if (!args.fields) return { error: "Missing required field: fields" };
      const fields = typeof args.fields === "string" ? JSON.parse(args.fields) : args.fields;
      return airtableFetch(
        `/${encodeURIComponent(args.base_id)}/${encodeURIComponent(args.table_name)}`,
        null,
        "POST",
        { fields },
      );
    }

    // --- Update record ---

    case "airtable_update_record": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      if (!args.record_id) return { error: "Missing required field: record_id" };
      if (!args.fields) return { error: "Missing required field: fields" };
      const fields = typeof args.fields === "string" ? JSON.parse(args.fields) : args.fields;
      return airtableFetch(
        `/${encodeURIComponent(args.base_id)}/${encodeURIComponent(args.table_name)}/${encodeURIComponent(args.record_id)}`,
        null,
        "PATCH",
        { fields },
      );
    }

    // --- Fields ---

    case "airtable_list_fields": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      const result = await airtableFetch(`/bases/${encodeURIComponent(args.base_id)}/tables`, null, "GET", null, true);
      if (result.error) return result;
      const table = (result.data.tables || []).find(
        (t) => t.name === args.table_name || t.id === args.table_name,
      );
      if (!table) return { error: `Table '${args.table_name}' not found in base` };
      return { status: result.status, data: { fields: table.fields || [] } };
    }

    // --- Views ---

    case "airtable_list_views": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      const result = await airtableFetch(`/bases/${encodeURIComponent(args.base_id)}/tables`, null, "GET", null, true);
      if (result.error) return result;
      const table = (result.data.tables || []).find(
        (t) => t.name === args.table_name || t.id === args.table_name,
      );
      if (!table) return { error: `Table '${args.table_name}' not found in base` };
      return { status: result.status, data: { views: table.views || [] } };
    }

    // --- Webhooks ---

    case "airtable_list_webhooks": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      return airtableFetch(`/bases/${encodeURIComponent(args.base_id)}/webhooks`, null, "GET", null, true);
    }

    // --- Comments ---

    case "airtable_get_comments": {
      if (!args.base_id) return { error: "Missing required field: base_id" };
      if (!args.table_name) return { error: "Missing required field: table_name" };
      if (!args.record_id) return { error: "Missing required field: record_id" };
      return airtableFetch(
        `/${encodeURIComponent(args.base_id)}/${encodeURIComponent(args.table_name)}/${encodeURIComponent(args.record_id)}/comments`,
      );
    }

    default:
      return { error: `Unknown airtable-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "airtable-mcp",
  version: "0.2.0",
  domain: "Productivity",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
