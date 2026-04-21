#!/usr/bin/env node
// Group management
// ===================================================================

/**
 * Fetch the list of available groups.
 * @returns {Promise<Array<{id: string, name: string, description: string}>>}
 */
async function fetchGroups() {
  // For now, return a static list of groups. This can be extended to fetch
  // groups from a configuration file or database.
  return [
    { id: "database", name: "Database", description: "Database-related tools" },
    { id: "cloud", name: "Cloud", description: "Cloud-related tools" },
    { id: "git", name: "Git", description: "Git-related tools" },
    { id: "comms", name: "Comms", description: "Communication-related tools" },
  ];
}
=======
// ===================================================================
// Prompt management
// ===================================================================

/**
 * Fetch the list of available prompts.
 * @returns {Promise<Array<{id: string, name: string, description: string}>>}
 */
async function fetchPrompts() {
  // For now, return a static list of prompts. This can be extended to fetch
  // prompts from a configuration file or database.
  return [
    { id: "project-analysis", name: "Project Analysis", description: "Analyze a project and suggest improvements" },
    { id: "code-review", name: "Code Review", description: "Review code and detect code smells" },
    { id: "research", name: "Research", description: "Research a topic and summarize findings" },
  ];
}

/**
 * Fetch a specific prompt by ID.
 * @param {string} promptId
 * @returns {Promise<{id: string, name: string, description: string, template: string} | null>}
 */
async function fetchPrompt(promptId) {
  // For now, return a static prompt. This can be extended to fetch
  // prompts from a configuration file or database.
  const prompts = [
    {
      id: "project-analysis",
      name: "Project Analysis",
      description: "Analyze a project and suggest improvements",
      template: "Analyze this repository and suggest improvements",
    },
    {
      id: "code-review",
      name: "Code Review",
      description: "Review code and detect code smells",
      template: "Review this code and detect code smells",
    },
    {
      id: "research",
      name: "Research",
      description: "Research a topic and summarize findings",
      template: "Research this topic and summarize findings",
    },
  ];

  return prompts.find((p) => p.id === promptId) || null;
}

// ===================================================================
// Resource management
// ===================================================================

/**
 * Fetch the list of available resources.
 * @returns {Promise<Array<{id: string, name: string, description: string}>>}
 */
async function fetchResources() {
  // For now, return a static list of resources. This can be extended to fetch
  // resources from a configuration file or database.
  return [
    { id: "knowledge-graph", name: "Knowledge Graph", description: "Knowledge graph for storing and managing contextual data" },
    { id: "sessions", name: "Sessions", description: "Session management for persistent session state" },
    { id: "learnings", name: "Learnings", description: "Learning system for capturing and organizing knowledge" },
  ];
}

/**
 * Fetch a specific resource by ID.
 * @param {string} resourceId
 * @returns {Promise<{id: string, name: string, description: string, schema: object} | null>}
 */
async function fetchResource(resourceId) {
  // For now, return a static resource. This can be extended to fetch
  // resources from a configuration file or database.
  const resources = [
    {
      id: "knowledge-graph",
      name: "Knowledge Graph",
      description: "Knowledge graph for storing and managing contextual data",
      schema: {
        type: "object",
        properties: {
          entities: { type: "array", items: { type: "object" } },
          observations: { type: "array", items: { type: "object" } },
          relations: { type: "array", items: { type: "object" } },
        },
      },
    },
    {
      id: "sessions",
      name: "Sessions",
      description: "Session management for persistent session state",
      schema: {
        type: "object",
        properties: {
          id: { type: "string" },
          project: { type: "string" },
          started_at: { type: "string", format: "date-time" },
          ended_at: { type: "string", format: "date-time", nullable: true },
          summary: { type: "string" },
          context: { type: "array", items: { type: "string" } },
        },
      },
    },
    {
      id: "learnings",
      name: "Learnings",
      description: "Learning system for capturing and organizing knowledge",
      schema: {
        type: "object",
        properties: {
          id: { type: "string" },
          category: { type: "string" },
          content: { type: "string" },
          tags: { type: "array", items: { type: "string" } },
          confidence: { type: "number", minimum: 0, maximum: 1 },
          project: { type: "string", nullable: true },
          created_at: { type: "string", format: "date-time" },
          updated_at: { type: "string", format: "date-time" },
        },
      },
    },
  ];

  return resources.find((r) => r.id === resourceId) || null;
}

// ===================================================================
// Group management
// ===================================================================

/**
 * Fetch the list of available groups.
 * @returns {Promise<Array<{id: string, name: string, description: string}>>}
 */
async function fetchGroups() {
  // For now, return a static list of groups. This can be extended to fetch
  // groups from a configuration file or database.
  return [
    { id: "database", name: "Database", description: "Database-related tools" },
    { id: "cloud", name: "Cloud", description: "Cloud-related tools" },
    { id: "git", name: "Git", description: "Git-related tools" },
    { id: "comms", name: "Comms", description: "Communication-related tools" },
  ];
}JSON-RPC stdio transport
// ===================================================================

let buffer = "";
const MAX_BUFFER_BYTES = 2 * 1_048_576; // 2 MB
=======
// ===================================================================
// JSON-RPC stdio transport
// ===================================================================

let buffer = "";
const MAX_BUFFER_BYTES = 2 * 1_048_576; // 2 MB

// Auto-reconnect configuration
const MAX_RECONNECT_ATTEMPTS = 5;
const INITIAL_RECONNECT_DELAY = 1000; // 1 second
let reconnectAttempts = 0;
let reconnectTimeout = null;

// ===================================================================
// Auto-reconnect helper
// ===================================================================

/**
 * Calculate the next reconnect delay with exponential backoff and jitter.
 * @param {number} attempt
 * @returns {number}
 */
function getReconnectDelay(attempt) {
  const delay = INITIAL_RECONNECT_DELAY * Math.pow(2, attempt);
  const jitter = delay * 0.2; // 20% jitter
  return delay + Math.random() * jitter;
}

/**
 * Attempt to reconnect to the stdio transport.
 */
function attemptReconnect() {
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    logError("Max reconnect attempts reached. Giving up.");
    process.exit(1);
  }

  const delay = getReconnectDelay(reconnectAttempts);
  logError(`Attempting to reconnect in ${delay}ms... (attempt ${reconnectAttempts + 1} of ${MAX_RECONNECT_ATTEMPTS})`);

  reconnectTimeout = setTimeout(() => {
    reconnectAttempts++;
    // In a real stdio transport, you would re-establish the connection here.
    // For now, we'll just log the attempt.
    logError(`Reconnect attempt ${reconnectAttempts}`);
    attemptReconnect();
  }, delay);
}

// ===================================================================
// Error handling
// ===================================================================

/**
 * Handle errors and attempt to reconnect if necessary.
 * @param {Error} error
 */
function handleError(error) {
  logError("Error in MCP bridge:", error);
  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout);
  }
  reconnectAttempts = 0;
  attemptReconnect();
}

// Listen for unhandled rejections and errors
process.on("unhandledRejection", (reason, promise) => {
  logError("Unhandled Rejection at:", promise, "reason:", reason);
  handleError(reason);
});

process.on("uncaughtException", (error) => {
  logError("Uncaught Exception:", error);
  handleError(error);
});Tool dispatch
// ===================================================================

/**
 * Dispatch a validated tool call to the appropriate handler.
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @returns {Promise<object>}
 */
async function dispatchTool(toolName, args) {
=======
// ===================================================================
// Group management
// ===================================================================

/**
 * Fetch the list of available groups.
 * @returns {Promise<Array<{id: string, name: string, description: string}>>}
 */
async function fetchGroups() {
  // For now, return a static list of groups. This can be extended to fetch
  // groups from a configuration file or database.
  return [
    { id: "database", name: "Database", description: "Database-related tools" },
    { id: "cloud", name: "Cloud", description: "Cloud-related tools" },
    { id: "git", name: "Git", description: "Git-related tools" },
    { id: "comms", name: "Comms", description: "Communication-related tools" },
  ];
}

/**
 * Dispatch a validated tool call to the appropriate handler within a group.
 * @param {string} groupId
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @returns {Promise<object>}
 */
async function dispatchGroupTool(groupId, toolName, args) {
  // Map group IDs to their respective cartridges
  const groupToCartridge = {
    database: "database-mcp",
    cloud: "cloud-mcp",
    git: "git-mcp",
    comms: "comms-mcp",
  };

  const cartridgeName = groupToCartridge[groupId];
  if (!cartridgeName) {
    return null;
  }

  // Dispatch the tool call to the appropriate cartridge
  return invokeCartridge(cartridgeName, args);
}

// ===================================================================
// Tool dispatch
// ===================================================================

/**
 * Dispatch a validated tool call to the appropriate handler.
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @returns {Promise<object>}
 */
async function dispatchTool(toolName, args) {SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP stdio transport bridge
//
// Bridges the running BoJ REST API (port 7700) to the MCP JSON-RPC
// stdio protocol so that Claude Code, Glama, and other MCP clients
// can discover and invoke BoJ cartridge tools.
//
// Usage: deno run --allow-net main.js
//    or: node main.js

import {
  RATE_LIMIT,
  isInputSizeOk,
  isValidToolName,
  rateLimitAllow,
  sanitizeErrorMessage,
  scanObjectForInjection,
  validateRequiredStrings,
} from "./lib/security.js";
import {
  fetchCartridgeInfo,
  fetchCartridges,
  fetchHealth,
  fetchMenu,
  handleGitHubTool,
  handleGitLabTool,
  invokeCartridge,
} from "./lib/api-clients.js";
import { buildToolList } from "./lib/tools.js";
import {
  initValidator,
  tryParseEnvelope,
  validateEnvelope,
} from "./lib/nickel-validator.js";
import { info, warn, error as logError } from "./lib/logger.js";

const BOJ_BASE = process.env.BOJ_URL || "http://localhost:7700";
const SERVER_NAME = "boj-server";
const SERVER_VERSION = "0.4.0";

// ===================================================================
// JSON-RPC stdio transport
// ===================================================================

let buffer = "";
const MAX_BUFFER_BYTES = 2 * 1_048_576; // 2 MB

process.stdin.setEncoding("utf8");
const pendingMessages = [];

process.stdin.on("data", (chunk) => {
  buffer += chunk;
  if (buffer.length > MAX_BUFFER_BYTES) {
    sendError(null, -32600, "Message too large");
    buffer = "";
    return;
  }
  let boundary;
  while ((boundary = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, boundary).trim();
    buffer = buffer.slice(boundary + 1);
    if (line.length > 0) {
      const p = handleMessage(line).catch(() => {});
      pendingMessages.push(p);
    }
  }
});

process.stdin.on("end", async () => {
  await Promise.allSettled(pendingMessages);
  process.exit(0);
});

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message: sanitizeErrorMessage(message) } });
}

// ===================================================================
// Hardening gate — validates every tool call before dispatch
// ===================================================================

/**
 * Run all security checks on a tool call.
 * Returns an error object {code, message} if rejected, or null if OK.
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @returns {{code: number, message: string}|null}
 */
function hardeningGate(toolName, args) {
  // 1. Rate limiting
  if (!rateLimitAllow()) {
    return { code: -32000, message: "Rate limit exceeded. Max " + RATE_LIMIT + " tool calls per minute." };
  }

  // 2. Tool name validation
  if (!isValidToolName(toolName)) {
    return { code: -32602, message: "Invalid tool name" };
  }

  // 3. Input size check
  if (!isInputSizeOk(args)) {
    return { code: -32600, message: "Tool arguments exceed maximum size (1 MB)" };
  }

  // 4. Prompt injection detection
  const injectionLevel = scanObjectForInjection(args);
  if (injectionLevel === "critical" || injectionLevel === "high") {
    logError("Injection blocked", { tool: toolName, confidence: injectionLevel });
    return { code: -32600, message: "Request rejected: suspicious content detected" };
  }
  if (injectionLevel === "medium") {
    warn("Injection warning", { tool: toolName, confidence: injectionLevel });
  }

  // 5. Required field validation
  let validationError = null;
  if (toolName === "boj_cartridge_info" || toolName === "boj_cartridge_invoke") {
    validationError = validateRequiredStrings(args, ["name"]);
  } else if (toolName === "boj_browser_navigate") {
    validationError = validateRequiredStrings(args, ["url"]);
  } else if (toolName === "boj_browser_click") {
    validationError = validateRequiredStrings(args, ["selector"]);
  } else if (toolName === "boj_browser_type") {
    validationError = validateRequiredStrings(args, ["selector", "text"]);
  } else if (toolName === "boj_browser_execute_js") {
    validationError = validateRequiredStrings(args, ["script"]);
  } else if (toolName.startsWith("boj_github_") && toolName !== "boj_github_list_repos") {
    if (toolName === "boj_github_graphql" || toolName === "boj_github_search_code" || toolName === "boj_github_search_issues") {
      validationError = validateRequiredStrings(args, ["query"]);
    } else {
      validationError = validateRequiredStrings(args, ["owner", "repo"]);
    }
  } else if (toolName.startsWith("boj_gitlab_") && toolName !== "boj_gitlab_list_projects") {
    validationError = validateRequiredStrings(args, ["project_id"]);
  } else if (toolName.startsWith("boj_cloud_") || toolName.startsWith("boj_comms_") || toolName === "boj_ml_huggingface" || toolName === "boj_research" || toolName === "boj_codeseeker") {
    validationError = validateRequiredStrings(args, ["operation"]);
  } else if (toolName === "boj_browser_tabs") {
    validationError = validateRequiredStrings(args, ["operation"]);
  }

  if (validationError) {
    return { code: -32602, message: validationError };
  }

  return null;
}

// ===================================================================
// Tool dispatch
// ===================================================================

/**
 * Dispatch a validated tool call to the appropriate handler.
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @returns {Promise<object>}
 */
async function dispatchTool(toolName, args) {
  switch (toolName) {
    case "boj_health":
      return fetchHealth();
    case "boj_menu":
      return fetchMenu();
    case "boj_cartridges":
      return fetchCartridges();
    case "boj_cartridge_info":
      return fetchCartridgeInfo(args.name);
    case "boj_cartridge_invoke":
      return invokeCartridge(args.name, args.params);

    case "boj_cloud_verpex":
    case "boj_cloud_cloudflare":
    case "boj_cloud_vercel":
      return invokeCartridge("cloud-mcp", { provider: toolName.replace("boj_cloud_", ""), ...args });

    case "boj_comms_gmail":
    case "boj_comms_calendar":
      return invokeCartridge("comms-mcp", { provider: toolName.replace("boj_comms_", ""), ...args });

    case "boj_ml_huggingface":
      return invokeCartridge("ml-mcp", { provider: "huggingface", ...args });

    case "boj_browser_navigate":
    case "boj_browser_click":
    case "boj_browser_type":
    case "boj_browser_read_page":
    case "boj_browser_screenshot":
    case "boj_browser_tabs":
    case "boj_browser_execute_js":
      return invokeCartridge("browser-mcp", { action: toolName.replace("boj_browser_", ""), ...args });

    case "boj_github_list_repos":
    case "boj_github_get_repo":
    case "boj_github_create_issue":
    case "boj_github_list_issues":
    case "boj_github_get_issue":
    case "boj_github_comment_issue":
    case "boj_github_create_pr":
    case "boj_github_list_prs":
    case "boj_github_get_pr":
    case "boj_github_merge_pr":
    case "boj_github_search_code":
    case "boj_github_search_issues":
    case "boj_github_get_file":
    case "boj_github_graphql":
      return handleGitHubTool(toolName, args);

    case "boj_gitlab_list_projects":
    case "boj_gitlab_get_project":
    case "boj_gitlab_create_issue":
    case "boj_gitlab_list_issues":
    case "boj_gitlab_create_mr":
    case "boj_gitlab_list_mrs":
    case "boj_gitlab_list_pipelines":
    case "boj_gitlab_setup_mirror":
      return handleGitLabTool(toolName, args);

    case "boj_codeseeker":
      return invokeCartridge("codeseeker-mcp", args);

    case "boj_research":
      return invokeCartridge("research-mcp", args);

    // Local coordination — direct to loopback backend on port 7745
    case "coord_register":
    case "coord_list_peers":
    case "coord_send":
    case "coord_receive":
    case "coord_claim_task":
    case "coord_status":
    case "coord_promote_to_supervisor":
    case "coord_send_gated":
    case "coord_review":
    case "coord_review_entry":
    case "coord_approve":
    case "coord_reject":
    case "coord_report_outcome":
    case "coord_get_affinities":
    case "coord_set_declared_affinities":
    case "coord_scan_suggestions":
    case "coord_transfer_master":
      return dispatchLocalCoord(toolName, args);

    default:
      return null; // unknown tool
  }
}

// ===================================================================
// local-coord-mcp direct dispatch (loopback only, port 7745)
// ===================================================================

const LOCAL_COORD_URL = process.env.COORD_BACKEND_URL || "http://127.0.0.1:7745";

// Nickel contracts run on coord_send / coord_send_gated only — those
// are the two tools whose `message` argument carries an A2ML envelope.
// Other coord_* calls are RPC-shaped (register/list/review/approve/...)
// and bypass contract validation. Expansion to more tools is a roadmap
// item — see Appendix K of COORD-MCP-DESIGN-LOG.md (Task #17 extension).
const ENVELOPE_CARRYING_TOOLS = new Set(["coord_send", "coord_send_gated"]);

initValidator();

async function dispatchLocalCoord(toolName, args) {
  // Runtime envelope validation (Task #17) — BEFORE the HTTP forward.
  if (ENVELOPE_CARRYING_TOOLS.has(toolName) && args && typeof args.message === "string") {
    const env = tryParseEnvelope(args.message);
    if (env && typeof env === "object") {
      const senderRole = env._meta?.sender_role || args.sender_role;
      const result = validateEnvelope(env, senderRole);
      if (!result.ok) {
        return {
          success: false,
          error: `envelope validation failed: ${result.error}`,
          hint: "See cartridges/local-coord-mcp/schemas/coord-messages-contracts.ncl for the active contracts",
        };
      }
    }
    // Plain-string messages (non-JSON) skip validation — they're not
    // A2ML envelopes. The Zig adapter still enforces shape + gating.
  }

  try {
    const res = await fetch(`${LOCAL_COORD_URL}/tools/${toolName}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(args || {}),
    });
    try {
      return await res.json();
    } catch {
      return { success: false, error: "local-coord-mcp backend returned non-JSON" };
    }
  } catch (e) {
    return {
      success: false,
      error: `local-coord-mcp backend unavailable at ${LOCAL_COORD_URL}: ${e.message}`,
      hint: "Start the adapter: cd cartridges/local-coord-mcp/adapter && zig build run",
    };
  }
}

// ===================================================================
// MCP message handler
// ===================================================================

async function handleMessage(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    sendError(null, -32700, "Parse error");
    return;
  }

  const { id, method, params } = msg;

  switch (method) {
    case "initialize": {
      info("MCP initialize", { client: params?.clientInfo?.name });
      sendResult(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      break;
    }

    case "notifications/initialized":
      break;

    case "tools/list": {
      const tools = buildToolList();
      sendResult(id, { tools });
      break;
    }

    case "tools/call": {
      const toolName = params?.name;
      const args = params?.arguments || {};

      const rejection = hardeningGate(toolName, args);
      if (rejection) {
        sendError(id, rejection.code, rejection.message);
        break;
      }

      const result = await dispatchTool(toolName, args);
      if (result === null) {
        sendError(id, -32601, "Unknown tool");
      } else {
        sendResult(id, {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        });
      }
      break;
    }

    case "groups/list": {
      const groups = await fetchGroups();
      sendResult(id, { groups });
      break;
    }

    case "groups/call": {
      const groupId = params?.groupId;
      const toolName = params?.name;
      const args = params?.arguments || {};

      if (!groupId) {
        sendError(id, -32602, "Group ID is required");
        break;
      }

      const rejection = hardeningGate(toolName, args);
      if (rejection) {
        sendError(id, rejection.code, rejection.message);
        break;
      }

      const result = await dispatchGroupTool(groupId, toolName, args);
      if (result === null) {
        sendError(id, -32601, "Unknown tool or group");
      } else {
        sendResult(id, {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        });
      }
      break;
    }

    case "prompts/list": {
      const prompts = await fetchPrompts();
      sendResult(id, { prompts });
      break;
    }

    case "prompts/get": {
      const promptId = params?.promptId;
      if (!promptId) {
        sendError(id, -32602, "Prompt ID is required");
        break;
      }

      const prompt = await fetchPrompt(promptId);
      if (prompt === null) {
        sendError(id, -32601, "Unknown prompt");
      } else {
        sendResult(id, { prompt });
      }
      break;
    }

    case "resources/list": {
      const resources = await fetchResources();
      sendResult(id, { resources });
      break;
    }

    case "resources/get": {
      const resourceId = params?.resourceId;
      if (!resourceId) {
        sendError(id, -32602, "Resource ID is required");
        break;
      }

      const resource = await fetchResource(resourceId);
      if (resource === null) {
        sendError(id, -32601, "Unknown resource");
      } else {
        sendResult(id, { resource });
      }
      break;
    }

    case "ping":
      sendResult(id, {});
      break;

    default:
      if (id !== undefined) {
        sendError(id, -32601, "Method not found");
      }
  }
}
