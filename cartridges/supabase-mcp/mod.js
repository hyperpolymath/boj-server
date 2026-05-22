// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// supabase-mcp/mod.js -- supabase gateway.

const BASE_URL = Deno.env.get("SUPABASE_MCP_BACKEND_URL") ?? "http://127.0.0.1:7725";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "supabase-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `supabase-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "supabase_connect": {
      const { project_url, anon_key } = args ?? {};
      if (!project_url || !anon_key) return { status: 400, data: { error: "project_url is required" } };
      const payload = { project_url, anon_key };
      return post("/api/v1/connect", payload);
    }
    case "supabase_query": {
      const { slot, table, filter, select } = args ?? {};
      if (!slot || !table) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table };
      if (filter !== undefined) payload.filter = filter;
      if (select !== undefined) payload.select = select;
      return post("/api/v1/query", payload);
    }
    case "supabase_insert": {
      const { slot, table, data } = args ?? {};
      if (!slot || !table || !data) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table, data };
      return post("/api/v1/insert", payload);
    }
    case "supabase_update": {
      const { slot, table, filter, data } = args ?? {};
      if (!slot || !table || !filter || !data) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table, filter, data };
      return post("/api/v1/update", payload);
    }
    case "supabase_delete": {
      const { slot, table, filter } = args ?? {};
      if (!slot || !table || !filter) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, table, filter };
      return post("/api/v1/delete", payload);
    }
    case "supabase_storage_list": {
      const { slot, bucket, path } = args ?? {};
      if (!slot || !bucket) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, bucket };
      if (path !== undefined) payload.path = path;
      return post("/api/v1/storage-list", payload);
    }
    case "supabase_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
