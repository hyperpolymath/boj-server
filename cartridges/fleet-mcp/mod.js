// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// fleet-mcp/mod.js — gitbot-fleet gate compliance tracker
//
// Delegates to backend at http://127.0.0.1:7723 (override with FLEET_BACKEND_URL).

const BASE_URL = Deno.env.get("FLEET_BACKEND_URL") ?? "http://127.0.0.1:7723";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "fleet-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `fleet-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "fleet-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `fleet-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "fleet_record_gate":
      return post("/api/v1/fleet_record_gate", args ?? {});
    case "fleet_bot_status":
      return post("/api/v1/fleet_bot_status", args ?? {});
    case "fleet_gate_score":
      return post("/api/v1/fleet_gate_score", args ?? {});
    case "fleet_has_mandatory":
      return post("/api/v1/fleet_has_mandatory", args ?? {});
    case "fleet_fleet_status":
      return post("/api/v1/fleet_fleet_status", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
