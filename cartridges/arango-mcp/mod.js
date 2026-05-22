// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// arango-mcp/mod.js -- arango gateway.

const BASE_URL = Deno.env.get("ARANGO_MCP_BACKEND_URL") ?? "http://127.0.0.1:7727";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "arango-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `arango-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "arango_connect": {
      const { url, database, username, password } = args ?? {};
      if (!url) return { status: 400, data: { error: "url is required" } };
      const payload = { url };
      if (database !== undefined) payload.database = database;
      if (username !== undefined) payload.username = username;
      if (password !== undefined) payload.password = password;
      return post("/api/v1/connect", payload);
    }
    case "arango_aql": {
      const { slot, query, bind_vars } = args ?? {};
      if (!slot || !query) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, query };
      if (bind_vars !== undefined) payload.bind_vars = bind_vars;
      return post("/api/v1/aql", payload);
    }
    case "arango_insert": {
      const { slot, collection, document } = args ?? {};
      if (!slot || !collection || !document) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, document };
      return post("/api/v1/insert", payload);
    }
    case "arango_get": {
      const { slot, collection, key } = args ?? {};
      if (!slot || !collection || !key) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, key };
      return post("/api/v1/get", payload);
    }
    case "arango_update": {
      const { slot, collection, key, update } = args ?? {};
      if (!slot || !collection || !key || !update) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, key, update };
      return post("/api/v1/update", payload);
    }
    case "arango_delete": {
      const { slot, collection, key } = args ?? {};
      if (!slot || !collection || !key) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, key };
      return post("/api/v1/delete", payload);
    }
    case "arango_graph_traversal": {
      const { slot, graph, start_vertex, depth } = args ?? {};
      if (!slot || !graph || !start_vertex) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, graph, start_vertex };
      if (depth !== undefined) payload.depth = depth;
      return post("/api/v1/graph-traversal", payload);
    }
    case "arango_list_collections": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-collections", payload);
    }
    case "arango_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
