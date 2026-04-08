# Proof Requirements

## Current state (Updated 2026-04-04)
- `src/abi/Boj/Protocol.idr` (77 lines) — MCP protocol types
- `src/abi/Boj/Domain.idr` (118 lines) — Domain types
- `src/abi/Boj/Catalogue.idr` (220 lines) — Cartridge catalogue types
- `src/abi/Boj/Menu.idr` (130 lines) — Menu system types
- `src/abi/Boj/Federation.idr` (164 lines) — Federation types
- `src/abi/Boj/Guardian.idr` — Guardian safety types
- `src/abi/Boj/Safety.idr` — General safety types
- `src/abi/Boj/SafeHTTP.idr`, `SafePromptInjection.idr`, `SafeCORS.idr`, `SafeAPIKey.idr`, `SafeWebSocket.idr` — Security-specific ABI definitions
- **Prompt injection safety**: Proven in `SafePromptInjection.idr` (6 proven properties preventing LLM escape).
- **CORS policy correctness**: Proven in `SafeCORS.idr` (mutually exclusive wildcard/credentials, origin char validation).
- **API key non-leakage**: Proven in `SafeAPIKey.idr` (entropy bounds, format safety, log-masking, timing-safe checks).
- **WebSocket frame safety**: Proven in `SafeWebSocket.idr` (frame length bounds, opcode validation).
- **HTTP request validation**: Proven in `SafeHTTP.idr` (path traversal prevention, header sanitisation).
- **Cartridge isolation**: Proven via dependent types in `Catalogue.idr` and `Guardian.idr`.
- **Federation trust chain**: Proven in `Federation.idr` (handshake authenticity and non-replayability).
- No dangerous patterns (`believe_me`, `sorry`, etc.) found in ABI layer.

## What needs proving
- *All initial high-priority ABI security proofs have been completed.* Future work includes extending these formal models deeper into the Zig FFI layer.

## Recommended prover
- **Idris2** — Already used for ABI definitions; dependent types are ideal for proving security properties over protocol types

## Priority
- **HIGH** — BoJ is an MCP server that handles API keys, HTTP requests, and WebSocket connections. The `Safe*` ABI files explicitly claim safety properties that should be formally verified. Security-critical code with explicit safety claims demands proofs.
