// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// grafana-mcp/mod.js -- Grafana monitoring cartridge implementation.
//
// Provides MCP tool handlers for the Grafana HTTP API:
//   - Dashboard search, retrieval, creation, deletion
//   - Datasource query execution (PromQL, InfluxQL, etc.)
//   - Alert rule listing with state filters
//   - Annotation creation (global or per-dashboard)
//   - Datasource and folder listing
//   - Instance health checks
//
// Auth: Bearer token via GRAFANA_API_TOKEN (required for all operations).
// API docs: https://grafana.com/docs/grafana/latest/developers/http_api/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

// ---------------------------------------------------------------------------
// Configuration — base URL is instance-specific, read from environment.
// ---------------------------------------------------------------------------

function getBaseUrl() {
  const url = typeof Deno !== "undefined"
    ? Deno.env.get("GRAFANA_BASE_URL")
    : process.env.GRAFANA_BASE_URL;
  return url || "http://localhost:3000/api";
}

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Grafana API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("GRAFANA_API_TOKEN")
    : process.env.GRAFANA_API_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Grafana auth headers and error
// handling. Supports GET, POST, DELETE methods.
// ---------------------------------------------------------------------------

async function grafanaFetch(path, { method = "GET", queryParams, body } = {}) {
  const baseUrl = getBaseUrl();
  const url = new URL(`${baseUrl}${path}`);

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

  // Handle rate limiting
  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by Grafana. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Grafana API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Dashboard search ---

    case "grafana_search_dashboards": {
      const query = {
        query: args.query,
        tag: args.tag,
        folderIds: args.folder_id,
        limit: args.limit,
        type: "dash-db",
      };
      return grafanaFetch("/search", { queryParams: query });
    }

    // --- Dashboard CRUD ---

    case "grafana_get_dashboard": {
      if (!args.uid) return { error: "Missing required field: uid" };
      return grafanaFetch(`/dashboards/uid/${encodeURIComponent(args.uid)}`);
    }

    case "grafana_create_dashboard": {
      if (!args.dashboard) return { error: "Missing required field: dashboard" };
      const body = {
        dashboard: args.dashboard,
        folderUid: args.folder_uid || "",
        overwrite: args.overwrite || false,
      };
      return grafanaFetch("/dashboards/db", { method: "POST", body });
    }

    case "grafana_delete_dashboard": {
      if (!args.uid) return { error: "Missing required field: uid" };
      return grafanaFetch(`/dashboards/uid/${encodeURIComponent(args.uid)}`, { method: "DELETE" });
    }

    // --- Datasource queries ---

    case "grafana_query_datasource": {
      if (!args.datasource_uid) return { error: "Missing required field: datasource_uid" };
      if (!args.query) return { error: "Missing required field: query" };
      const body = {
        queries: [{
          refId: "A",
          datasource: { uid: args.datasource_uid },
          expr: args.query,
        }],
        from: args.from || "now-1h",
        to: args.to || "now",
      };
      return grafanaFetch("/ds/query", { method: "POST", body });
    }

    // --- Alerts ---

    case "grafana_list_alerts": {
      const query = {
        state: args.state,
        folderUID: args.folder_uid,
        limit: args.limit,
      };
      return grafanaFetch("/v1/provisioning/alert-rules", { queryParams: query });
    }

    // --- Annotations ---

    case "grafana_create_annotation": {
      if (!args.text) return { error: "Missing required field: text" };
      const body = {
        text: args.text,
        dashboardUID: args.dashboard_uid,
        panelId: args.panel_id,
        tags: args.tags || [],
        time: args.time || Date.now(),
      };
      return grafanaFetch("/annotations", { method: "POST", body });
    }

    // --- Datasources ---

    case "grafana_list_datasources": {
      return grafanaFetch("/datasources");
    }

    // --- Folders ---

    case "grafana_list_folders": {
      const query = { limit: args.limit };
      return grafanaFetch("/folders", { queryParams: query });
    }

    // --- Health ---

    case "grafana_health": {
      return grafanaFetch("/health");
    }

    default:
      return { error: `Unknown grafana-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "grafana-mcp",
  version: "0.1.0",
  domain: "Monitoring",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
