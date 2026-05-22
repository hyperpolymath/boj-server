// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// turso-mcp/mod.js -- turso gateway.

const BASE_URL = Deno.env.get("TURSO_MCP_BACKEND_URL") ?? "http://127.0.0.1:7726";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "turso-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `turso-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "turso_connect": {
      const { url, auth_token } = args ?? {};
      if (!url) return { status: 400, data: { error: "url is required" } };
      const payload = { url };
      if (auth_token !== undefined) payload.auth_token = auth_token;
      return post("/api/v1/connect", payload);
    }
    case "turso_query": {
      const { slot, sql, params } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/query", payload);
    }
    case "turso_execute": {
      const { slot, sql } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      return post("/api/v1/execute", payload);
    }
    case "turso_batch": {
      const { slot, statements } = args ?? {};
      if (!slot || !statements) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, statements };
      return post("/api/v1/batch", payload);
    }
    case "turso_list_tables": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-tables", payload);
    }
    case "turso_sync": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/sync", payload);
    }
    case "turso_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
