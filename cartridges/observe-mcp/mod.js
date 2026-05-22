// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// observe-mcp/mod.js — Unified observability — metrics, logs, traces (Prometheus, Grafana, Loki, Jaeger)
//
// Delegates to backend at http://127.0.0.1:7736 (override with OBSERVE_BACKEND_URL).

const BASE_URL = Deno.env.get("OBSERVE_BACKEND_URL") ?? "http://127.0.0.1:7736";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "observe-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `observe-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "observe-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `observe-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "observe_register":
      return post("/api/v1/observe_register", args ?? {});
    case "observe_query_metrics":
      return post("/api/v1/observe_query_metrics", args ?? {});
    case "observe_query_logs":
      return post("/api/v1/observe_query_logs", args ?? {});
    case "observe_query_traces":
      return post("/api/v1/observe_query_traces", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
