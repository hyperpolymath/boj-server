// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k8s-mcp/mod.js -- k8s gateway.

const BASE_URL = Deno.env.get("K8S_MCP_BACKEND_URL") ?? "http://127.0.0.1:7715";

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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "k8s-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `k8s-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "k8s_connect": {
      const { kubeconfig, context } = args ?? {};
      const payload = {  };
      if (kubeconfig !== undefined) payload.kubeconfig = kubeconfig;
      if (context !== undefined) payload.context = context;
      return post("/api/v1/connect", payload);
    }
    case "k8s_list_pods": {
      const { slot, namespace, label_selector } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (namespace !== undefined) payload.namespace = namespace;
      if (label_selector !== undefined) payload.label_selector = label_selector;
      return post("/api/v1/list-pods", payload);
    }
    case "k8s_get_pod": {
      const { slot, namespace, name } = args ?? {};
      if (!slot || !namespace || !name) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, namespace, name };
      return post("/api/v1/get-pod", payload);
    }
    case "k8s_list_deployments": {
      const { slot, namespace } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      if (namespace !== undefined) payload.namespace = namespace;
      return post("/api/v1/list-deployments", payload);
    }
    case "k8s_apply": {
      const { slot, manifest } = args ?? {};
      if (!slot || !manifest) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, manifest };
      return post("/api/v1/apply", payload);
    }
    case "k8s_delete": {
      const { slot, kind, namespace, name } = args ?? {};
      if (!slot || !kind || !namespace || !name) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, kind, namespace, name };
      return post("/api/v1/delete", payload);
    }
    case "k8s_logs": {
      const { slot, namespace, pod, container, tail } = args ?? {};
      if (!slot || !namespace || !pod) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot, namespace, pod };
      if (container !== undefined) payload.container = container;
      if (tail !== undefined) payload.tail = tail;
      return post("/api/v1/logs", payload);
    }
    case "k8s_disconnect": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/disconnect", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
