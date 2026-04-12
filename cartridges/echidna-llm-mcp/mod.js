// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp/mod.js — ECHIDNA LLM proof-tactic neurosymbolic interface
//
// Delegates to backend at http://127.0.0.1:7721 (override with ECHIDNA_LLM_URL).

const BASE_URL = Deno.env.get("ECHIDNA_LLM_URL") ?? "http://127.0.0.1:7721";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna-llm-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `echidna-llm-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna-llm-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `echidna-llm-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "echidna_init":
      return post("/api/v1/echidna_init", args ?? {});
    case "echidna_authenticate":
      return post("/api/v1/echidna_authenticate", args ?? {});
    case "echidna_suggest_tactics":
      return post("/api/v1/echidna_suggest_tactics", args ?? {});
    case "echidna_rank_provers":
      return post("/api/v1/echidna_rank_provers", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
