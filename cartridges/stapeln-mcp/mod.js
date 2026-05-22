// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// stapeln-mcp/mod.js -- stapeln gateway

const BASE_URL = Deno.env.get("STAPELN_BACKEND_URL") ?? "http://127.0.0.1:7704";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "stapeln-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `stapeln-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "stapeln_list_stacks": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/list-stacks", payload);
    }

    case "stapeln_deploy": {
      const { name, replicas } = args ?? {};
      if (!name) return { status: 400, data: { error: "name is required" } };
      const payload = { name };
      if (replicas !== undefined) payload.replicas = replicas;
      return post("/api/v1/deploy", payload);
    }

    case "stapeln_scale": {
      const { name, replicas } = args ?? {};
      if (!name || !replicas) return { status: 400, data: { error: "name is required" } };
      const payload = { name, replicas };
      return post("/api/v1/scale", payload);
    }

    case "stapeln_get_health": {
      const { name } = args ?? {};
      if (!name) return { status: 400, data: { error: "name is required" } };
      const payload = { name };
      return post("/api/v1/get-health", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
