// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// agent-mcp/mod.js — OODA loop agent session enforcer
//
// Delegates to backend at http://127.0.0.1:7711 (override with AGENT_BACKEND_URL).

const BASE_URL = Deno.env.get("AGENT_BACKEND_URL") ?? "http://127.0.0.1:7711";
const TIMEOUT_MS = 15_000;

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "agent-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `agent-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

async function get(path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, { method: "GET", signal: ctrl.signal });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "agent-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `agent-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "agent_new_session":
      return post("/api/v1/agent_new_session", args ?? {});
    case "agent_end_session":
      return post("/api/v1/agent_end_session", args ?? {});
    case "agent_transition":
      return post("/api/v1/agent_transition", args ?? {});
    case "agent_state":
      return post("/api/v1/agent_state", args ?? {});
    case "agent_loop_count":
      return post("/api/v1/agent_loop_count", args ?? {});
    case "agent_validate_ooda":
      return post("/api/v1/agent_validate_ooda", args ?? {});
    case "agent_reset":
      return post("/api/v1/agent_reset", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
