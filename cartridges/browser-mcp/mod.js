// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// browser-mcp/mod.js — Firefox browser automation via Marionette
//
// Delegates to backend at http://127.0.0.1:7712 (override with BROWSER_BACKEND_URL).

const BASE_URL = Deno.env.get("BROWSER_BACKEND_URL") ?? "http://127.0.0.1:7712";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "browser-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `browser-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "browser-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `browser-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "browser_open":
      return post("/api/v1/browser_open", args ?? {});
    case "browser_close":
      return post("/api/v1/browser_close", args ?? {});
    case "browser_connect":
      return post("/api/v1/browser_connect", args ?? {});
    case "browser_navigate":
      return post("/api/v1/browser_navigate", args ?? {});
    case "browser_click":
      return post("/api/v1/browser_click", args ?? {});
    case "browser_type":
      return post("/api/v1/browser_type", args ?? {});
    case "browser_screenshot":
      return post("/api/v1/browser_screenshot", args ?? {});
    case "browser_read_page":
      return post("/api/v1/browser_read_page", args ?? {});
    case "browser_tab_list":
      return post("/api/v1/browser_tab_list", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
