<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 12. Server-initiated sampling — composition routing + ambiguous-input clarification

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 item 6)

## Context

MCP's `sampling/createMessage` is a reverse path: the server asks the connected LLM to make a sub-decision. The user-facing LLM remains in control (it sees the sampling request and decides whether to honour it), but the server can pose a question and receive a response without the user having to manually mediate.

This is **structurally** the right primitive for two BoJ scenarios that today are awkward:

**Scenario A: Cartridge composition routing**

A user asks the LLM: *"Deploy my app and tell me when it's healthy."* The LLM calls `boj_cartridge_invoke` with the high-level intent. BoJ now has to choose:

- Which deploy cartridge? `fly-mcp`, `render-mcp`, `railway-mcp`, `vercel-mcp`?
- Which healthcheck cartridge? `prometheus-mcp` poll, `sentry-mcp` watch, or just curl?
- What's the order? Deploy then check, or pre-validate then deploy?

BoJ can't make this choice well without knowing the user's situation. Today it either (a) requires the LLM to specify the cartridge explicitly (defeats "I just want to deploy") or (b) hard-codes routing rules (brittle, can't adapt).

With sampling: BoJ asks the LLM *"Given the user said X, which of these 4 deploy cartridges fits? Reply with cartridge name."* — and routes accordingly. The LLM brings world-knowledge that BoJ doesn't have.

**Scenario B: Ambiguous-input clarification**

A user calls `boj_cartridge_invoke` for `database-mcp` with parameters that could match multiple backends (e.g. `query: "SELECT * FROM users"` — could be PostgreSQL, SQLite, DuckDB). Today BoJ either picks an arbitrary default or errors.

With sampling: BoJ asks the LLM *"This query is ambiguous between {pg, sqlite, duckdb}. Which is the user's database?"* — and the LLM either knows from prior context or asks the user.

Without sampling, both scenarios force either pre-resolution (LLM must specify everything up front) or post-failure handling (try one, fail, try another). Both are worse than asking once at the right moment.

## Decision

Implement MCP `sampling/createMessage` server-initiated requests for **two specific patterns**, both opt-in per cartridge:

### Pattern 1: Composition router

A new helper in the bridge: `requestComposition(intent, candidates, context)`. Used by `boj_cartridge_invoke` when the target is ambiguous, and by prompt templates (PR #89) when a step needs LLM-side selection.

```js
// In boj_cartridge_invoke, when args.name is ambiguous:
const choice = await requestComposition({
  intent: "deploy and monitor",
  candidates: [
    { name: "fly-mcp", strengths: "fast cold-start, global edge" },
    { name: "render-mcp", strengths: "managed Postgres + cron" },
    { name: "railway-mcp", strengths: "monorepo support, env groups" },
    { name: "vercel-mcp", strengths: "frontend-focused, edge functions" },
  ],
  context: { user_message: ..., recent_tool_history: [...] },
});
// choice.name → "fly-mcp" (e.g.)
// proceed with invokeCartridge(choice.name, args)
```

MCP wire:
```jsonrpc
{
  "jsonrpc": "2.0",
  "id": <server-side-id>,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      { "role": "user", "content": { "type": "text",
        "text": "BoJ routing decision needed.\n\nUser intent: deploy and monitor\n\nCandidates:\n- fly-mcp: fast cold-start, global edge\n- render-mcp: managed Postgres + cron\n- railway-mcp: monorepo support, env groups\n- vercel-mcp: frontend-focused, edge functions\n\nReturn exactly one cartridge name from the candidate list. No explanation."
      }}
    ],
    "modelPreferences": {
      "intelligencePriority": 0.3,
      "speedPriority": 0.9,
      "costPriority": 0.8
    },
    "maxTokens": 32,
    "systemPrompt": "You are BoJ's cartridge router. Return cartridge names verbatim from the provided list, with no extra text."
  }
}
```

`modelPreferences` biases for cheap-fast — composition routing is high-frequency, doesn't need the heaviest model.

### Pattern 2: Clarification prompt

A new helper `requestClarification(question, options)` for the ambiguous-input scenario:

```js
const answer = await requestClarification({
  question: "The query 'SELECT * FROM users' is database-agnostic. Which backend?",
  options: ["postgresql", "sqlite", "duckdb", "mongodb"],
});
// answer.choice → "postgresql"
```

The wire shape is the same as Pattern 1 but with a different system prompt focusing on "ask the user if you don't know" rather than "pick from the list silently".

### Sampling client-side cooperation

MCP clients are not required to honour sampling requests. The spec is explicit: the client decides. A well-behaved client (Claude Code, etc.) shows the sampling request to the user (who sees it as "BoJ wants to ask the LLM something") and the user approves or denies.

BoJ's bridge handles three responses:

| Client response | BoJ behaviour |
|---|---|
| Sampling result returned | Use the returned message; proceed |
| Sampling rejected | Fall back to a deterministic default (documented per call site); proceed with reduced confidence |
| Sampling timeout (30s default) | Same as rejected |

The fallback path is **always present**. BoJ never blocks indefinitely on sampling.

### Where sampling is NOT used

Sampling is a power move; misuse is worse than not having it. Hard rules:

- **Never** in security-critical paths (e.g. `coord_approve`, `boj_github_merge_pr`). These need explicit user authorization, not LLM judgment.
- **Never** to ask "should I proceed?" — that's the calling LLM's job, not a sub-LLM-call.
- **Never** for input validation — that's `hardeningGate`'s job.
- **Never** in the OTel-traced hot path without budget tracking — sampling burns tokens; track per-session in `OTEL_*` attributes and respect a global budget.

A new env var `BOJ_SAMPLING_BUDGET_PER_SESSION` (default `50`) caps how many sampling requests BoJ will issue per MCP session. Exceeded → fall back to deterministic defaults.

### Audit + transparency

Every sampling request emits an OTel span (per ADR-0013, item 13) with attributes:

- `boj.sampling.pattern` — `composition_router` | `clarification`
- `boj.sampling.candidates_count`
- `boj.sampling.result` — `returned` | `rejected` | `timeout`
- `boj.sampling.chosen` — the value the LLM returned (or null)
- `boj.sampling.budget_remaining`

This means sampling activity is observable from the user's existing telemetry (ADR-0013 / item 13 already wires OTel) without bespoke logging.

## Consequences

### Positive

- **Closes the "BoJ needs world-knowledge" hole** — routing and clarification decisions can finally tap the LLM that's already connected.
- **Composition becomes adaptive** — `boj_cartridge_invoke` against "deploy" doesn't need a hard-coded provider; the right cartridge is chosen per call based on the user's actual situation.
- **High-frequency, low-cost** — composition routing biased toward fast/cheap models; doesn't burn the heaviest model on routing decisions.
- **Always has fallback** — sampling is opportunistic; rejection or timeout doesn't break BoJ. Reduces deployment risk.
- **Budget-bounded** — `BOJ_SAMPLING_BUDGET_PER_SESSION` prevents runaway sampling from a misbehaving cartridge.
- **Observable** — every sampling request is an OTel span; operators can see where sampling is helping vs. wasting tokens.
- **Underused capability** — most MCP servers don't use sampling. BoJ using it well is differentiated.

### Negative

- **Token budget visible to user** — sampling calls cost tokens the user pays for. Mitigation: per-session budget cap + clear OTel attribution so the user knows.
- **Client cooperation required** — clients that don't implement sampling silently no-op. Mitigation: documented fallback paths; degrade gracefully.
- **Sub-LLM-call latency** — sampling RTT depends on the client+model. Could be hundreds of ms. Mitigation: only use for genuinely-needed decisions; cache routing decisions within a session (same intent → same choice).
- **Sampling-driven choices can be unpredictable** — the LLM might pick a different cartridge for the same intent across runs. Mitigation: deterministic-mode env var (`BOJ_SAMPLING_DETERMINISTIC=true`) that uses the first option in candidate lists rather than sampling.
- **Audit complexity** — when something goes wrong, was it the cartridge choice (sampling) or the cartridge itself? Mitigation: OTel span carries the sampling decision; post-incident analysis can disentangle.

## Non-goals

- **Not making sampling the default for routing** — sampling is opt-in per call site. The composition-router helper is invoked explicitly; cartridges that don't want it don't get it.
- **Not using sampling for security decisions** — explicit rule. Security needs human-in-the-loop.
- **Not exposing sampling as a tool** — there's no `boj_sample` tool. Sampling is an internal bridge primitive; cartridges trigger it via the helpers above.
- **Not chaining sampling** — one sampling request per server-decision. No multi-turn sub-LLM-conversations; that's the user's LLM's job.
- **Not requiring sampling support in clients** — graceful degradation always available.

## Open questions

1. **System-prompt safety** — BoJ-authored system prompts are sent to the client's LLM. Could be misused if a cartridge submitted user-controlled text. Recommend: system prompts are static strings in BoJ code; only the `messages.content` carries variable data, and that data is the result of the calling tool's args (already filtered through `hardeningGate`'s injection scan).

2. **Caching sampling decisions** — within a session, "the user's database" probably doesn't change. Recommend per-session LRU keyed on (pattern, question-hash) so repeated calls don't re-sample.

3. **Multi-client sampling target** — if two MCP clients are connected, which one gets the sampling request? Recommend the most-recently-active client (whoever issued the most recent `tools/call`); document the heuristic; future RFC can refine.

4. **Sampling for prompts** — should the prompt templates from PR #89 themselves invoke sampling for intermediate steps? Recommend yes, but only in templates where the spec explicitly calls it out (e.g. an `auto-deploy` prompt could invoke composition routing internally). Keep `audit-repo`, `triage-issues`, etc. sampling-free.

5. **Cost attribution** — sampling calls hit the user's LLM quota. Should the OTel span carry the token cost in attributes (if the client reports it)? Recommend yes when available; document that the client may not report.

6. **Fallback determinism** — when sampling is rejected, "first option in the candidate list" is one fallback strategy. Are there call sites where a different deterministic strategy is correct (e.g. "lowest tier", "least recently used")? Recommend per-call-site fallback function; sensible defaults documented.

## Implementation sketch

When this RFC is accepted:

1. New `mcp-bridge/lib/sampling.js` with `requestComposition` and `requestClarification` helpers + budget tracking.
2. Helpers route through new wire-format method on the JSON-RPC server side (the bridge sends a `sampling/createMessage` request to the client, awaits response).
3. New env var `BOJ_SAMPLING_BUDGET_PER_SESSION` (default 50); declared in `glama.json`.
4. New env var `BOJ_SAMPLING_DETERMINISTIC` (default `false`); when true, helpers return the first option without sampling.
5. OTel instrumentation (depends on item 13 / PR #91): every sampling request emits a span.
6. Integration with `boj_cartridge_invoke` for the routing case (one call site to start).
7. Tests: mock-MCP-client that returns canned sampling responses; verify fallback behaviour on rejection + timeout.
8. Documentation: `docs/cartridges/SAMPLING-USAGE.md` covering when to invoke sampling, budget management, and the two patterns.

## Linked

- ADR-0007 (policy DSL) — sampling is *not* policy-gated (it's not a side-effectful operation), but the *result* of sampling feeds into a tool call that *is* policy-gated.
- ADR-0009 (sandbox cartridge) — sandbox provider selection is a natural composition-router use case.
- ADR-0011 (webhooks/notifications) — orthogonal but related; both are server-initiated MCP message types, both opt-in per client.
- Epic #87 item 6 (this) + item 13 (OTel, the observability surface for sampling).
- PR #89 (resources + prompts) — vocabulary; prompts could *internally* invoke sampling for sub-steps.
