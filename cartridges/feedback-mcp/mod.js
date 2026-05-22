// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// feedback-mcp/mod.js — Feedback collection and sentiment analysis
//
// Delegates to backend at http://127.0.0.1:7722 (override with FEEDBACK_BACKEND_URL).

const BASE_URL = Deno.env.get("FEEDBACK_BACKEND_URL") ?? "http://127.0.0.1:7722";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "feedback-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `feedback-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "feedback-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `feedback-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "feedback_register_channel":
      return post("/api/v1/feedback_register_channel", args ?? {});
    case "feedback_start_collecting":
      return post("/api/v1/feedback_start_collecting", args ?? {});
    case "feedback_submit":
      return post("/api/v1/feedback_submit", args ?? {});
    case "feedback_get_stats":
      return post("/api/v1/feedback_get_stats", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
