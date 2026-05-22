// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// claude-ai-mcp/mod.js — Anthropic Claude API cartridge.
//
// Delegates to the Anthropic Claude API via fetch().
// Requires ANTHROPIC_API_KEY environment variable.

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const ANTHROPIC_BASE = "https://api.anthropic.com/v1";
const TIMEOUT_MS = 60_000;

async function anthropicPost(path, payload) {
  if (!ANTHROPIC_API_KEY) {
    return { status: 401, data: { error: "ANTHROPIC_API_KEY not set" } };
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${ANTHROPIC_BASE}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { error: "Anthropic API timed out" } };
    return { status: 503, data: { error: `Anthropic API unavailable: ${e.message}` } };
  } finally {
    clearTimeout(t);
  }
}

async function anthropicGet(path) {
  if (!ANTHROPIC_API_KEY) {
    return { status: 401, data: { error: "ANTHROPIC_API_KEY not set" } };
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${ANTHROPIC_BASE}${path}`, {
      method: "GET",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { error: "Anthropic API timed out" } };
    return { status: 503, data: { error: `Anthropic API unavailable: ${e.message}` } };
  } finally {
    clearTimeout(t);
  }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- claude_chat ----------------------------------------------------------
    case "claude_chat": {
      const { model = "claude-sonnet-4-6", messages, system, max_tokens = 4096 } = args ?? {};
      if (!messages || !Array.isArray(messages) || messages.length === 0) {
        return { status: 400, data: { error: "messages array is required" } };
      }
      const payload = { model, messages, max_tokens };
      if (system) payload.system = system;
      return anthropicPost("/messages", payload);
    }

    // -- claude_count_tokens --------------------------------------------------
    case "claude_count_tokens": {
      const { model = "claude-sonnet-4-6", messages, system } = args ?? {};
      if (!messages || !Array.isArray(messages)) {
        return { status: 400, data: { error: "messages array is required" } };
      }
      const payload = { model, messages };
      if (system) payload.system = system;
      return anthropicPost("/messages/count_tokens", payload);
    }

    // -- claude_list_models ---------------------------------------------------
    case "claude_list_models": {
      return anthropicGet("/models");
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
