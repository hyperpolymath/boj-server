// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// telegram-mcp/mod.js -- telegram gateway.

const BASE_URL = Deno.env.get("TELEGRAM_MCP_BACKEND_URL") ?? "http://127.0.0.1:7730";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "telegram-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `telegram-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "telegram_authenticate": {
      const { token } = args ?? {};
      if (!token) return { status: 400, data: { error: "token is required" } };
      const payload = { token };
      return post("/api/v1/authenticate", payload);
    }
    case "telegram_send_message": {
      const { slot, chat_id, text, parse_mode } = args ?? {};
      if (!slot || !chat_id || !text) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, chat_id, text };
      if (parse_mode !== undefined) payload.parse_mode = parse_mode;
      return post("/api/v1/send-message", payload);
    }
    case "telegram_get_updates": {
      const { slot, offset, limit } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (offset !== undefined) payload.offset = offset;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/get-updates", payload);
    }
    case "telegram_get_chat": {
      const { slot, chat_id } = args ?? {};
      if (!slot || !chat_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, chat_id };
      return post("/api/v1/get-chat", payload);
    }
    case "telegram_send_photo": {
      const { slot, chat_id, photo, caption } = args ?? {};
      if (!slot || !chat_id || !photo) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, chat_id, photo };
      if (caption !== undefined) payload.caption = caption;
      return post("/api/v1/send-photo", payload);
    }
    case "telegram_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
