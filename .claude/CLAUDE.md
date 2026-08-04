<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# CLAUDE.md - AI Assistant Instructions

## Machine-Readable Artefacts

This repo follows the hyperpolymath standard. See `https://github.com/hyperpolymath/standards` for the canonical 6-file `.machine_readable/` layout (STATE/META/ECOSYSTEM/AGENTIC/NEUROSYM/PLAYBOOK in A2ML format).

---

## Language Policy (Hyperpolymath Standard)

The full policy is canonical in `hyperpolymath/standards`. Key points relevant to this repo:

- **No new TypeScript** — convert existing TS to AffineScript (`.affine`) directly; ReScript is no longer the destination as of 2026-04-30.
- **Deno** for the runtime, not Node. `deno.json` for imports, no `node_modules` in production.
- **AffineScript** for new application code. Compiles to typed-wasm.

### TypeScript Exemptions (Approved)

The former 6 exemptions (MCP cartridge adapters under `cartridges/*/adapter/mod.ts`) left this repo with the bundled `cartridges/` tree — the cartridges and their adapter exemptions now live in `boj-server-cartridges` (see its CLAUDE.md exemption table). No TS exemptions remain in this repo; adding one requires explicit user approval and an unblock condition. Audit lineage: TS-elimination audit, 2026-05-02.

### Documentation Format

- All docs `.adoc` (AsciiDoc) except GitHub-required files (SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md).

---

## ABI / FFI / Adapter Baseline (verified 2026-07-17)

Every cartridge's interface stack is three layers, in these languages, no
exceptions:

| Layer | Language | Role |
|---|---|---|
| **ABI** | **Idris2** | Formally verified contract — dependent-type proofs, state machine or exposure-gate invariants, `%default total`, zero `believe_me`/`postulate`/`assert_total` in the trusted core. |
| **FFI** | **Zig** | C-ABI implementation (ADR-0006 five-symbol pattern: `boj_cartridge_{init,deinit,name,version,invoke}`). |
| **Adapter** | **Zig** | The base-level API/service surface — see below. |

### The "unified adapter"

The current canonical shape (see
`cartridges/domains/config/k9iser-mcp/adapter/` in `boj-server-cartridges` for
the reference implementation, or `cartridges/templates/gossamer-mcp/adapter/`
there for the minting template): **one loopback listener**,
protocol-classified (REST `/invoke`, SSE `/sse`, GraphQL `/graphql`, gRPC-compat
`/grpc/<Svc>/<Method>`), that funnels every request through a **transaction
gate** (`exposureSatisfied`, mirroring the cartridge's own Idris2 exposure
contract when it has one) before a single dispatch call into the one Zig ABI
(`ffi.boj_cartridge_invoke`). Invariants (from the adapter READMEs, verbatim):

- **Stateless** — all state lives behind the FFI, never in the adapter.
- **Response passthrough** — whatever the FFI returns goes back to the wire
  unmodified (no embellishment, no silent recovery).
- **`cartridge.json` is source of truth** for the tool catalogue; drift between
  adapter and manifest is a CI failure.
- **Internal-only, never a public ingress.** Per ADR-0004 the only governed
  public surface is the `http-capability-gateway` (tier-2) in front of the
  unified Zig core; adapters bind loopback and sit behind it.

Naming lineage: the fuller 16-protocol-surface pattern is called the
**Hexadeca-Connector** elsewhere in the estate (`hyperpolymath/hypatia`,
`hyperpolymath/proven-servers`) — same Idris2-ABI + Zig-FFI substrate, more
protocol surfaces. It descends from a now-**retired** V-lang reference
(`developer-ecosystem/v-ecosystem/v_api_interfaces/v_api_interfaces.v`),
replaced across the estate by Zig+Idris2(+Rust-client where relevant) per the
V-lang ban (2026-04-10). Cartridge `adapter/` dirs keep a `SIDELINED-*.v.adoc`
note documenting what was replaced — never resurrect the V version, and never
substitute anything but Zig for a new adapter.

---

## PR Workflow

This repo squash-merges PRs. Two consequences worth knowing before pushing follow-ups:

- **Don't pile follow-up commits onto a branch whose PR is in review.** When the PR is squash-merged, `main` gets a new commit with a new SHA. Any commits you pushed after the PR was opened are still on the feature branch, on top of a base that no longer matches `main`. GitHub will then mark the PR as `mergeable_state: "blocked"` and any rebase will produce ghost-conflicts — the conflicting hunks are the *same content*, but git can't tell because the SHAs differ. If you have follow-up work, open it as a new PR off the current `main`.
- **After a squash-merge, delete the feature branch.** It contains pre-squash commits with stale SHAs; reusing it for new work re-creates the ghost-conflict problem. `git checkout main && git pull && git branch -D <branch> && git push origin --delete <branch>`.

Diagnostic: if a PR shows `blocked` and `git diff origin/main HEAD` is empty, the PR's content is already on main via squash-merge — close the PR rather than trying to merge it.

---

## CI / Required Status Checks

Never put `on.*.paths` on a workflow that is a **required** status check. A path-filtered required workflow that doesn't trigger is reported as permanently "Expected", which leaves the PR `mergeable_state: blocked` even when everything else is green (this stranded #213/#215 until #216).

Pattern for every required gate:

- **No `on.*.paths`** — the workflow always triggers, so the required check is always created.
- A lightweight always-run **`changes`** job recomputes the gate's relevant path set via `git diff origin/<base>...HEAD`.
- Each heavy job carries `needs: changes` + `if: needs.changes.outputs.run == 'true'`. A job skipped via `if:` counts as a **passing** required check, so unrelated PRs aren't blocked and don't pay for the heavy work.
- **Fail safe:** the detector defaults to `run=true` and only skips on a successful diff showing nothing relevant changed. Don't rename jobs/checks (breaks the required-context list).

Full rationale: `docs/AI-CONVENTIONS.adoc` §"CI / Required Status Checks" and the `docs/wikis/CI-and-Required-Checks.adoc` wiki page.
