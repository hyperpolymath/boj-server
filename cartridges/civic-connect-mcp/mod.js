// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// civic-connect-mcp/mod.js — CivicConnect community engagement platform
//
// Delegates to backend at http://127.0.0.1:7714 (override with CIVIC_CONNECT_URL).

const BASE_URL = Deno.env.get("CIVIC_CONNECT_URL") ?? "http://127.0.0.1:7714";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "civic-connect-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `civic-connect-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "civic-connect-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `civic-connect-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "civic_list_channels":
      return post("/api/v1/civic_list_channels", args ?? {});
    case "civic_send_message":
      return post("/api/v1/civic_send_message", args ?? {});
    case "civic_get_poll":
      return post("/api/v1/civic_get_poll", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
