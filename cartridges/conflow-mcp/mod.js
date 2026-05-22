// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// conflow-mcp/mod.js — Conflow configuration management
//
// Delegates to backend at http://127.0.0.1:7718 (override with CONFLOW_BACKEND_URL).

const BASE_URL = Deno.env.get("CONFLOW_BACKEND_URL") ?? "http://127.0.0.1:7718";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "conflow-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `conflow-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "conflow-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `conflow-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "conflow_get_config":
      return post("/api/v1/conflow_get_config", args ?? {});
    case "conflow_apply_config":
      return post("/api/v1/conflow_apply_config", args ?? {});
    case "conflow_validate_config":
      return post("/api/v1/conflow_validate_config", args ?? {});
    case "conflow_diff_config":
      return post("/api/v1/conflow_diff_config", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
