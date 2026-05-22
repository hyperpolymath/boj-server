// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// discord-mcp/mod.js -- discord gateway.

const BASE_URL = Deno.env.get("DISCORD_MCP_BACKEND_URL") ?? "http://127.0.0.1:7729";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "discord-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `discord-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "discord_authenticate": {
      const { token } = args ?? {};
      if (!token) return { status: 400, data: { error: "token is required" } };
      const payload = { token };
      return post("/api/v1/authenticate", payload);
    }
    case "discord_send_message": {
      const { slot, channel_id, content } = args ?? {};
      if (!slot || !channel_id || !content) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel_id, content };
      return post("/api/v1/send-message", payload);
    }
    case "discord_list_guilds": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-guilds", payload);
    }
    case "discord_list_channels": {
      const { slot, guild_id } = args ?? {};
      if (!slot || !guild_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, guild_id };
      return post("/api/v1/list-channels", payload);
    }
    case "discord_read_messages": {
      const { slot, channel_id, limit } = args ?? {};
      if (!slot || !channel_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel_id };
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/read-messages", payload);
    }
    case "discord_add_reaction": {
      const { slot, channel_id, message_id, emoji } = args ?? {};
      if (!slot || !channel_id || !message_id || !emoji) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel_id, message_id, emoji };
      return post("/api/v1/add-reaction", payload);
    }
    case "discord_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
