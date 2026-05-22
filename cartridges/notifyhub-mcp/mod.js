// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// notifyhub-mcp/mod.js — NotifyHub unified notification platform cartridge.
//
// Delegates to backend at http://127.0.0.1:8080 (override with NOTIFYHUB_URL).
// Auth: NOTIFYHUB_API_KEY (required for all operations).

const BASE_URL = Deno.env.get("NOTIFYHUB_URL") ?? "http://127.0.0.1:8080";
const TIMEOUT_MS = 20_000;

function getKey() {
  return Deno.env.get("NOTIFYHUB_API_KEY") ?? null;
}

function authHeaders() {
  const key = getKey();
  if (!key) return null;
  return { "Content-Type": "application/json", "X-API-Key": key };
}

async function post(path, payload) {
  const headers = authHeaders();
  if (!headers)
    return { status: 401, data: { success: false, error: "NOTIFYHUB_API_KEY env var is required" } };

  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "notifyhub-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `notifyhub-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "notifyhub_send_email": {
      const { to, subject, body, template, params } = args ?? {};
      if (!to || !subject || !body)
        return { status: 400, data: { error: "to, subject, and body are required" } };
      const payload = { to, subject, body };
      if (template !== undefined) payload.template = template;
      if (params !== undefined) payload.params = params;
      return post("/api/v1/notify/email", payload);
    }

    case "notifyhub_send_sms": {
      const { phone, body } = args ?? {};
      if (!phone || !body)
        return { status: 400, data: { error: "phone and body are required" } };
      return post("/api/v1/notify/sms", { phone, body });
    }

    case "notifyhub_send_slack": {
      const { recipient, body } = args ?? {};
      if (!recipient || !body)
        return { status: 400, data: { error: "recipient and body are required" } };
      return post("/api/v1/notify/slack", { recipient, body });
    }

    case "notifyhub_send_discord": {
      const { recipient, body } = args ?? {};
      if (!recipient || !body)
        return { status: 400, data: { error: "recipient and body are required" } };
      return post("/api/v1/notify/discord", { recipient, body });
    }

    case "notifyhub_send_telegram": {
      const { recipient, body } = args ?? {};
      if (!recipient || !body)
        return { status: 400, data: { error: "recipient and body are required" } };
      return post("/api/v1/notify/telegram", { recipient, body });
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
