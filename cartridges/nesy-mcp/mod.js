// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// nesy-mcp/mod.js -- nesy gateway

const BASE_URL = Deno.env.get("NESY_BACKEND_URL") ?? "http://127.0.0.1:7706";

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 15000);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload), signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "nesy-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `nesy-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "nesy_harmonize": {
      const { neural, symbolic } = args ?? {};
      if (!neural || !symbolic) return { status: 400, data: { error: "neural is required" } };
      const payload = { neural, symbolic };
      return post("/api/v1/harmonize", payload);
    }

    case "nesy_analyze_drift": {
      const { kind } = args ?? {};
      if (!kind) return { status: 400, data: { error: "kind is required" } };
      const payload = { kind };
      return post("/api/v1/analyze-drift", payload);
    }

    case "nesy_reasoning_mode_info": {
      const { mode } = args ?? {};
      if (!mode) return { status: 400, data: { error: "mode is required" } };
      const payload = { mode };
      return post("/api/v1/reasoning-mode-info", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
