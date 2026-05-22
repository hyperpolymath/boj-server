// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// reposystem-mcp/mod.js -- reposystem gateway

const BASE_URL = Deno.env.get("REPOSYSTEM_BACKEND_URL") ?? "http://127.0.0.1:7710";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "reposystem-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `reposystem-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "reposystem_list_repos": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/list-repos", payload);
    }

    case "reposystem_check_health": {
      const { repo_name } = args ?? {};
      if (!repo_name) return { status: 400, data: { error: "repo_name is required" } };
      const payload = { repo_name };
      return post("/api/v1/check-health", payload);
    }

    case "reposystem_sync_mirrors": {
      const { repo_name } = args ?? {};
      if (!repo_name) return { status: 400, data: { error: "repo_name is required" } };
      const payload = { repo_name };
      return post("/api/v1/sync-mirrors", payload);
    }

    case "reposystem_run_audit": {
      const { repo_name } = args ?? {};
      if (!repo_name) return { status: 400, data: { error: "repo_name is required" } };
      const payload = { repo_name };
      return post("/api/v1/run-audit", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
