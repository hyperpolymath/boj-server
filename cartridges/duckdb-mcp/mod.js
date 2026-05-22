// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// duckdb-mcp/mod.js -- duckdb gateway.

const BASE_URL = Deno.env.get("DUCKDB_MCP_BACKEND_URL") ?? "http://127.0.0.1:7723";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "duckdb-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `duckdb-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "duckdb_open": {
      const { path } = args ?? {};
      if (!path) return { status: 400, data: { error: "path is required" } };
      const payload = { path };
      return post("/api/v1/open", payload);
    }
    case "duckdb_query": {
      const { slot, sql } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      return post("/api/v1/query", payload);
    }
    case "duckdb_execute": {
      const { slot, sql } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      return post("/api/v1/execute", payload);
    }
    case "duckdb_import": {
      const { slot, file_path, table_name } = args ?? {};
      if (!slot || !file_path || !table_name) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, file_path, table_name };
      return post("/api/v1/import", payload);
    }
    case "duckdb_export": {
      const { slot, query, output_path } = args ?? {};
      if (!slot || !query || !output_path) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, query, output_path };
      return post("/api/v1/export", payload);
    }
    case "duckdb_list_tables": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-tables", payload);
    }
    case "duckdb_close": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/close", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
