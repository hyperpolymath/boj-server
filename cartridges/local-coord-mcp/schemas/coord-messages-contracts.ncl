# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# coord-messages-contracts.ncl — Nickel contracts for rich server-side
# envelope validation. Sibling to coord-messages.ncl (portable JSON
# Schema) — use this file for cross-field dependent constraints that
# JSON Schema can't elegantly express.
#
# Wired into mcp-bridge via a Deno shim (Task #17): on each coord_send
# or coord_send_gated call, the bridge imports this file, extracts
# `EnvelopeV1`, and applies it to the message body. Invalid envelopes
# are rejected with a descriptive error before they reach the Zig
# adapter.
#
# Usage pattern:
#   let contracts = import "coord-messages-contracts.ncl" in
#   let ok_envelope = my_envelope | contracts.EnvelopeV1 in
#   ...
#
# If any constraint fails, Nickel emits a descriptive error pointing at
# the offending field. The Deno shim translates that error into an MCP
# error response.

let OpDefaults = {
  status = 0,
  query = 0,
  context_query = 0,
  context_reply = 0,
  supervise_req = 0,
  supervise_resp = 0,
  attest_req = 0,
  attest_resp = 0,
  fyi = 1,
  progress = 1,
  warn_drift = 1,
  release = 1,
  claim = 2,
  handoff = 2,
  clarify = 2,
  blocker = 3,
  gated_op = 3,
} in

let OpKinds = std.record.fields OpDefaults in

{
  # ── Primitive contracts ─────────────────────────────────────────

  RiskTier = std.contract.from_predicate (fun v =>
    std.is_number v
    && v >= 0
    && v <= 4
    && v == (std.number.floor v)
  ),

  OpKind = std.contract.from_predicate (fun v =>
    std.is_string v && std.array.any (fun k => k == v) OpKinds
  ),

  MsgIdHex = std.contract.from_predicate (fun v =>
    std.is_string v
    && std.string.length v == 12
    && std.string.is_match "^[0-9a-f]{12}$" v
  ),

  HashHex = std.contract.from_predicate (fun v =>
    std.is_string v
    && std.string.length v == 64
    && std.string.is_match "^[0-9a-f]{64}$" v
  ),

  # ── Dependent constraints — the rules JSON Schema can't express ──

  # Any Tier >= 2 envelope MUST carry a non-empty context_fetch_id.
  # Blast-radius scaled: drone at Tier 0/1, strategic at Tier 2+.
  TierContextGate = std.contract.from_predicate (fun e =>
    !(std.record.has_field "risk_tier" e)
    || e.risk_tier < 2
    || (std.record.has_field "context_fetch_id" e
        && std.is_string e.context_fetch_id
        && std.string.length e.context_fetch_id > 0)
  ),

  # Any Tier >= 2 envelope from a peer whose role is "supervised" MUST
  # carry at least one attestation_refs entry. M-of-N Byzantine safety.
  #
  # The sender's role is NOT in the envelope itself (server-attached at
  # dispatch). Validator caller passes role via e._meta.sender_role when
  # running this contract server-side.
  TierAttestationGate = std.contract.from_predicate (fun e =>
    !(std.record.has_field "risk_tier" e)
    || e.risk_tier < 2
    || !(std.record.has_field "_meta" e)
    || !(std.record.has_field "sender_role" e._meta)
    || e._meta.sender_role != "supervised"
    || (std.record.has_field "attestation_refs" e
        && std.is_array e.attestation_refs
        && std.array.length e.attestation_refs >= 1)
  ),

  # urgent_direct=true is only permitted for supervisor + executor.
  # supervised peers never interrupt the user directly.
  UrgentDirectRestriction = std.contract.from_predicate (fun e =>
    !(std.record.has_field "urgent_direct" e)
    || !e.urgent_direct
    || !(std.record.has_field "_meta" e)
    || !(std.record.has_field "sender_role" e._meta)
    || e._meta.sender_role != "supervised"
  ),

  # If declared risk_tier differs from the op_kind's default, a
  # non-empty tier_override_reason MUST be present. Catches tier
  # underclaiming ("I said it's Tier 1 but it's a git push").
  TierOverrideJustification = std.contract.from_predicate (fun e =>
    !(std.record.has_field "op_kind" e)
    || !(std.record.has_field "risk_tier" e)
    || (
      let default_tier =
        if std.record.has_field e.op_kind OpDefaults then
          std.record.get e.op_kind OpDefaults
        else 0 in
      e.risk_tier == default_tier
      || (std.record.has_field "tier_override_reason" e
          && std.is_string e.tier_override_reason
          && std.string.length e.tier_override_reason > 0)
    )
  ),

  # ── Combined validator ─────────────────────────────────────────
  #
  # Lazy function that applies all four dependent-constraint contracts
  # in sequence. Shape validation stays in the JSON Schema sibling
  # (coord-messages.ncl / .json) — this validator runs AFTER shape has
  # been confirmed by a JSON Schema validator.
  #
  # Usage from the Deno shim (Task #17):
  #
  #   const contracts = await loadNickel("coord-messages-contracts.ncl");
  #   // First: JSON Schema validates shape.
  #   // Then: this validator applies dependent constraints.
  #   const result = applyNickelContract(contracts.validate, envelope);
  #
  # Wrapped in a function so Nickel doesn't eagerly try to realise it
  # when the file is imported — evaluation happens when validate is
  # called on actual envelope data.

  validate = fun envelope =>
    envelope
    | TierContextGate
    | TierAttestationGate
    | UrgentDirectRestriction
    | TierOverrideJustification,
}
