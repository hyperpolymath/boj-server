// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// container-mcp/mod.js -- container gateway.

const BASE_URL = Deno.env.get("CONTAINER_MCP_BACKEND_URL") ?? "http://127.0.0.1:7716";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "container-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `container-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "container_build": {
      const { context_path, image_name, containerfile } = args ?? {};
      if (!context_path || !image_name) return { status: 400, data: { error: "context_path is required" } };
      const payload = { context_path, image_name };
      if (containerfile !== undefined) payload.containerfile = containerfile;
      return post("/api/v1/build", payload);
    }
    case "container_create": {
      const { image, name, env, ports } = args ?? {};
      if (!image) return { status: 400, data: { error: "image is required" } };
      const payload = { image };
      if (name !== undefined) payload.name = name;
      if (env !== undefined) payload.env = env;
      if (ports !== undefined) payload.ports = ports;
      return post("/api/v1/create", payload);
    }
    case "container_start": {
      const { container_id } = args ?? {};
      if (!container_id) return { status: 400, data: { error: "container_id is required" } };
      const payload = { container_id };
      return post("/api/v1/start", payload);
    }
    case "container_stop": {
      const { container_id, timeout } = args ?? {};
      if (!container_id) return { status: 400, data: { error: "container_id is required" } };
      const payload = { container_id };
      if (timeout !== undefined) payload.timeout = timeout;
      return post("/api/v1/stop", payload);
    }
    case "container_remove": {
      const { container_id, force } = args ?? {};
      if (!container_id) return { status: 400, data: { error: "container_id is required" } };
      const payload = { container_id };
      if (force !== undefined) payload.force = force;
      return post("/api/v1/remove", payload);
    }
    case "container_list": {
      const { all } = args ?? {};
      const payload = {  };
      if (all !== undefined) payload.all = all;
      return post("/api/v1/list", payload);
    }
    case "container_logs": {
      const { container_id, tail } = args ?? {};
      if (!container_id) return { status: 400, data: { error: "container_id is required" } };
      const payload = { container_id };
      if (tail !== undefined) payload.tail = tail;
      return post("/api/v1/logs", payload);
    }
    case "container_inspect": {
      const { container_id } = args ?? {};
      if (!container_id) return { status: 400, data: { error: "container_id is required" } };
      const payload = { container_id };
      return post("/api/v1/inspect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
