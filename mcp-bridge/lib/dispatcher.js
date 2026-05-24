// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP JSON-RPC dispatch (transport-agnostic)
//
// Shared dispatch core consumed by both stdio (main.js) and HTTP
// (http-transport.js) transports. Returns a JSON-RPC response object
// or null for notifications. Does not touch stdout / sockets.

import { env } from "./runtime.js";
import {
  RATE_LIMIT,
  isInputSizeOk,
  isValidToolName,
  rateLimitAllow,
  sanitizeErrorMessage,
  scanObjectForInjection,
  validateRequiredStrings,
} from "./security.js";
import {
  fetchCartridgeInfo,
  fetchCartridges,
  fetchHealth,
  fetchMenu,
  handleGitHubTool,
  handleGitLabTool,
  invokeCartridge,
} from "./api-clients.js";
import { buildToolList } from "./tools.js";
import { listResources, readResource } from "./resources.js";
import { listPrompts, getPrompt } from "./prompts.js";
import {
  initValidator,
  tryParseEnvelope,
  validateEnvelope,
} from "./nickel-validator.js";
import * as pathClaims from "./path-claims.js";
import { info, warn, error as logError, setLevel as setLogLevel } from "./logger.js";
import * as otel from "./otel.js";

const SERVER_NAME = "boj-server";
const SERVER_VERSION = "0.4.7";

const LOCAL_COORD_URL = env.get("COORD_BACKEND_URL") ?? "http://127.0.0.1:7745";
const ENVELOPE_CARRYING_TOOLS = new Set(["coord_send", "coord_send_gated"]);

initValidator();

function result(id, value) {
  return { jsonrpc: "2.0", id, result: value };
}

function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message: sanitizeErrorMessage(message) } };
}

function hardeningGate(toolName, args) {
  if (!rateLimitAllow()) {
    return { code: -32000, message: "Rate limit exceeded. Max " + RATE_LIMIT + " tool calls per minute." };
  }
  if (!isValidToolName(toolName)) {
    return { code: -32602, message: "Invalid tool name" };
  }
  if (!isInputSizeOk(args)) {
    return { code: -32600, message: "Tool arguments exceed maximum size (1 MB)" };
  }
  const injectionLevel = scanObjectForInjection(args);
  if (injectionLevel === "critical" || injectionLevel === "high") {
    logError("Injection blocked", { tool: toolName, confidence: injectionLevel });
    return { code: -32600, message: "Request rejected: suspicious content detected" };
  }
  if (injectionLevel === "medium") {
    warn("Injection warning", { tool: toolName, confidence: injectionLevel });
  }

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
  } else if (toolName.startsWith("boj_cloud_") || toolName.startsWith("boj_comms_") || toolName === "boj_ml_huggingface" || toolName === "boj_research" || toolName === "boj_codeseeker" || toolName === "boj_search") {
    validationError = validateRequiredStrings(args, ["operation"]);
  } else if (toolName === "boj_browser_tabs") {
    validationError = validateRequiredStrings(args, ["operation"]);
  }

  if (validationError) {
    return { code: -32602, message: validationError };
  }
  return null;
}

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

    case "boj_search":
      return invokeCartridge("search-mcp", args);

    case "coord_register":
    case "coord_list_peers":
    case "coord_send":
    case "coord_receive":
    case "coord_claim_task":
    case "coord_status":
    case "coord_promote_to_master":
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
    case "coord_set_variant":
    case "coord_set_capabilities":
    case "coord_get_peer_capabilities":
    case "coord_health":
    case "coord_progress":
    case "coord_sweep_watchdog":
      return dispatchLocalCoord(toolName, args);

    default:
      return null;
  }
}

async function dispatchLocalCoord(toolName, args) {
  if (ENVELOPE_CARRYING_TOOLS.has(toolName) && args && typeof args.message === "string") {
    const envelope = tryParseEnvelope(args.message);
    if (envelope && typeof envelope === "object") {
      const senderRole = envelope._meta?.sender_role || args.sender_role;
      const r = validateEnvelope(envelope, senderRole);
      if (!r.ok) {
        return {
          success: false,
          error: `envelope validation failed: ${r.error}`,
          hint: "See cartridges/local-coord-mcp/schemas/coord-messages-contracts.ncl for the active contracts",
        };
      }
    }
  }

  const { forwarded, ctx } = pathClaimsBefore(toolName, args);

  try {
    const res = await fetch(`${LOCAL_COORD_URL}/tools/${toolName}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(forwarded),
    });
    let data;
    try {
      data = await res.json();
    } catch {
      return { success: false, error: "local-coord-mcp backend returned non-JSON" };
    }
    return pathClaimsAfter(toolName, args, data, ctx);
  } catch (e) {
    return {
      success: false,
      error: `local-coord-mcp backend unavailable at ${LOCAL_COORD_URL}: ${e.message}`,
      hint: "Start the adapter: cd cartridges/local-coord-mcp/adapter && zig build run",
    };
  }
}

// Path-claims live entirely at the bridge layer. The verified backend
// has no `paths` field on coord_claim_task, so we strip it before
// forwarding and stash it for the post-response annotate step.
function pathClaimsBefore(toolName, args) {
  const a = args || {};
  if (toolName === "coord_claim_task" && Array.isArray(a.paths)) {
    const { paths, ...rest } = a;
    return { forwarded: rest, ctx: { declaredPaths: paths } };
  }
  return { forwarded: a, ctx: {} };
}

function pathClaimsAfter(toolName, args, data, ctx) {
  if (!data || typeof data !== "object") return data;
  const task = args?.task;
  switch (toolName) {
    case "coord_claim_task": {
      if (!ctx.declaredPaths || !task || data.success === false) return data;
      const { paths, overlaps } = pathClaims.register({
        task,
        holder: data.holder || "(unknown)",
        paths: ctx.declaredPaths,
        ttl_s: typeof data.ttl_s === "number" ? data.ttl_s : undefined,
      });
      return { ...data, declared_paths: paths, path_overlap: overlaps };
    }
    case "coord_progress":
      if (task) pathClaims.refresh(task, data.ttl_s);
      return data;
    case "coord_report_outcome":
      if (task) pathClaims.release(task);
      return data;
    default:
      return data;
  }
}

/**
 * Dispatch a parsed JSON-RPC message. Returns a response object or
 * null for notifications. Transport-agnostic — the caller is responsible
 * for delivery (stdout write, HTTP body, SSE event, etc.).
 *
 * @param {object} msg parsed JSON-RPC message
 * @param {object} [ctx] optional context — { transport: "stdio"|"http", sessionId }
 * @returns {Promise<object|null>}
 */
export async function dispatchMcpMessage(msg, ctx = {}) {
  const { id, method, params } = msg;

  switch (method) {
    case "initialize": {
      info("MCP initialize", { client: params?.clientInfo?.name, transport: ctx.transport ?? "stdio" });
      return result(id, {
        protocolVersion: "2024-11-05",
        capabilities: {
          tools: { listChanged: true },
          resources: { subscribe: false },
          prompts: { listChanged: false },
          logging: { levels: ["debug", "info", "warn", "error"] },
        },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
    }

    case "notifications/initialized":
      return null;

    case "logging/setLevel": {
      const level = params?.level;
      const applied = setLogLevel(level);
      if (!applied) {
        return rpcError(id, -32602, `Unknown log level: ${level}. Expected debug|info|warn|error|silent.`);
      }
      info("MCP logging/setLevel", { level });
      return result(id, {});
    }

    case "tools/list":
      return result(id, { tools: buildToolList() });

    case "resources/list":
      return result(id, { resources: listResources() });

    case "resources/read": {
      const uri = params?.uri;
      if (typeof uri !== "string" || !uri.startsWith("boj://")) {
        return rpcError(id, -32602, "resources/read requires a boj:// URI");
      }
      try {
        const r = await readResource(uri);
        if (r === null) return rpcError(id, -32602, `Unknown resource: ${uri}`);
        return result(id, r);
      } catch (e) {
        return rpcError(id, -32603, e?.message ?? String(e));
      }
    }

    case "prompts/list":
      return result(id, { prompts: listPrompts() });

    case "prompts/get": {
      const name = params?.name;
      const args = params?.arguments ?? {};
      if (typeof name !== "string" || name.length === 0) {
        return rpcError(id, -32602, "prompts/get requires a 'name'");
      }
      const { result: promptResult, error: promptError } = getPrompt(name, args);
      if (promptError) return rpcError(id, promptError.code, promptError.message);
      return result(id, promptResult);
    }

    case "tools/call": {
      const toolName = params?.name;
      const args = params?.arguments || {};
      const span = otel.startSpan("mcp.tools.call", {
        "mcp.tool.name": toolName,
        "mcp.tool.arg_count": Object.keys(args).length,
        "mcp.transport": ctx.transport ?? "stdio",
      });
      const rejection = hardeningGate(toolName, args);
      if (rejection) {
        otel.endSpan(span, {
          status: "error",
          error: "gate_rejected",
          attributes: { "mcp.rejection.code": rejection.code },
        });
        return rpcError(id, rejection.code, rejection.message);
      }
      try {
        const toolResult = await dispatchTool(toolName, args);
        if (toolResult === null) {
          otel.endSpan(span, { status: "error", error: "unknown_tool" });
          return rpcError(id, -32601, "Unknown tool");
        }
        otel.endSpan(span, { status: "ok" });
        return result(id, {
          content: [{ type: "text", text: JSON.stringify(toolResult, null, 2) }],
        });
      } catch (e) {
        otel.endSpan(span, {
          status: "error",
          error: sanitizeErrorMessage(e?.message ?? String(e)),
        });
        return rpcError(id, -32603, e?.message ?? String(e));
      }
    }

    case "ping":
      return result(id, {});

    default:
      if (id !== undefined) return rpcError(id, -32601, "Method not found");
      return null;
  }
}
