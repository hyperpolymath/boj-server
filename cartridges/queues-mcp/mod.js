// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// queues-mcp/mod.js — Message queue bridge (Redis Streams, RabbitMQ, NATS)
//
// Delegates to backend at http://127.0.0.1:7738 (override with QUEUES_BACKEND_URL).

const BASE_URL = Deno.env.get("QUEUES_BACKEND_URL") ?? "http://127.0.0.1:7738";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "queues-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `queues-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "queues-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `queues-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "queue_connect":
      return post("/api/v1/queue_connect", args ?? {});
    case "queue_publish":
      return post("/api/v1/queue_publish", args ?? {});
    case "queue_subscribe":
      return post("/api/v1/queue_subscribe", args ?? {});
    case "queue_consume":
      return post("/api/v1/queue_consume", args ?? {});
    case "queue_ack":
      return post("/api/v1/queue_ack", args ?? {});
    case "queue_disconnect":
      return post("/api/v1/queue_disconnect", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
