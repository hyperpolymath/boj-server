// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hypatia-mcp/mod.js -- hypatia gateway

const BASE_URL = Deno.env.get("HYPATIA_BACKEND_URL") ?? "http://127.0.0.1:7701";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "hypatia-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `hypatia-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "hypatia_scan_repo": {
      const { path } = args ?? {};
      if (!path) return { status: 400, data: { error: "path is required" } };
      const payload = { path };
      return post("/api/v1/scan-repo", payload);
    }

    case "hypatia_get_score": {
      const { scan_id } = args ?? {};
      if (!scan_id) return { status: 400, data: { error: "scan_id is required" } };
      const payload = { scan_id };
      return post("/api/v1/get-score", payload);
    }

    case "hypatia_get_rule_set": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/get-rule-set", payload);
    }

    case "hypatia_train_model": {
      const { model_name } = args ?? {};
      if (!model_name) return { status: 400, data: { error: "model_name is required" } };
      const payload = { model_name };
      return post("/api/v1/train-model", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
