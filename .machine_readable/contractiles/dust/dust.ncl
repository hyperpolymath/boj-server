# SPDX-License-Identifier: PMPL-1.0-or-later
# dust.ncl — cleanup and hygiene runner for boj-server
#
# Pairs with: Dustfile.a2ml (same directory)
# Verb:       dust
# Semantics:  verify cleanup policies are met and all recovery paths are declared.
#             Runner checks for stale branches, stale artefacts, dead code, and
#             that each recovery scenario in Dustfile.a2ml has a verified path.
# CLI:        `contractile dust check`  → run hygiene checks
#             `contractile dust sweep`  → execute safe cleanup operations
#
# Anything else in this directory is human-only notes/archive; machines ignore.

{
  pedigree = {
    contractile_verb = "dust",
    semantics = "cleanup hygiene + rollback path verification",
    security = {
      leash = 'Kennel,
      trust_level = "read-only for check; limited write for sweep (reversible only)",
      allow_network = false,
      allow_filesystem_write = true,
      allow_subprocess = true,
    },
    metadata = {
      name = "dust-runner",
      version = "1.0.0",
      description = "Verifies cleanup policies and all declared recovery rollback paths. Sweep mode applies only reversible cleanup.",
      paired_xfile = "Dustfile.a2ml",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    recovery_scenarios
      | Array {
          id | String,
          description | String,
          rollback | String,
          blast_radius | [| 'file, 'directory, 'repo, 'ecosystem |],
          precondition | String | optional,
          notes | String | optional,
          status | [| 'declared, 'verified, 'failing |] | default = 'declared,
        },
  },

  run = {
    on_any_fail = "warn",
    report_format = "a2ml",
    emit_summary = true,
    sweep_policy = "reversible-only",
    stale_branch_retention_days = 90,
    artefact_retention_days = 90,
  },
}
