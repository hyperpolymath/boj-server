// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// coderag-mcp/mod.js — CodeRAG enterprise code intelligence cartridge.
//
// Delegates to backend at http://127.0.0.1:7474 (override with CODERAG_URL).
// No auth required. The backend connects to Neo4j on bolt://127.0.0.1:7687.

const BASE_URL = Deno.env.get("CODERAG_URL") ?? "http://127.0.0.1:7474";
const TIMEOUT_MS = 60_000; // graph analysis can be slow

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
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "coderag-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `coderag-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "coderag_analyze_repository": {
      const { repository_url, branch, auth_token } = args ?? {};
      if (!repository_url) return { status: 400, data: { error: "repository_url is required" } };
      const payload = { repository_url };
      if (branch !== undefined) payload.branch = branch;
      if (auth_token !== undefined) payload.auth_token = auth_token;
      return post("/api/v1/analyze", payload);
    }

    case "coderag_query_knowledge_graph": {
      const { query, language } = args ?? {};
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query };
      if (language !== undefined) payload.language = language;
      return post("/api/v1/query", payload);
    }

    case "coderag_calculate_metrics": {
      const { repository_url, metric_types } = args ?? {};
      if (!repository_url) return { status: 400, data: { error: "repository_url is required" } };
      const payload = { repository_url };
      if (metric_types !== undefined) payload.metric_types = metric_types;
      return post("/api/v1/metrics", payload);
    }

    case "coderag_semantic_search": {
      const { query, repository_url } = args ?? {};
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query };
      if (repository_url !== undefined) payload.repository_url = repository_url;
      return post("/api/v1/search", payload);
    }

    case "coderag_detect_language": {
      const { repository_url } = args ?? {};
      if (!repository_url) return { status: 400, data: { error: "repository_url is required" } };
      return post("/api/v1/detect-language", { repository_url });
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
