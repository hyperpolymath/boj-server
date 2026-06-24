<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# `tests/backend-assurance/` — pointer

The runnable property-test harness for the backend-assurance campaign
lives under **`elixir/test/backend_assurance/`** (BEAM-native), where
`mix test` picks it up automatically and `stream_data` is already a
declared test-only dep.

This directory is intentionally a pointer rather than a parallel test
home: keeping the tests under `elixir/test/` means one test runner,
one dep set, and one set of fixtures.

The prose-side trusted-extraction validation lives under
**`docs/backend-assurance/`**.

## Run

    cd elixir
    mix deps.get
    mix test --only backend_assurance

## CI

`.github/workflows/backend-assurance.yml` runs the same command on PRs
that touch `src/abi/Boj/SafetyLemmas.idr` or
`elixir/test/backend_assurance/**`.

## See also

- `docs/backend-assurance/README.md` — campaign overview + coverage table.
- `PROOF-NEEDS.md` — axiom audit + why this campaign exists.
