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

    // ── Consultant-mode Q&A (Phase 6 of echidnabot bot-mode wiring) ────────
    case "consultant_qa": {
      // Args: { repo: string, pr_number: number, question: string, context: string }
      //
      // Composes existing ECHIDNA endpoints into a single markdown-formatted
      // Q&A response. Used by echidnabot when a Consultant-mode repo gets
      // an `@echidnabot` mention on a PR comment.
      //
      // Strategy (composition over a new endpoint):
      //   1. /api/search — keyword search over the 66,674-proof corpus
      //      for proofs related to the user's question. Surfaces precedent
      //      that the reviewer might find useful.
      //   2. /api/tactics/suggest — aspect-tag model gives tactic hints
      //      for a freeform goal-shaped query.
      //   3. Format both into a single markdown answer block.
      //
      // No new ECHIDNA endpoint is needed; if one ever lands at /api/consult,
      // route preferentially to it from here.
      const question = (a.question ?? "").trim();
      if (!question) {
        return {
          status: 200,
          data: {
            answer:
              "_Mention received — no question text. Ping me with `@echidnabot " +
              "<your question>` and I'll look up related proofs and suggestions._",
            provenance: "no-op (empty question)",
          },
        };
      }

      const [searchResp, suggestResp] = await Promise.all([
        restGet(`/api/search?q=${encodeURIComponent(question)}`),
        restPost("/api/tactics/suggest", {
          goal: question,
          top_k: 3,
          active_tags: [],
        }),
      ]);

      const lines = [];
      lines.push("## 🦔 echidnabot · Consultant — composed answer");
      lines.push("");
      lines.push(`> ${question.slice(0, 200)}`);
      lines.push("");

      if (searchResp.status === 200 && Array.isArray(searchResp.data?.results) &&
          searchResp.data.results.length > 0) {
        lines.push("### 📚 Related precedent (corpus search)");
        lines.push("");
        for (const hit of searchResp.data.results.slice(0, 5)) {
          const name = hit.theorem ?? hit.name ?? hit.id ?? "?";
          const prover = hit.prover ?? "?";
          lines.push(`- \`${name}\` · ${prover}`);
        }
        lines.push("");
      }

      if (suggestResp.status === 200 && Array.isArray(suggestResp.data?.suggestions) &&
          suggestResp.data.suggestions.length > 0) {
        lines.push("### 💡 Tactic hints (aspect-tag model)");
        lines.push("");
        for (const s of suggestResp.data.suggestions.slice(0, 3)) {
          const tactic = s.tactic ?? s.text ?? "?";
          const conf = s.confidence != null ? ` (${(s.confidence * 100).toFixed(0)}%)` : "";
          lines.push(`- \`${tactic}\`${conf}`);
        }
        lines.push("");
      }

      if (lines.length === 4) {
        // Header + question, no search/suggest content — surface that.
        lines.push("_No related precedent or tactic suggestions found in the corpus._");
        lines.push(
          "_This response is a composition of /api/search + /api/tactics/suggest; " +
          "richer free-form Q&A awaits a dedicated /api/consult endpoint upstream._",
        );
      }

      return {
        status: 200,
        data: {
          answer: lines.join("\n"),
          provenance: "echidna-llm-mcp/consultant_qa: search+tactics/suggest composite",
        },
      };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
