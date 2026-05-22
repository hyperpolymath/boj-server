# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# prover-tag-claim.ncl — Example envelope for a prover-specific claim
# (Task #37 / DD-37).
#
# The `proof:<prover>` tag convention routes proof-sized work to peers
# whose declared affinities include that prover. Zero new server code —
# the existing affinity machinery (Task #13 effective_affinity, Task #14
# reassignment engine) does the routing based on declared_affinities +
# track record.
#
# Canonical prover names:
#   proof:lean4, proof:agda, proof:idris2, proof:rocq, proof:tla,
#   proof:echidna, proof:spark
#
# Validate with:
#   nickel eval examples/prover-tag-claim.ncl
#   (uses ../coord-messages-contracts.ncl to gate on dependent fields)

let contracts = import "../coord-messages-contracts.ncl" in

let envelope = {
  version = 1,
  msg_id = "7f3a92b4c1d0",
  prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
  sender = "claude-7f3a@boj-server",
  recipient = "*",
  timestamp = "2026-04-20T10:15:00Z",
  op_kind = "claim",
  risk_tier = 2,
  payload = {
    # Convention: proof:<prover>/<what>. Scheduler strips the prefix
    # when dispatching; keeps it for logs + track-record aggregation.
    task = "proof:agda/category-pullback-universal",
  },
  context_fetch_id = "ctx-b1c2",
  sender_confidence = 0.8,
  difficulty_hint = "high",
  task_difficulty = "novel",
  dispatch_preference = "deliberate",
} in

contracts.validate envelope
