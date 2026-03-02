# Contributing Cartridges to BoJ

## What is a cartridge?

A cartridge is a swappable, formally verified capability module. It occupies one or more cells in the 2D matrix (protocol x domain) and follows the three-layer stack:

1. **Idris2 ABI** — Type-safe interface with `%default total` and zero `believe_me`
2. **Zig FFI** — C-compatible native execution
3. **V-lang Adapter** — REST + gRPC + GraphQL endpoints

## Creating a new cartridge

### 1. Choose your matrix cell(s)

Pick a capability domain (what it does) and one or more protocols (how to talk to it):

- **Domain**: Cloud, Container, Database, K8s, Git, Secrets, Queues, IaC, Observe, SSG, Proof, Fleet, NeSy
- **Protocol**: MCP, LSP, DAP, BSP, NeSy, Agentic, Fleet, gRPC, REST

### 2. Create the directory

```
cartridges/your-cartridge-name/
  abi/           # Idris2 source
  ffi/           # Zig source
  adapter/       # V-lang source
```

### 3. Write the Idris2 ABI

Your ABI module must:
- Use `%default total`
- Have zero `believe_me`, `assert_total`, or `assert_smaller`
- Define the cartridge's types and operations
- Include C-ABI encoding/decoding functions (Int <-> your types)

### 4. Write the Zig FFI

Your FFI must:
- Match the Idris2 ABI's integer encodings exactly
- Use `export fn` for all C-callable functions
- Include tests
- Zero runtime dependencies

### 5. Write the V-lang adapter

Your adapter must:
- Expose the cartridge via the protocols declared in the menu
- Handle the order-ticket protocol
- Return proper status responses

### 6. Register in the menu

Add your cartridge to `.machine_readable/servers/menu.a2ml` under the Ayo section. Set status to `Development` initially.

### 7. Pass the IsUnbreakable proof

Once your Idris2 ABI type-checks clean, the Zig FFI builds, and the V-lang adapter compiles, submit a PR. The CI will verify:
- Zero `believe_me` in your ABI
- `%default total` in all Idris2 files
- Zig builds clean
- All tests pass
- SPDX headers present (PMPL-1.0-or-later)

When merged, your cartridge status changes to `Ready` and it appears in the Ayo section of the Teranga menu.

## Community recognition

Ayo means "joy" in Yoruba. When you contribute a verified cartridge, you're sharing joy with the community. Your name is honoured in the Ayo section of the menu.

## Questions?

Open a Discussion in the repository, or reach out via the channels listed in CONTRIBUTING.md.
