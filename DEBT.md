<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Technical debt register

One index of known debt in this repository, measured 2026-08-07 against
`78c4a05a`. Every item carries **the command that produced the evidence**, so
any entry can be re-checked or falsified in one step. Claims that are not
verified are labelled **DIAGNOSIS (unconfirmed)** rather than asserted.

This file is an index, not a replacement. The pre-existing registers remain
authoritative in their own domains and are linked, not duplicated:
[`PROOF-NEEDS.md`](PROOF-NEEDS.md) · [`TEST-NEEDS.md`](TEST-NEEDS.md) ·
[`docs/proof-debt.md`](docs/proof-debt.md) ·
[`docs/tech-debt-2026-05-26.md`](docs/tech-debt-2026-05-26.md).

Severity: **HIGH** — actively misleads, or a gate that cannot fail ·
**MEDIUM** — wrong but self-evident on contact · **LOW** — cosmetic or
historical.

---

## The single largest item

**The `cartridges/` retirement (#300) is incomplete.** Removing 128 cartridges
took the manifests but left every consumer behind: two permanently-off
workflows, scripts whose loops match nothing, Justfile recipes, test scripts,
count claims in fourteen documents, and 1,346 files of build residue. Items
C-1…C-6, D-1…D-4, T-1 and X-1 below are all one migration, not ten problems.

```sh
git grep -nF 'cartridges/' -- ':!docs' ':!*.md' ':!*.adoc' ':!tests/fixtures' | wc -l
```

---

## Licence — L

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| L-1 | MEDIUM | `glama.json` is the only packaging manifest with **no `license` field at all**. Every sibling declares MPL-2.0 (`package.json`, `jsr.json`, `smithery.yaml`, `CITATION.cff`, `guix.scm`, `elixir/mix.exs`). | `grep -L '"license"' glama.json package.json jsr.json` |
| L-2 | LOW | `ai-plugin.json` declares licence only as a URL (`legal_info_url`), with no SPDX key — inconsistent with the rest of the estate. | `grep -n 'legal_info_url\|license' ai-plugin.json` |
| L-3 | LOW | Four tracked source files of 500+ carry no `SPDX-License-Identifier`: `.github/copilot/coding-agent.yml`, `.github/funding.yml`, `.machine_readable/scripts/forge/git-cleanup.sh`, `configs/config.ncl`. | `git ls-files \| xargs grep -L 'SPDX-License-Identifier' 2>/dev/null` |

**Not debt, recorded as the positive control:** the dual-licence posture is
correct and documented — `NOTICE` explains MPL-2.0 (code) / CC-BY-SA-4.0
(prose), `LICENSES/` holds both texts, and `.reuse/dep5` covers headerless
config. 335 MPL / 184 CC-BY-SA headers, zero third licence, zero unattributed
vendored trees. **The sibling registry has neither `NOTICE` nor `.reuse/` —
see its own `DEBT.md` L-1.**

---

## Proof — P

The proofs themselves are in good order: **4** `believe_me` sites, all inside
the sanctioned module, all `%unsafe`-tagged; zero `postulate`, `assert_total`,
`assert_smaller`, `idris_crash`, `sorry`, `%default partial`, `?hole` anywhere
in `src/abi/`. **The debt is in the gates and the prose, not the proofs.**

```sh
grep -rn 'believe_me' src/abi --include='*.idr' | grep -v '|||'   # 4 sites
grep -n 'EXPECTED_AXIOMS=' scripts/check-trusted-base.sh          # 4
```

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| P-1 | HIGH | **`proofs.yml` can report success with no prover having run.** The `changes` job sets `run=false` for any PR outside its path set, and both proof jobs are `if: needs.changes.outputs.run == 'true'`; a skipped job reports SUCCESS to a required check. The weekly `cron` at `proofs.yml` is the only backstop. This is a deliberate design (documented in the workflow header) — recorded here because the failure mode is invisible to a reviewer reading a green tick. | `grep -n "run=false\|needs.changes.outputs.run" .github/workflows/proofs.yml` |
| P-2 | MEDIUM | `scripts/check-trusted-base.sh` still greps `src/ cartridges/ verification/`; one of the three no longer exists, so the scan surface is a third smaller than it reads. The axiom count itself still works. | `grep -n 'cartridges/' scripts/check-trusted-base.sh` |
| P-3 | MEDIUM | `PROOF-NEEDS.md` cites `cartridges/fleet-mcp/abi/FleetMcp/SafeFleet.idr lines 14 & 34` — a proof obligation anchored to a file in the *other* repo, so the line numbers cannot be checked from here. | `grep -n 'SafeFleet' PROOF-NEEDS.md` |
| P-4 | LOW | **FIXED 2026-08-07, retained for provenance.** `PROOF-NEEDS.md` asserted `PASS=105` and "**exactly 5**" axioms; the enforcing script has said `EXPECTED_AXIOMS=4` since `charEqSym` was discharged, and the gate now covers 1 package. Two "in sync" documents disagreed with each other and with the code. | `git log -1 --format=%h -- PROOF-NEEDS.md` |

**Cross-repo:** `boj-server-cartridges/scripts/check-trusted-base.sh` still
says *"boj-server sanctions EXACTLY 5 class-(J) axioms"*. Fixing it there
needs this file's correction to land first.

---

## CI/CD — C

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| C-1 | HIGH | **`abi-drift.yml` is permanently off** — `printf 'run=false'` unconditionally, so job `Emit manifest + verify FFI` never runs while still satisfying its required check by skipping. Its subject (per-cartridge iseriser drift) must be ported to the registry before the workflow *and its required context* are deleted. The port has not happened. | `grep -n "run=false" .github/workflows/abi-drift.yml` |
| C-2 | HIGH | **`lsp-dap-bsp.yml` is permanently off** — same mechanism, **four** dead jobs: ABI Specification Check, FFI Build & Test, Panel Manifest Validation, Cartridge Completeness Check. | `grep -n "run=false" .github/workflows/lsp-dap-bsp.yml` |
| C-3 | HIGH | **`main-estate-audit.yml` is still untracked here, deliberately — arming it today would fail `main` immediately.** The referenced suite is now published (`hyperpolymath/cicd-suite`, `11b5ab51`, all 26 actions resolve), so the 404 is fixed. But running its two relevant hard gates against this repo: `required-files-check` fails on 3 missing files (`CODEOWNERS`, `ARCHITECTURE.md`, `MAINTAINERS.adoc`), and `code-hygiene-check` matches **112 files** — including this repo's four *sanctioned, documented, CI-counted* `believe_me` axioms, which are its declared trusted base, not debt. Satisfying `required-files-check` means adding presence-only filler, which is how the template boilerplate on `fix/zig-ptr-cast-shim` was generated. **Fix the gates (see cicd-suite's README), then pin to `11b5ab51` and commit.** | `for f in CODEOWNERS ARCHITECTURE.md MAINTAINERS.adoc; do [ -f $f ] \|\| echo MISSING $f; done` · `git grep -Eic 'TODO\|FIXME\|STUB\|sorry\|believe_me\|admit' \| wc -l` → 112 |
| C-7 | HIGH | **13 of `cicd-suite`'s 26 actions cannot fail** — they emit `::warning::` and exit successfully while being named "Gate". The suite also contradicts itself: `required-files-check` hard-fails a repo lacking `GOVERNANCE.md`/`ARCHITECTURE.md`, while `formatting-check` warns those files should be `.adoc`. Estate-wide: `rollout_estate.sh` has copied the consuming workflow into **199 repos**, untracked in **198**. | `for a in ../cicd-suite/actions/*/; do grep -q 'exit 1' $a/action.yml \|\| echo $a; done \| wc -l` → 13 |
| C-4 | MEDIUM | Five required status-check contexts correspond to jobs that are green-by-skip (C-1, C-2). A reviewer cannot distinguish "passed" from "never ran". | `gh api repos/:owner/:repo/branches/main/protection` |
| C-5 | MEDIUM | `fuzz.yml` suppresses failure twice over: `\|\| true` **and** `continue-on-error: true`, with stderr sent to `/dev/null`. A crash is invisible rather than merely non-blocking. The bridge probes (including a `../../../etc/passwd` traversal case) assert nothing. | `grep -n 'continue-on-error\|\|\| true' .github/workflows/fuzz.yml` |
| C-6 | LOW | `pages.yml` and `pages-deploy.yml` both fire on push to main, publishing different content to two different hosts with no coordination. | `grep -l 'branches: \[main' .github/workflows/pages*.yml` |

**FIXED 2026-08-07** (recorded so the pattern is searchable): two gates —
`tests/truthfulness_check.sh` and `scripts/typecheck-proofs.sh` — looped over
the deleted tree, matched zero files, and exited 0 reporting success. Both now
fail hard on an empty subject. *A gate that cannot fail is worse than no gate,
because it is credited as assurance.*

---

## Code — D

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| D-1 | MEDIUM | Justfile recipes still operate on the deleted tree; `CART_COUNT=$(ls -d cartridges/*-mcp \| wc -l)` now reports 0 as though that were a fact about the system. | `grep -n 'cartridges/' Justfile` |
| D-2 | MEDIUM | `scripts/refresh-bundled-cartridges.sh` exists solely to sync the retired tree (it `rm -rf`s inside it). `scripts/boj-selinux-contexts.sh` labels `${BOJ_ROOT}/cartridges/`. | `grep -ln 'cartridges/' scripts/*.sh` |
| D-3 | MEDIUM | `mcp-bridge/lib/generate-offline-menu.js` falls back to `../../cartridges` when `BOJ_CARTRIDGES_PATH` is unset — so it regenerates an **empty menu** silently instead of failing. | `grep -n 'cartridges' mcp-bridge/lib/generate-offline-menu.js` |
| D-4 | MEDIUM | Test scripts still traverse the tree: `tests/aspect_tests.sh`, `tests/integration.sh`, `tests/federation_multinode.sh`. | `grep -ln 'cartridges/' tests/*.sh` |
| D-5 | MEDIUM | **Two git worktrees are committed as gitlinks (mode `160000`) with no `.gitmodules`.** A fresh clone gets two empty directories, and both show as permanently modified because neither matches its recorded commit. | `git ls-files -s .claude/worktrees/` · `ls .gitmodules` |
| D-8 | HIGH | **`container/Containerfile.fly:80` cannot build.** It does `COPY cartridges/ /tmp/carts-meta/` from the host build context and never runs `fetch-cartridges.sh`; `COPY` on a missing source is a hard failure. (The main `container/Containerfile` is **fine** — it fetches into the builder stage first, so its `COPY --from=zig-builder` is populated. One file, not both.) | `grep -n 'COPY cartridges/' container/Containerfile.fly` · `grep -c fetch-cartridges container/Containerfile.fly` → 0 |
| D-9 | MEDIUM | More empty-set loops outside the fixed set: `stapeln.toml:44` iterates `cartridges/*/ffi` **and** suffixes `\|\| true`, so it can never fail; `coord-tui/install.sh:28` builds from a path that no longer exists; `guix.scm:34` chdirs into it; `elixir/test/js_worker_pool_test.exs:6` resolves a missing module but passes today by short-circuiting when Deno is absent. | `git grep -n 'cartridges/\*' stapeln.toml guix.scm coord-tui/install.sh` |
| D-7 | LOW | Dead exemption entries left behind by the retirement: 9 in `.hypatia-ignore`, 5 in `.gitleaksignore`, plus `.dockerignore` headers still claiming "Stage 3 needs `cartridges/`". Harmless, but they make the allowlists look larger than the real exposure. | `grep -c cartridges .hypatia-ignore .gitleaksignore` |
| D-6 | LOW | Machine-specific absolute paths baked into tracked files: `generated/alloyiser/run-analysis.sh` (`/var/mnt/eclipse/...`), `reports/maintenance/latest.json`. Unrunnable off the original machine. | `git grep -n '/var/mnt/eclipse'` |
| D-10 | LOW | TODO/FIXME/XXX/HACK density is genuinely near zero — all 63 matches are policy/tooling references to marker *scanning*, not markers. Recorded as a positive control. | `git grep -nE '\b(TODO\|FIXME\|XXX\|HACK)\b' \| wc -l` |

---

## Test — T

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| T-1 | MEDIUM | `tests/security_test.js` (313 lines) and `tests/federation_multinode.sh` (170 lines) are referenced by **no workflow and no Justfile recipe**. They exist and run nowhere. | `grep -rn 'security_test\|federation_multinode' .github/ Justfile` |
| T-2 | MEDIUM | A real `zig build test` invocation inside `lsp-dap-bsp.yml` is permanently unreachable behind C-2's hardcoded `run=false`. | `grep -n 'zig build test' .github/workflows/lsp-dap-bsp.yml` |
| T-3 | LOW | `TEST-NEEDS.md` documents that E2E tests skip cleanly when Deno is absent — a documented silent coverage reduction. | `grep -n 'Deno-gated' TEST-NEEDS.md` |

---

## Documentation — X

Full findings live in the docs refresh; only structural items are indexed here.

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| X-1 | HIGH | **Cartridge counts disagree across the estate.** This repo asserts 125 in ~14 places; the registry's README asserts 139; disk says **142**. `README.md`'s own "Number transparency" clause makes this self-refuting. | `find ../boj-server-cartridges/cartridges -name cartridge.json \| wc -l` |
| X-2 | MEDIUM | `docs/AI-CONVENTIONS.adoc` opens agent onboarding by directing every AI agent to read three files that **do not exist** (`.machine_readable/STATE.a2ml`, `anchors/ANCHOR.a2ml`, `AGENTIC.a2ml`). | `ls .machine_readable/STATE.a2ml .machine_readable/AGENTIC.a2ml` |
| X-3 | MEDIUM | `docs/zig-ffi-verification.adoc` documents a Mutex migration **backwards** — it recommends `std.atomic.Mutex`, the symbol 0.16 removed, and names nine modules that use no such pattern. | `grep -n 'atomic.Mutex' docs/zig-ffi-verification.adoc` |
| X-4 | MEDIUM | `docs/wikis/` (7 `.adoc`) and the live GitHub wiki (6 `.md`) are **different page sets with no sync mechanism**, while `docs/wikis/README.adoc` claims to be "the sources for GitHub's wiki tab". | `git clone https://github.com/hyperpolymath/boj-server.wiki.git` |
| X-5 | MEDIUM | `CHANGELOG.md` has no `[0.5.0]` section though `package.json` says 0.5.0, and its `[Unreleased]` heading sits *below* the last release. 151 commits since the last dated entry, including two CWE-tagged security fixes. | `git log --oneline --since=2026-05-20 \| wc -l` |
| X-6 | LOW | `jsr.json` still says `0.4.7` while `package.json` says `0.5.0`. | `grep -h '"version"' package.json jsr.json` |

---

## Supply chain — S

| ID | Sev | Item | Evidence |
|----|-----|------|----------|
| S-1 | HIGH | See **C-3** — 27 mutable `@main` action pins in an untracked, permission-less workflow is the repo's largest supply-chain exposure. | `grep -c '@main' .github/workflows/main-estate-audit.yml` |
| S-2 | MEDIUM | 1,346 files of build residue survive under `cartridges/` on disk (226 `.so`), untracked and gitignored so `git status` stays silent about them. Confirmed: **no `.so` post-dates the retirement**, so nothing has been rebuilt there since — it is stale, not live. **DIAGNOSIS (unconfirmed):** a `local-coord-mcp.service` user unit was historically built from this tree and may still point at it; deletion is the owner's call. | `find cartridges -type f \| wc -l` · `find cartridges -name '*.so' -newermt 2026-08-03 \| wc -l` → 0 |
| S-3 | LOW | Release provenance is SLSA3 via `slsa-github-generator`, SHA-pinned. Recorded as a positive control. | `grep -n 'slsa' .github/workflows/release.yml` |

---

## How to use this file

Add an item when you find debt you are not fixing in the same change. Give it
the next ID in its domain, a severity, and — non-negotiably — **a command that
reproduces the evidence**. An item without a reproducible check is an opinion,
and opinions rot silently. Remove an item only when its command proves it gone;
where the fix is interesting, keep the row and mark it FIXED with the date, as
P-4 and the C-section note do.
