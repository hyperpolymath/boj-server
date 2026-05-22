// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pmpl-mcp/mod.js — PMPL licence chain verification and artefact hashing
//
// Delegates to backend at http://127.0.0.1:7737 (override with PMPL_BACKEND_URL).

const BASE_URL = Deno.env.get("PMPL_BACKEND_URL") ?? "http://127.0.0.1:7737";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "pmpl-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `pmpl-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "pmpl-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `pmpl-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "pmpl_create_chain":
      return post("/api/v1/pmpl_create_chain", args ?? {});
    case "pmpl_extend_chain":
      return post("/api/v1/pmpl_extend_chain", args ?? {});
    case "pmpl_verify_chain":
      return post("/api/v1/pmpl_verify_chain", args ?? {});
    case "pmpl_hash_artefact":
      return post("/api/v1/pmpl_hash_artefact", args ?? {});
    case "pmpl_check_compatible":
      return post("/api/v1/pmpl_check_compatible", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
