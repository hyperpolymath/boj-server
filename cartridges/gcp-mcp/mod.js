// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gcp-mcp/mod.js -- gcp gateway.

const BASE_URL = Deno.env.get("GCP_MCP_BACKEND_URL") ?? "http://127.0.0.1:7714";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "gcp-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `gcp-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "gcp_authenticate": {
      const { project, credentials_file } = args ?? {};
      if (!project) return { status: 400, data: { error: "project is required" } };
      const payload = { project };
      if (credentials_file !== undefined) payload.credentials_file = credentials_file;
      return post("/api/v1/authenticate", payload);
    }
    case "gcp_storage_list": {
      const { bucket, prefix } = args ?? {};
      const payload = {  };
      if (bucket !== undefined) payload.bucket = bucket;
      if (prefix !== undefined) payload.prefix = prefix;
      return post("/api/v1/storage-list", payload);
    }
    case "gcp_storage_get": {
      const { bucket, object } = args ?? {};
      if (!bucket || !object) return { status: 400, data: { error: "bucket is required" } };
      const payload = { bucket, object };
      return post("/api/v1/storage-get", payload);
    }
    case "gcp_compute_list": {
      const { zone, filter } = args ?? {};
      const payload = {  };
      if (zone !== undefined) payload.zone = zone;
      if (filter !== undefined) payload.filter = filter;
      return post("/api/v1/compute-list", payload);
    }
    case "gcp_run_invoke": {
      const { service_url, method, body } = args ?? {};
      if (!service_url) return { status: 400, data: { error: "service_url is required" } };
      const payload = { service_url };
      if (method !== undefined) payload.method = method;
      if (body !== undefined) payload.body = body;
      return post("/api/v1/run-invoke", payload);
    }
    case "gcp_session_state": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/session-state", payload);
    }
    case "gcp_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
