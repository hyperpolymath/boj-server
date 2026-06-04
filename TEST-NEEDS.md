<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# TEST-NEEDS.md — BoJ Server

**Last updated:** 2026-04-25
**Stack:** Elixir/OTP REST layer + Deno JS dispatch + Zig FFI invoker
**CRG target:** Grade C (dogfood threshold)
**CRG C standards from:** `developer-ecosystem/standards/TEST-NEEDS.md`

---

## Current Coverage (173 ExUnit tests, 0 failures)

10 StreamData property tests + 163 regular ExUnit tests = 173 total. CRG C threshold met.

| File | Tests | Category |
|------|-------|----------|
| `elixir/test/catalog_test.exs` | 25 | Unit + schema invariants |
| `elixir/test/router_test.exs` | 37 | Integration (in-process Plug.Test) + auth enforcement |
| `elixir/test/trust_policy_test.exs` | 11 | Unit — TrustPolicy required_exposure + satisfies? |
| `elixir/test/credential_decryptor_test.exs` | 19 | Unit + crypto round-trip |
| `elixir/test/node_key_test.exs` | 11 | Unit + X25519 ECDH |
| `elixir/test/js_invoker_test.exs` | 10 | Unit + E2E (Deno-gated) |
| `elixir/test/invoker_test.exs` | 15 | Unit + exit-code classification |
| `elixir/test/js_worker_pool_test.exs` | 9 | Unit + E2E (Deno-gated) |
| `elixir/test/contract_test.exs` | 15 | Contract (boundary pairs) |
| `elixir/test/aspect_test.exs` | 15 | Aspect (no-crash, content-type, security, idempotency) |
| `elixir/test/catalog_properties_test.exs` | 10 properties | StreamData property tests |
| `elixir/benchmarks/boj_bench.exs` | 10 Benchee scenarios | Benchmarks (dev only) |

### What each file covers

**catalog_test.exs** — `BojRest.Catalog` GenServer
- `list/0` returns non-empty list of maps
- Every cartridge has required string fields: name, version, domain
- Every cartridge has a non-empty tools list
- Every tool has name and description
- Cartridge names are unique
- `get/1` returns `:not_found` for unknown names
- `get/1` returns `{:ok, cart}` for `boj-health` (FFI cartridge)
- `get/1` returns `{:ok, cart}` for `model-router-mcp` (JS cartridge, no FFI)
- FFI cartridges all have `ffi.so_path` as string
- `auth.method` is always one of the known values
- `tier` is always one of the known tier values

**router_test.exs** — `BojRest.Router` HTTP surface (Plug.Test)
- `GET /health` — 200, has status/version/cartridges_loaded, no `mode` field
- `GET /menu` — 200, all entries have name/domain/tier
- `GET /cartridges` — 200, count matches list length
- `GET /cartridge/boj-health` — 200, has `ffi` key
- `GET /cartridge/model-router-mcp` — 200, no `ffi` key
- `GET /cartridge/unknown-xyz-999` — 404 with `error: "unknown-cartridge"`
- `GET /.well-known/boj-node-pubkey` — 200, 43-char base64url pubkey, algorithm x25519
- `POST /cartridge/unknown-xyz/invoke` — 404
- `POST /cartridge/model-router-mcp/invoke` without `tool` — 400 `missing-tool-field`
- `POST /cartridge/model-router-mcp/invoke classify_task` — 200 E2E (Deno-gated, `@tag :e2e`)
- Unknown route — 404 `route-not-found`

**credential_decryptor_test.exs** — `BojRest.CredentialDecryptor`
- Nil/absent credentials → `{:ok, %{}}`
- Plaintext accepted from loopback
- Plaintext rejected from non-loopback
- Plaintext with non-string values rejected
- Multiple plaintext credentials accepted
- ECDH + ChaCha20-Poly1305 round-trip decryption succeeds
- Wrong node key → `"decryption failed"` error
- Unsupported version (v99) → version error
- Missing `caller_pubkey` field → error
- Malformed base64 `caller_pubkey` → error
- Wrong pubkey size (16 bytes, not 32) → error
- Wrong nonce size (8 bytes, not 12) → error
- Credentials as non-map string → error

**node_key_test.exs** — `BojRest.NodeKey` GenServer
- `public_key/0` returns 32-byte binary
- `private_key/0` returns 32-byte binary
- Public key stable across calls
- Private key stable across calls
- Public key consistent with private key (scalar-mult derivation)
- Node key participates correctly in X25519 ECDH shared-secret derivation
- Public and private keys are distinct

**js_invoker_test.exs** — `BojRest.JsInvoker`
- `deno_path/0` returns nil or string
- Non-existent mod.js → `{:error, %{classification: :mod_missing}}`
- Missing deno binary → `{:error, %{classification: :deno_missing}}`
- E2E: `classify_task` via model-router-mcp (Deno-gated, `@tag :e2e`)
- E2E: `estimate_cost` via model-router-mcp (Deno-gated)
- E2E: unknown tool → graceful error
- E2E: `extra_env` forwarding does not crash

---

## Coverage vs CRG C Standard

| Category | Required | Current | Status |
|----------|----------|---------|--------|
| Unit tests | 100+ | ~110 | ✅ |
| Smoke tests | 9+ | ~12 (router happy-path set) | ✅ |
| End-to-end tests | 4+ | 5 E2E (Deno-gated) | ✅ |
| Property tests | 10+ | 10 StreamData properties | ✅ |
| Contract tests | 13+ | 15 (contract_test.exs) | ✅ |
| Aspect tests | 14+ | 15 (aspect_test.exs) | ✅ |
| Benchmarks | 10+ | 10 Benchee scenarios | ✅ |
| **Total** | **165+** | **173** | **CRG C ✅** |

**Current grade: C** (all categories at or above threshold)

---

## Path to CRG Grade B

Grade B requires:
- External validation targets (published test results, CI badge)
- Mutation testing (Muzak or equivalent) showing >80% mutation kill rate
- Six Sigma benchmark targets (latency at 99th percentile)
- Security/fuzz corpus for CredentialDecryptor

---

## Notes

- **E2E tests are Deno-gated** — tagged `@tag :e2e` and skip cleanly if `deno` is absent.
  CI must install Deno for E2E coverage.
- **FFI/Zig tests** are not in this suite — they run via `zig test` in `ffi/zig/`.
- **115 cartridges loaded** from `cartridges/` as of 2026-04-30 (111 with `.so` built; the 4 without are `database-mcp`, `echidna-llm-mcp`, `lang-mcp`, `orchestrator-lsp-mcp`).
- **Panic-attack pre-commit hook** runs `panic-attack assail` — check `PANIC-ATTACK.a2ml`
  for current Clade classification and any open findings.
