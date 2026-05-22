// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// circleci-mcp/mod.js -- CircleCI CI/CD cartridge implementation.
//
// Provides MCP tool handlers for the CircleCI API v2:
//   - Pipeline listing and detail retrieval
//   - Workflow listing and detail retrieval
//   - Job listing with status and timing
//   - Artifact listing
//   - Pipeline triggering
//   - Workflow cancellation
//   - Environment variable listing (names only, values masked)
//
// Auth: Bearer token via CIRCLECI_TOKEN (required for all operations).
// API docs: https://circleci.com/docs/api/v2/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://circleci.com/api/v2";

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("CIRCLECI_TOKEN")
    : process.env.CIRCLECI_TOKEN;
  return token || null;
}

async function cciFetch(path, { method = "GET", queryParams, body } = {}) {
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
    headers["Circle-Token"] = token;
  }

  const options = { method, headers };
  if (body) {
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), options);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return { status: 429, error: `Rate limited by CircleCI. Retry after ${retryAfter || "unknown"} seconds.`, retryAfter };
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

    case "circleci_list_pipelines": {
      if (!args.project_slug) return { error: "Missing required field: project_slug" };
      const query = { branch: args.branch, "page-token": args.page_token };
      return cciFetch(`/project/${args.project_slug}/pipeline`, { queryParams: query });
    }

    case "circleci_get_pipeline": {
      if (!args.pipeline_id) return { error: "Missing required field: pipeline_id" };
      return cciFetch(`/pipeline/${encodeURIComponent(args.pipeline_id)}`);
    }

    case "circleci_list_workflows": {
      if (!args.pipeline_id) return { error: "Missing required field: pipeline_id" };
      const query = { "page-token": args.page_token };
      return cciFetch(`/pipeline/${encodeURIComponent(args.pipeline_id)}/workflow`, { queryParams: query });
    }

    case "circleci_get_workflow": {
      if (!args.workflow_id) return { error: "Missing required field: workflow_id" };
      return cciFetch(`/workflow/${encodeURIComponent(args.workflow_id)}`);
    }

    case "circleci_list_jobs": {
      if (!args.workflow_id) return { error: "Missing required field: workflow_id" };
      const query = { "page-token": args.page_token };
      return cciFetch(`/workflow/${encodeURIComponent(args.workflow_id)}/job`, { queryParams: query });
    }

    case "circleci_list_artifacts": {
      if (!args.project_slug) return { error: "Missing required field: project_slug" };
      if (!args.job_number) return { error: "Missing required field: job_number" };
      return cciFetch(`/project/${args.project_slug}/${args.job_number}/artifacts`);
    }

    case "circleci_trigger_pipeline": {
      if (!args.project_slug) return { error: "Missing required field: project_slug" };
      const body = {
        branch: args.branch,
        tag: args.tag,
        parameters: args.parameters || {},
      };
      return cciFetch(`/project/${args.project_slug}/pipeline`, { method: "POST", body });
    }

    case "circleci_cancel_workflow": {
      if (!args.workflow_id) return { error: "Missing required field: workflow_id" };
      return cciFetch(`/workflow/${encodeURIComponent(args.workflow_id)}/cancel`, { method: "POST" });
    }

    case "circleci_list_envvars": {
      if (!args.project_slug) return { error: "Missing required field: project_slug" };
      return cciFetch(`/project/${args.project_slug}/envvar`);
    }

    default:
      return { error: `Unknown circleci-mcp tool: ${toolName}` };
  }
}

export const metadata = {
  name: "circleci-mcp",
  version: "0.1.0",
  domain: "CI/CD",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 9,
};
