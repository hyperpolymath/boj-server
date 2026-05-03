# CLAUDE.md - AI Assistant Instructions

## Machine-Readable Artefacts

This repo follows the hyperpolymath standard. See `https://github.com/hyperpolymath/standards` for the canonical 6-file `.machine_readable/` layout (STATE/META/ECOSYSTEM/AGENTIC/NEUROSYM/PLAYBOOK in A2ML format).

---

## Language Policy (Hyperpolymath Standard)

The full policy is canonical in `hyperpolymath/standards`. Key points relevant to this repo:

- **No new TypeScript** — convert existing TS to AffineScript (`.affine`) directly; ReScript is no longer the destination as of 2026-04-30.
- **Deno** for the runtime, not Node. `deno.json` for imports, no `node_modules` in production.
- **AffineScript** for new application code. Compiles to typed-wasm.

### TypeScript Exemptions (Approved)

The "no new TypeScript" rule has 6 approved exemptions in this repo — all MCP cartridge adapters. The MCP SDK (`@anthropic/sdk`) is TypeScript-native, and the adapters are JSON-RPC-over-stdio glue. Until AffineScript has bindings to the MCP protocol, these adapters must remain TS.

| Path | Files | Rationale | Unblock condition |
|---|---|---|---|
| `cartridges/{academic-workflow,bofig,ephapax,fireflag,hesiod,sanctify}-mcp/adapter/mod.ts` | 6 | MCP cartridge adapters using `@anthropic/sdk`. The SDK is TS-native; equivalent functionality requires AffineScript bindings to MCP, which don't exist yet. | AffineScript MCP bindings (no scheduled issue — file under `affinescript` when scope is decided). |

Adding to this list requires explicit user approval and an unblock condition. Audit lineage: TS-elimination audit, 2026-05-02. Mirror tables in `affinescript`, `standards`, and `my-lang` repos.

### Documentation Format

- All docs `.adoc` (AsciiDoc) except GitHub-required files (SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md).
