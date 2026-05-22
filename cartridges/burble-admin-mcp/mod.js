// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// burble-admin-mcp/mod.js — Burble WebRTC server administration
//
// Delegates to backend at http://127.0.0.1:7713 (override with BURBLE_ADMIN_URL).

const BASE_URL = Deno.env.get("BURBLE_ADMIN_URL") ?? "http://127.0.0.1:7713";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "burble-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `burble-admin-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "burble-admin-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `burble-admin-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "burble_check_health":
      return post("/api/v1/burble_check_health", args ?? {});
    case "burble_list_rooms":
      return post("/api/v1/burble_list_rooms", args ?? {});
    case "burble_create_room":
      return post("/api/v1/burble_create_room", args ?? {});
    case "burble_close_room":
      return post("/api/v1/burble_close_room", args ?? {});
    case "burble_kick_user":
      return post("/api/v1/burble_kick_user", args ?? {});
    case "burble_get_config":
      return post("/api/v1/burble_get_config", args ?? {});
    case "burble_update_config":
      return post("/api/v1/burble_update_config", args ?? {});
    case "burble_voice_stats":
      return post("/api/v1/burble_voice_stats", args ?? {});
    case "burble_toggle_recording":
      return post("/api/v1/burble_toggle_recording", args ?? {});
    case "burble_node_status":
      return post("/api/v1/burble_node_status", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
