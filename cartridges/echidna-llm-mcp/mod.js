// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp/mod.js — LLM advisor cartridge for the ECHIDNA proof engine.
//
// Implements two operations called by echidna/src/rust/llm.rs:
//
//   consult        — free-form Q&A: question + context → {answer, model, latency_ms}
//   suggest_tactics — structured tactic generation for a proof goal →
//                    {tactics, recommended_provers, decomposition,
//                     auxiliary_lemmas, reasoning, model, latency_ms}
//
// Both operations route to the Anthropic Claude API directly (same pattern as
// claude-ai-mcp/mod.js). Model selection:
//   - If the caller specifies a model name, map it to a concrete Claude model ID.
//   - Fallback: claude-sonnet-4-6.
//
// Auth: ANTHROPIC_API_KEY env var (set by BoJ credential forwarding or vault-mcp).
//
// Request shape (echidna sends either "tool"/"arguments" or "operation"/"params"):
//
//   consult:
//     { question: string, context: string, model: string,
//       max_tokens: int, temperature: float, response_format: string }
//
//   suggest_tactics:
//     { system: string, prompt: string, model: string,
//       max_tokens: int, temperature: float, response_format: string }
//
// Response shape:
//   consult:        { answer: string, model: string, latency_ms: int }
//   suggest_tactics: { tactics: [...], recommended_provers: [...],
//                     decomposition: null|{...}, auxiliary_lemmas: [...],
//                     reasoning: string, model: string, latency_ms: int }

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ANTHROPIC_BASE = "https://api.anthropic.com/v1";
const TIMEOUT_MS = 60_000;
const DEFAULT_MAX_TOKENS = 2048;

// Map tier names (opus/sonnet/haiku) to concrete model IDs.
// Falls through to the literal string if it's already a full model ID.
const MODEL_MAP = {
  "opus":   "claude-opus-4-6",
  "sonnet": "claude-sonnet-4-6",
  "haiku":  "claude-haiku-4-5-20251001",
};

/**
 * Resolve a caller-supplied model hint to a concrete Anthropic model ID.
 * Accepts tier names ("opus", "sonnet", "haiku"), full model IDs, or anything
 * else (falls back to sonnet).
 *
 * @param {string|undefined} hint
 * @returns {string}
 */
function resolveModel(hint) {
  if (!hint) return MODEL_MAP["sonnet"];
  if (MODEL_MAP[hint]) return MODEL_MAP[hint];
  // Accept full model IDs that start with "claude-"
  if (hint.startsWith("claude-")) return hint;
  // Unknown — default to sonnet
  return MODEL_MAP["sonnet"];
}

// ---------------------------------------------------------------------------
// HTTP helper — matches the pattern in claude-ai-mcp/mod.js
// ---------------------------------------------------------------------------

/**
 * POST to the Anthropic API with ANTHROPIC_API_KEY from env.
 *
 * @param {string} path  — e.g. "/messages"
 * @param {object} body  — request body (will be JSON-encoded)
 * @returns {{ status: number, data: object }}
 */
async function anthropicPost(path, body) {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  if (!apiKey) {
    return { status: 401, data: { error: "ANTHROPIC_API_KEY not set — configure via vault-mcp or env" } };
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${ANTHROPIC_BASE}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ error: "non-JSON response from Anthropic" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") {
      return { status: 504, data: { error: "Anthropic API timed out after 60 s" } };
    }
    return { status: 503, data: { error: `Anthropic API unavailable: ${e.message}` } };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Extract the first text block from an Anthropic Messages API response.
 *
 * @param {object} apiResp — parsed JSON body from /v1/messages
 * @returns {string}
 */
function extractText(apiResp) {
  const content = apiResp.content ?? [];
  return content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");
}

// ---------------------------------------------------------------------------
// consult — free-form Q&A
// ---------------------------------------------------------------------------

/**
 * Route a free-form question + context to the LLM and return a formatted answer.
 *
 * The LLM receives a system prompt that primes it for formal verification Q&A
 * and a user message that concatenates the question with any provided context.
 *
 * @param {object} args — { question, context, model, max_tokens, temperature, response_format }
 * @returns {{ status: number, data: { answer: string, model: string, latency_ms: number } }}
 */
async function consult(args) {
  const t0 = Date.now();

  const {
    question,
    context = "",
    model: modelHint,
    max_tokens = DEFAULT_MAX_TOKENS,
    temperature = 0.3,
    response_format = "markdown",
  } = args ?? {};

  if (!question || typeof question !== "string" || question.trim() === "") {
    return { status: 400, data: { error: "consult: 'question' is required and must be a non-empty string" } };
  }

  const resolvedModel = resolveModel(modelHint);

  // Build the user message, embedding context when provided.
  let userContent = question;
  if (context && context.trim() !== "") {
    userContent = `Context:\n${context}\n\nQuestion:\n${question}`;
  }

  // System prompt: formal-verification advisor role.
  const systemPrompt = response_format === "markdown"
    ? "You are ECHIDNA's formal-verification advisor. Answer concisely in Markdown. " +
      "Focus on theorem-proving strategy, prover selection, and formal correctness. " +
      "Your answers are advisory — the formal provers verify everything independently."
    : "You are ECHIDNA's formal-verification advisor. Answer concisely in plain text. " +
      "Focus on theorem-proving strategy, prover selection, and formal correctness. " +
      "Your answers are advisory — the formal provers verify everything independently.";

  const payload = {
    model: resolvedModel,
    max_tokens,
    system: systemPrompt,
    messages: [{ role: "user", content: userContent }],
  };
  if (typeof temperature === "number") {
    payload.temperature = temperature;
  }

  const { status, data: apiData } = await anthropicPost("/messages", payload);

  if (status !== 200) {
    // Surface the Anthropic error upstream.
    const errMsg = apiData?.error?.message ?? apiData?.error ?? `Anthropic returned HTTP ${status}`;
    return { status, data: { error: `consult: LLM call failed — ${errMsg}` } };
  }

  const answer = extractText(apiData);
  const latency_ms = Date.now() - t0;

  return {
    status: 200,
    data: {
      answer,
      model: apiData.model ?? resolvedModel,
      latency_ms,
    },
  };
}

// ---------------------------------------------------------------------------
// suggest_tactics — structured tactic generation
// ---------------------------------------------------------------------------

/**
 * Structured tactic advisor.  The caller (echidna llm.rs) builds the system
 * and user prompts (build_system_prompt / build_user_prompt) and passes them
 * verbatim.  We route them to the LLM and parse the JSON response back into
 * the TacticSuggestionResponse shape echidna expects.
 *
 * Expected LLM JSON response schema (from echidna's build_system_prompt):
 * {
 *   "tactics": [{"tactic":"...","confidence":0.0-1.0,"target_prover":"...","rationale":"..."}],
 *   "recommended_provers": [{"prover":"...","confidence":0.0-1.0,"reason":"..."}],
 *   "decomposition": null | {"strategy":"...","subgoals":[...],"recommended_order":[...]},
 *   "auxiliary_lemmas": [...],
 *   "reasoning": "..."
 * }
 *
 * @param {object} args — { system, prompt, model, max_tokens, temperature, response_format }
 * @returns {{ status: number, data: TacticSuggestionResponse & { model: string, latency_ms: number } }}
 */
async function suggestTactics(args) {
  const t0 = Date.now();

  const {
    system: systemPrompt,
    prompt: userPrompt,
    model: modelHint,
    max_tokens = DEFAULT_MAX_TOKENS,
    temperature = 0.2,
  } = args ?? {};

  if (!userPrompt || typeof userPrompt !== "string" || userPrompt.trim() === "") {
    return { status: 400, data: { error: "suggest_tactics: 'prompt' is required and must be a non-empty string" } };
  }

  const resolvedModel = resolveModel(modelHint);

  const payload = {
    model: resolvedModel,
    max_tokens,
    messages: [{ role: "user", content: userPrompt }],
  };
  // System prompt from echidna instructs the model to return structured JSON.
  if (systemPrompt && typeof systemPrompt === "string") {
    payload.system = systemPrompt;
  }
  if (typeof temperature === "number") {
    payload.temperature = temperature;
  }

  const { status, data: apiData } = await anthropicPost("/messages", payload);

  if (status !== 200) {
    const errMsg = apiData?.error?.message ?? apiData?.error ?? `Anthropic returned HTTP ${status}`;
    return { status, data: { error: `suggest_tactics: LLM call failed — ${errMsg}` } };
  }

  const rawText = extractText(apiData);
  const latency_ms = Date.now() - t0;
  const resolvedModelId = apiData.model ?? resolvedModel;

  // Parse the structured JSON the LLM was instructed to return.
  // The echidna system prompt (build_system_prompt) asks for a specific JSON
  // schema.  If parsing fails we return a best-effort single-tactic fallback
  // so the Rust caller gets a valid TacticSuggestionResponse rather than an
  // opaque error.
  let structured;
  try {
    // The LLM sometimes wraps the JSON in a markdown code fence — strip it.
    const trimmed = rawText.trim();
    const jsonStr = trimmed.startsWith("```")
      ? trimmed.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")
      : trimmed;
    structured = JSON.parse(jsonStr);
  } catch (_parseErr) {
    // Fallback: wrap the raw text as a single "explore" tactic.
    structured = {
      tactics: [
        {
          tactic: rawText.trim().slice(0, 200),
          confidence: 0.5,
          target_prover: "auto",
          rationale: "LLM output was plain text, not JSON — wrapping as single tactic suggestion",
        },
      ],
      recommended_provers: [],
      decomposition: null,
      auxiliary_lemmas: [],
      reasoning: "Structured JSON parse failed; returned raw LLM output as tactic",
    };
  }

  return {
    status: 200,
    data: {
      // Spread structured fields from the LLM — echidna's Rust deserialiser
      // reads tactics, recommended_provers, decomposition, auxiliary_lemmas, reasoning.
      tactics: structured.tactics ?? [],
      recommended_provers: structured.recommended_provers ?? [],
      decomposition: structured.decomposition ?? null,
      auxiliary_lemmas: structured.auxiliary_lemmas ?? [],
      reasoning: structured.reasoning ?? "",
      // Extra fields consumed by TacticSuggestionResponse.
      model: resolvedModelId,
      latency_ms,
    },
  };
}

// ---------------------------------------------------------------------------
// handleTool — BoJ cartridge dispatch entry point
// ---------------------------------------------------------------------------

/**
 * BoJ JS cartridge entry point, called by BojRest.JsInvoker via js_runner.js.
 *
 * Accepts both canonical BoJ tool names and the echidna "operation" aliases
 * because the router normalises "operation" → "tool" in BojRest.Router.
 *
 * @param {string} toolName
 * @param {object} args
 * @returns {{ status: number, data: object }}
 */
export async function handleTool(toolName, args) {
  switch (toolName) {
    // ── consult ────────────────────────────────────────────────────────────
    case "consult":
      return consult(args);

    // ── suggest_tactics ───────────────────────────────────────────────────
    case "suggest_tactics":
      return suggestTactics(args);

    // ── unknown ────────────────────────────────────────────────────────────
    default:
      return {
        status: 404,
        data: { error: `echidna-llm-mcp: unknown operation '${toolName}'. Supported: consult, suggest_tactics` },
      };
  }
}
