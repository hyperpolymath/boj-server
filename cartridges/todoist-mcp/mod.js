// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// todoist-mcp/mod.js -- Todoist task manager cartridge implementation.
//
// Provides MCP tool handlers for the Todoist REST API v2:
//   - Task listing with filter expressions
//   - Single task retrieval by ID
//   - Task creation with due dates, priorities, labels
//   - Task completion
//   - Project listing and details
//   - Label listing
//   - Comment retrieval
//   - Section browsing
//   - Completed task history (Sync API)
//
// Auth: Bearer token via TODOIST_API_TOKEN (required).
// API docs: https://developer.todoist.com/rest/v2/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://api.todoist.com/rest/v2";
const SYNC_API_BASE = "https://api.todoist.com/sync/v9";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Todoist API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("TODOIST_API_TOKEN")
    : process.env.TODOIST_API_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Todoist API headers,
// bearer auth, and error normalization.
// ---------------------------------------------------------------------------

async function todoistFetch(path, queryParams, method, body, useSyncApi) {
  const base = useSyncApi ? SYNC_API_BASE : API_BASE;
  const url = new URL(`${base}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/todoist-mcp/0.2.0",
  };

  const token = getToken();
  if (!token) {
    return { status: 401, error: "TODOIST_API_TOKEN not set." };
  }
  headers["Authorization"] = `Bearer ${token}`;

  const fetchOpts = { method: method || "GET", headers };

  if (body) {
    headers["Content-Type"] = "application/json";
    fetchOpts.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), fetchOpts);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  if (response.status === 204) {
    return { status: 204, data: { success: true } };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Todoist API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Task listing ---

    case "todoist_get_tasks": {
      const params = {};
      if (args.project_id) params.project_id = args.project_id;
      if (args.label) params.label = args.label;
      if (args.filter) params.filter = args.filter;
      return todoistFetch("/tasks", params);
    }

    // --- Single task ---

    case "todoist_get_task": {
      if (!args.task_id) return { error: "Missing required field: task_id" };
      return todoistFetch(`/tasks/${encodeURIComponent(args.task_id)}`);
    }

    // --- Task creation ---

    case "todoist_create_task": {
      if (!args.content) return { error: "Missing required field: content" };
      const body = { content: args.content };
      if (args.description) body.description = args.description;
      if (args.project_id) body.project_id = args.project_id;
      if (args.due_string) body.due_string = args.due_string;
      if (args.due_date) body.due_date = args.due_date;
      if (args.priority) body.priority = args.priority;
      if (args.labels) body.labels = args.labels.split(",").map((l) => l.trim());
      return todoistFetch("/tasks", null, "POST", body);
    }

    // --- Task completion ---

    case "todoist_complete_task": {
      if (!args.task_id) return { error: "Missing required field: task_id" };
      return todoistFetch(`/tasks/${encodeURIComponent(args.task_id)}/close`, null, "POST");
    }

    // --- Projects ---

    case "todoist_list_projects": {
      return todoistFetch("/projects");
    }

    case "todoist_get_project": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      return todoistFetch(`/projects/${encodeURIComponent(args.project_id)}`);
    }

    // --- Labels ---

    case "todoist_list_labels": {
      return todoistFetch("/labels");
    }

    // --- Comments ---

    case "todoist_get_comments": {
      const params = {};
      if (args.task_id) params.task_id = args.task_id;
      if (args.project_id) params.project_id = args.project_id;
      return todoistFetch("/comments", params);
    }

    // --- Sections ---

    case "todoist_list_sections": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      return todoistFetch("/sections", { project_id: args.project_id });
    }

    // --- Completed tasks (Sync API) ---

    case "todoist_get_completed_tasks": {
      const params = {};
      if (args.project_id) params.project_id = args.project_id;
      if (args.limit) params.limit = args.limit;
      return todoistFetch("/completed/get_all", params, "GET", null, true);
    }

    default:
      return { error: `Unknown todoist-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "todoist-mcp",
  version: "0.2.0",
  domain: "Productivity",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
