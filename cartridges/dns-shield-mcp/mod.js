// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// dns-shield-mcp/mod.js — DNS security shield — DoQ, DoH, DNSSEC, CAA
//
// Delegates to backend at http://127.0.0.1:7720 (override with DNS_SHIELD_URL).

const BASE_URL = Deno.env.get("DNS_SHIELD_URL") ?? "http://127.0.0.1:7720";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "dns-shield-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `dns-shield-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "dns-shield-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `dns-shield-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "dns_resolve_doq":
      return post("/api/v1/dns_resolve_doq", args ?? {});
    case "dns_resolve_doh":
      return post("/api/v1/dns_resolve_doh", args ?? {});
    case "dns_check_caa":
      return post("/api/v1/dns_check_caa", args ?? {});
    case "dns_validate_dnssec":
      return post("/api/v1/dns_validate_dnssec", args ?? {});
    case "dns_flush_cache":
      return post("/api/v1/dns_flush_cache", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
