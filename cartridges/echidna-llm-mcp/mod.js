// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp/mod.js — ECHIDNA cross-repo invocation surface
//
// Two backend URLs:
//   ECHIDNA_LLM_URL  (default :7721) — LLM advisory ops (suggest, rank)
//   ECHIDNA_REST_URL (default :8000) — Full 105-prover REST API (list, prove, verify)

const LLM_URL  = Deno.env.get("ECHIDNA_LLM_URL")  ?? "http://127.0.0.1:7721";
const REST_URL = Deno.env.get("ECHIDNA_REST_URL") ?? "http://127.0.0.1:8000";
const TIMEOUT_MS = 30_000;

async function post(baseUrl, path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${baseUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna backend timed out" } };
    return { status: 503, data: { success: false, error: `echidna backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

async function get(baseUrl, path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${baseUrl}${path}`, { method: "GET", signal: ctrl.signal });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna backend timed out" } };
    return { status: 503, data: { success: false, error: `echidna backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    // ── Discovery ──────────────────────────────────────────────────────────
    case "echidna_list_provers":
      // Returns all 105 provers with name, tier, category, and complexity.
      return get(REST_URL, "/api/provers");

    // ── Proof invocation ───────────────────────────────────────────────────
    case "echidna_prove":
      // Invoke a prover backend on a file path. Requires `file`; `prover`
      // and `timeout_secs` are optional (auto-detect from extension if omitted).
      return post(REST_URL, "/api/prove", args ?? {});

    case "echidna_verify":
      // Verify proof content from a string. Requires `content` and `prover`.
      return post(REST_URL, "/api/verify", args ?? {});

    // ── Tactic search ──────────────────────────────────────────────────────
    case "echidna_search":
      // Keyword search over the proof corpus. Accepts `query` string.
      return get(REST_URL, `/api/search?q=${encodeURIComponent((args ?? {}).query ?? "")}`);

    // ── LLM advisory ops (port 7721) ───────────────────────────────────────
    case "echidna_init":
      return post(LLM_URL, "/api/v1/echidna_init", args ?? {});

    case "echidna_authenticate":
      return post(LLM_URL, "/api/v1/echidna_authenticate", args ?? {});

    case "echidna_suggest_tactics":
      return post(LLM_URL, "/api/v1/echidna_suggest_tactics", args ?? {});

    case "echidna_rank_provers":
      return post(LLM_URL, "/api/v1/echidna_rank_provers", args ?? {});

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
