// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// local-memory-mcp/mod.js — Persistent local memory cartridge (SQLite-backed).
//
// Delegates to backend at http://127.0.0.1:7750 (override with LOCAL_MEMORY_URL).
// No auth required. All data stays local — no cloud, no API keys.

const BASE_URL = Deno.env.get("LOCAL_MEMORY_URL") ?? "http://127.0.0.1:7750";
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
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "local-memory-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `local-memory-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "memory_session_start": {
      const { project } = args ?? {};
      const payload = {};
      if (project !== undefined) payload.project = project;
      return post("/api/v1/session/start", payload);
    }

    case "memory_session_end": {
      const { summary } = args ?? {};
      const payload = {};
      if (summary !== undefined) payload.summary = summary;
      return post("/api/v1/session/end", payload);
    }

    case "memory_learn": {
      const { category, content, tags, confidence, project } = args ?? {};
      if (!category || !content)
        return { status: 400, data: { error: "category and content are required" } };
      const payload = { category, content };
      if (tags !== undefined) payload.tags = tags;
      if (confidence !== undefined) payload.confidence = confidence;
      if (project !== undefined) payload.project = project;
      return post("/api/v1/learnings", payload);
    }

    case "memory_recall": {
      const { query, limit } = args ?? {};
      const payload = {};
      if (query !== undefined) payload.query = query;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/learnings/recall", payload);
    }

    case "memory_search": {
      const { query, types, limit } = args ?? {};
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query };
      if (types !== undefined) payload.types = types;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/search", payload);
    }

    case "memory_decide": {
      const { title, decision, reasoning, alternatives, confidence, project } = args ?? {};
      if (!title || !decision || !reasoning)
        return { status: 400, data: { error: "title, decision, and reasoning are required" } };
      const payload = { title, decision, reasoning };
      if (alternatives !== undefined) payload.alternatives = alternatives;
      if (confidence !== undefined) payload.confidence = confidence;
      if (project !== undefined) payload.project = project;
      return post("/api/v1/decisions", payload);
    }

    case "memory_entity_observe": {
      const { entityName, entityType, content } = args ?? {};
      if (!entityName || !entityType || !content)
        return { status: 400, data: { error: "entityName, entityType, and content are required" } };
      return post("/api/v1/entities/observe", { entityName, entityType, content });
    }

    case "memory_entity_search": {
      const { query, entityType, limit } = args ?? {};
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query };
      if (entityType !== undefined) payload.entityType = entityType;
      if (limit !== undefined) payload.limit = limit;
      return post("/api/v1/entities/search", payload);
    }

    case "memory_entity_open": {
      const { name, id } = args ?? {};
      const payload = {};
      if (name !== undefined) payload.name = name;
      if (id !== undefined) payload.id = id;
      return post("/api/v1/entities/open", payload);
    }

    case "memory_entity_relate": {
      const { fromEntityId, toEntityId, relationType, weight } = args ?? {};
      if (!fromEntityId || !toEntityId || !relationType)
        return { status: 400, data: { error: "fromEntityId, toEntityId, and relationType are required" } };
      const payload = { fromEntityId, toEntityId, relationType };
      if (weight !== undefined) payload.weight = weight;
      return post("/api/v1/entities/relate", payload);
    }

    case "memory_insights": {
      const { project } = args ?? {};
      const payload = {};
      if (project !== undefined) payload.project = project;
      return post("/api/v1/insights", payload);
    }

    case "memory_profile_set": {
      const { field, value } = args ?? {};
      if (!field || !value) return { status: 400, data: { error: "field and value are required" } };
      return post("/api/v1/profile/set", { field, value });
    }

    case "memory_profile_get": {
      const { field } = args ?? {};
      if (!field) return { status: 400, data: { error: "field is required" } };
      return post("/api/v1/profile/get", { field });
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
