# 📊 BoJ Server — Tests and Benches

**Status:** ACHIEVED (CRG Grade D-alpha)  
**Last Updated:** 2026-04-20  
**Compliance:** [Hyperpolymath Testing & Benchmarking Taxonomy v1.1.0](../../developer-ecosystem/standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc)

## 🎯 Overview

BoJ Server maintains a high-rigor testing suite covering the full 2D matrix of protocol adapters and capability domains. The suite includes 365 passing tests across 13 categories and 14 aspect dimensions.

## 🌳 Test Matrix (Categories)

| Category | Status | Count | Details |
|----------|--------|-------|---------|
| **Unit** | PASS | 158+ | Core FFI modules + cartridge FFI logic |
| **P2P (Property)** | PASS | 14 | Cartridge name uniqueness, vocabulary compliance, matrix completeness |
| **E2E** | PASS | 13 | MCP lifecycle, tool invocation, order-ticket protocol flow |
| **Build** | PASS | - | `just build` (Zig FFI) + `mix compile` (Elixir REST) |
| **Execution** | PASS | - | Deno/Node bridge + BEAM runtime (Elixir) |
| **Reflexive** | PASS | 12 | `just doctor` health checks + self-diagnostic Guardian module |
| **Lifecycle** | PASS | 14 | Dynamic loader mount/unmount + session state |
| **Smoke** | PASS | 8 | CLI help, MCP schema validation, health endpoint |
| **Property-Based** | PASS | 15+ | FFI roundtrip bijection (echidna reference) |
| **Contract/Invariant**| PASS | 13 | Must/Trust/K9 enforcement on config + catalogues |
| **Regression** | PASS | 6 | Fixed bug verification (URL encoding, port mapping) |
| **Chaos/Resilience** | PASS | 12 | Guardian failure isolation + resource gating |
| **Proof Regression** | PASS | 108+ | Idris2 ABI totality checks (`%default total`) |

## 📊 Aspect Dimensions

| Aspect | Status | Evidence |
|--------|--------|----------|
| **Security** | PASS | 17 tests: Injection detection, sandboxing, SSRF prevention, credential masking |
| **Performance** | PASS | 10 benchmarks: Serialization <1ms, latency <5ms avg, throughput 69k req/s |
| **Safety** | PASS | `believe_me` count reduced 31 -> 4; panic-attack assail pass |
| **Interoperability**| PASS | MCP 2024-11-05 + JSON-RPC 2.0 + REST/gRPC/GraphQL schemas |
| **Dependability** | PASS | Guardian module resource-aware failure tolerance |
| **Observability** | PASS | `boj_health` tool + structured JSON logging |

## ⚡ Benchmarks (Baselines)

| Metric | Target | Result | Status |
|--------|--------|--------|--------|
| JSON-RPC Serialization | <1.0ms | 0.001ms | ✅ Extraordinary |
| JSON-RPC Deserialization | <1.0ms | 0.002ms | ✅ Extraordinary |
| Round-trip Latency | <5.0ms | 0.004ms | ✅ Extraordinary |
| Cartridge listing | >100 req/s | 69,000 req/s | ✅ Extraordinary |
| Tool schema gen (1000) | <10ms | 1.36ms | ✅ Extraordinary |
| Injection detection | <100µs | 1.28µs | ✅ Extraordinary |

## 🛠️ Tooling

- **Deno:** Primary test runner for MCP bridge and integration tests.
- **Zig:** Test runner for FFI and native adapter logic (`zig build test`).
- **Mix:** Test runner for the Elixir REST multiplier (`mix test`).
- **Idris2:** Formal proof verification (`idris2 --check`).
- **panic-attack:** Static analysis and security scanning (`just scan`).

## 🔄 How to Run

```bash
# Full test suite
just test

# Specific categories
deno test tests/smoke_test.ts
deno test tests/e2e_mcp_test.ts
deno test tests/mcp_bench.ts

# FFI tests
cd ffi/zig && zig build test

# Elixir tests
cd elixir && mix test
```

## 📚 References

- [TEST-NEEDS.md](../TEST-NEEDS.md) — Detailed requirement tracking.
- [READINESS.md](READINESS.md) — CRG Grade evidence.
- [.machine_readable/6a2/STATE.a2ml](../.machine_readable/6a2/STATE.a2ml) — Latest machine-readable stats.
