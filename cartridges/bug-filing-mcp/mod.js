// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// bug-filing-mcp/mod.js — autonomous bug-report filing.
//
// Wraps the real feedback-o-tron engine via its localhost HTTP intake
// (http://127.0.0.1:7722; run the engine with FEEDBACK_A_TRON_HTTP=1).
// Override the backend with BUG_FILING_BACKEND_URL.
//
// v0.2 tools (the interactive loop): research_feedback (avoid duplicates,
// get the repo's template questions) -> synthesize_feedback (intent-gated,
// template-hydrated draft + open questions) -> submit_feedback (validated
// template_data, multi-forge dispatch).
//
// This is the boj-side packaging of the engine for the autonomous bug-reporting
// pipeline (feedback-o-tron/docs/AUTONOMOUS-BUG-PIPELINE.adoc, contract C4 dispatch
// under D0 = new wrapping cartridge). It is NOT feedback-mcp (an unrelated
// in-memory sentiment counter that happens to share the 7722 placeholder port).

const BASE_URL = Deno.env.get("BUG_FILING_BACKEND_URL") ?? "http://127.0.0.1:7722";
const TIMEOUT_MS = 30_000;

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload ?? {}),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ error: "non-JSON response from bug-filing backend" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") {
      return { status: 504, data: { error: "bug-filing backend (feedback-o-tron) timed out" } };
    }
    return {
      status: 503,
      data: {
        error: `bug-filing backend unavailable: ${e.message}. ` +
          `Start feedback-o-tron with FEEDBACK_A_TRON_HTTP=1 (listening on ${BASE_URL}).`,
      },
    };
  } finally {
    clearTimeout(t);
  }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "research_feedback":
      return post("/api/v1/research_feedback", args ?? {});
    case "synthesize_feedback":
      return post("/api/v1/synthesize_feedback", args ?? {});
    case "submit_feedback":
      return post("/api/v1/submit_feedback", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
