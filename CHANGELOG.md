<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# Changelog

All notable changes to Bundle of Joy Server are documented here.

## [0.4.7] — 2026-05-20

### Changed

- **README install section expanded** to cover every major MCP client: Claude Code,
  Claude Desktop, Gemini CLI, GitHub Copilot (VS Code), Cursor, Cline, Windsurf,
  Continue.dev, Zed, plus a generic stdio template. Copy-paste-ready snippets
  for each client's config-file path.
- **Runtime documentation corrected**: clone-and-configure path now lists Deno
  (preferred per CLAUDE.md policy), Bun, and Node as equally valid runtimes for
  `mcp-bridge/main.js`. Spurious `npm install` step removed — `package.json`
  declares zero runtime dependencies, so no install is ever required.

### Notes

- This is the release that publishes the **AAA-tier tool descriptions** to npm.
  The description rewrite landed in `25887157` / `ad837abe` after 0.4.1 but was
  never npm-published; downstream MCP clients (and Glama's quality scoring)
  were running 0.4.1 with the older one-liner descriptions. Republishing as
  0.4.7 ships the rich Purpose / Behavior / Returns / Errors / Usage text on
  every tool and the per-parameter `description` fields with patterns/enums.

## [Unreleased]

### Changed

- **Cowboy listener now binds to `127.0.0.1` by default** (was: all
  interfaces). Configurable via the `BOJ_BIND_IP` environment variable;
  invalid values fail-fast at boot rather than silently falling back to
  `0.0.0.0`. This is the code-enforced expression of the ADR-0004 §1
  invariant that BoJ's back-side bind is not externally routable in
  deployments fronted by `http-capability-gateway` (HCG tier-2). Phase E
  rollout-runbook §1.4 prerequisite #6. Legacy/standalone deployments
  that want all-interfaces exposure must now opt in explicitly
  (`BOJ_BIND_IP=0.0.0.0` or `BOJ_BIND_IP=::`). Refs
  [`hyperpolymath/standards#100`](https://github.com/hyperpolymath/standards/issues/100),
  [`#91`](https://github.com/hyperpolymath/standards/issues/91).

- **k8s Service for BoJ is now `type: ClusterIP`** (was: `LoadBalancer`).
  Per ADR-0004 §1 and the Phase E rollout-runbook §1.4 prereq #8, BoJ
  must not be externally addressable when fronted by
  `http-capability-gateway` (HCG tier-2). External clients reach HCG;
  HCG forwards to BoJ over the pod-network loopback. Legacy/standalone
  deployments that need BoJ exposed externally should override `type`
  in a kustomize/helm overlay rather than reverting the canonical
  manifest (see header comment in `k8s/service.yaml`). Adds
  `hyperpolymath.dev/exposure: "internal-only"` and
  `hyperpolymath.dev/external-via: "http-capability-gateway (tier-2)"`
  annotations so the posture is discoverable from `kubectl describe`.
  Refs
  [`hyperpolymath/standards#100`](https://github.com/hyperpolymath/standards/issues/100),
  [`#91`](https://github.com/hyperpolymath/standards/issues/91).

- **Container `APP_HOST` default is now `127.0.0.1`** (was: `"[::]"`
  IPv6 all-interfaces). Tightens three sites that feed the Zig adapter
  binary's `--host` flag: `stapeln.toml [targets.production]`,
  `container/entrypoint.sh`, and `container/compose.prod.yaml`. Same
  Phase E posture as the Cowboy bind change in the Elixir path: BoJ
  binds loopback by default when fronted by `http-capability-gateway`
  (HCG tier-2). Legacy/standalone deployments without HCG in front
  should override `APP_HOST=0.0.0.0` (IPv4 all-interfaces) or
  `APP_HOST=::` (IPv6 all-interfaces) in their deployment config.
  Phase E rollout-runbook §1.4 prereq #7. Refs
  [`hyperpolymath/standards#100`](https://github.com/hyperpolymath/standards/issues/100),
  [`#91`](https://github.com/hyperpolymath/standards/issues/91).

### Added

- **ADR-0014 — cross-cartridge composition safety (RFC)** — frames the
  unresolved research question that the per-cartridge ABI proofs do not
  compose automatically across `boj_cartridge_invoke`. Defines composition
  safety as a two-level contract: a static Idris2 envelope
  (`Boj.Composition.InvocationOf` lifting `IsUnbreakable` + `ProtocolMatch`
  + per-cartridge `ArgsContract` into the inter-cartridge call) and a
  dynamic Nickel `compositions` block in ADR-0007's `policy-mcp` PDP.
  First proof pair is `panic-attack-mcp → vordr-mcp` (both cartridges
  exist on disk); the prompt-suggested `panic-attack → sandbox → vordr`
  chain is parked behind ADR-0009's `sandbox-mcp` build-out.

- **README "Formal verification" section** — surfaces the audited posture
  outside `PROOF-NEEDS.md` so external readers can see, without digging,
  that all P1/P2 obligations are closed with constructive proofs and that
  the remaining `believe_me` invocations are *principled assumptions over
  Idris2 primitives*, not unproven debt.

- **Streamable HTTP transport (ADR-0013, PR1 of 2)** — MCP bridge now selects
  between stdio (default), `http`, and `both` via `BOJ_TRANSPORT`. HTTP
  endpoints: `POST /mcp` for JSON-RPC, `GET /mcp` for the server-initiated
  SSE notifications stream, `DELETE /mcp` for explicit session teardown,
  `GET /healthz` for liveness. Sessions are server-issued UUIDs in the
  `Mcp-Session-Id` header; the manager expires idle sessions after 30 min
  and fans events out across attached SSE streams. Auth: `none` (loopback
  only — refuses non-loopback binds) or `bearer` (token list via
  `BOJ_HTTP_AUTH_TOKENS`). The same `hardeningGate` runs on every request.
  Zero new deps — built on `Deno.serve` and `node:http`. mTLS / OIDC auth
  and the Cloudflare Workers / Durable-Objects shim are owed in PR2.
- **`boj://capabilities/deployment` resource** — reports per-deployment
  cartridge availability so clients can avoid invoking host-local-only
  cartridges (browser-mcp, container-mcp, local-coord-mcp, sandbox-mcp,
  ffmpeg-mcp) against a Worker / remote-HTTP deployment.
- **k9iser-mcp cartridge** — reference implementation of the `-iser`
  regeneration-cartridge pattern (central K9 contract regeneration), mirroring
  ssg-mcp: `cartridge.json`, `mod.js`, Idris2 ABI, Zig FFI, panels.
- **Unified transaction-gated adapter**: one internal/loopback listener,
  protocol-routed REST + SSE + GraphQL + gRPC-compat → single dispatch → one
  Zig ABI. Replaces the ssg-era 3-parallel-port anti-pattern; the trust gate
  runs before every dispatch, mirroring the Idris2 `exposureSatisfied`
  contract (no gatekeeperless path). Internal-only behind
  `http-capability-gateway` per ADR-0004.
- **boj-rest SSE surface**: `POST /cartridge/:name/sse` on the same single
  Cowboy listener and trust-gated dispatch, `text/event-stream`.

### Changed

- **Doc reconciliation to ADR-0004**: `elixir/README.adoc`,
  `mcp-bridge/api-clients.js`, and `OPERATOR-QUICKSTART.md` corrected to the
  verified runtime + ADR-0004 tiered model (they previously and wrongly
  described it as "skeleton/501/pending rewrite").

### Fixed

- **`Boj.SafeAPIKey.logSafeBounded` rebuilt for Idris2 0.8.0.** The pre-
  existing proof did not type-check on `main`; the 2026-05-18 audit's claim
  that `SafeAPIKey` carried constructive proofs closing BJ2-partial was a
  desk-read, not a build. Three independent defects: (1) removed the
  redundant local `plusLteMonotone` helper (called now-gone `lteTransitive`
  and used wrong arg order on `plusLteMonotoneRight`/`Left`; stdlib's
  `Data.Nat.plusLteMonotone` has exactly the needed shape); (2) lifted both
  short and long paths out of the `with`-block (the elaborator doesn't
  reduce `length "***"` at type level inside a `with`-block — goal stays
  as `LTE (integerToNat (prim__cast_IntInteger (prim__strLength (if ...))))
  11` with the `if`-arm unreduced); (3) right-associated the long-path
  proof to match `++`'s associativity (`a ++ b ++ c = a ++ (b ++ c)`).
  Plus two bound-name typos in `toLogSafeShortEq`/`toLogSafeLongEq`. All
  12 safety modules now build green via per-module `idris2 --check`. No
  new `believe_me` axioms.

- **`tests/aspect_tests.sh` grep-count bash bug.** `Aspect — Thread
  Safety + ABI Contract + SPDX` had been red on `main`, gating every PR
  with `tests/aspect_tests.sh: line 77: [[: 0\n0: syntax error in
  expression`. Root cause: `grep -c 'pattern' file 2>/dev/null || echo
  "0"`. `grep -c` always prints the count (including `0`) **and** exits
  non-zero on no-match, so `|| echo "0"` also fires — `has_export` ends
  up `"0\n0"` and `[[ "0\n0" -gt 0 ]]` chokes on the newline in
  arithmetic context. Swapped `|| echo "0"` → `|| true` on all four
  call-sites.

- **Honest framing of the ABI axiom count.** `src/abi/Boj/SafetyLemmas.idr`'s
  module docstring claimed "Three axiomatic `believe_me` primitives" while
  five live in the file. Docstring now enumerates all five and tags each to
  its underlying `prim__*` primitive. `appendLengthSum` and
  `substrLengthBound` also had `(x y : T)` multi-binder syntax that Idris2
  0.8.0 rejects at parse time — comma-separated form `(x, y : T)` restores
  parsability. Types and proof terms unchanged. The 2026-05-18
  `PROOF-NEEDS.md` audit (5 axioms, all class (J) — irreducible over Idris2
  primitives, principled assumptions not unproven debt) is now consistent
  with the source and surfaced via the new README "Formal verification"
  section.

- **`dogfood-gate.yml` failed YAML validation at startup** (0 s, no jobs) on
  every branch including `main`: an inline `python3 -c "` block placed Python
  source at column 1 inside a `run: |` block scalar, terminating the scalar
  early. Because **Dogfood Gate** is a required status check, this silently
  blocked every PR in the repo. The validator now lives in
  `.github/scripts/validate-eclexiaiser.py` and is invoked from the workflow.

> Verification (k9iser-mcp): Elixir suite 177/177 (incl. 2 SSE tests); Zig
> ffi 16/16 and unified adapter 5/5 (exposure-gate truth table mirroring the
> Idris2 contract); `idris2 --check K9iserMcp/SafeK9iser.idr` passes.
> http-capability-gateway production-wiring (ADR-0004 tier-2) and the
> iseriser-scaffold rollout remain out of scope and separately tracked.

## [0.4.0] — 2026-04-17

### Changed

- **V-lang banned estate-wide (2026-04-10)**: Adapter layer language policy updated.
  V-lang is no longer an accepted cartridge adapter language. Zig is the default
  replacement for the adapter tier (`ffi/zig/` remains; V adapter files were swept
  in commit c4674f8). Historical V-lang API interfaces have been moved to
  `developer-ecosystem/v-ecosystem/v-api-interfaces/v-<name>/` for potential
  donation to the V community — they are not HP infrastructure.
- **Cartridge manifests = Nickel** (prior closed decision `boj-cartridge-manifest-format-dd.md`):
  The authoritative cartridge manifest format is Nickel (`.ncl`). Current on-disk
  manifests are `cartridge.json`; migration to Nickel is tracked as future work
  (see open question in ADR-0002).
- **BoJ-only MCP rule** (standing estate policy): All MCP access to hyperpolymath
  services MUST route through BoJ. Standalone MCPs outside BoJ are not permitted.
  Added explicit citation in `docs/FEDERATION.md`.
- **Unified-zig-api stack alignment** (planned): BoJ will consume
  `developer-ecosystem/zig-api/` — the unified Idris2 ABI + Zig runtime + C adaptor
  + proven-backed path safety stack. `UNIFIED-ZIG-API-STACK.adoc` in
  `developer-ecosystem/` is the canonical reference. BoJ does **not yet** call
  `libzig_api` in code; alignment is tracked in ADR-0002 as future work.
  First estate consumers wired on 2026-04-17: lol-gateway (commits dbb475f/26b6b8c),
  aerie (e0b17f8), emergency-button/emergency-room (4bd070b),
  proven→zig-api path-safety wiring (6663956), gen-header CI drift check (0d6a814).
- **ADR-0002 added**: Documents the decision to align BoJ with the unified-zig-api
  stack, with explicit status of current V-lang adapter retirement and Zig migration.

## [0.3.0] — 2026-03-20

### Added
- Consolidated boj-server-mistral and boj-server-gemini into unified repo
- PanLL ReScript/TEA UI components (BojModel, BojEngine, Boj, BojModule)
- Gemini CLI extension support (gemini-extension.json, GEMINI.md)
- 9 architecture docs: Quantum Security, HSM Integration, Cartridge Marketplace,
  BoJ OS, Formal Verification, Type Safety, Zero Trust, SDP Architecture, Gossip Protocol
- Cartridge tools specification (Minter, Provisioner, Configurator, Panel Harness)
- Intentfile and Mustfile (contractile invariant declarations)
- Farm/fleet enrollment configs
- EXHIBIT-A (Ethical Use) and EXHIBIT-B (Quantum-Safe Provenance)
- Hypatia vulnerability-scanning and dependency-update rules

### Fixed
- Constant-time comparison in webhook HMAC verification (timing attack prevention)
- .mcp.json version aligned to 0.3.0
- package.json license corrected to PMPL-1.0-or-later
- SPDX headers added to all new files

### Removed
- boj-server-gemini repo (consolidated, deleted from GitHub)
- boj-server-mistral repo (consolidated, deleted locally)

## [0.2.0] — 2026-03-09

### Added
- Thread-safety hardening: `std.Thread.Mutex` on all 9 FFI modules (55 globals, ~120 exports)
- 2 thread-safety seam checks (concurrent register+query, concurrent mount+unmount)
- panic-attack assail validation (1 expected weak point in QUIC crypto, 0 critical)
- Third-axis extensibility (backend/provider dimension) with extension.a2ml template
- MCP stdio bridge (`boj-server --mcp`, JSON-RPC 2.0, all 18 cartridges as MCP tools)
- Seam checks module (15 panic-attack-style integration contract tests)
- SLA monitoring (3-tier: community/standard/premium, percentile tracking, 11 tests)
- Community cartridge submissions (Ayo tier, review state machine, 11 tests)
- Auto-SDP perimeter (zero-trust, allow-list, auto-ban, 10 tests)
- 4-continent seed node configuration (EU-West, EU-Central, US-East, AP-South)
- QUIC-first transport (X25519+ChaCha20-Poly1305, backward compatible, 10 tests)
- Multi-node federation testing (11 tests, REST API peering)
- Coprocessor dispatch (Axiom.jl-style: detect→select→dispatch→fallback, 14 tests)
- Podman secure instance (quadlet + seccomp + read-only rootfs)
- docs/API-CONTRACT.md — stable API surface
- docs/GETTING-STARTED.md — clone→build→run→test→extend
- docs/EXTENSIBILITY.md — third axis and extension mechanism

### Fixed
- V 0.5.0 http.Server auto-bind broken → pre-bind with net.listen_tcp
- Duplicate linker symbols (loader includes catalogue transitively)
- Deadlock in coprocessor select_by_name (calls selectDevice directly under mutex)

## [0.1.0] — 2026-03-08

### Added
- Core catalogue ABI (Idris2) with IsUnbreakable proof gate
- Core catalogue FFI (Zig) with C-ABI exports
- Dynamic loader with SHA-256 hash verification
- Guardian resource-aware failure tolerance (12 tests)
- V-lang triple adapter (REST 7700 + gRPC 7701 + GraphQL 7702)
- 18 cartridges: database, fleet, nesy, agent, cloud, container, k8s, git, secrets, queues, iac, observe, ssg, proof, lsp, dap, bsp, feedback
- All 18 cartridges with ABI + FFI + Adapter + .so shared library builds
- Umoja federation with QUIC+UDP gossip protocol (40 tests)
- VeriSimDB backing store integration (7 tests)
- PanLL BoJ panel (887 lines, 5 tabs)
- Containerfile (Chainguard base), compose.toml, vordr.toml
- CI pipeline (zig-test.yml)
- Configurable ports via environment variables
