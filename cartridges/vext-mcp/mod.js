// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vext-mcp/mod.js -- vext gateway

const BASE_URL = Deno.env.get("VEXT_BACKEND_URL") ?? "http://127.0.0.1:7711";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "vext-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `vext-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "vext_verify_message": {
      const { msg, sig } = args ?? {};
      if (!msg || !sig) return { status: 400, data: { error: "msg is required" } };
      const payload = { msg, sig };
      return post("/api/v1/verify-message", payload);
    }

    case "vext_check_attestation": {
      const { issuer } = args ?? {};
      if (!issuer) return { status: 400, data: { error: "issuer is required" } };
      const payload = { issuer };
      return post("/api/v1/check-attestation", payload);
    }

    case "vext_append_chain": {
      const { payload } = args ?? {};
      if (!payload) return { status: 400, data: { error: "payload is required" } };
      const payload = { payload };
      return post("/api/v1/append-chain", payload);
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
