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
  version = "0.3.0",
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
      description = "Register this instance as a coordination peer. Returns a peer ID and a session token for all subsequent calls. Optional `context` (alphanumeric + hyphen/underscore, max 32 bytes) disambiguates multiple windows of the same client_kind — peer_id becomes <kind>-<4hex>@<context>.",
      inputSchema = {
        type = "object",
        properties = {
          client_kind = {
            type = "string",
            description = "Client type: claude, gemini, copilot, or custom",
            enum = ["claude", "gemini", "copilot", "custom"],
          },
          context = {
            type = "string",
            description = "Optional per-window disambiguator (repo name, tty label). Alphanumeric/hyphen/underscore only, max 32 chars.",
          },
          role = {
            type = "string",
            description = "Optional requested role (DD-32). master is ALWAYS rejected here — promote via coord_promote_to_master. Default derived from client_kind (claude->journeyman, others->apprentice). Old names (executor, supervised) accepted as aliases for one release.",
            enum = ["journeyman", "apprentice", "executor", "supervised"],
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
    # ── Supervision tools ─────────────────────────────────────────
    {
      name = "coord_promote_to_master",
      description = "Promote this peer to the master role (DD-32, renamed from supervisor). Requires the BOJ_MASTER_TOKEN env-var to be set on the server and the presented secret to match. Old BOJ_SUPERVISOR_TOKEN is read as fallback for one release. At most one master at a time. Intended for the Opus-tier Claude that holds the veto. The old tool name `coord_promote_to_supervisor` is accepted as an alias.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Own session token from coord_register" },
          secret = { type = "string", description = "Must match BOJ_SUPERVISOR_TOKEN env var on the server" },
        },
        required = ["token", "secret"],
      },
    },
    {
      name = "coord_send_gated",
      description = "Send a message with a declared risk_tier. Tier 2+ from role=apprentice peers is quarantined for master review; everything else delivers directly. Returns status:quarantined + request_id when gated.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Session token from coord_register" },
          target = { type = "string", description = "Peer ID to send to, or '*' for broadcast" },
          message = { type = "string", description = "Message content (typically an A2ML envelope per schemas/coord-messages.ncl)" },
          risk_tier = { type = "integer", minimum = 0, maximum = 4, description = "Declared risk tier 0-4 per the risk ladder" },
        },
        required = ["token", "target", "message", "risk_tier"],
      },
    },
    {
      name = "coord_review",
      description = "List all currently quarantined messages awaiting master decision. Master role only.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Supervisor session token" },
        },
        required = ["token"],
      },
    },
    {
      name = "coord_review_entry",
      description = "Read the full message body of a specific quarantined entry. Supervisor role only.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Supervisor session token" },
          request_id = { type = "integer", description = "Request ID from coord_review or coord_send_gated" },
        },
        required = ["token", "request_id"],
      },
    },
    {
      name = "coord_approve",
      description = "Approve a quarantined message — delivers to target and removes from queue. Supervisor role only.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Supervisor session token" },
          request_id = { type = "integer", description = "Request ID to approve" },
        },
        required = ["token", "request_id"],
      },
    },
    {
      name = "coord_reject",
      description = "Reject a quarantined message with a reason — removes from queue without delivery. Supervisor role only. Reason logged for audit.",
      inputSchema = {
        type = "object",
        properties = {
          token = { type = "string", description = "Supervisor session token" },
          request_id = { type = "integer", description = "Request ID to reject" },
          reason = { type = "string", description = "Reason for rejection (surfaces in audit log)" },
        },
        required = ["token", "request_id", "reason"],
      },
    },
  ],
}
