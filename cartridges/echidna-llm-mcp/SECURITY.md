<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->

# Security Policy — `echidna-llm-mcp` cartridge

## Reporting Vulnerabilities

This cartridge is a sub-component of `boj-server`. Vulnerability reports for
this cartridge follow the parent project's process. See:

- [`boj-server/SECURITY.md`](../../SECURITY.md) — canonical reporting flow.

## Cartridge-specific notes

- **No authentication layer at the FFI boundary.** The cartridge is invoked
  via the BoJ Server's loader; access control is the loader's responsibility.
- **No persistent state.** Calls are stateless from the cartridge's
  perspective. Session state (echidna endpoint URL, auth token) is held in
  the FFI's static module; it does not survive process restart.
- **Outbound HTTP**: all calls leave the host through the configured echidna
  REST endpoint (default `http://127.0.0.1:8081`). Payload schemas are
  documented in [`docs/CALL-PROTOCOL.adoc`](docs/CALL-PROTOCOL.adoc).
- **Zig FFI**: V-lang adapter was removed during the V-lang ban
  (2026-04-10). The Zig adapter (Zig 0.15.2+) replaces it; an optional
  Deno runtime (`mod.js`) is the canonical transport.

## Threat model

Documented in `boj-server`'s `.machine_readable/threat-model.a2ml`. The
cartridge inherits the parent's STRIDE classification + crypto-class
inventory and adds no new privileged operations.
