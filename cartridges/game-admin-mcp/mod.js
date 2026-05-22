// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// game-admin-mcp/mod.js — Game server administration and configuration drift
//
// Delegates to backend at http://127.0.0.1:7724 (override with GAME_ADMIN_URL).

const BASE_URL = Deno.env.get("GAME_ADMIN_URL") ?? "http://127.0.0.1:7724";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "game-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `game-admin-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "game-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `game-admin-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "game_probe_server":
      return post("/api/v1/game_probe_server", args ?? {});
    case "game_list_servers":
      return post("/api/v1/game_list_servers", args ?? {});
    case "game_get_config":
      return post("/api/v1/game_get_config", args ?? {});
    case "game_set_config":
      return post("/api/v1/game_set_config", args ?? {});
    case "game_server_action":
      return post("/api/v1/game_server_action", args ?? {});
    case "game_drift_status":
      return post("/api/v1/game_drift_status", args ?? {});
    case "game_list_profiles":
      return post("/api/v1/game_list_profiles", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
