// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// kategoria-mcp/mod.js -- kategoria gateway

const BASE_URL = Deno.env.get("KATEGORIA_BACKEND_URL") ?? "http://127.0.0.1:7709";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "kategoria-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `kategoria-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "kategoria_classify": {
      const { input } = args ?? {};
      if (!input) return { status: 400, data: { error: "input is required" } };
      const payload = { input };
      return post("/api/v1/classify", payload);
    }

    case "kategoria_get_levels": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/get-levels", payload);
    }

    case "kategoria_eval_challenge": {
      const { level, input } = args ?? {};
      if (!level || !input) return { status: 400, data: { error: "level is required" } };
      const payload = { level, input };
      return post("/api/v1/eval-challenge", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
