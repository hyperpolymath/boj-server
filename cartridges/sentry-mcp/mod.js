// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// sentry-mcp/mod.js -- Sentry error tracking cartridge implementation.
//
// Provides MCP tool handlers for the Sentry API:
//   - Issue listing with query/sort filters
//   - Issue detail retrieval
//   - Event listing with full stack traces
//   - Issue resolution/unresolving
//   - Project and release listing
//   - DSN key lookup
//   - Team listing
//   - Tag search and browsing
//   - Performance transaction queries
//
// Auth: Bearer token via SENTRY_AUTH_TOKEN (required for all operations).
// API docs: https://docs.sentry.io/api/
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

// ---------------------------------------------------------------------------
// Configuration — base URL defaults to sentry.io SaaS.
// ---------------------------------------------------------------------------

function getBaseUrl() {
  const url = typeof Deno !== "undefined"
    ? Deno.env.get("SENTRY_BASE_URL")
    : process.env.SENTRY_BASE_URL;
  return url || "https://sentry.io/api/0";
}

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Sentry auth token from environment.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("SENTRY_AUTH_TOKEN")
    : process.env.SENTRY_AUTH_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Sentry auth headers and error handling.
// ---------------------------------------------------------------------------

async function sentryFetch(path, { method = "GET", queryParams, body } = {}) {
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

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited by Sentry. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.detail || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Sentry API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Issues ---

    case "sentry_list_issues": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.project) return { error: "Missing required field: project" };
      const query = {
        query: args.query,
        sort: args.sort,
        limit: args.limit,
      };
      return sentryFetch(`/projects/${encodeURIComponent(args.organization)}/${encodeURIComponent(args.project)}/issues/`, { queryParams: query });
    }

    case "sentry_get_issue": {
      if (!args.issue_id) return { error: "Missing required field: issue_id" };
      return sentryFetch(`/issues/${encodeURIComponent(args.issue_id)}/`);
    }

    case "sentry_list_events": {
      if (!args.issue_id) return { error: "Missing required field: issue_id" };
      const query = { full: args.full, limit: args.limit };
      return sentryFetch(`/issues/${encodeURIComponent(args.issue_id)}/events/`, { queryParams: query });
    }

    case "sentry_resolve_issue": {
      if (!args.issue_id) return { error: "Missing required field: issue_id" };
      if (!args.status) return { error: "Missing required field: status" };
      const body = { status: args.status };
      return sentryFetch(`/issues/${encodeURIComponent(args.issue_id)}/`, { method: "PUT", body });
    }

    // --- Projects ---

    case "sentry_list_projects": {
      if (!args.organization) return { error: "Missing required field: organization" };
      return sentryFetch(`/organizations/${encodeURIComponent(args.organization)}/projects/`);
    }

    // --- Releases ---

    case "sentry_list_releases": {
      if (!args.organization) return { error: "Missing required field: organization" };
      const query = { project: args.project, per_page: args.limit };
      return sentryFetch(`/organizations/${encodeURIComponent(args.organization)}/releases/`, { queryParams: query });
    }

    // --- DSN ---

    case "sentry_get_dsn": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.project) return { error: "Missing required field: project" };
      return sentryFetch(`/projects/${encodeURIComponent(args.organization)}/${encodeURIComponent(args.project)}/keys/`);
    }

    // --- Teams ---

    case "sentry_list_teams": {
      if (!args.organization) return { error: "Missing required field: organization" };
      return sentryFetch(`/organizations/${encodeURIComponent(args.organization)}/teams/`);
    }

    // --- Tags ---

    case "sentry_search_tags": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.project) return { error: "Missing required field: project" };
      const path = args.key
        ? `/projects/${encodeURIComponent(args.organization)}/${encodeURIComponent(args.project)}/tags/${encodeURIComponent(args.key)}/values/`
        : `/projects/${encodeURIComponent(args.organization)}/${encodeURIComponent(args.project)}/tags/`;
      return sentryFetch(path);
    }

    // --- Performance ---

    case "sentry_list_transactions": {
      if (!args.organization) return { error: "Missing required field: organization" };
      if (!args.project) return { error: "Missing required field: project" };
      const query = {
        query: args.query,
        sort: args.sort,
        per_page: args.limit,
        field: ["transaction", "p50()", "p95()", "failure_rate()", "count()"],
        project: args.project,
      };
      return sentryFetch(`/organizations/${encodeURIComponent(args.organization)}/events/`, { queryParams: query });
    }

    default:
      return { error: `Unknown sentry-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "sentry-mcp",
  version: "0.1.0",
  domain: "Monitoring",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
