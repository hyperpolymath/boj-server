// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// mongodb-mcp/mod.js -- mongodb gateway.

const BASE_URL = Deno.env.get("MONGODB_MCP_BACKEND_URL") ?? "http://127.0.0.1:7720";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "mongodb-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `mongodb-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "mongo_connect": {
      const { connection_string, database } = args ?? {};
      if (!connection_string || !database) return { status: 400, data: { error: "connection_string is required" } };
      const payload = { connection_string, database };
      return post("/api/v1/mongo-connect", payload);
    }
    case "mongo_find": {
      const { slot, collection, filter, limit } = args ?? {};
      if (!slot || !collection) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection };
      if (filter !== undefined) payload.filter = filter;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/mongo-find", payload);
    }
    case "mongo_insert": {
      const { slot, collection, documents } = args ?? {};
      if (!slot || !collection || !documents) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, documents };
      return post("/api/v1/mongo-insert", payload);
    }
    case "mongo_update": {
      const { slot, collection, filter, update, multi } = args ?? {};
      if (!slot || !collection || !filter || !update) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, filter, update };
      if (multi !== undefined) payload.multi = multi;
      return post("/api/v1/mongo-update", payload);
    }
    case "mongo_delete": {
      const { slot, collection, filter } = args ?? {};
      if (!slot || !collection || !filter) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, filter };
      return post("/api/v1/mongo-delete", payload);
    }
    case "mongo_aggregate": {
      const { slot, collection, pipeline } = args ?? {};
      if (!slot || !collection || !pipeline) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, collection, pipeline };
      return post("/api/v1/mongo-aggregate", payload);
    }
    case "mongo_list_collections": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/mongo-list-collections", payload);
    }
    case "mongo_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/mongo-disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
