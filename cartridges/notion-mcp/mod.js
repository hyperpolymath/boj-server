// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// notion-mcp/mod.js — Notion workspace pages, databases, and blocks
//
// Delegates to backend at http://127.0.0.1:7735 (override with NOTION_BACKEND_URL).

const BASE_URL = Deno.env.get("NOTION_BACKEND_URL") ?? "http://127.0.0.1:7735";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "notion-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `notion-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "notion-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `notion-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "notion_authenticate":
      return post("/api/v1/notion_authenticate", args ?? {});
    case "notion_search":
      return post("/api/v1/notion_search", args ?? {});
    case "notion_get_page":
      return post("/api/v1/notion_get_page", args ?? {});
    case "notion_create_page":
      return post("/api/v1/notion_create_page", args ?? {});
    case "notion_update_page":
      return post("/api/v1/notion_update_page", args ?? {});
    case "notion_query_database":
      return post("/api/v1/notion_query_database", args ?? {});
    case "notion_append_blocks":
      return post("/api/v1/notion_append_blocks", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
