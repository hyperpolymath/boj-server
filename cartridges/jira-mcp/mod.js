// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// jira-mcp/mod.js — Jira project management and issue tracking
//
// Delegates to backend at http://127.0.0.1:7730 (override with JIRA_BACKEND_URL).

const BASE_URL = Deno.env.get("JIRA_BACKEND_URL") ?? "http://127.0.0.1:7730";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "jira-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `jira-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "jira-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `jira-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "jira_authenticate":
      return post("/api/v1/jira_authenticate", args ?? {});
    case "jira_search_issues":
      return post("/api/v1/jira_search_issues", args ?? {});
    case "jira_get_issue":
      return post("/api/v1/jira_get_issue", args ?? {});
    case "jira_create_issue":
      return post("/api/v1/jira_create_issue", args ?? {});
    case "jira_update_issue":
      return post("/api/v1/jira_update_issue", args ?? {});
    case "jira_add_comment":
      return post("/api/v1/jira_add_comment", args ?? {});
    case "jira_list_projects":
      return post("/api/v1/jira_list_projects", args ?? {});
    case "jira_transition_issue":
      return post("/api/v1/jira_transition_issue", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
