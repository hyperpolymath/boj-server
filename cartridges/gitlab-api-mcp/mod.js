// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gitlab-api-mcp/mod.js — GitLab REST API — projects, issues, MRs
//
// Delegates to backend at http://127.0.0.1:7727 (override with GITLAB_API_URL).

const BASE_URL = Deno.env.get("GITLAB_API_URL") ?? "http://127.0.0.1:7727";
const TIMEOUT_MS = 15_000;

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "gitlab-api-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `gitlab-api-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

async function get(path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, { method: "GET", signal: ctrl.signal });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "gitlab-api-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `gitlab-api-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "gitlab_authenticate":
      return post("/api/v1/gitlab_authenticate", args ?? {});
    case "gitlab_list_projects":
      return post("/api/v1/gitlab_list_projects", args ?? {});
    case "gitlab_get_project":
      return post("/api/v1/gitlab_get_project", args ?? {});
    case "gitlab_list_issues":
      return post("/api/v1/gitlab_list_issues", args ?? {});
    case "gitlab_create_issue":
      return post("/api/v1/gitlab_create_issue", args ?? {});
    case "gitlab_create_mr":
      return post("/api/v1/gitlab_create_mr", args ?? {});
    case "gitlab_setup_mirror":
      return post("/api/v1/gitlab_setup_mirror", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
