// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// buildkite-mcp/mod.js -- Buildkite CI/CD cartridge implementation.
//
// Provides MCP tool handlers for the Buildkite REST API v2:
//   - Pipeline listing and detail retrieval
//   - Build listing, detail, triggering, cancellation
//   - Job inspection with step details
//   - Job log retrieval
//   - Artifact listing
//   - Agent listing with status and metadata
//
// Auth: Bearer token via BUILDKITE_API_TOKEN (required for all operations).
// API docs: https://buildkite.com/docs/apis/rest-api
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.buildkite.com/v2";

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("BUILDKITE_API_TOKEN")
    : process.env.BUILDKITE_API_TOKEN;
  return token || null;
}

async function bkFetch(path, { method = "GET", queryParams, body } = {}) {
  const url = new URL(`${API_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "Content-Type": "application/json",
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const options = { method, headers };
  if (body) {
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return { status: 429, error: `Rate limited by Buildkite. Retry after ${retryAfter || "unknown"} seconds.`, retryAfter };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "buildkite_list_pipelines": {
      if (!args.organization) return { error: "Missing required field: organization" };
      const query = { page: args.page, per_page: args.per_page };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines`, { queryParams: query });
    }

    case "buildkite_get_pipeline": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}`);
    }

    case "buildkite_list_builds": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      const query = { state: args.state, branch: args.branch, page: args.page, per_page: args.per_page };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds`, { queryParams: query });
    }

    case "buildkite_get_build": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.build_number) return { error: "Missing required field: build_number" };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds/${args.build_number}`);
    }

    case "buildkite_create_build": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.commit) return { error: "Missing required field: commit" };
      if (!args.branch) return { error: "Missing required field: branch" };
      const body = {
        commit: args.commit,
        branch: args.branch,
        message: args.message || "",
        env: args.env || {},
      };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds`, { method: "POST", body });
    }

    case "buildkite_cancel_build": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.build_number) return { error: "Missing required field: build_number" };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds/${args.build_number}/cancel`, { method: "PUT" });
    }

    case "buildkite_list_jobs": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.build_number) return { error: "Missing required field: build_number" };
      const result = await bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds/${args.build_number}`);
      if (result.error) return result;
      return { status: result.status, data: { jobs: result.data.jobs || [] } };
    }

    case "buildkite_get_job_log": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.build_number) return { error: "Missing required field: build_number" };
      if (!args.job_id) return { error: "Missing required field: job_id" };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds/${args.build_number}/jobs/${encodeURIComponent(args.job_id)}/log`);
    }

    case "buildkite_list_artifacts": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.pipeline) return { error: "Missing required field: pipeline" };
      if (!args.build_number) return { error: "Missing required field: build_number" };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/pipelines/${encodeURIComponent(args.pipeline)}/builds/${args.build_number}/artifacts`);
    }

    case "buildkite_list_agents": {
      if (!args.organization) return { error: "Missing required field: organization" };
      const query = { page: args.page, per_page: args.per_page };
      return bkFetch(`/organizations/${encodeURIComponent(args.organization)}/agents`, { queryParams: query });
    }

    default:
      return { error: `Unknown buildkite-mcp tool: ${toolName}` };
  }
}

export const metadata = {
  name: "buildkite-mcp",
  version: "0.1.0",
  domain: "CI/CD",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
