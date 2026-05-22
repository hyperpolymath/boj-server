// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ssg-mcp/mod.js — Static site generator (Hugo, Zola, Astro, Casket)
//
// Delegates to backend at http://127.0.0.1:7742 (override with SSG_BACKEND_URL).

const BASE_URL = Deno.env.get("SSG_BACKEND_URL") ?? "http://127.0.0.1:7742";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "ssg-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `ssg-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "ssg-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `ssg-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "ssg_load_content":
      return post("/api/v1/ssg_load_content", args ?? {});
    case "ssg_build":
      return post("/api/v1/ssg_build", args ?? {});
    case "ssg_preview":
      return post("/api/v1/ssg_preview", args ?? {});
    case "ssg_deploy":
      return post("/api/v1/ssg_deploy", args ?? {});
    case "ssg_clean":
      return post("/api/v1/ssg_clean", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
