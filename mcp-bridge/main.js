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
const SERVER_VERSION = "0.2.0";

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

async function fetchMenu() {
  try {
    const res = await fetch(`${BOJ_BASE}/menu`);
    return await res.json();
  } catch {
    return null;
  }
}

async function fetchHealth() {
  try {
    const res = await fetch(`${BOJ_BASE}/health`);
    return await res.json();
  } catch {
    return { status: "unreachable" };
  }
}

async function fetchCartridges() {
  try {
    const res = await fetch(`${BOJ_BASE}/cartridges`);
    return await res.json();
  } catch {
    return null;
  }
}

async function invokeCartridge(name, params) {
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${name}/invoke`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params || {}),
    });
    return await res.json();
  } catch (err) {
    return { error: err.message };
  }
}

async function fetchCartridgeInfo(name) {
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${name}`);
    return await res.json();
  } catch {
    return null;
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
