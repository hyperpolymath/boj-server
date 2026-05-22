// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// clickhouse-mcp/mod.js -- clickhouse gateway.

const BASE_URL = Deno.env.get("CLICKHOUSE_MCP_BACKEND_URL") ?? "http://127.0.0.1:7722";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "clickhouse-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `clickhouse-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "clickhouse_connect": {
      const { host, port, database, user, password } = args ?? {};
      const payload = {  };
      if (host !== undefined) payload.host = host;
      if (port !== undefined) payload.port = port;
      if (database !== undefined) payload.database = database;
      if (user !== undefined) payload.user = user;
      if (password !== undefined) payload.password = password;
      return post("/api/v1/connect", payload);
    }
    case "clickhouse_query": {
      const { slot, sql, format } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      if (format !== undefined) payload.format = format;
      return post("/api/v1/query", payload);
    }
    case "clickhouse_insert": {
      const { slot, table, data } = args ?? {};
      if (!slot || !table || !data) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table, data };
      return post("/api/v1/insert", payload);
    }
    case "clickhouse_ddl": {
      const { slot, sql } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      return post("/api/v1/ddl", payload);
    }
    case "clickhouse_list_tables": {
      const { slot, database } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (database !== undefined) payload.database = database;
      return post("/api/v1/list-tables", payload);
    }
    case "clickhouse_describe": {
      const { slot, table } = args ?? {};
      if (!slot || !table) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table };
      return post("/api/v1/describe", payload);
    }
    case "clickhouse_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
