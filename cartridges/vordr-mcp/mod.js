// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vordr-mcp/mod.js -- vordr gateway

const BASE_URL = Deno.env.get("VORDR_BACKEND_URL") ?? "http://127.0.0.1:7712";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "vordr-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `vordr-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "vordr_scan": {
      const { image_ref } = args ?? {};
      if (!image_ref) return { status: 400, data: { error: "image_ref is required" } };
      const payload = { image_ref };
      return post("/api/v1/scan", payload);
    }

    case "vordr_set_baseline": {
      const { image_ref } = args ?? {};
      if (!image_ref) return { status: 400, data: { error: "image_ref is required" } };
      const payload = { image_ref };
      return post("/api/v1/set-baseline", payload);
    }

    case "vordr_alerts": {
      const { _args } = args ?? {};
      const payload = {  };
      return post("/api/v1/alerts", payload);
    }

    case "vordr_compare": {
      const { image_a, image_b } = args ?? {};
      if (!image_a || !image_b) return { status: 400, data: { error: "image_a is required" } };
      const payload = { image_a, image_b };
      return post("/api/v1/compare", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
