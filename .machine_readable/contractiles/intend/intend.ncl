# SPDX-License-Identifier: PMPL-1.0-or-later
# intend.ncl — purpose/scope verification runner for boj-server
#
# Pairs with: Intentfile.a2ml (same directory)
# Verb:       intend
# Semantics:  verify the repo matches its declared purpose; detect scope-creep
#             by checking for anti-purpose violations (banned languages, banned
#             patterns, standalone MCP servers, etc.)
# CLI:        `contractile intend check`  → verify purpose alignment
#             `contractile intend scope`  → report current scope vs declared
#
# Anything else in this directory is human-only notes/archive; machines ignore.

{
  pedigree = {
    contractile_verb = "intend",
    semantics = "purpose declaration + scope-creep detection",
    security = {
      leash = 'Kennel,
      trust_level = "read-only; no execution of project code",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,
    },
    metadata = {
      name = "intend-runner",
      version = "1.0.0",
      description = "Verifies repo aligns with declared purpose. Hard-gates on anti-purpose violations.",
      paired_xfile = "Intentfile.a2ml",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    checks
      | Array {
          id | String,
          description | String,
          kind | [| 'anti_purpose, 'scope, 'architecture, 'ecosystem |],
          probe | String,
          severity | [| 'critical, 'warning, 'info |] | default = 'critical,
          status | [| 'declared, 'verified, 'failing |] | default = 'declared,
        },
  },

  run = {
    on_any_fail = "warn",
    report_format = "a2ml",
    emit_summary = true,
    block_on_severity = 'critical,
  },
}
