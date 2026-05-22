// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// database-mcp/mod.js -- database gateway.

const BASE_URL = Deno.env.get("DATABASE_MCP_BACKEND_URL") ?? "http://127.0.0.1:7718";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "database-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `database-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "database_connect": {
      const { backend, connection_string } = args ?? {};
      if (!backend || !connection_string) return { status: 400, data: { error: "backend is required" } };
      const payload = { backend, connection_string };
      return post("/api/v1/connect", payload);
    }
    case "database_query": {
      const { slot, query, params } = args ?? {};
      if (!slot || !query) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, query };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/query", payload);
    }
    case "database_execute": {
      const { slot, statement, params } = args ?? {};
      if (!slot || !statement) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, statement };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/execute", payload);
    }
    case "database_list_tables": {
      const { slot, schema } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (schema !== undefined) payload.schema = schema;
      return post("/api/v1/list-tables", payload);
    }
    case "database_describe": {
      const { slot, table } = args ?? {};
      if (!slot || !table) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table };
      return post("/api/v1/describe", payload);
    }
    case "database_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
