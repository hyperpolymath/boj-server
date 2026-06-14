# SPDX-License-Identifier: MPL-2.0
# must.ncl — baseline invariant runner for boj-server
#
# Pairs with: Mustfile.a2ml (same directory)
# Verb:       must
# Semantics:  every declared invariant must pass. Runner evaluates physical-state
#             checks (file existence, no banned patterns, SPDX headers, etc.) and
#             hard-gates on any critical failure. K9 validator enforces these in CI.
# CLI:        `contractile must check`  → evaluate all must-checks
#             `contractile must list`   → list invariants with current status
#
# Anything else in this directory is human-only notes/archive; machines ignore.

{
  pedigree = {
    contractile_verb = "must",
    semantics = "baseline invariants (physical state + language policy + security)",
    security = {
      leash = 'Kennel,
      trust_level = "read-only; no execution of project code",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = true,
    },
    metadata = {
      name = "must-runner",
      version = "1.0.0",
      description = "Evaluates all declared must-invariants. Blocks merge on critical failure. K9 validator is the authoritative CI enforcement.",
      paired_xfile = "Mustfile.a2ml",
      k9_validator = ".machine_readable/svc/self-validating/boj-server-metadata.k9.ncl",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    checks
      | Array {
          id | String,
          description | String,
          run | String,
          severity | [| 'critical, 'warning, 'info |] | default = 'critical,
          status | [| 'declared, 'verified, 'failing |] | default = 'declared,
        },
  },

  run = {
    on_any_fail = "exit-nonzero",
    report_format = "a2ml",
    emit_summary = true,
    block_on_severity = 'critical,
  },
}
