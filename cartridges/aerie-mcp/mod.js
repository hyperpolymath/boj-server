// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aerie-mcp/mod.js — Aerie environment lifecycle manager
//
// Delegates to backend at http://127.0.0.1:7710 (override with AERIE_BACKEND_URL).

const BASE_URL = Deno.env.get("AERIE_BACKEND_URL") ?? "http://127.0.0.1:7710";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "aerie-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `aerie-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "aerie-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `aerie-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "aerie_list_envs":
      return post("/api/v1/aerie_list_envs", args ?? {});
    case "aerie_create_env":
      return post("/api/v1/aerie_create_env", args ?? {});
    case "aerie_destroy_env":
      return post("/api/v1/aerie_destroy_env", args ?? {});
    case "aerie_get_status":
      return post("/api/v1/aerie_get_status", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
