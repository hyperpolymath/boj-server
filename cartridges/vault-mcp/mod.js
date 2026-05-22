// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vault-mcp/mod.js — Vault CLI credential broker (execute, list, verify, rotate)
//
// Delegates to backend at http://127.0.0.1:7744 (override with VAULT_BACKEND_URL).

const BASE_URL = Deno.env.get("VAULT_BACKEND_URL") ?? "http://127.0.0.1:7744";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "vault-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `vault-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "vault-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `vault-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "vault_execute":
      return post("/api/v1/vault_execute", args ?? {});
    case "vault_list":
      return post("/api/v1/vault_list", args ?? {});
    case "vault_status":
      return post("/api/v1/vault_status", args ?? {});
    case "vault_verify":
      return post("/api/v1/vault_verify", args ?? {});
    case "vault_rotate":
      return post("/api/v1/vault_rotate", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
