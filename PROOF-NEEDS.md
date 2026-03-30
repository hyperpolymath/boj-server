# Proof Requirements

## Current state
- `src/abi/Boj/Protocol.idr` (77 lines) — MCP protocol types
- `src/abi/Boj/Domain.idr` (118 lines) — Domain types
- `src/abi/Boj/Catalogue.idr` (220 lines) — Cartridge catalogue types
- `src/abi/Boj/Menu.idr` (130 lines) — Menu system types
- `src/abi/Boj/Federation.idr` (164 lines) — Federation types
- `src/abi/Boj/Guardian.idr` — Guardian safety types
- `src/abi/Boj/Safety.idr` — General safety types
- `src/abi/Boj/SafeHTTP.idr`, `SafePromptInjection.idr`, `SafeCORS.idr`, `SafeAPIKey.idr`, `SafeWebSocket.idr` — Security-specific ABI definitions
- No dangerous patterns (`believe_me`, `sorry`, etc.) found in ABI layer

## What needs proving
- **Prompt injection safety**: Prove that `SafePromptInjection` filtering is complete (no bypass possible for known injection patterns)
- **CORS policy correctness**: Prove `SafeCORS` origin validation admits only explicitly allowed origins
- **API key non-leakage**: Prove that API keys in `SafeAPIKey` never appear in response bodies or logs
- **WebSocket frame safety**: Prove `SafeWebSocket` rejects malformed frames and enforces message size limits
- **HTTP request validation**: Prove `SafeHTTP` correctly validates all request components before forwarding
- **Cartridge isolation**: Prove cartridges cannot access resources outside their declared capability set
- **Federation trust chain**: Prove federation handshakes establish authentic, non-replayable trust

## Recommended prover
- **Idris2** — Already used for ABI definitions; dependent types are ideal for proving security properties over protocol types

## Priority
- **HIGH** — BoJ is an MCP server that handles API keys, HTTP requests, and WebSocket connections. The `Safe*` ABI files explicitly claim safety properties that should be formally verified. Security-critical code with explicit safety claims demands proofs.
