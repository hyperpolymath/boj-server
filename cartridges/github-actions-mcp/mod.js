// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github-actions-mcp/mod.js -- GitHub Actions CI/CD cartridge implementation.
//
// Provides MCP tool handlers for the GitHub Actions REST API:
//   - Workflow listing and dispatch
//   - Run listing, detail retrieval, re-run, cancellation
//   - Job and step inspection
//   - Artifact listing
//   - Log retrieval
//   - Secret listing (names only)
//   - Self-hosted runner listing
//   - Cache management
//
// Auth: Bearer token via GITHUB_TOKEN (required for all operations).
// API docs: https://docs.github.com/en/rest/actions
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.github.com";

// ---------------------------------------------------------------------------
// Auth helper
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("GITHUB_TOKEN")
    : process.env.GITHUB_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper
// ---------------------------------------------------------------------------

async function ghaFetch(path, { method = "GET", queryParams, body } = {}) {
  const url = new URL(`${API_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const options = { method, headers };
  if (body) {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by GitHub. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  // Some endpoints return 204 No Content
  if (response.status === 204) {
    return { status: 204, data: { message: "Success (no content)" } };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Workflows ---

    case "gha_list_workflows": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/workflows`);
    }

    // --- Runs ---

    case "gha_list_runs": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      const base = args.workflow_id
        ? `/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/workflows/${encodeURIComponent(args.workflow_id)}/runs`
        : `/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs`;
      const query = {
        branch: args.branch,
        status: args.status,
        per_page: args.per_page,
      };
      return ghaFetch(base, { queryParams: query });
    }

    case "gha_get_run": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}`);
    }

    // --- Jobs ---

    case "gha_list_jobs": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      const query = { filter: args.filter };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/jobs`, { queryParams: query });
    }

    // --- Logs ---

    case "gha_get_logs": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/logs`);
    }

    // --- Artifacts ---

    case "gha_list_artifacts": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/artifacts`);
    }

    // --- Dispatch ---

    case "gha_dispatch_workflow": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.workflow_id) return { error: "Missing required field: workflow_id" };
      if (!args.ref) return { error: "Missing required field: ref" };
      const body = { ref: args.ref, inputs: args.inputs || {} };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/workflows/${encodeURIComponent(args.workflow_id)}/dispatches`, { method: "POST", body });
    }

    // --- Re-run ---

    case "gha_rerun_workflow": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      const endpoint = args.failed_only
        ? `/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/rerun-failed-jobs`
        : `/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/rerun`;
      return ghaFetch(endpoint, { method: "POST" });
    }

    // --- Cancel ---

    case "gha_cancel_run": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      if (!args.run_id) return { error: "Missing required field: run_id" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runs/${args.run_id}/cancel`, { method: "POST" });
    }

    // --- Secrets ---

    case "gha_list_secrets": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/secrets`);
    }

    // --- Runners ---

    case "gha_list_runners": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/runners`);
    }

    // --- Caches ---

    case "gha_list_caches": {
      if (!args.owner) return { error: "Missing required field: owner" };
      if (!args.repo) return { error: "Missing required field: repo" };
      const query = { key: args.key, sort: args.sort };
      return ghaFetch(`/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/actions/caches`, { queryParams: query });
    }

    default:
      return { error: `Unknown github-actions-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export
// ---------------------------------------------------------------------------

export const metadata = {
  name: "github-actions-mcp",
  version: "0.1.0",
  domain: "CI/CD",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
