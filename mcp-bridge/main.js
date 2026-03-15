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
const SERVER_VERSION = "0.3.0";

// --- JSON-RPC stdio transport ---

let buffer = "";

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let boundary;
  while ((boundary = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, boundary).trim();
    buffer = buffer.slice(boundary + 1);
    if (line.length > 0) {
      handleMessage(line);
    }
  }
});

process.stdin.on("end", () => {
  process.exit(0);
});

function send(obj) {
  const msg = JSON.stringify(obj);
  process.stdout.write(msg + "\n");
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
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
    { name: "lang-mcp", version: "0.1.0", domain: "Languages", protocols: ["MCP","REST"], status: "Available", available: true, languages: ["eclexia","affinescript","betlang","ephapax","mylang","wokelang","anvomidav","phronesis","error-lang","julia-the-viper","me-dialect","oblibeny"] },
  ],
  tier_shield: [
    { name: "secrets-mcp", version: "0.1.0", domain: "Secrets", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "proof-mcp", version: "0.1.0", domain: "Proof", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_ayo: [],
  summary: { total: 21, ready: 21, mounted: 0 },
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
        case "boj_research": {
          const result = await invokeCartridge("research-mcp", args);
          sendResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
          break;
        }
        default:
          sendError(id, -32601, `Unknown tool: ${toolName}`);
      }
      break;
    }

    case "ping": {
      sendResult(id, {});
      break;
    }

    default: {
      if (id !== undefined) {
        sendError(id, -32601, `Method not found: ${method}`);
      }
    }
  }
}
