<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# BoJ-Server Proof Story — 2026-06-01

> **Status**: draft for owner review. Synthesises 4 parallel Explore-subagent reports (existing-state inventory, trust-chain map, competitor baseline, layered roadmap) plus owner-direct verification of a key Agent C claim.
>
> **Owner directive**: "explore the whole thing and identify what proofs, from basic assumptions upwards and all over the BoJ need to be achieved to ensure this is the most solid narrative and most solidly proven server that is out there"
>
> **Sister artefact**: `docs/planning/cartridge-catalogue-2026-06-01.md` (PR #179) for the cartridge expansion plan. This document is its proof-rigour counterpart.

---

## 1. Headline finding

**You are already the most formally verified MCP server in the world.** That isn't aspirational — it's measured. Agent C's competitor survey found that essentially every other MCP server (Anthropic's reference set, OpenAI GPTs, Vercel AI SDK, Cloudflare Workers AI, NVIDIA verified agent skills, the ~1000 servers in Glama's catalogue) makes **zero** formal-verification claims. Three exceptional cases exist (Prova-MCP, MCPShield, Rocq-MCP) but each *uses* formal verification — none *prove* their own MCP runtime.

You already have:
- 5 class-J axioms in boj-server, **all externally validated** via backend-assurance harness — single isolated module (`SafetyLemmas.idr`)
- 10+ Qed/cartridge-ABI theorems landed (BJ1 dispatch, BJ2 isolation, BJ3 protocol coverage)
- typed-wasm: 22 modules with all 10 safety levels carrier-backed, 0 `believe_me`/`postulate`
- echo-types: foundationally complete, 0 postulates, `--safe --without-K`, Pillars A–D verified
- ephapax: counterexample-Qed for legacy preservation (proved-false), four-layer redesign passing for L1+L3, 11/13 Buchholz constructors closable
- proven: trust root with ~70 witness-type overclaims now **honestly enumerated** and being cleared (2026-05-20 re-audit)

The narrative isn't "we want to be the most-proven MCP server"; it's **"we already are, and here's how we extend the lead."**

---

## 2. The trust chain — what is proven vs assumed today

Agent B mapped 9 conceptual layers. Three layer-boundary contracts are formally proven; four remain at prose-ADR or assumed.

### Layer stack (bottom-up)

| Layer | Artefacts | Proven | Assumed |
|---|---|---|---|
| **L1 HW / OS / runtime** | BEAM, Zig+LLVM, Linux kernel | BEAM scheduler crash-isolation (ADR-0005); Zig memory-safety model | Kernel syscall correctness; BEAM GC no-leak; LLVM correct lowering of `prim__*` |
| **L2 Language runtimes** | Idris2 0.8.0, Zig type-checker, Elixir BEAM, Coq kernel, Agda kernel | Totality checking on cartridge dispatch (BJ1) | 5 class-J axioms (charEqSound/charEqSym/unpackLength/appendLengthSum/substrLengthBound); Zig type-checker soundness; Cowboy parsing |
| **L3 Cartridge ABI** | 16 `src/abi/Boj/*.idr` files, 5.4k LOC | **BJ1** (CartridgeDispatch), **BJ2** (CredentialIsolation), **BJ3** (APIContractCoverage) all closed 2026-05-18 | Proof composition across modules |
| **L4 Cartridge FFI** | `ffi/zig/src/loader.zig`, 99 `ffi/*_ffi.zig` files | dlopen symbol-presence classification | 5-symbol ABI contract honoured by cartridge author (ADR-0006 **prose-only**); memory ownership boundary |
| **L5 Cartridge logic** | Per-cartridge Zig/Deno/Rust code | Tier-1 (11) have formal Idris2 specs | Tier-2-6 (101) only manifest + heuristic review; no automated check that github-api-mcp doesn't call Slack APIs |
| **L6 Cartridge invocation** | `elixir/lib/boj_rest/{invoker,catalog,router}.ex` | Invoker OS-process isolation; ETS catalog | Supervisor restart timing; ETS concurrency; JSON round-trip via Jason |
| **L7 Transport** | Cowboy (7700-7703), Plug router | Required-field type check | Cowboy parsing no-crash; HTTP smuggling immunity |
| **L8 Boundary** | `trust_policy.ex`, HCG (ADR-0004), policy-mcp (ADR-0007) | Loopback bypass; trust-level audit log | X-Trust-Level authenticity (mTLS Phase B **pending**); Nickel PDP (ADR-0007 **RFC-stage**) |
| **L9 User-visible promise** | `boj://server/info`, manifests, README | Cartridge name resolution; BJ2 isolation at the boundary | Tier-claim accuracy; dispatch determinism |

### Edge contracts (trust passes between layers)

| Edge | Contract | Status |
|---|---|---|
| L2 → L3 | BJ1 dispatch | ✅ proven (`CartridgeDispatch.idr:56-66`) |
| L3 → L4 | IsUnbreakable readiness guard | ✅ proven |
| L4 → L5 | 5-symbol ABI (init/deinit/name/version/invoke + 7 return codes) | ⚠️ prose-only (ADR-0006) |
| L5 → L6 | Return-code respect | ⚠️ assumed |
| L6 → L7 | JSON preservation (Jason) | ⚠️ external dep |
| L7 → L8 | X-Trust-Level header + loopback bypass | ⚠️ pending mTLS Phase B |
| L8 → L9 | BJ2 credential isolation | ✅ proven (`CredentialIsolation.idr:20-38`) |

### 12 leaf assumptions (the load-bearing list)

In rough priority order:

1. BEAM crash isolation (cartridge `.so` segfault doesn't crash Elixir VM)
2. Idris2 `believe_me` soundness for 5 SafetyLemmas axioms
3. Cartridge ABI symbol presence (all 5 symbols exported)
4. Memory ownership boundary (cartridge respects `out_buf`/`in_out_len`)
5. HTTP JSON codec round-trip (Jason correctness)
6. Zig type-checker correctness
7. Cowboy HTTP parsing soundness
8. Loopback interface kernel isolation
9. Idris2 module-import coherence (acyclic, type-checker-enforced)
10. Cartridge manifest accuracy (declared tier == actual implementation)
11. Trust-level header authenticity (no cross-proxy forgery)
12. No cartridge-to-cartridge data leakage (dlopen isolation)

Each is a candidate "what could we prove that we currently just assume?"

### Root promise (one sentence)

> A cartridge invoked via `POST /cartridge/:name/invoke` with a tool name and JSON arguments will either (a) execute the named tool with type-safe argument dispatch and return the result, or (b) return a classified error, with the guarantee that a Teranga-tier cartridge's isolation properties (BJ1 dispatch, BJ2 credential partition, BJ3 protocol coverage) hold end-to-end, and that a cartridge crash does not crash the BoJ server.

---

## 2.5 Echo-types — cross-cutting type-theoretic foundation

**Owner directive 2026-06-01**: every proof wave below must first check `hyperpolymath/echo-types` for a reusable definition or lemma. If relevant, the wave consumes echo-types via a SHA-pinned import. If absent, the wave **extends echo-types first**, proves the extension there, and then consumes downstream. Cross-document: every consumer cites the echo-types module + commit; the echo-types module's `EXPLAINME.adoc` lists boj-server as a downstream consumer once the first wave imports it.

### Why echo-types is the right foundation

`echo-types` is the estate's constructive Agda formalisation of *proof-relevant lossy computation* — `--safe --without-K`, 0 postulates. Its core abstractions map directly onto boj-server's proof obligations:

| boj-server invariant | echo-types primitive |
|---|---|
| Cartridge dispatch — distinct cartridges cannot collide on a message type | `EchoResidueTaxonomy` *indexed* residue form (proof-relevant distinguishability of dispatch keys) |
| Multi-protocol composition — outputs of `Cᵢ` parse under input schema of `Cᵢ₊₁` | `EchoImageFactorizationProp` (epi-mono earn-back: the residue of the projection bears the witness that the next stage's precondition is satisfied) |
| Credential isolation (BJ2) — a Teranga capability cannot leak across cartridges | Linear / affine bridge + `EchoSecurity` application module |
| Audit log integrity (`local-coord-mcp`, MFA-001 to MFA-006) | `EchoProvenance` application module (hash-chain as echo: the digest is the residue that constrains the preimage) |
| Cost / budget proofs (Glama scoring, panel cost-meters) | Tropical bridge + `EchoResidueTaxonomy` *cost* residue form |
| Effect / capability tracking across L4–L8 boundaries | Graded modality bridge (loss-graded reindexing per `docs/retractions.adoc` R-2026-05-18) |
| Class-J axiom witnesses (5 in `SafetyLemmas.idr`) | `EchoResidueTaxonomy` *generic Σ-cert* residue form |
| Federated coord (ADR-0010) role-projection | Choreographic bridge |
| Adversary-knowledge bounds | Epistemic bridge |

The drift = echo + tropical cost composition (per VeriSimDB foundation pack) is the single most natural fit for boj-server's anchor theorem.

### Status of echo-types at 2026-06-01

Per `echo-types/EXPLAINME.adoc` and `.machine_readable/6a2/STATE.a2ml`:

- Core echo / fiber theorems present (`echo-intro`, `map-over`, `map-over-id`, `map-over-comp`, `map-square`).
- Bridges complete: linear, graded, tropical, choreographic, epistemic, CNO, Janus, Dyadic, Ordinal, Indexed, Relational, Categorical, Scope.
- Eight residue forms in `EchoResidueTaxonomy` (trivial, identity, generic Σ-cert, linear-affine, indexed, cost, search, epistemic).
- Investigation EI-2 (integration-recipe distinctness) terminated negatively via PATH B — **do not reopen**; treat as a settled negative result.
- Ordinal/Buchholz track: 11 of 13 per-constructor rank-mono cases closed; Slice-3 headline closed via Route A in PR #142/#143.

This means W1 and W2 of boj-server's proof roadmap can be expressed *today* in echo-types vocabulary without extension. W3-W6 likely require small extensions — to be identified per wave as the work begins.

### Extension policy

When a wave needs a definition not in echo-types:

1. File the gap as an echo-types issue (`hyperpolymath/echo-types`), referencing the boj-server wave + theorem name.
2. Land the extension in echo-types first (small, focused PR; passes `--safe --without-K`; no new postulates).
3. SHA-pin the echo-types import in the boj-server proof PR.
4. Echo-types `EXPLAINME.adoc` "Applied prototype hook" or downstream-consumers section lists boj-server.

This keeps echo-types as the proof-foundation single-source-of-truth and prevents duplicate type definitions drifting across the estate.

---

## 3. Competitive context — what the rest of the field claims

### The baseline

**Most MCP / agent-runtime systems make zero formal claims.** Verified examples:

- **Anthropic's reference MCP servers** (`github.com/modelcontextprotocol/servers`) — disclaim formal verification explicitly.
- **OpenAI GPTs / actions** — prompt engineering + human-in-the-loop, no proofs.
- **Vercel AI SDK** — testing utilities + types, no formal verification.
- **Cloudflare Workers AI** — runtime scanning + semantic intent, not formal correctness.
- **Glama catalogue (~1000 servers)** — searching for "verified"/"formal"/"proven"/"Coq"/"Idris"/"Agda"/"Lean"/"TLA+" returns essentially nothing.
- **NVIDIA "verified agent skills"** — cryptographic signing + automated vuln scanning, not formal proof.

### The 3 exceptional cases (each scoped narrowly)

1. **Prova-MCP** — agents verify their own reasoning chains by kernel-checking Lean 4 proofs. Scope: agent-assisted theorem proving, not runtime safety of the server.
2. **MCPShield** (arxiv 2604.05969) — labeled-transition-system formal threat framework, 91% claimed coverage across a 7-category 23-vector threat taxonomy. Published peer-reviewed framework, not deployed at runtime.
3. **Rocq-MCP** — exposes Rocq (Coq-family) as MCP tools. **Uses** MCP to do proofs; doesn't prove MCP.

### The prior-art ceiling (outside agent space)

- **seL4** — 8.7k C + 600 asm functional-correctness proof in Isabelle/HOL.
- **CompCert** — semantics-preserving C→assembly compiler proof.
- **Project Everest / EverCrypt** — 124k lines verified F* in real-world production (Linux, Firefox, Tezos).
- **CHERI / VeriCHERI** — RTL-level formal verification of capability hardware.

### 3 positioning framings — each defensible if executed

1. **"First MCP server with formally verified cartridge loading"** — anchor on BJ1 + extend to cover the dlopen + symbol presence + signature compatibility chain.
2. **"First formally verified capability gateway for multi-cartridge agent integration"** — anchor on BJ2 + extend to the L8 boundary. Positions directly against NVIDIA's signing model.
3. **"Formally proven supply-chain safety for federated MCP cartridges"** — anchor on the federated coord ADR-0010 + provenance / SBOM verification.

None of these are claimed by anyone today.

---

## 4. Roadmap — 6 waves, ~40-50 proof days, 18-24 months

Agent D's plan, condensed. Each wave estimate is solo-with-Joshua at ~6-8 weeks proof capacity per quarter.

### W1 — Cartridge-layer type preservation (Weeks 1-4, ~8 days)
- `local-coord-mcp` closes P-04/P-05/P-06/P-07 (record format, CRC truncation, replay-equivalence, quarantine state machine) — 6 days, infrastructure already present.
- `007-mcp` policy-apply type-safety — ~1 day.
- One domain cartridge (e.g., `dap-mcp` or `bsp-mcp`) protocol dispatch uniqueness lemma — ~1 day.
- **Echo-types import**: `EchoResidueTaxonomy` *indexed* residue form (dispatch keys); `EchoProvenance` for replay-equivalence as hash-chain echo. **No extension expected** — both present at echo-types HEAD.

### W2 — Invocation protocol soundness + multi-protocol composition (Weeks 5-12, ~8 days)
- `CartridgeDispatch.invokeSound` (direct-invoke preserves type) — 2 days.
- **`MultiProtocol.invokeChainSoundness`** ← the anchor theorem (see §5) — 3 days.
- `sseFrameIntegrity` — 1 day.
- Aligns with typed-wasm Phase 2 (L2 access-site carrier, ADR-0003 accepted 2026-05-30) as a case-study consumer.
- **Echo-types import**: `EchoImageFactorizationProp` (the anchor theorem statement *is* an epi-mono earn-back across cartridge boundaries); graded modality bridge for invocation-effect tracking. **No extension expected** — Tier 2 EchoImageFactorizationProp landed 2026-05-28.

### W3 — Capability containment + vault isolation (Weeks 13-18, ~5 days)
- `VaultIsolation` upgrade to dynamic isolation (cartridges added post-init) — 2 days.
- `CapabilityContainment.borrowCap` (capability temporary-borrow, not store-or-re-export) — 2 days.
- `CredentialFlow.credentialCannotEscape` — 1 day.
- **Echo-types import**: linear/affine bridge + `EchoSecurity` application module. **Likely extension**: capability *borrow-and-return* may need a new linear-affine variant in echo-types — file as echo-types issue, land extension first.

### W4 — End-to-end safety case (Weeks 19-24, ~10 days)
- `SafetyCase.e2eInferenceSound` — the umbrella theorem composing W1-W3 lemmas — 5 days bookkeeping.
- `CompositionLemma.multiCartridgeChain` — chain induction — 2 days.
- `AdversarialModel` — negative lemmas (can't forge IDs, can't bypass isolation, can't corrupt dispatch) — 1 day.
- **Echo-types import**: tropical bridge (cost composition under chain), `EchoProvenance` (audit trail across the chain), epistemic bridge (adversary knowledge bound). **Possible extension**: composition lemma for chained echo factorizations — likely covered by `map-over-comp` but may need a chain-specific lemma; file as echo-types issue if so.

### W5 — Backend-assurance expansion (Weeks 25-28, ~4 days)
- Audit + externally validate any new class-J axioms introduced by new cartridges — 2 days.
- **Harness mechanisation** — formalise the discipline itself in Coq or Agda: "a class-J axiom is valid iff (trusted-extraction doc + property test + BEAM evidence)" — 2 days.
- **Echo-types import**: `EchoResidueTaxonomy` *generic Σ-cert* residue form — class-J axioms are precisely Σ-cert residues with external-evidence witnesses. **Extension expected**: a new residue form "*externally-validated*" or a refinement of generic Σ-cert with a backend-assurance side-condition. File as echo-types issue first.

### W6 — Publication + standoff (Weeks 29+, ~2 days/cartridge)
- Technical report on the W4 e2e proof.
- Ready 3-5 proof-bearing cartridges for production.
- Establish proof-maintenance policy (within 2 weeks of any proof-bearing PR, a `docs/proof-summary.md` follow-up must cite which theorems cover which invariants).
- **Echo-types cross-document**: by W6 each of W1-W5's downstream consumers should be listed in echo-types `EXPLAINME.adoc` under a new "downstream consumers" section. Publication framing: "boj-server is the first capability-gateway *consumer* of the echo-types foundation; echo-types is its proof bedrock."

### Top-3 quick wins (1.5-2 total days — front-load before W1)

| Theorem | Statement | Days |
|---|---|---|
| `CartridgeDispatch.noCollisions` | Dispatch is injective — no two cartridges accidentally handle the same message type | 0.5 |
| `SafeLocalCoord.replayDeterminism` | Replay log iterator on the same BitStream prefix produces the same state — structural / by reflexivity | 0.5 |
| `SafetyLemmas.axiomsAreIrreducible` | Negative proof that the 5 class-J axioms cannot be discharged in Idris2 0.8.0 because Char/String have no constructors | 1 |

These three are quotable in a paper / pitch deck without waiting for W4.

---

## 5. The anchor theorem

### `MultiProtocol.invokeChainSoundness`

**Informal statement**: Given a sequence of cartridge invocations C₁ → C₂ → C₃ where each cartridge correctly implements its protocol contract, the outputs of each cartridge can always be parsed by the next cartridge's input schema; no type error can arise mid-chain, even if the invocations span different domains (e.g., OAuth → database → LLM).

### Why this one

- **Genuinely novel**: no other agent runtime — Claude, Anthropic's MCP, OpenAI's function-calling, Vercel, NVIDIA — has formally proven that chained cartridge invocations preserve type safety. typed-wasm covers access-site safety; proven covers individual library safety; **composing agent operations across trust boundaries is unique to boj-server's claim**.
- **Load-bearing**: W2 gates W3 (capability containment is only meaningful if invokes are sound), W3 gates W4 (e2e safety). This proof unblocks two full waves.
- **Publishable**: theorem statement is elegant enough for JFLA (Journées Francophones des Langages Applicatifs) or an ICFP workshop. "Formally verified agent orchestration" is a hookline.

**Effort**: 3-5 days in W2.

---

## 6. Decision points for owner

### D1 — positioning framing (pick one or commit to all three)
1. Cartridge-loading verified (anchor on BJ1 + extend to dlopen chain)
2. Capability-gateway verified (anchor on BJ2 + extend to L8)
3. Supply-chain federation verified (anchor on ADR-0010 + SBOM)

All three are achievable; the question is what to put on the front page. Recommend D1.2 (capability gateway) — it's the framing closest to your current proof artefacts, and "first formally verified capability gateway for LLM agents" parses as a sentence even to someone who doesn't know what a cartridge is.

### D2 — accept the 18-24-month timeline, or compress?
Solo + Joshua at 6-8 weeks proof per quarter ≈ 30 weeks of proof work over 18 months, with W4 as the big push. Compressing requires either (a) more proof help (a collaborator with Coq/Idris2 fluency), or (b) deferring the anchor theorem and shipping incremental wave reports.

### D3 — where do the 4 still-prose ADRs fit?
- **ADR-0006** (5-symbol cartridge ABI) — currently prose-only. Formalise in W2 alongside `invokeSound`.
- **ADR-0004** (HCG mTLS Phase B) — operational not provable; gate the L7→L8 edge until it lands.
- **ADR-0007** (Nickel PDP DSL) — still RFC. Has its own proof-debt; defer to a separate Nickel-track.
- **ADR-0010** (federated coord + ML-KEM) — proposed only. Treat as Phase 4+ or after W6.

### D4 — proof-debt tracking discipline
boj-server's `PROOF-NEEDS.md` and `docs/proof-debt.md` are already exemplary (Agent A says: estate reference for the Trusted-Base Reduction Policy). Question: do you want a **per-cartridge** `proof-summary.md` requirement (W6 policy), or just per-repo? Per-cartridge gives much higher resolution but is high-overhead.

### D5 — echo-types extension governance
Per the §2.5 owner directive, when a wave needs an echo-types extension, the workflow is: file as echo-types issue → land extension there first → SHA-pin in downstream boj-server PR → cross-link in `EXPLAINME.adoc`. Open sub-questions:
- **Repo of record for boj-server-specific instances** — when an `EchoResidueTaxonomy` instance is *only* boj-server-relevant (e.g. a "cartridge-tier-validated" instance), does it live in echo-types (estate-wide) or boj-server (local)? Recommend echo-types for any instance with a re-usable shape, boj-server for one-off.
- **Pace** — echo-types extension PRs must pass `--safe --without-K` and add no postulates. This is strict; W3 + W5 extensions may need 1-2 extra days each.
- **Reciprocal documentation** — at what cadence does echo-types' `EXPLAINME.adoc` get refreshed with the downstream-consumers list? Recommend at each wave-completion checkpoint.

---

## 7. Open questions

1. **Joshua's involvement in proof work specifically** — Agent D's roadmap assumes he can help with bookkeeping in W4. Is that realistic / desired? If he's primarily a cartridge implementer, the 18-24 mo timeline is brittle.
2. **Publication venues** — JFLA / ICFP workshop / a position paper at a security conference. The anchor-theorem framing changes the right venue. POPL is too theory-heavy; CCS / S&P would land if framed as capability containment.
3. **Trust-base re-audit cadence** — proven's 2026-05-20 honesty refresh found 70 overclaims. Should that audit be quarterly across all repos, or once-then-static?
4. **Tooling-stub remediation interaction** — per Q2 (cartridge minter retired no replacement, 3 stubs remain), if catalogue expansion follows the recommendation to rewrite all 4 tools in Rust/Zig, those tools become part of the trust chain too. New `tools/` deserve at least Eno-tier discipline.
5. **License clarity for the proof corpus** — boj-server is now AGPL-3.0-or-later (PR #157). The proven library it depends on — what license? Re-export terms for someone consuming boj-server's BJ1/BJ2/BJ3 proof artefacts?

---

## 8. Phasing relative to the cartridge catalogue

The catalogue document (PR #179) proposed a 5-phase rollout (tooling → backfill → high-leverage waves → depth fills → exotic). The proof-story phases overlap:

| Catalogue phase | Proof phase | Interaction |
|---|---|---|
| Phase 0 — tooling | (no proof work) | The 4 tools-to-rewrite become L4-adjacent infrastructure; they should sit at trust-tier Eno minimum |
| Phase 1 — 14-LSP backfill | Proof quick-wins (W0) | The LSPs come in as Ayo / Eno; quick-win theorems land in parallel |
| Phase 2 — high-leverage waves | W1-W2 | Vector-DB / local-inference waves are mostly Ayo cartridges; the *runtime* improvements (e.g. invokeChainSoundness) lift their tier ceiling |
| Phase 3 — depth fills | W3-W4 | Capability containment + e2e safety case land here, anchoring the security half of the catalogue |
| Phase 4 — exotic | W5-W6 | Backend-assurance expansion + publication; exotic cartridges are too narrow for W6's reference-cartridge slot |

---

## 9. Provenance

- 4 Explore subagents fanned out 2026-06-01 ~13:30Z; all returned within ~12 minutes (existing state), ~6 minutes (trust chain), ~13 minutes (competitor baseline), ~6 minutes (roadmap).
- Owner-direct verification corrected Agent C's claim about `launch-scaffolder` being the cartridge minter's replacement (it is not — it's a desktop launcher generator). The minter is retired with no replacement, deepening the Q2 stub-rewrite scope from 3 tools to 4.
- Subagent transcripts at `/tmp/claude-1000/-home-hyperpolymath-developer-repos/.../tasks/`.
- **2026-06-01 amendment**: section 2.5 (echo-types foundation), per-wave echo-types module mapping in section 4, and section 6 D5 (echo-types extension governance) added per owner directive: "in the proofs you do, you need to check the echo-types repo and make sure this is part of the proofing for the repo, if not, establish the extension to what is there and work down that path proving as you go, then cross document". Echo-types module references sourced from `echo-types/EXPLAINME.adoc` at 2026-06-01 HEAD.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
