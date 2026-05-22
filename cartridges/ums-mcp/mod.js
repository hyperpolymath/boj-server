// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ums-mcp/mod.js — Universal Map Specification — level editor and validator
//
// Delegates to backend at http://127.0.0.1:7743 (override with UMS_BACKEND_URL).

const BASE_URL = Deno.env.get("UMS_BACKEND_URL") ?? "http://127.0.0.1:7743";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "ums-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `ums-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "ums-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `ums-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "ums_create_project":
      return post("/api/v1/ums_create_project", args ?? {});
    case "ums_open_project":
      return post("/api/v1/ums_open_project", args ?? {});
    case "ums_close_project":
      return post("/api/v1/ums_close_project", args ?? {});
    case "ums_load_level":
      return post("/api/v1/ums_load_level", args ?? {});
    case "ums_save_level":
      return post("/api/v1/ums_save_level", args ?? {});
    case "ums_validate_level":
      return post("/api/v1/ums_validate_level", args ?? {});
    case "ums_list_profiles":
      return post("/api/v1/ums_list_profiles", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
