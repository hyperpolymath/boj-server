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

const BOJ_BASE = process.env.BOJ_URL || "http://localhost:7700";
const SERVER_NAME = "boj-server";
const SERVER_VERSION = "0.3.1";

// ===================================================================
// HARDENING: Prompt injection detection
// Ported from proven/src/Proven/SafeMCP.idr — patterns and confidence
// levels match the formally verified Idris2 implementation exactly.
// ===================================================================

// Injection patterns from SafeMCP.idr injectionPatterns list.
// All comparisons are case-insensitive (toLower before matching).
const INJECTION_PATTERNS = [
  // Role/instruction override attempts
  "ignore previous instructions",
  "ignore all previous",
  "disregard your instructions",
  "forget your instructions",
  "new instructions:",
  "system prompt:",
  "you are now",
  "act as if",
  "pretend you are",
  "override your",
  "bypass your",
  "ignore your safety",
  "jailbreak",
  // Markup-based injection (XML tags, chat template tokens)
  "<system>",
  "</system>",
  "[INST]",
  "[/INST]",
  "<<SYS>>",
  "<</SYS>>",
  "### Instruction:",
  "### Human:",
  "### Assistant:",
  // Additional high-risk patterns (from task spec, not in SafeMCP.idr
  // but consistent with its design philosophy)
  "```system",
  "new role:",
  "act as",
  "DAN mode",
  "developer mode",
  "base64:",
  "eval(",
  "exec(",
];

/**
 * Analyze a string for prompt injection attempts.
 * Returns a confidence level matching SafeMCP.idr analyzeInjection:
 *   "none" | "low" | "medium" | "high" | "critical"
 *
 * Mirrors the Idris2 logic:
 *   - patternCount >= 3 OR (hasXmlTags AND patternCount >= 1) => Critical
 *   - patternCount >= 2 OR hasRoleSwitch => High
 *   - patternCount >= 1 => Medium
 *   - hasXmlTags alone => Low
 *   - otherwise => None
 */
function analyzeInjection(s) {
  if (typeof s !== "string") return "none";
  const lower = s.toLowerCase();
  const matchedCount = INJECTION_PATTERNS.filter(
    (pat) => lower.includes(pat.toLowerCase())
  ).length;
  const hasXmlTags =
    lower.includes("<system>") || lower.includes("</system>");
  const hasRoleSwitch =
    lower.includes("### human:") || lower.includes("### assistant:");

  if (matchedCount >= 3 || (hasXmlTags && matchedCount >= 1)) return "critical";
  if (matchedCount >= 2 || hasRoleSwitch) return "high";
  if (matchedCount >= 1) return "medium";
  if (hasXmlTags) return "low";
  return "none";
}

/**
 * Scan all string values in an object tree for injection patterns.
 * Returns the highest confidence level found across all values.
 * This is the equivalent of SafeMCP.idr validateToolParams — checking
 * every parameter value for injection content.
 */
function scanObjectForInjection(obj, maxDepth = 10) {
  if (maxDepth <= 0) return "none";
  let worst = "none";
  const rank = { none: 0, low: 1, medium: 2, high: 3, critical: 4 };

  function visit(val, depth) {
    if (depth <= 0) return;
    if (typeof val === "string") {
      const level = analyzeInjection(val);
      if (rank[level] > rank[worst]) worst = level;
    } else if (Array.isArray(val)) {
      for (const item of val) visit(item, depth - 1);
    } else if (val !== null && typeof val === "object") {
      for (const key of Object.keys(val)) visit(val[key], depth - 1);
    }
  }
  visit(obj, maxDepth);
  return worst;
}

// ===================================================================
// HARDENING: Rate limiter (token bucket)
// Prevents tool call flooding. Default: 60 calls/minute, configurable
// via BOJ_RATE_LIMIT env var. Self-contained, no external deps.
// ===================================================================

const RATE_LIMIT = parseInt(process.env.BOJ_RATE_LIMIT, 10) || 60;
const RATE_WINDOW_MS = 60_000; // 1 minute window

const rateBucket = {
  tokens: RATE_LIMIT,
  lastRefill: Date.now(),
};

/**
 * Token bucket rate limiter. Returns true if the call is allowed,
 * false if the caller should be throttled.
 */
function rateLimitAllow() {
  const now = Date.now();
  const elapsed = now - rateBucket.lastRefill;
  // Refill tokens proportionally to elapsed time
  if (elapsed > 0) {
    const refill = Math.floor((elapsed / RATE_WINDOW_MS) * RATE_LIMIT);
    rateBucket.tokens = Math.min(RATE_LIMIT, rateBucket.tokens + refill);
    rateBucket.lastRefill = now;
  }
  if (rateBucket.tokens > 0) {
    rateBucket.tokens -= 1;
    return true;
  }
  return false;
}

// ===================================================================
// HARDENING: Input size limits
// Reject tool arguments exceeding 1 MB to prevent memory exhaustion.
// Matches SafeMCP.idr maxResultSize (1048576 bytes).
// ===================================================================

const MAX_INPUT_SIZE_BYTES = 1_048_576; // 1 MB

/**
 * Check if the serialized size of tool arguments exceeds the limit.
 * Returns true if within bounds, false if too large.
 */
function isInputSizeOk(args) {
  try {
    // JSON.stringify gives a reasonable byte-size approximation for
    // ASCII-heavy MCP payloads. Exact UTF-8 length would require
    // TextEncoder but this is sufficient for a safety bound.
    const serialized = JSON.stringify(args);
    return serialized.length <= MAX_INPUT_SIZE_BYTES;
  } catch {
    // If args can't be serialized, reject as malformed
    return false;
  }
}

// ===================================================================
// HARDENING: Input validation helpers
// Validate types and required fields for tool call arguments before
// they reach any dispatcher or external API call.
// ===================================================================

/**
 * Validate that required string fields are present and are strings.
 * Returns null if valid, or an error message string if invalid.
 */
function validateRequiredStrings(args, fieldNames) {
  for (const name of fieldNames) {
    if (args[name] === undefined || args[name] === null) {
      return `Missing required field: ${name}`;
    }
    if (typeof args[name] !== "string") {
      return `Field '${name}' must be a string`;
    }
    // Enforce a sane max length per field (64 KB) to catch oversized
    // individual values even when total payload is under 1 MB
    if (args[name].length > 65_536) {
      return `Field '${name}' exceeds maximum length (64 KB)`;
    }
  }
  return null;
}

/**
 * Validate a tool name matches expected MCP tool name format.
 * Mirrors SafeMCP.idr isValidToolName (alphanumeric + underscore + hyphen).
 */
function isValidToolName(name) {
  return (
    typeof name === "string" &&
    name.length > 0 &&
    name.length <= 128 &&
    /^[a-zA-Z0-9_-]+$/.test(name)
  );
}

// ===================================================================
// HARDENING: Error sanitization
// Strip internal paths, stack traces, and environment details from
// error messages returned to MCP clients. Attackers should not learn
// filesystem layout or runtime internals from error responses.
// ===================================================================

/**
 * Sanitize an error message for external consumption.
 * Removes absolute paths, stack traces, and known sensitive patterns.
 */
function sanitizeErrorMessage(message) {
  if (typeof message !== "string") return "Internal error";
  // Remove absolute filesystem paths (Unix and Windows)
  let sanitized = message.replace(/\/[a-zA-Z0-9_./-]{3,}/g, "[path]");
  sanitized = sanitized.replace(/[A-Z]:\\[a-zA-Z0-9_.\\/-]{3,}/g, "[path]");
  // Remove stack trace lines (common Node/Deno format)
  sanitized = sanitized.replace(/\s+at\s+.+\(.+\)/g, "");
  sanitized = sanitized.replace(/\s+at\s+.+:\d+:\d+/g, "");
  // Remove environment variable references
  sanitized = sanitized.replace(/process\.env\.\w+/g, "[env]");
  // Truncate to reasonable length
  if (sanitized.length > 500) {
    sanitized = sanitized.slice(0, 500) + "...";
  }
  return sanitized;
}

// --- JSON-RPC stdio transport ---

let buffer = "";

// HARDENING: Cap the read buffer at 2 MB to prevent memory exhaustion
// from a malicious client sending an unbounded stream without newlines.
const MAX_BUFFER_BYTES = 2 * MAX_INPUT_SIZE_BYTES;

process.stdin.setEncoding("utf8");
// Track in-flight message handlers so we can drain before exit.
const pendingMessages = [];

process.stdin.on("data", (chunk) => {
  buffer += chunk;
  // HARDENING: Drop the buffer if it grows beyond the safety limit
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
      // Queue the async handler and track it so stdin EOF doesn't race.
      const p = handleMessage(line).catch(() => {});
      pendingMessages.push(p);
    }
  }
});

process.stdin.on("end", async () => {
  // Drain all pending message handlers before exiting.
  await Promise.allSettled(pendingMessages);
  process.exit(0);
});

function send(obj) {
  const msg = JSON.stringify(obj);
  process.stdout.write(msg + "\n");
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

// HARDENING: All error messages are sanitized before being sent to the
// MCP client to prevent leaking internal paths or stack traces.
function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message: sanitizeErrorMessage(message) } });
}

// --- Fetch menu from BoJ REST API ---

// Static cartridge manifest for offline/inspection mode
const OFFLINE_MENU = {
  tier_teranga: [
    { name: "database-mcp", version: "0.2.0", domain: "Database", protocols: ["MCP","REST","gRPC"], status: "Available", available: true, backends: ["VeriSimDB (VQL)", "QuandleDB (KQL)", "LithoGlyph (GQL)", "SQLite", "PostgreSQL", "Redis"] },
    { name: "nesy-mcp", version: "0.1.0", domain: "NeSy", protocols: ["NeSy","MCP","REST"], status: "Available", available: true },
    { name: "fleet-mcp", version: "0.1.0", domain: "Fleet", protocols: ["Fleet","MCP","REST"], status: "Available", available: true },
    { name: "agent-mcp", version: "0.1.0", domain: "Cloud", protocols: ["Agentic","MCP","REST","gRPC"], status: "Available", available: true },
    { name: "cloud-mcp", version: "0.1.0", domain: "Cloud", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "container-mcp", version: "0.1.0", domain: "Container", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "k8s-mcp", version: "0.1.0", domain: "Kubernetes", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "git-mcp", version: "0.1.0", domain: "Git/VCS", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "queues-mcp", version: "0.1.0", domain: "Queues", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "iac-mcp", version: "0.1.0", domain: "IaC", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "observe-mcp", version: "0.1.0", domain: "Observability", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "ssg-mcp", version: "0.1.0", domain: "SSG", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "lsp-mcp", version: "0.1.0", domain: "Cloud", protocols: ["LSP","MCP","REST"], status: "Available", available: true },
    { name: "dap-mcp", version: "0.1.0", domain: "Cloud", protocols: ["DAP","MCP","REST"], status: "Available", available: true },
    { name: "bsp-mcp", version: "0.1.0", domain: "Cloud", protocols: ["BSP","MCP","REST"], status: "Available", available: true },
    { name: "feedback-mcp", version: "0.1.0", domain: "Feedback", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "comms-mcp", version: "0.1.0", domain: "Communications", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "ml-mcp", version: "0.1.0", domain: "ML/AI", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "research-mcp", version: "0.1.0", domain: "Research", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "codeseeker-mcp", version: "0.1.0", domain: "Code Intelligence", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "lang-mcp", version: "0.1.0", domain: "Languages", protocols: ["MCP","REST"], status: "Available", available: true, languages: ["eclexia","affinescript","betlang","ephapax","mylang","wokelang","anvomidav","phronesis","error-lang","julia-the-viper","me-dialect","oblibeny"] },
  ],
  tier_shield: [
    { name: "secrets-mcp", version: "0.1.0", domain: "Secrets", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "proof-mcp", version: "0.1.0", domain: "Proof", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_ayo: [],
  summary: { total: 22, ready: 22, mounted: 0 },
};

async function fetchMenu() {
  try {
    const res = await fetch(`${BOJ_BASE}/menu`);
    return await res.json();
  } catch {
    return OFFLINE_MENU;
  }
}

async function fetchHealth() {
  try {
    const res = await fetch(`${BOJ_BASE}/health`);
    return await res.json();
  } catch {
    return { status: "offline", message: "BoJ REST API not reachable. Start the server with: systemctl --user start boj-server" };
  }
}

async function fetchCartridges() {
  try {
    const res = await fetch(`${BOJ_BASE}/cartridges`);
    return await res.json();
  } catch {
    return { note: "Offline mode — cartridge matrix available when BoJ REST API is running", cartridges: Object.keys(OFFLINE_MENU.tier_teranga.concat(OFFLINE_MENU.tier_shield).reduce((acc, c) => { acc[c.name] = c.domain; return acc; }, {})) };
  }
}

function isValidCartridgeName(name) {
  return typeof name === "string" && /^[a-z0-9][a-z0-9-]*$/.test(name) && name.length <= 64;
}

async function invokeCartridge(name, params) {
  if (!isValidCartridgeName(name)) {
    return { error: `Invalid cartridge name: ${name}` };
  }
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${encodeURIComponent(name)}/invoke`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params || {}),
    });
    return await res.json();
  } catch {
    return { error: "BoJ REST API not reachable. Invocation requires a running server.", cartridge: name, hint: "Start with: systemctl --user start boj-server" };
  }
}

async function fetchCartridgeInfo(name) {
  if (!isValidCartridgeName(name)) {
    return { error: `Invalid cartridge name: ${name}` };
  }
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${encodeURIComponent(name)}`);
    return await res.json();
  } catch {
    const all = OFFLINE_MENU.tier_teranga.concat(OFFLINE_MENU.tier_shield);
    const found = all.find(c => c.name === name);
    return found || { error: `Unknown cartridge: ${name}` };
  }
}

// --- Real API passthrough for high-value cartridges ---
// These bypass the BoJ REST API and call services directly when the
// V-lang adapter isn't running. Tokens from environment (temporary)
// or vault-mcp zero-knowledge proxy (production).

const GITHUB_TOKEN = process.env.GITHUB_TOKEN || "";
const GITLAB_TOKEN = process.env.GITLAB_TOKEN || "";

async function githubApiCall(method, path, body) {
  if (!GITHUB_TOKEN) {
    return { error: "GITHUB_TOKEN not set. Store in vault-mcp or export to environment." };
  }
  try {
    const url = `https://api.github.com${path}`;
    const opts = {
      method,
      headers: {
        "Authorization": `Bearer ${GITHUB_TOKEN}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "boj-server/0.3.0",
      },
    };
    if (body && method !== "GET") {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(url, opts);
    const data = await res.json();
    const rateLimit = {
      remaining: res.headers.get("x-ratelimit-remaining"),
      reset: res.headers.get("x-ratelimit-reset"),
      limit: res.headers.get("x-ratelimit-limit"),
    };
    return { status: res.status, data, rateLimit };
  } catch (err) {
    return { error: `GitHub API error: ${err.message}` };
  }
}

async function githubGraphQL(query, variables) {
  if (!GITHUB_TOKEN) {
    return { error: "GITHUB_TOKEN not set." };
  }
  try {
    const res = await fetch("https://api.github.com/graphql", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${GITHUB_TOKEN}`,
        "Content-Type": "application/json",
        "User-Agent": "boj-server/0.3.0",
      },
      body: JSON.stringify({ query, variables: variables || {} }),
    });
    return await res.json();
  } catch (err) {
    return { error: `GitHub GraphQL error: ${err.message}` };
  }
}

async function gitlabApiCall(method, path, body) {
  if (!GITLAB_TOKEN) {
    return { error: "GITLAB_TOKEN not set." };
  }
  const baseUrl = process.env.GITLAB_URL || "https://gitlab.com";
  try {
    const url = `${baseUrl}/api/v4${path}`;
    const opts = {
      method,
      headers: {
        "PRIVATE-TOKEN": GITLAB_TOKEN,
        "Accept": "application/json",
        "User-Agent": "boj-server/0.3.0",
      },
    };
    if (body && method !== "GET") {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(url, opts);
    const data = await res.json();
    return { status: res.status, data };
  } catch (err) {
    return { error: `GitLab API error: ${err.message}` };
  }
}

// Route GitHub API tool calls to real API
async function handleGitHubTool(toolName, args) {
  switch (toolName) {
    case "boj_github_list_repos":
      return githubApiCall("GET", `/user/repos?per_page=${args.per_page || 30}&sort=${args.sort || "updated"}`);
    case "boj_github_get_repo":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}`);
    case "boj_github_create_issue":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/issues`, { title: args.title, body: args.body, labels: args.labels });
    case "boj_github_list_issues":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/issues?state=${args.state || "open"}&per_page=${args.per_page || 30}`);
    case "boj_github_get_issue":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/issues/${args.issue_number}`);
    case "boj_github_comment_issue":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/issues/${args.issue_number}/comments`, { body: args.body });
    case "boj_github_create_pr":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/pulls`, { title: args.title, body: args.body, head: args.head, base: args.base || "main" });
    case "boj_github_list_prs":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/pulls?state=${args.state || "open"}`);
    case "boj_github_get_pr":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/pulls/${args.pull_number}`);
    case "boj_github_merge_pr":
      return githubApiCall("PUT", `/repos/${args.owner}/${args.repo}/pulls/${args.pull_number}/merge`, { merge_method: args.method || "merge" });
    case "boj_github_search_code":
      return githubApiCall("GET", `/search/code?q=${encodeURIComponent(args.query)}`);
    case "boj_github_search_issues":
      return githubApiCall("GET", `/search/issues?q=${encodeURIComponent(args.query)}`);
    case "boj_github_get_file":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/contents/${args.path}?ref=${args.ref || "main"}`);
    case "boj_github_graphql":
      return githubGraphQL(args.query, args.variables);
    default:
      return { error: `Unknown GitHub tool: ${toolName}` };
  }
}

// Route GitLab API tool calls to real API
async function handleGitLabTool(toolName, args) {
  switch (toolName) {
    case "boj_gitlab_list_projects":
      return gitlabApiCall("GET", `/projects?owned=true&per_page=${args.per_page || 20}`);
    case "boj_gitlab_get_project":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}`);
    case "boj_gitlab_create_issue":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/issues`, { title: args.title, description: args.description });
    case "boj_gitlab_list_issues":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/issues?state=${args.state || "opened"}`);
    case "boj_gitlab_create_mr":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/merge_requests`, { title: args.title, source_branch: args.source, target_branch: args.target || "main" });
    case "boj_gitlab_list_mrs":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/merge_requests?state=${args.state || "opened"}`);
    case "boj_gitlab_list_pipelines":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/pipelines`);
    case "boj_gitlab_setup_mirror":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/remote_mirrors`, { url: args.target_url, enabled: true });
    default:
      return { error: `Unknown GitLab tool: ${toolName}` };
  }
}

// --- Build MCP tool list from BoJ cartridges ---

function cartridgeToTools(cartridges) {
  const tools = [];

  // Core server tools
  tools.push({
    name: "boj_health",
    description: "Check BoJ server health status",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_menu",
    description:
      "List all BoJ cartridges with their domains, protocols, tiers, and availability",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_cartridges",
    description:
      "Show the BoJ cartridge matrix — protocol x domain grid showing which cartridges serve which protocol/domain combinations",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_cartridge_info",
    description: "Get detailed information about a specific BoJ cartridge",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description:
            "Cartridge name (e.g. database-mcp, container-mcp, git-mcp)",
        },
      },
      required: ["name"],
    },
  });

  tools.push({
    name: "boj_cartridge_invoke",
    description:
      "Invoke a BoJ cartridge operation. Send a command to a specific cartridge for execution.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Cartridge name (e.g. database-mcp, git-mcp)",
        },
        params: {
          type: "object",
          description: "Parameters to pass to the cartridge invocation",
        },
      },
      required: ["name"],
    },
  });

  // Cloud providers
  tools.push({
    name: "boj_cloud_verpex",
    description: "Manage Verpex hosting via cPanel UAPI — domains, DNS, email, databases, SSL, cron, metrics",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-domains", "dns-list", "dns-add", "dns-remove", "email-list", "email-create", "databases-list", "database-create", "ssl-status", "cron-list", "metrics"], description: "The Verpex operation to perform" },
        hostname: { type: "string", description: "cPanel hostname (for authenticate)" },
        username: { type: "string", description: "cPanel username (for authenticate)" },
        api_token: { type: "string", description: "cPanel API token (for authenticate)" },
        domain: { type: "string", description: "Domain name (for DNS, SSL operations)" },
        params: { type: "object", description: "Additional operation parameters" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_cloud_cloudflare",
    description: "Manage Cloudflare resources — Workers, D1 databases, KV namespaces, R2 buckets, DNS zones/records",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-workers", "get-worker", "list-d1", "query-d1", "list-kv", "kv-get", "kv-put", "list-r2", "list-dns-zones", "list-dns-records", "add-dns-record"], description: "The Cloudflare operation" },
        api_token: { type: "string", description: "Cloudflare API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_cloud_vercel",
    description: "Manage Vercel projects — deployments, domains, environment variables, logs, serverless functions",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-projects", "get-project", "list-deployments", "get-deployment", "list-domains", "list-env-vars", "deployment-logs", "list-functions"], description: "The Vercel operation" },
        api_token: { type: "string", description: "Vercel API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  // Communications
  tools.push({
    name: "boj_comms_gmail",
    description: "Gmail operations — send, read, search emails, manage labels",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "send", "read", "search", "labels"], description: "Gmail operation" },
        oauth_token: { type: "string", description: "OAuth2 token (for authenticate)" },
        params: { type: "object", description: "Operation parameters (to, subject, body for send; query for search; message_id for read)" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_comms_calendar",
    description: "Google Calendar operations — list events, create events, check availability",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-events", "create-event", "free-busy"], description: "Calendar operation" },
        oauth_token: { type: "string", description: "OAuth2 token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  // ML/AI
  tools.push({
    name: "boj_ml_huggingface",
    description: "Hugging Face operations — search models, model info, inference, spaces, datasets",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-models", "model-info", "inference", "list-spaces", "list-datasets"], description: "HuggingFace operation" },
        api_token: { type: "string", description: "HF API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters (query for search, model_id for info/inference)" },
      },
      required: ["operation"],
    },
  });

  // Browser automation (Firefox via Marionette)
  tools.push({
    name: "boj_browser_navigate",
    description: "Navigate Firefox to a URL",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to navigate to" },
      },
      required: ["url"],
    },
  });

  tools.push({
    name: "boj_browser_click",
    description: "Click an element on the page by CSS selector",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector of the element to click" },
      },
      required: ["selector"],
    },
  });

  tools.push({
    name: "boj_browser_type",
    description: "Type text into an element on the page",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector of the input element" },
        text: { type: "string", description: "Text to type" },
      },
      required: ["selector", "text"],
    },
  });

  tools.push({
    name: "boj_browser_read_page",
    description: "Read the text content of the current page",
    inputSchema: {
      type: "object",
      properties: {},
    },
  });

  tools.push({
    name: "boj_browser_screenshot",
    description: "Take a screenshot of the current page",
    inputSchema: {
      type: "object",
      properties: {},
    },
  });

  tools.push({
    name: "boj_browser_tabs",
    description: "List, create, or close browser tabs",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["list", "create", "close"], description: "Tab operation" },
        url: { type: "string", description: "URL for new tab (create only)" },
        tab_id: { type: "number", description: "Tab ID (close only)" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_browser_execute_js",
    description: "Execute JavaScript in the current page context",
    inputSchema: {
      type: "object",
      properties: {
        script: { type: "string", description: "JavaScript code to execute" },
      },
      required: ["script"],
    },
  });

  // GitHub API (real passthrough)
  const ghTools = [
    { name: "boj_github_list_repos", desc: "List your GitHub repositories", props: { per_page: { type: "number" }, sort: { type: "string", enum: ["updated", "created", "pushed", "full_name"] } } },
    { name: "boj_github_get_repo", desc: "Get a GitHub repository", props: { owner: { type: "string" }, repo: { type: "string" } }, req: ["owner", "repo"] },
    { name: "boj_github_create_issue", desc: "Create an issue on a GitHub repo", props: { owner: { type: "string" }, repo: { type: "string" }, title: { type: "string" }, body: { type: "string" }, labels: { type: "array", items: { type: "string" } } }, req: ["owner", "repo", "title"] },
    { name: "boj_github_list_issues", desc: "List issues on a GitHub repo", props: { owner: { type: "string" }, repo: { type: "string" }, state: { type: "string", enum: ["open", "closed", "all"] }, per_page: { type: "number" } }, req: ["owner", "repo"] },
    { name: "boj_github_get_issue", desc: "Get a specific issue", props: { owner: { type: "string" }, repo: { type: "string" }, issue_number: { type: "number" } }, req: ["owner", "repo", "issue_number"] },
    { name: "boj_github_comment_issue", desc: "Comment on an issue", props: { owner: { type: "string" }, repo: { type: "string" }, issue_number: { type: "number" }, body: { type: "string" } }, req: ["owner", "repo", "issue_number", "body"] },
    { name: "boj_github_create_pr", desc: "Create a pull request", props: { owner: { type: "string" }, repo: { type: "string" }, title: { type: "string" }, body: { type: "string" }, head: { type: "string" }, base: { type: "string" } }, req: ["owner", "repo", "title", "head"] },
    { name: "boj_github_list_prs", desc: "List pull requests", props: { owner: { type: "string" }, repo: { type: "string" }, state: { type: "string", enum: ["open", "closed", "all"] } }, req: ["owner", "repo"] },
    { name: "boj_github_get_pr", desc: "Get a specific pull request", props: { owner: { type: "string" }, repo: { type: "string" }, pull_number: { type: "number" } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_merge_pr", desc: "Merge a pull request", props: { owner: { type: "string" }, repo: { type: "string" }, pull_number: { type: "number" }, method: { type: "string", enum: ["merge", "squash", "rebase"] } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_search_code", desc: "Search code on GitHub", props: { query: { type: "string" } }, req: ["query"] },
    { name: "boj_github_search_issues", desc: "Search issues and PRs on GitHub", props: { query: { type: "string" } }, req: ["query"] },
    { name: "boj_github_get_file", desc: "Get file contents from a repo", props: { owner: { type: "string" }, repo: { type: "string" }, path: { type: "string" }, ref: { type: "string" } }, req: ["owner", "repo", "path"] },
    { name: "boj_github_graphql", desc: "Execute a GitHub GraphQL query", props: { query: { type: "string" }, variables: { type: "object" } }, req: ["query"] },
  ];
  for (const t of ghTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [] } });
  }

  // GitLab API (real passthrough)
  const glTools = [
    { name: "boj_gitlab_list_projects", desc: "List your GitLab projects", props: { per_page: { type: "number" } } },
    { name: "boj_gitlab_get_project", desc: "Get a GitLab project", props: { project_id: { type: "string", description: "Project ID or URL-encoded path" } }, req: ["project_id"] },
    { name: "boj_gitlab_create_issue", desc: "Create a GitLab issue", props: { project_id: { type: "string" }, title: { type: "string" }, description: { type: "string" } }, req: ["project_id", "title"] },
    { name: "boj_gitlab_list_issues", desc: "List GitLab project issues", props: { project_id: { type: "string" }, state: { type: "string", enum: ["opened", "closed", "all"] } }, req: ["project_id"] },
    { name: "boj_gitlab_create_mr", desc: "Create a merge request", props: { project_id: { type: "string" }, title: { type: "string" }, source: { type: "string" }, target: { type: "string" } }, req: ["project_id", "title", "source"] },
    { name: "boj_gitlab_list_mrs", desc: "List merge requests", props: { project_id: { type: "string" }, state: { type: "string", enum: ["opened", "closed", "merged", "all"] } }, req: ["project_id"] },
    { name: "boj_gitlab_list_pipelines", desc: "List CI/CD pipelines", props: { project_id: { type: "string" } }, req: ["project_id"] },
    { name: "boj_gitlab_setup_mirror", desc: "Set up a push mirror", props: { project_id: { type: "string" }, target_url: { type: "string" } }, req: ["project_id", "target_url"] },
  ];
  for (const t of glTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [] } });
  }

  // Code Intelligence (CodeSeeker)
  tools.push({
    name: "boj_codeseeker",
    description: "CodeSeeker code intelligence — hybrid search (vector + text + path with RRF), knowledge graph traversal (imports, calls, extends, implements), auto-detected pattern retrieval, and Graph RAG context. All data stored locally in .codeseeker/",
    inputSchema: {
      type: "object",
      properties: {
        operation: {
          type: "string",
          enum: ["index", "search", "traverse", "patterns", "graph-rag", "status", "close"],
          description: "Operation: index (build/refresh index), search (hybrid search), traverse (graph traversal from a symbol), patterns (auto-detected conventions), graph-rag (RAG with graph context), status (session state), close (close session)"
        },
        codebase_path: { type: "string", description: "Absolute path to the codebase to index or query (required for index)" },
        slot: { type: "number", description: "Session slot index returned by the index operation (required for search/traverse/patterns/graph-rag/status/close)" },
        query: { type: "string", description: "Search query or Graph RAG question (required for search and graph-rag)" },
        mode: { type: "string", enum: ["hybrid", "vector", "text", "path"], description: "Search mode (default: hybrid)" },
        symbol: { type: "string", description: "Symbol or file path to traverse from (required for traverse)" },
        relation: { type: "string", enum: ["imports", "calls", "extends", "implements", "uses"], description: "Graph relation type to traverse (required for traverse)" },
        depth: { type: "number", description: "Traversal depth (default: 2)" },
        limit: { type: "number", description: "Maximum number of search results (default: 10)" },
      },
      required: ["operation"],
    },
  });

  // Research
  tools.push({
    name: "boj_research",
    description: "Academic research — search papers, citations, references, authors",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-papers", "paper-details", "citations", "references", "author-search", "author-papers"], description: "Research operation" },
        api_key: { type: "string", description: "API key (for authenticate)" },
        params: { type: "object", description: "Operation parameters (query for search, paper_id for details/citations, author_id for author-papers)" },
      },
      required: ["operation"],
    },
  });

  return tools;
}

// --- MCP message handler ---

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
      sendResult(id, {
        protocolVersion: "2024-11-05",
        capabilities: {
          tools: { listChanged: false },
        },
        serverInfo: {
          name: SERVER_NAME,
          version: SERVER_VERSION,
        },
      });
      break;
    }

    case "notifications/initialized": {
      // Client acknowledgement — no response needed
      break;
    }

    case "tools/list": {
      const tools = cartridgeToTools();
      sendResult(id, { tools });
      break;
    }

    case "tools/call": {
      const toolName = params?.name;
      const args = params?.arguments || {};

      // ==============================================================
      // HARDENING GATE: All five checks run before any tool dispatch.
      // This is the single chokepoint — every tool call passes through.
      // ==============================================================

      // 1. Rate limiting — reject if bucket is empty
      if (!rateLimitAllow()) {
        sendError(id, -32000, "Rate limit exceeded. Max " + RATE_LIMIT + " tool calls per minute.");
        break;
      }

      // 2. Tool name validation — must match SafeMCP.idr isValidToolName
      if (!isValidToolName(toolName)) {
        sendError(id, -32602, "Invalid tool name");
        break;
      }

      // 3. Input size check — reject payloads over 1 MB
      if (!isInputSizeOk(args)) {
        sendError(id, -32600, "Tool arguments exceed maximum size (1 MB)");
        break;
      }

      // 4. Prompt injection detection — scan all string values in args.
      //    Mirrors SafeMCP.idr analyzeInjection confidence levels:
      //    - Critical: reject outright (likely attack)
      //    - High: reject (strong signal of injection)
      //    - Medium: log warning, allow (may be legitimate but suspicious)
      //    - Low/None: allow silently
      const injectionLevel = scanObjectForInjection(args);
      if (injectionLevel === "critical" || injectionLevel === "high") {
        // Log for auditing — include tool name but NOT the args content
        // (which may contain the attack payload itself)
        process.stderr.write(
          `[boj-mcp] INJECTION BLOCKED: tool=${toolName} confidence=${injectionLevel} time=${new Date().toISOString()}\n`
        );
        sendError(id, -32600, "Request rejected: suspicious content detected");
        break;
      }
      if (injectionLevel === "medium") {
        // Log warning but allow — could be legitimate content that
        // happens to contain a pattern (e.g. discussing prompt injection)
        process.stderr.write(
          `[boj-mcp] INJECTION WARNING: tool=${toolName} confidence=${injectionLevel} time=${new Date().toISOString()}\n`
        );
      }

      // 5. Required field validation for tools that take string params.
      //    Catches missing/wrong-type args before they hit API calls
      //    where they'd cause confusing downstream errors.
      {
        let validationError = null;
        if (toolName === "boj_cartridge_info") {
          validationError = validateRequiredStrings(args, ["name"]);
        } else if (toolName === "boj_cartridge_invoke") {
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
          // Most GitHub tools need owner+repo; GraphQL needs query
          if (toolName === "boj_github_graphql") {
            validationError = validateRequiredStrings(args, ["query"]);
          } else if (toolName === "boj_github_search_code" || toolName === "boj_github_search_issues") {
            validationError = validateRequiredStrings(args, ["query"]);
          } else if (toolName !== "boj_github_list_repos") {
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
          sendError(id, -32602, validationError);
          break;
        }
      }

      // ==============================================================
      // END HARDENING GATE — dispatch to tool handlers
      // ==============================================================

      switch (toolName) {
        case "boj_health": {
          const health = await fetchHealth();
          sendResult(id, {
            content: [
              { type: "text", text: JSON.stringify(health, null, 2) },
            ],
          });
          break;
        }
        case "boj_menu": {
          const menu = await fetchMenu();
          sendResult(id, {
            content: [
              { type: "text", text: JSON.stringify(menu, null, 2) },
            ],
          });
          break;
        }
        case "boj_cartridges": {
          const matrix = await fetchCartridges();
          sendResult(id, {
            content: [
              { type: "text", text: JSON.stringify(matrix, null, 2) },
            ],
          });
          break;
        }
        case "boj_cartridge_info": {
          const info = await fetchCartridgeInfo(args.name);
          sendResult(id, {
            content: [
              { type: "text", text: JSON.stringify(info, null, 2) },
            ],
          });
          break;
        }
        case "boj_cartridge_invoke": {
          const result = await invokeCartridge(args.name, args.params);
          sendResult(id, {
            content: [
              { type: "text", text: JSON.stringify(result, null, 2) },
            ],
          });
          break;
        }
        case "boj_cloud_verpex":
        case "boj_cloud_cloudflare":
        case "boj_cloud_vercel": {
          const result = await invokeCartridge("cloud-mcp", { provider: toolName.replace("boj_cloud_", ""), ...args });
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_comms_gmail":
        case "boj_comms_calendar": {
          const result = await invokeCartridge("comms-mcp", { provider: toolName.replace("boj_comms_", ""), ...args });
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_ml_huggingface": {
          const result = await invokeCartridge("ml-mcp", { provider: "huggingface", ...args });
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_browser_navigate":
        case "boj_browser_click":
        case "boj_browser_type":
        case "boj_browser_read_page":
        case "boj_browser_screenshot":
        case "boj_browser_tabs":
        case "boj_browser_execute_js": {
          const action = toolName.replace("boj_browser_", "");
          const result = await invokeCartridge("browser-mcp", { action, ...args });
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
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
        case "boj_github_graphql": {
          const result = await handleGitHubTool(toolName, args);
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_gitlab_list_projects":
        case "boj_gitlab_get_project":
        case "boj_gitlab_create_issue":
        case "boj_gitlab_list_issues":
        case "boj_gitlab_create_mr":
        case "boj_gitlab_list_mrs":
        case "boj_gitlab_list_pipelines":
        case "boj_gitlab_setup_mirror": {
          const result = await handleGitLabTool(toolName, args);
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_codeseeker": {
          const result = await invokeCartridge("codeseeker-mcp", args);
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        case "boj_research": {
          const result = await invokeCartridge("research-mcp", args);
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        default:
          // HARDENING: Don't echo the full tool name back — it was already
          // validated above, but keep the message terse as defence in depth.
          sendError(id, -32601, "Unknown tool");
      }
      break;
    }

    case "ping": {
      sendResult(id, {});
      break;
    }

    default: {
      if (id !== undefined) {
        // HARDENING: Don't echo the method name verbatim to avoid
        // reflecting attacker-controlled content in responses.
        sendError(id, -32601, "Method not found");
      }
    }
  }
}
