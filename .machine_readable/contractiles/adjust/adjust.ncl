# SPDX-License-Identifier: PMPL-1.0-or-later
# adjust.ncl — accessibility invariant runner for boj-server
#
# Pairs with: Adjustfile.a2ml (same directory)
# Verb:       adjust
# Semantics:  verify all user-facing interfaces meet WCAG 2.2 AA minimum.
#             Runner applies automated accessibility probes and hard-gates on
#             any critical regression.
# CLI:        `contractile adjust check`  → run accessibility probes
#             `contractile adjust report` → emit accessibility compliance report
#
# Anything else in this directory is human-only notes/archive; machines ignore.

{
  pedigree = {
    contractile_verb = "adjust",
    semantics = "accessibility & digital justice (WCAG 2.2 AA)",
    security = {
      leash = 'Kennel,
      trust_level = "read-only; accessibility probes only",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = true,
    },
    metadata = {
      name = "adjust-runner",
      version = "1.0.0",
      description = "Verifies WCAG 2.2 AA compliance across all user-facing interfaces. Hard-gates on critical regressions.",
      paired_xfile = "Adjustfile.a2ml",
      standard = "WCAG-2.2-AA",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    invariants
      | Array {
          id | String,
          criterion | String,
          wcag_ref | String | optional,
          category | [| 'visual, 'keyboard, 'screen_reader, 'interactive, 'media, 'motion, 'cli_tui, 'documentation |],
          probe | String,
          severity | [| 'critical, 'warning, 'info |] | default = 'critical,
          status | [| 'declared, 'verified, 'failing, 'na |] | default = 'declared,
        },
  },

  run = {
    on_any_fail = "exit-nonzero",
    report_format = "a2ml",
    emit_summary = true,
    block_on_severity = 'critical,
  },
}
