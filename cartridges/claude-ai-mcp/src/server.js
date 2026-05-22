#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// claude-ai-mcp — Anthropic Messages API cartridge for the BoJ
//
// Exposes three MCP tools:
//   claude_chat         — send messages, get a response
//   claude_count_tokens — count tokens without sending
//   claude_list_models  — list available model IDs
//
// Auth: ANTHROPIC_API_KEY env var (sourced from vault-mcp in production).
// No npm dependencies — uses Node built-in https module only.

"use strict";

const https = require("https");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SERVER_NAME = "claude-ai-mcp";
const SERVER_VERSION = "0.1.0";
const ANTHROPIC_VERSION = "2023-06-01";
const BASE_HOST = "api.anthropic.com";

const KNOWN_MODELS = [
  { id: "claude-opus-4-6",             tier: "Opus",   note: "Most capable — complex reasoning, formal verification" },
  { id: "claude-sonnet-4-6",           tier: "Sonnet", note: "Balanced — standard coding and analysis (default)" },
  { id: "claude-haiku-4-5-20251001",   tier: "Haiku",  note: "Fastest — simple lookups, mechanical tasks" },
];

const DEFAULT_MODEL = "claude-sonnet-4-6";
const DEFAULT_MAX_TOKENS = 4096;

// ---------------------------------------------------------------------------
// HTTP helper (no npm, uses Node built-in https)
// ---------------------------------------------------------------------------

/**
 * Make a POST request to the Anthropic API.
 * Returns the parsed JSON body or throws on HTTP error.
 *
 * @param {string} path - e.g. "/v1/messages"
 * @param {object} body - request body
 * @param {string} apiKey - Anthropic API key
 * @returns {Promise<object>}
 */
function anthropicPost(path, body, apiKey) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const options = {
      hostname: BASE_HOST,
      port: 443,
      path,
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(payload),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        try {
          const parsed = JSON.parse(data);
          if (res.statusCode >= 400) {
            const msg = parsed.error?.message || `HTTP ${res.statusCode}`;
            reject(new Error(`Anthropic API error (${res.statusCode}): ${msg}`));
          } else {
            resolve(parsed);
          }
        } catch (e) {
          reject(new Error(`Failed to parse Anthropic response: ${e.message}`));
        }
      });
    });

    req.on("error", (e) => reject(new Error(`HTTPS request failed: ${e.message}`)));
    req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

/**
 * claude_chat: send a conversation, return assistant reply text + usage.
 */
async function claudeChat(args) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is not set. Source it from vault-mcp.");
  }

  const model = args.model || DEFAULT_MODEL;
  const maxTokens = args.max_tokens || DEFAULT_MAX_TOKENS;

  const body = {
    model,
    max_tokens: maxTokens,
    messages: args.messages,
  };

  if (args.system) {
    body.system = args.system;
  }
  if (typeof args.temperature === "number") {
    body.temperature = args.temperature;
  }

  const response = await anthropicPost("/v1/messages", body, apiKey);

  // Extract text from content blocks
  const textBlocks = (response.content || [])
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");

  return {
    text: textBlocks,
    model: response.model,
    stop_reason: response.stop_reason,
    usage: response.usage,
    id: response.id,
  };
}

/**
 * claude_count_tokens: count tokens without sending the message.
 */
async function claudeCountTokens(args) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is not set. Source it from vault-mcp.");
  }

  const model = args.model || DEFAULT_MODEL;

  const body = {
    model,
    messages: args.messages,
  };
  if (args.system) {
    body.system = args.system;
  }

  const response = await anthropicPost("/v1/messages/count_tokens", body, apiKey);

  return {
    input_tokens: response.input_tokens,
    model,
  };
}

/**
 * claude_list_models: return known model IDs.
 */
function claudeListModels() {
  return {
    models: KNOWN_MODELS,
    default: DEFAULT_MODEL,
    note: "claude-sonnet-4-6 is the recommended default for most tasks.",
  };
}

// ---------------------------------------------------------------------------
// MCP tool definitions
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: "claude_chat",
    description:
      "Send a message (or multi-turn conversation) to a Claude model and return the text response. Uses the Anthropic Messages API. Requires ANTHROPIC_API_KEY.",
    inputSchema: {
      type: "object",
      properties: {
        messages: {
          type: "array",
          description: "Conversation history. Each entry needs 'role' (user|assistant) and 'content' (string).",
          items: {
            type: "object",
            properties: {
              role: { type: "string", enum: ["user", "assistant"] },
              content: { type: "string" },
            },
            required: ["role", "content"],
          },
          minItems: 1,
        },
        model: {
          type: "string",
          description: "Model ID. Defaults to claude-sonnet-4-6.",
        },
        system: {
          type: "string",
          description: "Optional system prompt.",
        },
        max_tokens: {
          type: "number",
          description: "Max tokens in response (default 4096).",
        },
        temperature: {
          type: "number",
          description: "Sampling temperature 0.0–1.0 (default 1.0).",
        },
      },
      required: ["messages"],
    },
  },
  {
    name: "claude_count_tokens",
    description:
      "Count how many input tokens a set of messages would consume without sending them. Uses the Anthropic token-counting endpoint.",
    inputSchema: {
      type: "object",
      properties: {
        messages: {
          type: "array",
          items: {
            type: "object",
            properties: {
              role: { type: "string", enum: ["user", "assistant"] },
              content: { type: "string" },
            },
            required: ["role", "content"],
          },
          minItems: 1,
        },
        model: {
          type: "string",
          description: "Model to count against (affects tokenisation). Defaults to claude-sonnet-4-6.",
        },
        system: {
          type: "string",
          description: "System prompt to include in the count.",
        },
      },
      required: ["messages"],
    },
  },
  {
    name: "claude_list_models",
    description:
      "Return the Claude model IDs available through this cartridge, with tier labels and notes.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
];

// ---------------------------------------------------------------------------
// MCP stdio transport (JSON-RPC 2.0, Content-Length framing)
// ---------------------------------------------------------------------------

let buffer = "";

process.stdin.setEncoding("utf-8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;

    const header = buffer.substring(0, headerEnd);
    const lengthMatch = header.match(/Content-Length:\s*(\d+)/i);
    if (!lengthMatch) {
      buffer = buffer.substring(headerEnd + 4);
      continue;
    }

    const contentLength = parseInt(lengthMatch[1], 10);
    const bodyStart = headerEnd + 4;
    if (buffer.length < bodyStart + contentLength) break;

    const body = buffer.substring(bodyStart, bodyStart + contentLength);
    buffer = buffer.substring(bodyStart + contentLength);

    try {
      const message = JSON.parse(body);
      handleMessage(message);
    } catch (_err) {
      sendError(null, -32700, "Parse error");
    }
  }
});

function send(message) {
  const body = JSON.stringify(message);
  const header = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
  process.stdout.write(header + body);
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function handleMessage(msg) {
  if (msg.method === "initialize") {
    sendResult(msg.id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
  } else if (msg.method === "notifications/initialized") {
    // no-op
  } else if (msg.method === "tools/list") {
    sendResult(msg.id, { tools: TOOLS });
  } else if (msg.method === "tools/call") {
    handleToolCall(msg);
  } else if (msg.method === "ping") {
    sendResult(msg.id, {});
  } else if (msg.id !== undefined) {
    sendError(msg.id, -32601, `Unknown method: ${msg.method}`);
  }
}

function handleToolCall(msg) {
  const { name, arguments: args } = msg.params;

  const dispatch = async () => {
    switch (name) {
      case "claude_chat":
        return await claudeChat(args);
      case "claude_count_tokens":
        return await claudeCountTokens(args);
      case "claude_list_models":
        return claudeListModels();
      default:
        sendError(msg.id, -32602, `Unknown tool: ${name}`);
        return null;
    }
  };

  dispatch()
    .then((result) => {
      if (result !== null) {
        sendResult(msg.id, {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        });
      }
    })
    .catch((err) => {
      const errMsg = err instanceof Error ? err.message : String(err);
      sendError(msg.id, -32603, errMsg);
    });
}

// ---------------------------------------------------------------------------
// Crash resilience — keep the server alive when a single request fails
// ---------------------------------------------------------------------------

process.on("uncaughtException", (err) => {
  process.stderr.write(`[${SERVER_NAME}] uncaughtException: ${err.message}\n`);
  process.stderr.write(`${err.stack}\n`);
});

process.on("unhandledRejection", (reason) => {
  const msg = reason instanceof Error ? reason.message : String(reason);
  process.stderr.write(`[${SERVER_NAME}] unhandledRejection: ${msg}\n`);
});

process.stdin.on("end", () => {
  process.stderr.write(`[${SERVER_NAME}] stdin closed — exiting cleanly\n`);
  process.exit(0);
});

process.stdin.on("error", (err) => {
  process.stderr.write(`[${SERVER_NAME}] stdin error: ${err.message}\n`);
});

process.stdout.on("error", (err) => {
  // EPIPE — Claude Code closed its end; exit cleanly instead of crashing
  if (err.code === "EPIPE") {
    process.exit(0);
  }
  process.stderr.write(`[${SERVER_NAME}] stdout error: ${err.message}\n`);
});

process.stderr.write(`[${SERVER_NAME}] MCP server running on stdio\n`);
