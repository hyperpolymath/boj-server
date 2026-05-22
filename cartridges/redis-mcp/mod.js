// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis-mcp/mod.js -- redis gateway.

const BASE_URL = Deno.env.get("REDIS_MCP_BACKEND_URL") ?? "http://127.0.0.1:7721";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "redis-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `redis-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "redis_connect": {
      const { host, port, db, password } = args ?? {};
      const payload = {  };
      if (host !== undefined) payload.host = host;
      if (port !== undefined) payload.port = port;
      if (db !== undefined) payload.db = db;
      if (password !== undefined) payload.password = password;
      return post("/api/v1/connect", payload);
    }
    case "redis_get": {
      const { slot, key } = args ?? {};
      if (!slot || !key) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, key };
      return post("/api/v1/get", payload);
    }
    case "redis_set": {
      const { slot, key, value, ttl } = args ?? {};
      if (!slot || !key || !value) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, key, value };
      if (ttl !== undefined) payload.ttl = ttl;
      return post("/api/v1/set", payload);
    }
    case "redis_del": {
      const { slot, keys } = args ?? {};
      if (!slot || !keys) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, keys };
      return post("/api/v1/del", payload);
    }
    case "redis_keys": {
      const { slot, pattern } = args ?? {};
      if (!slot || !pattern) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, pattern };
      return post("/api/v1/keys", payload);
    }
    case "redis_hgetall": {
      const { slot, key } = args ?? {};
      if (!slot || !key) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, key };
      return post("/api/v1/hgetall", payload);
    }
    case "redis_lpush": {
      const { slot, key, values } = args ?? {};
      if (!slot || !key || !values) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, key, values };
      return post("/api/v1/lpush", payload);
    }
    case "redis_publish": {
      const { slot, channel, message } = args ?? {};
      if (!slot || !channel || !message) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, channel, message };
      return post("/api/v1/publish", payload);
    }
    case "redis_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
