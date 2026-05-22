// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k9iser-mcp/mod.js — Wrap configs into self-validating K9 contracts.
//
// Delegates to backend at http://127.0.0.1:7743 (override with K9ISER_BACKEND_URL).
// The backend runs the `k9iser` binary against a checked-out repo working
// tree: load_manifest -> generate -> validate -> apply (commit+push).

const BASE_URL = Deno.env.get("K9ISER_BACKEND_URL") ?? "http://127.0.0.1:7743";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "k9iser-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `k9iser-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "k9_load_manifest":
      return post("/api/v1/k9_load_manifest", args ?? {});
    case "k9_generate":
      return post("/api/v1/k9_generate", args ?? {});
    case "k9_validate":
      return post("/api/v1/k9_validate", args ?? {});
    case "k9_apply":
      return post("/api/v1/k9_apply", args ?? {});
    case "k9_clean":
      return post("/api/v1/k9_clean", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
