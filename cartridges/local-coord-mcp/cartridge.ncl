# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# local-coord-mcp/cartridge.ncl
#
# Nickel source-of-truth manifest for the local coordination cartridge.
# Generate JSON for MCP bridge: nickel export --format json < cartridge.ncl > cartridge.json

{
  "$schema" = "https://boj.dev/schemas/cartridge/v1.json",
  spdx = "PMPL-1.0-or-later",
  copyright = "Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>",
  name = "local-coord-mcp",
  version = "0.1.0",
  description = "Localhost multi-instance coordination — peer discovery, message passing, and task claiming for parallel AI sessions on the same machine",
  domain = "ai",
  tier = "Ayo",
  protocols = ["MCP", "Agentic"],
  federation = "none",
  bind = {
    address = "127.0.0.1",
    port = 7745,
    loopback_only = true,
  },
  auth = {
    method = "session-token",
    env_var | optional = null,
    credential_source | optional = null,
    description = "Per-instance session token issued on coord_register. All subsequent calls require this token.",
  },
  api = {
    base_url = "local://local-coord-mcp",
    content_type = "application/json",
  },
  tools = [
    {
      name = "coord_register",
      description = "Register this instance as a coordination peer. Returns a hybrid peer ID (e.g. claude-7f3a) and a session token for all subsequent calls.",
      inputSchema = {
        type = "object",
        properties = {
          client_kind = {
            type = "string",
            description = "Client type: claude, gemini, copilot, or custom",
            enum = ["claude", "gemini", "copilot", "custom"],
          },
        },
        required = ["client_kind"],
      },
    },
    {
      name = "coord_list_peers",
      description = "List all active coordination peers on this machine. Returns peer IDs, client kinds, and states.",
      inputSchema = {
        type = "object",
        properties = {
          token = {
            type = "string",
            description = "Session token from coord_register",
          },
        },
        required = ["token"],
      },
    },
    {
      name = "coord_send",
      description = "Send a message to a specific peer (by peer ID) or broadcast to all peers (target '*'). Messages are queued in recipient inboxes.",
      inputSchema = {
        type = "object",
        properties = {
          token = {
            type = "string",
            description = "Session token from coord_register",
          },
          target = {
            type = "string",
            description = "Peer ID to send to, or '*' for broadcast",
          },
          message = {
            type = "string",
            description = "Message content",
          },
        },
        required = ["token", "target", "message"],
      },
    },
    {
      name = "coord_receive",
      description = "Receive the next message from this peer's inbox. Returns the message content, or empty if no messages pending.",
      inputSchema = {
        type = "object",
        properties = {
          token = {
            type = "string",
            description = "Session token from coord_register",
          },
        },
        required = ["token"],
      },
    },
    {
      name = "coord_claim_task",
      description = "Attempt to claim a task (mutex-style). If the task is unclaimed, this peer becomes the holder. If another peer holds it, the claim is denied. Idempotent if already held by caller.",
      inputSchema = {
        type = "object",
        properties = {
          token = {
            type = "string",
            description = "Session token from coord_register",
          },
          task = {
            type = "string",
            description = "Task identifier to claim (e.g. 'audit-boj-server')",
          },
        },
        required = ["token", "task"],
      },
    },
    {
      name = "coord_status",
      description = "Set or broadcast this peer's current work status. Other peers can see it via coord_list_peers.",
      inputSchema = {
        type = "object",
        properties = {
          token = {
            type = "string",
            description = "Session token from coord_register",
          },
          status = {
            type = "string",
            description = "Current work status description",
          },
        },
        required = ["token", "status"],
      },
    },
  ],
}
