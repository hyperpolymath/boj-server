#!/usr/bin/env node
// SPDX-License-Identifier: PMPL-1.0-or-later
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

import { SERVER_NAME, SERVER_VERSION } from "./lib/version.js";
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
import { info, warn, error as logError } from "./lib/logger.js";

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

    default:
      return null; // unknown tool
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

    case "ping":
      sendResult(id, {});
      break;

    default:
      if (id !== undefined) {
        sendError(id, -32601, "Method not found");
      }
  }
}
