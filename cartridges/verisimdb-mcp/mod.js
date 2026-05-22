// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verisimdb-mcp/mod.js -- verisimdb gateway

const BASE_URL = Deno.env.get("VERISIMDB_BACKEND_URL") ?? "http://127.0.0.1:7705";

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 15000);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload), signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "verisimdb-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `verisimdb-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "verisimdb_store_octad": {
      const { key, data } = args ?? {};
      if (!key || !data) return { status: 400, data: { error: "key is required" } };
      const payload = { key, data };
      return post("/api/v1/store-octad", payload);
    }

    case "verisimdb_get_octad": {
      const { key } = args ?? {};
      if (!key) return { status: 400, data: { error: "key is required" } };
      const payload = { key };
      return post("/api/v1/get-octad", payload);
    }

    case "verisimdb_detect_drift": {
      const { key } = args ?? {};
      if (!key) return { status: 400, data: { error: "key is required" } };
      const payload = { key };
      return post("/api/v1/detect-drift", payload);
    }

    case "verisimdb_query_audit": {
      const { from_ts, to_ts } = args ?? {};
      if (!from_ts || !to_ts) return { status: 400, data: { error: "from_ts is required" } };
      const payload = { from_ts, to_ts };
      return post("/api/v1/query-audit", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
