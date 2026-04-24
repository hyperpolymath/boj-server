// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp/mod.js — ECHIDNA cross-repo invocation surface (105 provers)
//
// Backend: ECHIDNA REST API at ECHIDNA_REST_URL.
//   Local default:  http://127.0.0.1:8081  (echidna --port 8081, the main.rs default)
//   Fly.io private: http://echidna-nesy.flycast:8090
//
// All 15 tools go through the single REST backend — there is no separate LLM port.
// Tactic suggestions are served by the Julia ML layer at /api/suggest, and by the
// aspect-tag model at /api/tactics/suggest; both are behind the same 8081 gateway.

const REST_URL = Deno.env.get("ECHIDNA_REST_URL") ?? "http://127.0.0.1:8081";
const TIMEOUT_MS = 30_000;

async function restPost(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${REST_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna timed out" } };
    return { status: 503, data: { success: false, error: `echidna unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

async function restGet(path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${REST_URL}${path}`, { method: "GET", signal: ctrl.signal });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "echidna timed out" } };
    return { status: 503, data: { success: false, error: `echidna unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  const a = args ?? {};
  switch (toolName) {
    // ── Discovery / health ─────────────────────────────────────────────────
    case "echidna_list_provers":
      // Returns all 105 provers: name, tier, complexity. Call this first to get
      // valid prover IDs for other tools. Corresponds to GET /api/provers.
      return restGet("/api/provers");

    case "echidna_health":
      return restGet("/api/health");

    case "echidna_rank_provers":
      // Returns the same prover list as echidna_list_provers but intended as
      // a selection hint: sort the response by tier ASC, complexity ASC to pick
      // the prover most likely to succeed for a given domain.
      return restGet("/api/provers");

    case "echidna_aspect_tags":
      return restGet("/api/aspect-tags");

    // ── Proof invocation ───────────────────────────────────────────────────
    case "echidna_prove":
      // POST /api/prove — invoke a prover on file content.
      // Body: { prover: ProverKind, content: string, timeout?: number, neural?: bool }
      return restPost("/api/prove", a);

    case "echidna_verify":
      // POST /api/verify — verify proof content (parse + verify round-trip).
      // Body: { prover: ProverKind, content: string }
      return restPost("/api/verify", a);

    case "echidna_verify_raw":
      // POST /api/verify_raw — invoke prover binary directly on raw content,
      // skipping the parse/export round-trip. Needed for EProver, CaDiCaL, etc.
      // Body: { prover: ProverKind, content: string }
      return restPost("/api/verify_raw", a);

    // ── Tactic / premise suggestions ───────────────────────────────────────
    case "echidna_suggest":
      // POST /api/suggest — Julia ML neural tactic suggestions (corpus-backed).
      // Body: { prover: ProverKind, content: string, limit?: number }
      return restPost("/api/suggest", a);

    case "echidna_suggest_tactics":
      // POST /api/tactics/suggest — aspect-tag model tactic suggestions.
      // Body: { goal: string, prover?: string, active_tags?: string[], top_k?: number }
      // Advisory only — results are hints; they do not affect ECHIDNA trust levels.
      return restPost("/api/tactics/suggest", a);

    // ── Corpus search ──────────────────────────────────────────────────────
    case "echidna_search":
      // GET /api/search?q=... — keyword search over 66,674-proof corpus.
      return restGet(`/api/search?q=${encodeURIComponent(a.query ?? "")}`);

    case "echidna_search_theorems":
      // GET /api/theorems/search?q=... — theorem-specific search with metadata.
      return restGet(`/api/theorems/search?q=${encodeURIComponent(a.query ?? "")}`);

    // ── Interactive proof sessions ─────────────────────────────────────────
    case "echidna_session_create":
      // POST /api/session/create — start an interactive tactic session.
      // Body: { prover: ProverKind }  Returns: { session_id: string }
      return restPost("/api/session/create", a);

    case "echidna_session_state": {
      // GET /api/session/:id/state — current goals and completion status.
      const id = encodeURIComponent(a.session_id ?? "");
      return restGet(`/api/session/${id}/state`);
    }

    case "echidna_session_apply": {
      // POST /api/session/:id/apply — apply a tactic to the current goal.
      // Body: { session_id: string, tactic: string }
      const id = encodeURIComponent(a.session_id ?? "");
      return restPost(`/api/session/${id}/apply`, { tactic: a.tactic ?? "" });
    }

    case "echidna_session_tree": {
      // GET /api/session/:id/tree — proof tree for the session.
      const id = encodeURIComponent(a.session_id ?? "");
      return restGet(`/api/session/${id}/tree`);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
