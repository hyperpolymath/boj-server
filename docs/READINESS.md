<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# BoJ Server Component Readiness Assessment

**Standard:** [Component Readiness Grades (CRG) v2.0](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)
**Assessed:** 2026-04-18
**Assessor:** Jonathan D.A. Jewell
**Previous assessment:** 2026-03-09 (CRG v1.0)

**Current Grade:** D

This line is parsed by `just crg-grade` / `just crg-badge`. The grade above is
the worst-graded in-scope component — BoJ Server's weakest link drags the
whole. See the table in §3 for per-component grades.

---

## 1. CRG v2.0 Grade Reference

| Grade | Name                  | Release Stage | Stability Posture        | Shorthand         |
|-------|-----------------------|---------------|--------------------------|-------------------|
| X     | Untested              | —             | —                        | —                 |
| F     | Harmful / Wasteful    | —             | —                        | reject/delegate   |
| E     | Minimal / Salvageable | Pre-alpha     | Unstable                 | pre-alpha         |
| D     | Partial / Inconsistent| Alpha         | Unstable                 | `alpha-unstable`  |
| C     | Self-Validated        | Alpha         | Stable in home context   | `alpha-stable`    |
| B     | Broadly Validated     | Beta          | Stable for broad trial   | `beta-stable`     |
| A     | Field-Proven          | Stable        | Stable                   | `stable`          |

**Evidence gates (v2.0 is stricter than v1.0):**

- **D**: RSR-compliant + Immaculate Guide compliance (hyperpolymath projects)
  + per-capability test + documented scope.
- **C**: All of D, plus active dogfooding in home context with no known home-context
  failures, plus **deep code and folder annotation** (purpose, boundaries,
  invariants, execution/test/proof surfaces, per-directory orientation).
- **B**: All of C, plus validated against **six genuinely diverse external
  targets** with feedback fed back into the component.
- **A**: All of B, plus real-world external feedback, no harm in the wild,
  demonstrated net-positive value.

**Publication gate**: non-abstract implementation claims require **B+**.

---

## 2. Headline Evidence (as of 2026-04-18)

| Metric | Value | Source |
|--------|-------|--------|
| Cartridges in fleet | 99 (plus 1 non-standard: `model-router-mcp`) | `cartridges/*/cartridge.json` |
| Cartridge `README.adoc` coverage | **100/100** (46 newly generated 2026-04-18) | `cartridges/*/README.adoc` |
| Cartridge shared libs built | 96/99 | `.machine_readable/6a2/STATE.a2ml` §quality |
| Total tests passing | **365** (178 core FFI + 113 cartridge FFI + 40 federation + 14 coprocessor + 11 SLA + 11 community + 10 SDP + 28 readiness + 13 E2E + 12 guardian + 7 VeriSimDB + 11 multi-node + 58 MCP bridge + 17 aspect) | STATE.a2ml |
| `believe_me` count | 4 (down from 31 — sweep complete 2026-04-12) | STATE.a2ml |
| V-lang adapters | **Sidelined** — all cartridge adapters are now Zig, `.v` variants preserved alongside as `SIDELINED-*.v.adoc` | `cartridges/*/adapter/` |
| `glama-grade` | AAA (Security A, License A, Quality A) | STATE.a2ml |
| Dependabot alerts | 0 | STATE.a2ml |
| SSE transport | Active on port 7703 (fixed 2026-03-29) | STATE.a2ml |
| CI pipeline | `zig-test.yml` (all tests on push) | `.github/workflows/` |

---

## 3. Component Assessment

All components graded **as-is today**, per CRG v2.0 Principle 4 (honest
assessment over aspirational grading). Stability posture column reflects the
component's state **within its home context only** unless noted.

| Component                    | Grade | Stability Posture        | Evidence Summary                                                                                  | Promotion blocker                                       | Last Assessed |
|------------------------------|-------|--------------------------|---------------------------------------------------------------------------------------------------|---------------------------------------------------------|---------------|
| Catalogue ABI (Idris2)       | D     | `alpha-unstable`         | Type-checks with `%default total`. 4 `believe_me` (down from 31). No runtime invariants exercised. | Dogfood + deep annotation of invariants per directory   | 2026-04-18    |
| Catalogue FFI (Zig)          | D     | `alpha-unstable`         | Builds clean. 178 core tests pass. Not yet validated against an independent consumer.              | Add external consumer in home context, then annotate    | 2026-04-18    |
| C Headers (generated)        | D     | `alpha-unstable`         | Generated, matches Idris2 encodings. Not tested via a C consumer.                                  | Real C consumer + ABI round-trip test                   | 2026-04-18    |
| Cartridge fleet (99)         | D     | `alpha-unstable`         | 96/99 shared libs built. 100/100 cartridges now have `README.adoc`. 113 FFI tests pass.            | Deep per-cartridge annotation (readmes are overview only) | 2026-04-18    |
| Zig adapter layer (per cartridge) | D | `alpha-unstable`         | All adapters ported from V to Zig. V predecessors retained as `SIDELINED-*.v.adoc`.                | Exercise adapter under real-protocol load               | 2026-04-18    |
| Dynamic Loader               | D     | `alpha-unstable`         | Hash verification, mount/unmount. 14 loader tests pass.                                            | Use in anger on multi-cartridge live reload             | 2026-04-18    |
| Guardian module              | D     | `alpha-unstable`         | Resource-aware failure tolerance. 12 tests pass.                                                   | Fault-injection campaign                                | 2026-04-18    |
| Umoja Federation             | D     | `alpha-unstable`         | Real UDP gossip, hash attestation, QUIC transport. 40 federation tests + 11 multi-node tests.      | Live multi-host run with adversarial peers              | 2026-04-18    |
| VeriSimDB backing store      | D     | `alpha-unstable`         | Cartridge state persistence. 7 tests pass.                                                         | Dogfood persistence across restart + migration          | 2026-04-18    |
| PanLL BoJ panel              | D     | `alpha-unstable`         | 887-line TEA view in PanLL repo. 5 tabs, matrix view, federation UI.                               | Use in daily PanLL workflow; record friction log        | 2026-04-18    |
| CI pipeline (`zig-test.yml`) | D     | `alpha-unstable`         | All 365 tests run on push.                                                                         | Cover publish/release path end-to-end                   | 2026-04-18    |
| Container ecosystem          | D     | `alpha-unstable`         | Containerfile + compose.toml + vordr.toml present. Podman quadlet defined but image unpublished.    | Publish image, run unattended for ≥1 week               | 2026-04-18    |
| Coprocessor dispatch         | D     | `alpha-unstable`         | Axiom.jl-style, 14 tests.                                                                          | Live routing under real tool-call mix                   | 2026-04-18    |
| SLA module                   | D     | `alpha-unstable`         | 11 tests.                                                                                          | Apply to a real-time guarantee                          | 2026-04-18    |
| Community module             | D     | `alpha-unstable`         | 11 tests.                                                                                          | Real external contributor transaction                   | 2026-04-18    |
| SDP module                   | D     | `alpha-unstable`         | 10 tests.                                                                                          | End-to-end session with a live peer                     | 2026-04-18    |
| MCP bridge (Deno)            | D     | `alpha-unstable`         | 58 MCP bridge tests + 17 aspect (security) tests added 2026-04-04.                                 | Drive from a real MCP client under load                 | 2026-04-18    |
| Order-Ticket Protocol        | D     | `alpha-unstable`         | A2ML spec + 13 E2E tests.                                                                          | Production flow on a real engagement                    | 2026-04-18    |
| Extensibility (3rd axis)     | D     | `alpha-unstable`         | Backend field stubbed in ABI+FFI, 2 tests, `extension.a2ml` template.                              | One third-party extension accepted and merged           | 2026-04-18    |
| Teranga Menu                 | X     | —                        | A2ML spec defined. No runtime generation yet.                                                      | Build the runtime generator                             | 2026-04-18    |
| Documentation (this corpus)  | D     | `alpha-unstable`         | 46 cartridge READMEs freshly generated 2026-04-18 (overview-level). `docs/practice/DOGFOOD-LOG.adoc` started 2026-04-18. | Deep per-cartridge annotation + 4 weeks of dated DOGFOOD-LOG entries | 2026-04-18    |

**No component has yet cleared the CRG v2.0 C bar.** The v1.0 table above was
optimistic about what "Alpha" bought — v2.0 makes clear that the missing
evidence is *dogfooded reliability with deep annotation*, not just
"type-checks + tests pass".

---

## 4. What's Needed for D → C

CRG v2.0 requires two new pieces of evidence on top of D:

1. **Active dogfooding in home context with no known home-context failures.**
   - Start date: 2026-04-18 (first `docs/practice/DOGFOOD-LOG.adoc` entry).
   - Home context = hyperpolymath estate repos operated through BoJ cartridges.
   - "No known failures" is a moving claim, not a one-off snapshot — it must hold
     continuously across the evidence window.

2. **Deep code and folder annotation** — per CRG 4.5, that means for each
   component: purpose, boundaries, invariants, execution/test/proof surfaces,
   and per-directory orientation where the code is otherwise opaque.
   - The 46 cartridge READMEs added 2026-04-18 are **overview-level** — they
     cover purpose, tools, architecture-at-a-glance, and build steps. They
     are a necessary step but not a sufficient one.
   - Still missing: per-directory `README.adoc` orientation notes inside
     `abi/`, `ffi/`, `adapter/` for any cartridge where a reviewer would
     otherwise have to read source to orient.

**Minimum first-ring targets for C promotion:**

- Catalogue ABI + Catalogue FFI (the trunk — if these aren't C, nothing else
  can be).
- `cartridge fleet` — at least 6 cartridges annotated to depth, dogfooded
  daily, zero home-context failures for 4 weeks.
- PanLL BoJ panel — because it is the most visible dogfood surface.

---

## 5. What's Needed for C → B

Six **genuinely diverse** external targets with feedback fed back into the
component. Candidate target types (diversity axes):

- Non-hyperpolymath open-source project consuming the MCP bridge.
- Language runtime other than BEAM/Deno/Zig-native (e.g. OCaml, Gleam,
  Elixir) driving a cartridge end-to-end.
- Embedded / resource-constrained host.
- Different OS family (one of the six must not be Linux).
- Different federation topology (non-star, e.g. mesh with ≥3 peers).
- Different auth posture (unauthenticated, API-key, and vault-brokered in the
  mix).

B+ is the minimum for non-abstract implementation-facing publication
(whitepapers, talks, or papers that claim working software). Below B, any
publication must be explicitly abstract / provisional.

---

## 6. Summary (2026-04-18)

- **All in-scope components at Grade D**: the project is honestly in alpha.
- **Cartridge README coverage 100%**: first time in project history.
- **V-lang sidelined**: all adapters are Zig; V source retained as
  `SIDELINED-*.v.adoc` alongside the Zig successor.
- **No component at C or above**: the v2.0 rubric exposes that dogfood
  evidence and deep annotation were undercounted in the v1.0 read.
- **DOGFOOD-LOG.adoc started**: dated evidence will accumulate here, not in
  self-reports.
- **Machine-readable grade line present** (§1 above) for `just crg-grade` /
  `just crg-badge`.

**Next milestone:** first-ring D → C on Catalogue ABI/FFI + 6 lead cartridges
+ PanLL panel. Deep annotation pass precedes the 4-week dogfood window.
