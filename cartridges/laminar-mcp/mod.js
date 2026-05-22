// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// laminar-mcp/mod.js — Laminar CI/CD pipeline management
//
// Delegates to backend at http://127.0.0.1:7731 (override with LAMINAR_BACKEND_URL).

const BASE_URL = Deno.env.get("LAMINAR_BACKEND_URL") ?? "http://127.0.0.1:7731";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "laminar-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `laminar-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "laminar-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `laminar-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "laminar_create_pipeline":
      return post("/api/v1/laminar_create_pipeline", args ?? {});
    case "laminar_run_stage":
      return post("/api/v1/laminar_run_stage", args ?? {});
    case "laminar_get_status":
      return post("/api/v1/laminar_get_status", args ?? {});
    case "laminar_cancel_pipeline":
      return post("/api/v1/laminar_cancel_pipeline", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
