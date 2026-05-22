// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// research-mcp/mod.js — Academic paper search (Semantic Scholar, OpenAlex)
//
// Delegates to backend at http://127.0.0.1:7739 (override with RESEARCH_BACKEND_URL).

const BASE_URL = Deno.env.get("RESEARCH_BACKEND_URL") ?? "http://127.0.0.1:7739";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "research-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `research-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "research-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `research-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "research_authenticate":
      return post("/api/v1/research_authenticate", args ?? {});
    case "research_search":
      return post("/api/v1/research_search", args ?? {});
    case "research_get_paper":
      return post("/api/v1/research_get_paper", args ?? {});
    case "research_list_providers":
      return post("/api/v1/research_list_providers", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
