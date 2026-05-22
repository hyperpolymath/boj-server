// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// git-mcp/mod.js — Multi-forge git operations (GitHub, GitLab, Gitea, Bitbucket)
//
// Delegates to backend at http://127.0.0.1:7728 (override with GIT_BACKEND_URL).

const BASE_URL = Deno.env.get("GIT_BACKEND_URL") ?? "http://127.0.0.1:7728";
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "git-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `git-mcp backend unavailable: ${e.message}` } };
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
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "git-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `git-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "git_authenticate":
      return post("/api/v1/git_authenticate", args ?? {});
    case "git_select_repo":
      return post("/api/v1/git_select_repo", args ?? {});
    case "git_status":
      return post("/api/v1/git_status", args ?? {});
    case "git_log":
      return post("/api/v1/git_log", args ?? {});
    case "git_diff":
      return post("/api/v1/git_diff", args ?? {});
    case "git_create_branch":
      return post("/api/v1/git_create_branch", args ?? {});
    case "git_push":
      return post("/api/v1/git_push", args ?? {});
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
