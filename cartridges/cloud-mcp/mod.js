// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cloud-mcp/mod.js — Multi-cloud provider session manager (AWS/GCP/Azure/DO/Vercel)
//
// Delegates to backend at http://127.0.0.1:7715 (override with CLOUD_BACKEND_URL).

const BASE_URL = Deno.env.get("CLOUD_BACKEND_URL") ?? "http://127.0.0.1:7715";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "cloud-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `cloud-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

async function get(path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, { method: "GET", signal: ctrl.signal });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "cloud-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `cloud-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "cloud_authenticate":
      return post("/api/v1/cloud_authenticate", args ?? {});
    case "cloud_logout":
      return post("/api/v1/cloud_logout", args ?? {});
    case "cloud_state":
      return post("/api/v1/cloud_state", args ?? {});
    case "cloud_execute":
      return post("/api/v1/cloud_execute", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
