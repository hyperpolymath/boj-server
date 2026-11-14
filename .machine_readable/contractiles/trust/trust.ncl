# SPDX-License-Identifier: MPL-2.0
# trust.ncl — trust boundary verification runner for boj-server
#
# Pairs with: Trustfile.deed (same directory; A7 8.1). Not yet written: the
#             legacy Trustfile.a2ml was retired 2026-11-14 with no mapping
#             spec to translate it (docs/history/A2ML-REMOVED.adoc).
# Verb:       trust
# Semantics:  verify provenance, integrity, and trust-boundary invariants.
#             Runner evaluates the declared trust checks (licence present,
#             no secrets committed, container images pinned, etc.) and
#             reports on the overall trust posture.
# CLI:        `contractile trust check`  → evaluate all trust probes
#             `contractile trust audit`  → full provenance + integrity audit
#
# Anything else in this directory is human-only notes/archive; machines ignore.

{
  pedigree = {
    contractile_verb = "trust",
    semantics = "trust boundary verification + provenance + integrity",
    security = {
      leash = 'Kennel,
      trust_level = "read-only; cryptographic probe allowed",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = true,
    },
    metadata = {
      name = "trust-runner",
      version = "1.0.0",
      description = "Evaluates trust-boundary invariants: provenance, integrity, secrets hygiene, signature checks. Hard-gates on critical failures.",
      paired_xfile = "Trustfile.deed",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    verifications
      | Array {
          id | String,
          description | String,
          command | String,
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
