<!--
SPDX-License-Identifier: MPL-2.0
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

The "no new TypeScript" rule has 6 approved exemptions in this repo — all MCP cartridge adapters. The MCP SDK (`@anthropic/sdk`) is TypeScript-native, and the adapters are JSON-RPC-over-stdio glue. Until AffineScript has bindings to the MCP protocol, these adapters must remain TS.

| Path | Files | Rationale | Unblock condition |
|---|---|---|---|
| `cartridges/{academic-workflow,bofig,ephapax,fireflag,hesiod,sanctify}-mcp/adapter/mod.ts` | 6 | MCP cartridge adapters using `@anthropic/sdk`. The SDK is TS-native; equivalent functionality requires AffineScript bindings to MCP, which don't exist yet. | AffineScript MCP bindings (no scheduled issue — file under `affinescript` when scope is decided). |

Adding to this list requires explicit user approval and an unblock condition. Audit lineage: TS-elimination audit, 2026-05-02. Mirror tables in `affinescript`, `standards`, and `my-lang` repos.

### Documentation Format

- All docs `.adoc` (AsciiDoc) except GitHub-required files (SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md).

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
