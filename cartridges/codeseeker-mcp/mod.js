// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// codeseeker-mcp/mod.js — CodeSeeker hybrid code search and graph RAG
//
// Delegates to backend at http://127.0.0.1:7716 (override with CODESEEKER_BACKEND_URL).

const BASE_URL = Deno.env.get("CODESEEKER_BACKEND_URL") ?? "http://127.0.0.1:7716";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "codeseeker-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `codeseeker-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "codeseeker-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `codeseeker-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "codeseeker_open":
      return post("/api/v1/codeseeker_open", args ?? {});
    case "codeseeker_close":
      return post("/api/v1/codeseeker_close", args ?? {});
    case "codeseeker_index":
      return post("/api/v1/codeseeker_index", args ?? {});
    case "codeseeker_query":
      return post("/api/v1/codeseeker_query", args ?? {});
    case "codeseeker_state":
      return post("/api/v1/codeseeker_state", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
