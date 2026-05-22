// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// slack-mcp/mod.js -- slack gateway.

const BASE_URL = Deno.env.get("SLACK_MCP_BACKEND_URL") ?? "http://127.0.0.1:7728";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "slack-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `slack-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "slack_authenticate": {
      const { token } = args ?? {};
      if (!token) return { status: 400, data: { error: "token is required" } };
      const payload = { token };
      return post("/api/v1/authenticate", payload);
    }
    case "slack_send_message": {
      const { slot, channel, text, thread_ts } = args ?? {};
      if (!slot || !channel || !text) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel, text };
      if (thread_ts !== undefined) payload.thread_ts = thread_ts;
      return post("/api/v1/send-message", payload);
    }
    case "slack_list_channels": {
      const { slot, types } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (types !== undefined) payload.types = types;
      return post("/api/v1/list-channels", payload);
    }
    case "slack_read_thread": {
      const { slot, channel, thread_ts } = args ?? {};
      if (!slot || !channel || !thread_ts) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel, thread_ts };
      return post("/api/v1/read-thread", payload);
    }
    case "slack_search": {
      const { slot, query, count } = args ?? {};
      if (!slot || !query) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, query };
      if (count !== undefined) payload.count = count;
      return post("/api/v1/search", payload);
    }
    case "slack_get_user": {
      const { slot, user_id } = args ?? {};
      if (!slot || !user_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, user_id };
      return post("/api/v1/get-user", payload);
    }
    case "slack_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
