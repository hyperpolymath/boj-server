// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// iac-mcp/mod.js -- iac gateway.

const BASE_URL = Deno.env.get("IAC_MCP_BACKEND_URL") ?? "http://127.0.0.1:7717";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "iac-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `iac-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "iac_init": {
      const { tool, working_dir } = args ?? {};
      if (!working_dir) return { status: 400, data: { error: "working_dir is required" } };
      const payload = { working_dir };
      if (tool !== undefined) payload.tool = tool;
      return post("/api/v1/init", payload);
    }
    case "iac_plan": {
      const { slot, target } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (target !== undefined) payload.target = target;
      return post("/api/v1/plan", payload);
    }
    case "iac_apply": {
      const { slot, auto_approve } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (auto_approve !== undefined) payload.auto_approve = auto_approve;
      return post("/api/v1/apply", payload);
    }
    case "iac_destroy": {
      const { slot, auto_approve } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (auto_approve !== undefined) payload.auto_approve = auto_approve;
      return post("/api/v1/destroy", payload);
    }
    case "iac_state": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/state", payload);
    }
    case "iac_output": {
      const { slot, name } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (name !== undefined) payload.name = name;
      return post("/api/v1/output", payload);
    }
    case "iac_release": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/release", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
