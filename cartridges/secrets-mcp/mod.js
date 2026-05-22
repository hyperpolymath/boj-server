// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// secrets-mcp/mod.js — Secrets management (Vault, SOPS, env-vault)
//
// Delegates to backend at http://127.0.0.1:7741 (override with SECRETS_BACKEND_URL).

const BASE_URL = Deno.env.get("SECRETS_BACKEND_URL") ?? "http://127.0.0.1:7741";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "secrets-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `secrets-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "secrets-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `secrets-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "secrets_unseal":
      return post("/api/v1/secrets_unseal", args ?? {});
    case "secrets_authenticate":
      return post("/api/v1/secrets_authenticate", args ?? {});
    case "secrets_get":
      return post("/api/v1/secrets_get", args ?? {});
    case "secrets_set":
      return post("/api/v1/secrets_set", args ?? {});
    case "secrets_seal":
      return post("/api/v1/secrets_seal", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
