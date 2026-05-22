// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// matrix-mcp/mod.js -- matrix gateway.

const BASE_URL = Deno.env.get("MATRIX_MCP_BACKEND_URL") ?? "http://127.0.0.1:7731";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "matrix-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `matrix-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "matrix_authenticate": {
      const { homeserver, access_token } = args ?? {};
      if (!homeserver || !access_token) return { status: 400, data: { error: "homeserver is required" } };
      const payload = { homeserver, access_token };
      return post("/api/v1/authenticate", payload);
    }
    case "matrix_send_message": {
      const { slot, room_id, body, msgtype } = args ?? {};
      if (!slot || !room_id || !body) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, room_id, body };
      if (msgtype !== undefined) payload.msgtype = msgtype;
      return post("/api/v1/send-message", payload);
    }
    case "matrix_list_rooms": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/list-rooms", payload);
    }
    case "matrix_get_messages": {
      const { slot, room_id, limit } = args ?? {};
      if (!slot || !room_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, room_id };
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/get-messages", payload);
    }
    case "matrix_join_room": {
      const { slot, room_id } = args ?? {};
      if (!slot || !room_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, room_id };
      return post("/api/v1/join-room", payload);
    }
    case "matrix_leave_room": {
      const { slot, room_id } = args ?? {};
      if (!slot || !room_id) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, room_id };
      return post("/api/v1/leave-room", payload);
    }
    case "matrix_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
