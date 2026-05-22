// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// postgresql-mcp/mod.js -- postgresql gateway.

const BASE_URL = Deno.env.get("POSTGRESQL_MCP_BACKEND_URL") ?? "http://127.0.0.1:7719";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "postgresql-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `postgresql-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "pg_connect": {
      const { connection_string } = args ?? {};
      if (!connection_string) return { status: 400, data: { error: "connection_string is required" } };
      const payload = { connection_string };
      return post("/api/v1/pg-connect", payload);
    }
    case "pg_query": {
      const { slot, sql, params } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/pg-query", payload);
    }
    case "pg_execute": {
      const { slot, sql, params } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/pg-execute", payload);
    }
    case "pg_begin": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/pg-begin", payload);
    }
    case "pg_commit": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/pg-commit", payload);
    }
    case "pg_rollback": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/pg-rollback", payload);
    }
    case "pg_list_tables": {
      const { slot, schema } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (schema !== undefined) payload.schema = schema;
      return post("/api/v1/pg-list-tables", payload);
    }
    case "pg_describe": {
      const { slot, table } = args ?? {};
      if (!slot || !table) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table };
      return post("/api/v1/pg-describe", payload);
    }
    case "pg_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/pg-disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
