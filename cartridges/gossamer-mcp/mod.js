// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gossamer-mcp/mod.js -- gossamer gateway

const BASE_URL = Deno.env.get("GOSSAMER_BACKEND_URL") ?? "http://127.0.0.1:7703";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "gossamer-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `gossamer-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "gossamer_create_window": {
      const { width, height, title } = args ?? {};
      const payload = {  };
      if (width !== undefined) payload.width = width;
      if (height !== undefined) payload.height = height;
      if (title !== undefined) payload.title = title;
      return post("/api/v1/create-window", payload);
    }

    case "gossamer_load_panel": {
      const { handle, uri } = args ?? {};
      if (!handle || !uri) return { status: 400, data: { error: "handle is required" } };
      const payload = { handle, uri };
      return post("/api/v1/load-panel", payload);
    }

    case "gossamer_eval_js": {
      const { handle, script } = args ?? {};
      if (!handle || !script) return { status: 400, data: { error: "handle is required" } };
      const payload = { handle, script };
      return post("/api/v1/eval-js", payload);
    }

    case "gossamer_get_version": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/get-version", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
