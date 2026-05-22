// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opendatamcp/mod.js — Open Data MCP cartridge.
//
// Delegates to backend at http://127.0.0.1:8000 (override with OPENDATA_URL).
// No auth required. Access and publish public open datasets.

const BASE_URL = Deno.env.get("OPENDATA_URL") ?? "http://127.0.0.1:8000";
const TIMEOUT_MS = 30_000; // dataset queries can be slow

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "opendatamcp backend timed out" } };
    return { status: 503, data: { success: false, error: `opendatamcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "opendatamcp_query_dataset": {
      const { dataset_id, query, limit } = args ?? {};
      if (!dataset_id || !query)
        return { status: 400, data: { error: "dataset_id and query are required" } };
      const payload = { dataset_id, query };
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/datasets/query", payload);
    }

    case "opendatamcp_list_datasets": {
      const { category, country } = args ?? {};
      const payload = {};
      if (category !== undefined) payload.category = category;
      if (country !== undefined) payload.country = country;
      return post("/api/v1/datasets/list", payload);
    }

    case "opendatamcp_get_dataset_info": {
      const { dataset_id } = args ?? {};
      if (!dataset_id) return { status: 400, data: { error: "dataset_id is required" } };
      return post("/api/v1/datasets/info", { dataset_id });
    }

    case "opendatamcp_publish_dataset": {
      const { name, description, source_url, license, category } = args ?? {};
      if (!name || !description || !source_url || !license || !category)
        return { status: 400, data: { error: "name, description, source_url, license, and category are required" } };
      return post("/api/v1/datasets/publish", { name, description, source_url, license, category });
    }

    case "opendatamcp_search_datasets": {
      const { keywords, limit } = args ?? {};
      if (!keywords) return { status: 400, data: { error: "keywords is required" } };
      const payload = { keywords };
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/datasets/search", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
