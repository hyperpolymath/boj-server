// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// neon-mcp/mod.js -- neon gateway.

const BASE_URL = Deno.env.get("NEON_MCP_BACKEND_URL") ?? "http://127.0.0.1:7724";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "neon-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `neon-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "neon_connect": {
      const { connection_string } = args ?? {};
      if (!connection_string) return { status: 400, data: { error: "connection_string is required" } };
      const payload = { connection_string };
      return post("/api/v1/connect", payload);
    }
    case "neon_query": {
      const { slot, sql, params } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      if (params !== undefined) payload.params = params;
      return post("/api/v1/query", payload);
    }
    case "neon_execute": {
      const { slot, sql } = args ?? {};
      if (!slot || !sql) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, sql };
      return post("/api/v1/execute", payload);
    }
    case "neon_list_branches": {
      const { project_id } = args ?? {};
      if (!project_id) return { status: 400, data: { error: "project_id is required" } };
      const payload = { project_id };
      return post("/api/v1/list-branches", payload);
    }
    case "neon_create_branch": {
      const { project_id, branch_name, parent_branch } = args ?? {};
      if (!project_id || !branch_name) return { status: 400, data: { error: "project_id is required" } };
      const payload = { project_id, branch_name };
      if (parent_branch !== undefined) payload.parent_branch = parent_branch;
      return post("/api/v1/create-branch", payload);
    }
    case "neon_list_tables": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-tables", payload);
    }
    case "neon_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
