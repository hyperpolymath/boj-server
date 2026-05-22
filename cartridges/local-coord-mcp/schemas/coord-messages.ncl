# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# coord-messages.ncl — Envelope schema for local-coord-mcp messages (v1).
#
# Source-of-truth for all messages passing through coord_send / coord_receive.
# Nickel source exports to JSON Schema via:
#
#     nickel export --format json schemas/coord-messages.ncl > schemas/coord-messages.json
#
# Design rationale + ops playbook lives in docs/envelope-design.adoc.
# Supervision architecture lives in the workspace memory file
# project_coord_supervision_architecture.md.

{
  "$schema" = "https://json-schema.org/draft-07/schema#",
  "$id" = "https://boj.dev/schemas/coord-messages/v1.json",
  spdx = "MPL-2.0",
  copyright = "Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>",
  title = "local-coord-mcp message envelope (v1)",
  version = 1,

  # ────────────────────────────────────────────────────────────────────
  # Op-kind taxonomy.
  #
  # Each op_kind declares a default risk tier. The server may auto-promote
  # via sanity gate (e.g. content mentions `git push` → Tier 3 regardless
  # of declared tier). Peers may declare a lower tier ONLY with a
  # tier_override_reason that explains why (e.g. "read-only dry-run").
  #
  # Tier semantics:
  #   0 free           status / query / reads / peer discovery
  #   1 logged         single-file edits (non-critical), tests, lint, fyi
  #   2 light gate     multi-file edits, dep bumps, new files — auto-approve
  #                    after 60s unless master intervenes
  #   3 hard gate      commits, pushes, mirrors, secret-adjacent, schema
  #                    migrations, deletions — master approval, no
  #                    timeout
  #   4 forbidden      force-push, branch delete, public-repo creation,
  #                    license changes, touching always-private repos —
  #                    schema-level reject for role=apprentice
  # ────────────────────────────────────────────────────────────────────

  op_kinds = {
    # Tier 0 — always free
    status           = { tier_default = 0, description = "Peer sets its current work status, visible to others." },
    query            = { tier_default = 0, description = "Ask a peer or the server a read-only question." },
    context_query    = { tier_default = 0, description = "Request big-picture context for Tier 2+ preparation. Returns a context_fetch_id cited by subsequent higher-tier ops." },
    context_reply    = { tier_default = 0, description = "Server or peer responds to a context_query." },
    supervise_req    = { tier_default = 0, description = "Apprentice peer requests authorisation for a gated op; embeds the original envelope." },
    supervise_resp   = { tier_default = 0, description = "Master responds with approve/reject + reason." },
    attest_req       = { tier_default = 0, description = "Server asks a second journeyman for independent attestation on a Tier 2+ op from an apprentice peer (BFT f=1)." },
    attest_resp      = { tier_default = 0, description = "Journeyman responds with attest/reject + reason." },
    fyi              = { tier_default = 1, description = "Log-only progress/observation. Never interrupts the user." },

    # Tier 1 — logged, no gate
    progress         = { tier_default = 1, description = "Task progress update: percent + note." },
    warn_drift       = { tier_default = 1, description = "Peer detected drift from a rule / invariant / expected state." },
    release          = { tier_default = 1, description = "Release a previously-claimed task." },

    # Tier 2 — light gate (60s auto-approve)
    claim            = { tier_default = 2, description = "Claim a task. Mutex-style. Tier escalates to 3 when scope=estate." },
    handoff          = { tier_default = 2, description = "Transfer a task from one peer to another with artefact refs. Tier escalates to 3 when scope=estate." },
    clarify          = { tier_default = 2, description = "Question for the user, batched through master. Only journeyman + master peers may set urgent_direct=true." },

    # Tier 3 — hard gate (master approval required)
    blocker          = { tier_default = 3, description = "Peer cannot proceed without user input. Surfaces inline in master terminal." },

    # op_kinds whose tier is always the envelope's declared risk_tier;
    # used for wrapping arbitrary actions through the supervision system.
    gated_op         = { tier_default = 3, description = "Wrapper for an arbitrary high-risk action awaiting Tier 3 approval." },
  },

  # ────────────────────────────────────────────────────────────────────
  # Core envelope schema.
  # ────────────────────────────────────────────────────────────────────

  envelope = {
    type = "object",
    additionalProperties = false,
    properties = {
      # ── Identity + provenance ─────────────────────────────────────
      version           = { type = "integer", const = 1, description = "Envelope schema version. Rejected if mismatched." },
      msg_id            = { type = "string", pattern = "^[0-9a-f]{12}$", description = "12-char lowercase hex, unique per sender. Sender-generated." },
      prev_msg_hash     = { type = "string", pattern = "^[0-9a-f]{64}$", description = "SHA-256 of sender's previous envelope. First-ever message uses 64 zeros. Chain break = instant reject." },
      correlation_id    = { type = "string", maxLength = 64, description = "Optional. Pairs request/response across turns." },

      # ── Routing ──────────────────────────────────────────────────
      sender            = { type = "string", description = "Peer ID of sender: <kind>-<4hex>[@<context>]." },
      recipient         = { type = "string", description = "Peer ID of recipient, or '*' for broadcast." },
      timestamp         = { type = "string", format = "date-time", description = "ISO 8601 UTC timestamp, sender-generated." },

      # ── Operation ─────────────────────────────────────────────────
      op_kind           = { type = "string", description = "One of the keys in op_kinds." },
      risk_tier         = { type = "integer", minimum = 0, maximum = 4 },
      payload           = { type = "object", description = "Shape determined by op_kind — see payloads.*." },

      # ── Self-assessment (optional for Tier 0/1; recommended Tier 2+) ──
      sender_confidence = { type = "number", minimum = 0.0, maximum = 1.0, description = "Sender's declared confidence in its fit for this op." },
      sender_reasoning  = { type = "string", maxLength = 200, description = "One-sentence justification. Required if sender_confidence present." },

      # ── Adaptive horizon (required for Tier 2+) ───────────────────
      context_fetch_id  = { type = "string", maxLength = 64, description = "ID returned by a prior context_query. REQUIRED for Tier 2+ — server rejects without. Caps staleness (N minutes)." },

      # ── Byzantine tolerance ──────────────────────────────────────
      attestation_refs  = {
        type = "array",
        description = "Cosigner attestations. REQUIRED for Tier 2+ envelopes from role=apprentice peers. Empty otherwise.",
        maxItems = 8,
        items = {
          type = "object",
          additionalProperties = false,
          properties = {
            attester       = { type = "string", description = "Peer ID of attester." },
            decision       = { type = "string", enum = ["attest", "reject"] },
            reason         = { type = "string", maxLength = 200 },
            token_mac      = { type = "string", pattern = "^[0-9a-f]{64}$", description = "HMAC-SHA256(attester_token, envelope_sans_attestations). Proves attester signed this specific content." },
          },
          required = ["attester", "decision", "reason", "token_mac"],
        },
      },

      tier_override_reason = { type = "string", maxLength = 200, description = "Required when declared risk_tier differs from op_kinds.<op>.tier_default. Sanity gate may reject. Server records." },

      # ── Dispatch hints (Tasks #15, #36) ───────────────────────────
      dispatch_preference = { type = "string", enum = ["deliberate", "broadcast", "auto"], description = "Routing hint (DD-30). 'auto' lets the server derive from task_difficulty." },
      task_difficulty     = { type = "string", enum = ["trivial", "routine", "challenging", "novel"], description = "Difficulty level (DD-30). Drives default dispatch_preference." },
      difficulty_hint     = { type = "string", enum = ["low", "medium", "high"], description = "Task #36 — how hard to get right, orthogonal to risk_tier (how bad if wrong). Drives model-class routing (DD-36)." },

      # ── User-interaction flags ────────────────────────────────────
      urgent_direct     = { type = "boolean", default = false, description = "Requests inline interrupt in master terminal. Only role ∈ {master, journeyman} may set true — schema rejects for apprentice." },
      ack_required      = { type = "boolean", default = false },
      ttl_seconds       = { type = "integer", minimum = 1, maximum = 86400, description = "Optional auto-expiry. Default = unlimited." },
    },
    required = ["version", "msg_id", "prev_msg_hash", "sender", "recipient", "timestamp", "op_kind", "risk_tier", "payload"],
  },

  # ────────────────────────────────────────────────────────────────────
  # Per-op-kind payload schemas. Server dispatches by op_kind and validates
  # payload against the matching schema here.
  # ────────────────────────────────────────────────────────────────────

  payloads = {
    status = {
      type = "object",
      additionalProperties = false,
      properties = { status = { type = "string", maxLength = 256 } },
      required = ["status"],
    },

    query = {
      type = "object",
      additionalProperties = false,
      properties = {
        question     = { type = "string", maxLength = 1024 },
        response_to  = { type = "string", description = "Optional msg_id being replied to." },
      },
      required = ["question"],
    },

    context_query = {
      type = "object",
      additionalProperties = false,
      properties = {
        scope_repo      = { type = "string", description = "Repo name. Optional." },
        scope_files     = { type = "array", items = { type = "string" }, description = "Specific files. Optional." },
        scope_peers     = { type = "string", enum = ["self", "claiming", "all"] },
        scope_queue     = { type = "boolean", description = "Include task-queue snapshot." },
        summarise_for   = { type = "string", enum = ["apprentice", "journeyman", "master", "supervised", "executor", "supervisor"], description = "Determines summary depth. Apprentice (ex-supervised) gets summary; journeyman/master (ex-executor/supervisor) get raw on request. Old names accepted as aliases per DD-32." },
      },
      required = [],
    },

    context_reply = {
      type = "object",
      additionalProperties = false,
      properties = {
        context_fetch_id = { type = "string", description = "ID the requester cites in later Tier 2+ envelopes." },
        ttl_seconds      = { type = "integer", description = "Staleness budget." },
        summary          = { type = "string", maxLength = 8192 },
        raw              = { type = "object", description = "Full structured context, only for journeyman/master." },
      },
      required = ["context_fetch_id", "ttl_seconds", "summary"],
    },

    progress = {
      type = "object",
      additionalProperties = false,
      properties = {
        task    = { type = "string", maxLength = 128 },
        percent = { type = "integer", minimum = 0, maximum = 100 },
        note    = { type = "string", maxLength = 512 },
      },
      required = ["task", "percent"],
    },

    warn_drift = {
      type = "object",
      additionalProperties = false,
      properties = {
        detected = { type = "string", maxLength = 512 },
        severity = { type = "string", enum = ["low", "med", "high"] },
        evidence = { type = "array", items = { type = "string" }, maxItems = 8 },
      },
      required = ["detected", "severity"],
    },

    claim = {
      type = "object",
      additionalProperties = false,
      properties = {
        task       = { type = "string", maxLength = 128 },
        task_tags  = { type = "array", items = { type = "string", maxLength = 32 }, maxItems = 8, description = "Affinity-routing tags. Server uses to score this claim against peer affinities." },
        scope      = { type = "string", enum = ["local", "repo", "estate"] },
      },
      required = ["task", "scope"],
    },

    release = {
      type = "object",
      additionalProperties = false,
      properties = {
        task    = { type = "string", maxLength = 128 },
        outcome = { type = "string", enum = ["success", "fail", "abandoned"] },
        note    = { type = "string", maxLength = 512 },
      },
      required = ["task", "outcome"],
    },

    handoff = {
      type = "object",
      additionalProperties = false,
      properties = {
        task           = { type = "string", maxLength = 128 },
        to             = { type = "string", description = "Recipient peer_id." },
        artefact_refs  = { type = "array", items = { type = "string" }, maxItems = 32 },
        scope          = { type = "string", enum = ["local", "repo", "estate"] },
      },
      required = ["task", "to", "scope"],
    },

    supervise_req = {
      type = "object",
      additionalProperties = false,
      properties = {
        original_msg       = { "$ref" = "#/envelope" },
        requested_action   = { type = "string", maxLength = 512 },
      },
      required = ["original_msg", "requested_action"],
    },

    supervise_resp = {
      type = "object",
      additionalProperties = false,
      properties = {
        original_msg_id = { type = "string" },
        decision        = { type = "string", enum = ["approve", "reject"] },
        reason          = { type = "string", maxLength = 512 },
      },
      required = ["original_msg_id", "decision", "reason"],
    },

    attest_req = {
      type = "object",
      additionalProperties = false,
      properties = {
        original_msg_id = { type = "string" },
        original_msg    = { "$ref" = "#/envelope" },
        ask             = { type = "string", maxLength = 512, description = "What the attester is being asked to verify." },
      },
      required = ["original_msg_id", "original_msg", "ask"],
    },

    attest_resp = {
      type = "object",
      additionalProperties = false,
      properties = {
        original_msg_id = { type = "string" },
        decision        = { type = "string", enum = ["attest", "reject"] },
        reason          = { type = "string", maxLength = 512 },
      },
      required = ["original_msg_id", "decision", "reason"],
    },

    fyi = {
      type = "object",
      additionalProperties = false,
      properties = {
        message = { type = "string", maxLength = 1024 },
        tags    = { type = "array", items = { type = "string" }, maxItems = 8 },
      },
      required = ["message"],
    },

    clarify = {
      type = "object",
      additionalProperties = false,
      properties = {
        question            = { type = "string", maxLength = 1024 },
        context_summary     = { type = "string", maxLength = 1024 },
        options             = { type = "array", items = { type = "string" }, maxItems = 8 },
        blocks_task         = { type = "string", description = "Task identifier this clarification blocks, if any." },
      },
      required = ["question"],
    },

    blocker = {
      type = "object",
      additionalProperties = false,
      properties = {
        task         = { type = "string", maxLength = 128 },
        blocker      = { type = "string", maxLength = 1024 },
        attempted    = { type = "array", items = { type = "string" }, description = "Things the peer already tried." },
        needed       = { type = "string", description = "What the user must provide or decide." },
      },
      required = ["task", "blocker", "needed"],
    },

    gated_op = {
      type = "object",
      description = "Wrapper for an arbitrary high-risk action; used when no purpose-built op_kind fits.",
      additionalProperties = true,
      properties = {
        action     = { type = "string", maxLength = 256 },
        payload    = { type = "object" },
      },
      required = ["action"],
    },
  },

  # ────────────────────────────────────────────────────────────────────
  # Peer registration extensions — fields added to coord_register beyond
  # the current (client_kind, context). Advisory until Task #5 wires them
  # into the FFI Peer struct.
  # ────────────────────────────────────────────────────────────────────

  peer_registration_extensions = {
    role = {
      type = "string",
      enum = ["master", "journeyman", "apprentice", "supervisor", "executor", "supervised"],
      description = "Trust tier (DD-32). master (ex-supervisor) = approval authority; journeyman (ex-executor) = trusted to act solo on Tier 2; apprentice (ex-supervised) = Tier 2+ quarantined. Defaults: client_kind=claude -> journeyman; non-claude -> apprentice. master must be requested explicitly via coord_promote_to_master with BOJ_MASTER_TOKEN. Old enum values accepted as aliases for one release.",
    },
    affinities = {
      type = "array",
      items = { type = "string", maxLength = 32, pattern = "^[a-z][a-z0-9-]*$" },
      maxItems = 16,
      description = "Free-form strength tags (e.g. 'proof-analysis', 'typescript-refactor', 'long-document-grok'). Router prefers peers whose affinities match task_tags. Non-matching peers can still claim.",
    },
  },

  # ────────────────────────────────────────────────────────────────────
  # Forbidden-action policy (Tier 4).
  #
  # Schema-level reject for envelopes from role=apprentice matching any
  # of these signatures. The server runs this list at validate time.
  # ────────────────────────────────────────────────────────────────────

  tier_4_forbidden_for_apprentice = [
    { match_kind = "payload_contains", value = "--force", description = "Force-push (raw or wrapped)." },
    { match_kind = "payload_contains", value = "git push --force", description = "Force-push explicit." },
    { match_kind = "payload_contains", value = "branch --delete", description = "Remote branch delete." },
    { match_kind = "payload_contains", value = "gh repo create --public", description = "Public repo creation." },
    { match_kind = "payload_contains", value = "LICENSE", description = "Any touch to LICENSE files — tier 4 by default, require Opus exception." },
    { match_kind = "path_touches_any_of", value = ["007", ".git-private-farm", "hyperpolymath-sovereign-registry", "blog-drafts", "claude-memory"], description = "Always-private repos — see memory/always-private-repos.md." },
  ],

  # ────────────────────────────────────────────────────────────────────
  # Sanity gate — content heuristics auto-promoting risk_tier.
  # ────────────────────────────────────────────────────────────────────

  sanity_auto_promote = [
    { pattern = "git push", min_tier = 3, reason = "Push operation" },
    { pattern = "git commit", min_tier = 2, reason = "Commit operation" },
    { pattern = "\\brm\\s+-[rR]f?", min_tier = 3, reason = "Recursive rm" },
    { pattern = "DROP TABLE", min_tier = 3, reason = "Schema destruction" },
    { pattern = "SET secret", min_tier = 3, reason = "Secret modification" },
    { pattern = "--no-verify", min_tier = 3, reason = "Hook bypass" },
  ],

  # Note on validation layers:
  # - This file (JSON-Schema-style) is the PORTABLE interface. Exports
  #   to coord-messages.json for any JSON Schema validator.
  # - Rich dependent-constraint validation lives in sibling file
  #   schemas/coord-messages-contracts.ncl — use that for server-side
  #   checks via the Deno shim (Task #17). It expresses rules that JSON
  #   Schema can't cleanly say (Tier 2+ requires context_fetch_id, etc.)
}
