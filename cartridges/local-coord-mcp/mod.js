// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-coord-mcp/mod.js — Localhost multi-instance coordination
//
// Delegates to backend at http://127.0.0.1:7745 (override with COORD_BACKEND_URL).
// CRITICAL: Backend MUST bind to loopback only — the Idris2 ABI guarantees this.

const BASE_URL = Deno.env.get("COORD_BACKEND_URL") ?? "http://127.0.0.1:7745";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "local-coord-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `local-coord-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

// Path canonical: /tools/<tool>. Matches main.js:dispatchLocalCoord and the
// estate-wide Zig-adapter convention. Earlier /api/v1/* paths were a dead
// code path — the mcp-bridge bypasses mod.js and POSTs directly to the
// adapter, so mod.js is a secondary transport used only by alternative
// bridges (e.g. an Elixir catalogue-level proxy).
export async function handleTool(toolName, args) {
  switch (toolName) {
    case "coord_register":
    case "coord_list_peers":
    case "coord_send":
    case "coord_receive":
    case "coord_claim_task":
    case "coord_status":
      return post(`/tools/${toolName}`, args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
