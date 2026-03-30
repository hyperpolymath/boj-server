# Test & Benchmark Requirements

## Current State
- Unit tests: 1 Rust test file + 1 aspect_tests.sh script — effectively NONE for the main codebase
- Integration tests: NONE
- E2E tests: NONE
- Benchmarks: 63 benchmark files exist (likely V-lang ecosystem benchmarks)
- panic-attack scan: 1 report found (panic-attack-report.json)

## What's Missing
### Point-to-Point (P2P)
This is a major MCP server with 228 Zig + 108 Idris2 + 29 JS + 128 V + 8 Rust + 5 ReScript source files. The test coverage is catastrophically low:

- **src/** (entire MCP bridge implementation) — ZERO tests
- **cartridges/** (all cartridge implementations) — no tests
- **adapter/** — no tests
- **mcp-bridge/** — no tests
- **ffi/** (Zig) — no tests
- **tools/** — no tests
- **tray/** — no tests
- All 228 Zig source files — ZERO tests
- All 108 Idris2 ABI definitions — ZERO verification tests
- All 128 V source files — ZERO tests
- All 29 JS source files — ZERO tests

### End-to-End (E2E)
- MCP server startup and health check
- Cartridge loading and invocation
- Browser cartridge: navigate, click, type, read_page
- GitHub cartridge: CRUD on repos, issues, PRs
- GitLab cartridge: project management, CI pipeline interaction
- Cloud cartridges (Cloudflare, Vercel, Verpex) — CRUD operations
- Gmail/Calendar cartridge operations
- Research cartridge: search and retrieval
- Cartridge discovery and listing
- Error handling for unavailable services
- Authentication flow for each cartridge

### Aspect Tests
- [ ] Security (MCP protocol injection, cartridge sandboxing, credential handling, SSRF via browser cartridge)
- [ ] Performance (concurrent cartridge invocations, large response handling, connection pooling)
- [ ] Concurrency (parallel MCP requests, cartridge state isolation, browser session management)
- [ ] Error handling (network failures, API rate limits, invalid tool calls, timeout handling)
- [ ] Accessibility (N/A — server)

### Build & Execution
- [ ] zig build — not verified
- [ ] npm/deno run — not verified
- [ ] MCP server starts and responds to health check — not verified
- [ ] CLI --help works — not verified
- [ ] Self-diagnostic — aspect_tests.sh exists but unclear if comprehensive

### Benchmarks Needed
- MCP request/response latency per cartridge
- Concurrent request throughput
- Browser cartridge page load and interaction speed
- Memory usage under sustained load
- Cartridge hot-loading performance
- Connection pool efficiency

### Self-Tests
- [x] panic-attack assail — report exists (verify findings)
- [ ] Built-in health check (boj_health exists — verify coverage)

## Priority
- **HIGH** — This is THE central MCP server for the entire ecosystem. 228 Zig + 108 Idris2 + 128 V + 29 JS + 8 Rust + 5 ReScript source files with effectively ZERO functional tests. The 63 benchmark files appear to be from V-lang ecosystem rather than boj-server itself. A single test script (aspect_tests.sh) is not adequate for a server handling browser automation, GitHub/GitLab operations, cloud infrastructure management, and email. Security testing is especially critical given the privileged operations this server performs.

## FAKE-FUZZ ALERT

- `tests/fuzz/placeholder.txt` is a scorecard placeholder inherited from rsr-template-repo — it does NOT provide real fuzz testing
- Replace with an actual fuzz harness (see rsr-template-repo/tests/fuzz/README.adoc) or remove the file
- Priority: P2 — creates false impression of fuzz coverage
