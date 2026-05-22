// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// claude-agents-power-mcp/mod.js — Claude Agents Power MCP cartridge.
//
// Delegates to backend at http://127.0.0.1:3000 (override with CLAUDE_AGENTS_URL).
// Auth: GITHUB_TOKEN (required for agent install; list/search work without it).

const BASE_URL = Deno.env.get("CLAUDE_AGENTS_URL") ?? "http://127.0.0.1:3000";
const TIMEOUT_MS = 20_000;

function getToken() {
  return Deno.env.get("GITHUB_TOKEN") ?? null;
}

function authHeaders() {
  const token = getToken();
  const h = { "Content-Type": "application/json" };
  if (token) h["Authorization"] = `Bearer ${token}`;
  return h;
}

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "claude-agents-power-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `claude-agents-power-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "claude_agents_analyze_project": {
      const { project_path, language } = args ?? {};
      const payload = {};
      if (project_path !== undefined) payload.project_path = project_path;
      if (language !== undefined) payload.language = language;
      return post("/api/v1/agents/analyze", payload);
    }

    case "claude_agents_list_agents": {
      const { category, language, limit } = args ?? {};
      const payload = {};
      if (category !== undefined) payload.category = category;
      if (language !== undefined) payload.language = language;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/agents/list", payload);
    }

    case "claude_agents_search_agents": {
      const { keywords, language } = args ?? {};
      if (!keywords) return { status: 400, data: { error: "keywords is required" } };
      const payload = { keywords };
      if (language !== undefined) payload.language = language;
      return post("/api/v1/agents/search", payload);
    }

    case "claude_agents_install_agents": {
      if (!getToken())
        return { status: 401, data: { error: "GITHUB_TOKEN env var is required to install agents" } };
      const { agent_ids, target_dir, language } = args ?? {};
      if (!agent_ids || !Array.isArray(agent_ids) || agent_ids.length === 0)
        return { status: 400, data: { error: "agent_ids array is required" } };
      const payload = { agent_ids };
      if (target_dir !== undefined) payload.target_dir = target_dir;
      if (language !== undefined) payload.language = language;
      return post("/api/v1/agents/install", payload);
    }

    case "claude_agents_get_download_stats": {
      const { agent_id, limit } = args ?? {};
      const payload = {};
      if (agent_id !== undefined) payload.agent_id = agent_id;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/agents/stats", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
