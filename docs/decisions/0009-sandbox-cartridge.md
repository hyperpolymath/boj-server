<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 9. Sandbox cartridge — multi-provider, tier-gated code execution

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 item 2)

## Context

BoJ's multi-agent architecture (master / journeyman / apprentice supervision via `local-coord-mcp`) has no execution substrate. Agents on the bus can call tools, read resources, claim tasks, but cannot **run code**. This is a gap because:

- Common agent workflows include "write code, run it, observe output, iterate" — the canonical LLM-coding loop has nowhere to land
- The trust-tier model has no expression in execution: writing code is a "small_write" (creating a file), but *running* that code is closer to "destructive" (arbitrary side effects)
- `panic-attack-mcp` does static analysis pre-execution, `vordr-mcp` does post-execution integrity — there's a deliberate gap in the middle where execution should sit
- Existing cartridges that *do* run code (`browser-mcp`'s `execute_js`, container-mcp's full container lifecycle) are general-purpose and not tier-gated; they're hard to reason about as "the place agents execute untrusted code"

The estate also can't pull in standard tools without violating ADR-0002 (BoJ-only MCP) — a third-party `e2b-mcp` or `modal-mcp` would be a standalone MCP, which is forbidden. The capability must enter BoJ as a cartridge.

## Decision

Build **`sandbox-mcp`** — a multi-provider, tier-gated execution cartridge. One MCP-facing cartridge surface; pluggable backends.

### Provider abstraction

```
sandbox-mcp
  ├── ABI (Idris2)          — Sandbox.idr, Execution.idr, Provider.idr
  ├── FFI (Zig)             — uniform sandbox_* calls
  └── Adapter (Deno)        — provider modules:
        ├── e2b.js          — e2b.dev firecracker microVMs
        ├── modal.js        — Modal.com containers
        ├── codesandbox.js  — CodeSandbox sandpack runners
        ├── replit.js       — Replit Repl Spaces
        └── local.js        — local Podman + bubblewrap (no network)
```

Provider selection by env (`SANDBOX_PROVIDER=e2b|modal|codesandbox|replit|local`) or per-call argument. The MCP surface is provider-agnostic; calls don't change shape when switching backends.

### Tool surface

```
sandbox_create     — provision a fresh sandbox; returns sandbox_id
sandbox_exec       — execute a command/script inside an existing sandbox
sandbox_read       — read a file from inside the sandbox
sandbox_write      — write a file into the sandbox (input only)
sandbox_install    — install a language toolchain or package
sandbox_destroy    — release the sandbox; idempotent
sandbox_list       — list active sandboxes belonging to the calling peer
```

Each tool maps to one provider call. `sandbox_exec` is the high-frequency one; the rest exist so the LLM doesn't have to redo provisioning across multiple `exec` calls.

### Tier model

Per ADR-0007:

| Tool | Tier | Required role | Master approval |
|---|---|---|---|
| `sandbox_create` | 2 | apprentice | no — but the sandbox itself is bounded by the tier of operations it can run |
| `sandbox_exec` | 2-4 (depends on capabilities) | journeyman | only if `capabilities` includes `network` |
| `sandbox_read` | 1 | apprentice | no |
| `sandbox_write` | 1 | apprentice | no — write into sandbox, not host |
| `sandbox_install` | 2 | journeyman | no — bounded to sandbox |
| `sandbox_destroy` | 0 | apprentice | no |
| `sandbox_list` | 0 | apprentice | no — read-only |

`sandbox_exec` is the policy hot-spot. Each sandbox has declared **capabilities** at create-time:

```
capabilities: {
  network:     boolean,   # internet access
  filesystem:  "ro" | "rw",
  duration_s:  number,    # hard timeout, max 1800
  memory_mb:   number,    # max 4096
  cpu_quota:   number,    # 0.1 .. 4.0 cores
}
```

`network: true` flips `sandbox_exec` from tier-2 to tier-4 (per policy). The policy engine (ADR-0007) computes the effective tier per-call from the sandbox's capabilities + the calling peer's role.

### Provider differences (deliberately surfaced)

The cartridge does **not** abstract over provider semantics in a leaky way. Five provider properties are exposed as part of `sandbox_create`'s response:

- `isolation_level`: `microvm` | `container` | `process` — e2b is microvm, Modal is container, local-bubblewrap is process
- `cold_start_ms`: provider-typical, helps the LLM decide whether to reuse vs. create
- `language_support`: declared by provider; `["python", "node", "rust", "go"]` etc.
- `egress_policy`: `none` | `allowlist:<urls>` | `unrestricted`
- `attestation`: hash/signature of the sandbox image (Modal supports this; e2b partial; local depends on bubblewrap setup)

This lets the LLM (or the policy engine) make informed choices. If the user policy requires `attestation: required`, `local` provider is the only valid choice.

### Wiring into `panic-attack-mcp` and `vordr-mcp`

The execution lifecycle is:

1. **Pre-flight** (optional but encouraged): `panic-attack_scan` on the code about to be executed. Static analysis catches banned constructs before runtime.
2. **Execution**: `sandbox_create` + `sandbox_write` + `sandbox_exec`.
3. **Post-flight** (optional): `vordr_verify` on artefacts the sandbox produced, before they leave the sandbox boundary.

These wirings are *recommendations*, not enforcements. The LLM composes them via the `audit-repo`-style prompt patterns from PR #89. A future `execute-untrusted-code` prompt template can encode the canonical 3-step flow.

### Cleanup discipline

Sandboxes are bound to peer tokens (`coord_register`). When a peer's session ends (token expires, coord watchdog fires), `sandbox-mcp` releases all sandboxes owned by that peer. Prevents orphan-sandbox cost explosions.

## Consequences

### Positive

- **Closes the execution gap** — agents on the BoJ bus now have a tier-gated place to run code, instead of either (a) doing nothing useful with code or (b) executing in `browser-mcp.execute_js` which has wrong tier semantics.
- **One MCP surface, many providers** — addresses the "use e2b for now, switch to Modal later" reality without disrupting consuming prompts.
- **Tier expression in execution** — `capabilities.network: true` flipping `sandbox_exec` to tier-4 makes the tier system load-bearing for the highest-blast-radius operation BoJ performs.
- **Composes with existing cartridges** — `panic-attack-mcp` pre-flight + `sandbox-mcp` execution + `vordr-mcp` post-flight is the architecturally-shaped flow. Three separate cartridges, one workflow.
- **Provider differences exposed honestly** — `isolation_level`, `attestation`, `egress_policy` published per provider; LLM (and policy) can choose appropriately.
- **Bounded resources** — every sandbox has duration/memory/CPU caps, set at create-time and enforced by the provider.

### Negative

- **External-provider dependency** — three of five backends (e2b, Modal, CodeSandbox, Replit) are paid SaaS. Pricing structure varies. Mitigation: `local` backend (Podman + bubblewrap) for users who refuse SaaS dependency; documented as the "always-available" floor.
- **API drift** — provider APIs change. Mitigation: pin provider SDK versions in the cartridge's Deno imports; expose `provider_version` in `sandbox_list` so drift is observable.
- **Auth surface** — each provider needs an API key (`E2B_API_KEY`, `MODAL_TOKEN`, etc.). Adds ~5 env vars to glama.json.
- **Cost surprises** — LLM agents can spin up sandboxes faster than humans monitor cost. Mitigation: per-peer rate limits via ADR-0007 policy (max N sandboxes per hour, max M minutes total runtime per day).
- **Sandbox-as-pivot risk** — a compromised sandbox with `network: true` becomes a pivot point for outbound attacks. Mitigation: `egress_policy` strict default (no internet); requires explicit policy override to enable.

## Non-goals

- **Not a generic compute provider** — sandbox-mcp is for short-lived, LLM-driven code execution. Not for long-running services. Use `container-mcp`, `k8s-mcp`, or provider-specific cartridges for those.
- **Not a CI runner** — `buildkite-mcp` / `circleci-mcp` / `laminar-mcp` cover CI. Sandbox is for ad-hoc agent execution.
- **Not a debugger** — `dap-mcp` exists for that.
- **Not state-preserving across peer sessions** — sandbox lifetime ≤ peer session lifetime. No "resume yesterday's sandbox". Persisting requires a different cartridge.
- **Not GPU-enabled in v1** — provider APIs for GPU exist (Modal, Replit), but tier-gating GPU usage adds complexity. Revisit in a follow-up.

## Open questions

1. **Default provider** — `local` (always available, no SaaS) or `e2b` (best LLM-coding ergonomics)? Recommend `local` as default with strong docs on enabling SaaS providers for production use.

2. **Sandbox sharing** — can two peers on the coord bus share a sandbox (e.g. journeyman creates, apprentice executes)? Risk: cross-peer privilege escalation. Recommend disallow for v1; revisit when there's a concrete use case.

3. **Output streaming** — `sandbox_exec` is naturally streaming (stdout/stderr come over time). MCP doesn't have great primitives for this yet. v1: return on completion with full output; v2: SSE streaming once ADR-0011 (webhooks/notifications) lands.

4. **Filesystem semantics** — when does `sandbox_write` accept binary content? Base64? Streaming? Recommend base64 for v1 (simplest); revisit with chunked streaming when SSE lands.

5. **Network policy granularity** — `egress_policy` as an allow-list of URLs is straightforward for e2b/Modal but harder for `local` (would need iptables rules in bubblewrap). Recommend allowlist for SaaS providers; documented "best-effort" for local.

6. **`sandbox-mcp` vs container-mcp scope** — there's overlap with `container-mcp`'s lifecycle. Recommend: `container-mcp` is for managing persistent containers (services, databases, build environments); `sandbox-mcp` is for ephemeral, untrusted, agent-driven execution. Both can coexist; their tier and lifetime semantics differ.

## Implementation sketch

When this RFC is accepted:

1. New cartridge `cartridges/sandbox-mcp/` with the standard Idris2/Zig/Deno triple.
2. Five provider adapters under `cartridges/sandbox-mcp/adapter/providers/`. `local` lands first (no SaaS dependency to bring up); `e2b` second (best LLM-coding ergonomics); others in subsequent PRs.
3. Manifest declares 7 tools (`sandbox_create`/`exec`/`read`/`write`/`install`/`destroy`/`list`).
4. New default policy entries in `policies/boj-default.ncl` (depends on ADR-0007 landing first).
5. New env vars: `SANDBOX_PROVIDER`, `E2B_API_KEY`, `MODAL_TOKEN`, etc. — declared in glama.json.
6. Tests: per-provider integration suite (mocked transport for SaaS, real bubblewrap for local).
7. Documentation: `docs/cartridges/SANDBOX-MCP.md` covering provider selection, policy authoring, and the panic-attack → sandbox → vordr flow.

## Linked

- ADR-0007 (trust-tier policy DSL) — the policy bundle is the precondition for tier-gated execution.
- ADR-0010 (cross-machine federation) — sandboxes are *machine-local*; cross-machine peer cannot share a sandbox handle. Federation needs to be aware.
- `panic-attack-mcp` cartridge — pre-flight static analysis.
- `vordr-mcp` cartridge — post-flight integrity verification.
- Epic #87 item 2 (this).
