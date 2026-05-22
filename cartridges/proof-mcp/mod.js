// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// proof-mcp/mod.js -- proof gateway

const BASE_URL = Deno.env.get("PROOF_BACKEND_URL") ?? "http://127.0.0.1:7707";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "proof-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `proof-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "proof_init_session": {
      const { backend } = args ?? {};
      if (!backend) return { status: 400, data: { error: "backend is required" } };
      const payload = { backend };
      return post("/api/v1/init-session", payload);
    }

    case "proof_load_obligation": {
      const { slot, backend } = args ?? {};
      if (!slot || !backend) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, backend };
      return post("/api/v1/load-obligation", payload);
    }

    case "proof_verify": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/verify", payload);
    }

    case "proof_get_result": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/get-result", payload);
    }

    case "proof_get_state": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/get-state", payload);
    }

    case "proof_reset_session": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/reset-session", payload);
    }

    case "proof_release_session": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/release-session", payload);
    }

    case "proof_can_transition": {
      const { from, to } = args ?? {};
      if (!from || !to) return { status: 400, data: { error: "from is required" } };
      const payload = { from, to };
      return post("/api/v1/can-transition", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
