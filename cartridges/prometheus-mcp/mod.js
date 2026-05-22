// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// prometheus-mcp/mod.js -- Prometheus monitoring cartridge implementation.
//
// Provides MCP tool handlers for the Prometheus HTTP API v1:
//   - Instant queries (single point in time PromQL evaluation)
//   - Range queries (PromQL over time window with step resolution)
//   - Scrape target listing with health status
//   - Alert rule listing with state and annotations
//   - Label name and value browsing
//   - Metric metadata (type, help, unit)
//   - Time series listing by label matchers
//
// Auth: Optional Bearer token via PROMETHEUS_TOKEN.
// API docs: https://prometheus.io/docs/prometheus/latest/querying/api/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

// ---------------------------------------------------------------------------
// Configuration — base URL is instance-specific, read from environment.
// ---------------------------------------------------------------------------

function getBaseUrl() {
  const url = typeof Deno !== "undefined"
    ? Deno.env.get("PROMETHEUS_BASE_URL")
    : process.env.PROMETHEUS_BASE_URL;
  return url || "http://localhost:9090/api/v1";
}

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Prometheus auth token from environment.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("PROMETHEUS_TOKEN")
    : process.env.PROMETHEUS_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Prometheus headers and error handling.
// ---------------------------------------------------------------------------

async function promFetch(path, { method = "GET", queryParams, body } = {}) {
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
  };

  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const options = { method, headers };
  if (body) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    options.body = body;
  }

  const response = await fetch(url.toString(), options);
  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.error || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Prometheus API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Instant query ---

    case "prometheus_query": {
      if (!args.query) return { error: "Missing required field: query" };
      const query = { query: args.query, time: args.time };
      return promFetch("/query", { queryParams: query });
    }

    // --- Range query ---

    case "prometheus_query_range": {
      if (!args.query) return { error: "Missing required field: query" };
      if (!args.start) return { error: "Missing required field: start" };
      if (!args.end) return { error: "Missing required field: end" };
      if (!args.step) return { error: "Missing required field: step" };
      const query = {
        query: args.query,
        start: args.start,
        end: args.end,
        step: args.step,
      };
      return promFetch("/query_range", { queryParams: query });
    }

    // --- Targets ---

    case "prometheus_list_targets": {
      const query = { state: args.state };
      return promFetch("/targets", { queryParams: query });
    }

    // --- Alerts ---

    case "prometheus_list_alerts": {
      return promFetch("/alerts");
    }

    // --- Labels ---

    case "prometheus_list_labels": {
      const query = { start: args.start, end: args.end };
      return promFetch("/labels", { queryParams: query });
    }

    case "prometheus_label_values": {
      if (!args.label) return { error: "Missing required field: label" };
      const query = { start: args.start, end: args.end };
      return promFetch(`/label/${encodeURIComponent(args.label)}/values`, { queryParams: query });
    }

    // --- Metadata ---

    case "prometheus_metadata": {
      const query = { metric: args.metric, limit: args.limit };
      return promFetch("/metadata", { queryParams: query });
    }

    // --- Series ---

    case "prometheus_series": {
      if (!args.match) return { error: "Missing required field: match" };
      const query = {
        "match[]": args.match,
        start: args.start,
        end: args.end,
      };
      return promFetch("/series", { queryParams: query });
    }

    default:
      return { error: `Unknown prometheus-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "prometheus-mcp",
  version: "0.1.0",
  domain: "Monitoring",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 8,
};
