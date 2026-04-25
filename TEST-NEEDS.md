# TEST-NEEDS.md — BoJ Server

**Last updated:** 2026-04-25
**Stack:** Elixir/OTP REST layer + Deno JS dispatch + Zig FFI invoker
**CRG target:** Grade C (dogfood threshold)
**CRG C standards from:** `developer-ecosystem/standards/TEST-NEEDS.md`

---

## Current Coverage (50 ExUnit tests, 0 failures)

| File | Tests | Category |
|------|-------|----------|
| `elixir/test/catalog_test.exs` | 11 | Unit + property-style |
| `elixir/test/router_test.exs` | 12 | Integration (in-process Plug.Test) |
| `elixir/test/credential_decryptor_test.exs` | 12 | Unit + crypto round-trip |
| `elixir/test/node_key_test.exs` | 7 | Unit |
| `elixir/test/js_invoker_test.exs` | 8 | Unit + E2E (Deno-gated) |

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

## Gap Analysis vs CRG C Standard

| Category | Required | Current | Status |
|----------|----------|---------|--------|
| Unit tests | 100+ | 50 | ❌ Gap: 50 more needed |
| Smoke tests | 9+ | ~9 (router happy-path set) | ✅ |
| End-to-end tests | 4+ | 3 E2E (Deno-gated) | ⚠️ Conditional |
| Property tests | 15+ | ~11 (catalog invariants + decryptor properties) | ❌ Gap: 4+ more |
| Contract tests | 13+ | 0 (no Pact/contract harness yet) | ❌ |
| Aspect tests | 14+ | 0 (no aspect harness yet) | ❌ |
| Benchmarks | 10+ | 0 | ❌ |
| **Total** | **165+** | **50** | **CRG D** |

**Current grade: D** (foundation suite in place, gaps to C listed below)

---

## Path to CRG Grade C

### P1 — Expand unit tests to 100+ (Gap: 50 tests)

Priority areas:
- `BojRest.Catalog`: edge cases — malformed JSON in cartridge.json, empty tools list,
  cartridges_root not found, duplicate detection
- `BojRest.Invoker`: all exit code classifications (args/open/symbol/init/crashed),
  `cli_path/0` resolution order, `probe/1`, `name/1`, `version/1`
- `BojRest.JsInvoker`: runner_path resolution, bad JSON output, timeout path
  (requires a slow mod.js fixture), application-level error (4xx/5xx status codes)
- `BojRest.CredentialDecryptor`: ciphertext too short, JSON-in-plaintext-has-int-values
- `BojRest.NodeKey`: key file persistence (tempdir), env var loading paths
- Router: `POST /invoke` with encrypted credentials end-to-end

### P2 — Property tests to 15+ (StreamData installed, Gap: 4+ tests)

`stream_data ~> 1.1` is in `mix.exs` (only: test).  Write StreamData property tests in:
- `catalog_test.exs`: for all cartridges, `get(cart["name"])` always returns the cart back
- `credential_decryptor_test.exs`: any string→string map plaintext from loopback always
  passes; any non-string value always fails validation
- `router_test.exs`: GET /cartridge/<any name from list> always returns 200

### P3 — Contract tests (Gap: 13)

Use `ExUnit` contract-style modules (or add `pact_elixir` when available):
- One module per boundary: Catalog↔Router, JsInvoker↔Runner, Router↔Invoker,
  NodeKey↔CredentialDecryptor, CredentialDecryptor↔Router

### P4 — Aspect tests (Gap: 14)

Panic-free aspects from `panic-free-tests-and-benches` Clade A standard:
- No process crash on any valid input (Clade A goal)
- `BojRest.Catalog.get/1` never throws
- Router always returns valid JSON content-type
- CredentialDecryptor never leaks key material in error strings
- NodeKey survives concurrent reads under `Task.async_stream`

### P5 — Benchmarks (Gap: 10)

Add `benchee ~> 1.3` (only: dev):
- Catalog `list/0` with 107 cartridges (ETS read)
- Catalog `get/1` hit vs miss
- CredentialDecryptor: plaintext vs encrypted path
- NodeKey ECDH round-trip
- JsInvoker cold-start time (requires Deno)

---

## Notes

- **E2E tests are Deno-gated** — tagged `@tag :e2e` and skip cleanly if `deno` is absent.
  CI must install Deno for E2E coverage.
- **FFI/Zig tests** are not in this suite — they run via `zig test` in `ffi/zig/`.
- **107 cartridges loaded** from `cartridges/` as of 2026-04-25.
- **Panic-attack pre-commit hook** runs `panic-attack assail` — check `PANIC-ATTACK.a2ml`
  for current Clade classification and any open findings.
