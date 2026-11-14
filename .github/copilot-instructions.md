<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
<!-- Authoritative source: docs/AI-CONVENTIONS.adoc -->

# Copilot Instructions

## Before Writing Code

- Read `0-AI-MANIFEST.deed` in the repo root: it points to `boj-server_chora.deed` (repo facts) and `.claude/CLAUDE.md` (agent conventions).
- A2ML is retired: never create a `.a2ml` file (see `docs/history/A2ML-REMOVED.adoc`).

## License

- SPDX: `MPL-2.0` on all new files.
- Never use AGPL-3.0.
- Copyright: `Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>`

## Code Style

- Use descriptive variable names.
- Annotate and document all files.
- Add SPDX header to every source file.
- Use `just` for build/test/lint commands.

## Banned Patterns

- Idris2: no `believe_me`, no `assert_total`
- Haskell: no `unsafeCoerce`, no `unsafePerformIO`
- OCaml: no `Obj.magic`
- Coq: no `Admitted`
- Lean: no `sorry`
- Rust: no `transmute` unless FFI with `// SAFETY:` comment

## Banned Languages

- No TypeScript (use AffineScript)
- No Node.js / npm / bun (use Deno)
- No Go (use Rust)
- No Python (use Julia or Rust)

## Containers

- Use Podman, never Docker.
- Name the file `Containerfile`, never `Dockerfile`.
- Base image: `cgr.dev/chainguard/wolfi-base:latest`.

## ABI/FFI

- ABI definitions in Idris2 (`src/abi/`).
- FFI implementations in Zig (`ffi/zig/`).
- Generated C headers in `generated/abi/`.

## State Files

Repo state and metadata are clauses of `boj-server_chora.deed` (lifecycle `(status)`,
`(meta)`, `(agentic)`, `(neurosym)`, `(playbook)`, `(anchor)`). Never create STATE, META,
ECOSYSTEM, AGENTIC, NEUROSYM or PLAYBOOK `.a2ml` files anywhere.
