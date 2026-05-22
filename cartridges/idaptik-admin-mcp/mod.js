// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// idaptik-admin-mcp/mod.js — IDApTIK game server administration
//
// Delegates to backend at http://127.0.0.1:7729 (override with IDAPTIK_ADMIN_URL).

const BASE_URL = Deno.env.get("IDAPTIK_ADMIN_URL") ?? "http://127.0.0.1:7729";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "idaptik-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `idaptik-admin-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "idaptik-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `idaptik-admin-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "idaptik_server_status":
      return post("/api/v1/idaptik_server_status", args ?? {});
    case "idaptik_list_sessions":
      return post("/api/v1/idaptik_list_sessions", args ?? {});
    case "idaptik_create_session":
      return post("/api/v1/idaptik_create_session", args ?? {});
    case "idaptik_end_session":
      return post("/api/v1/idaptik_end_session", args ?? {});
    case "idaptik_get_config":
      return post("/api/v1/idaptik_get_config", args ?? {});
    case "idaptik_update_config":
      return post("/api/v1/idaptik_update_config", args ?? {});
    case "idaptik_list_level_packs":
      return post("/api/v1/idaptik_list_level_packs", args ?? {});
    case "idaptik_toggle_training":
      return post("/api/v1/idaptik_toggle_training", args ?? {});
    case "idaptik_player_stats":
      return post("/api/v1/idaptik_player_stats", args ?? {});
    case "idaptik_server_action":
      return post("/api/v1/idaptik_server_action", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
