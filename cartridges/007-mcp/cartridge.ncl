# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# 007-mcp / cartridge.ncl
#
# Nickel source-of-truth manifest for the 007 language cartridge.
# Export JSON for the MCP bridge:
#   nickel export --format json --output cartridge.json cartridge.ncl
#
# Cartridge source lives IN this repo (007-lang) per design-log DD-24.
# `just cartridge-install` builds it and deploys to boj-server/cartridges/007-mcp/.
#
# Exposed surface: the FULL oo7 CLI (every Justfile recipe) + two lifecycle
# hooks (on-enter, on-exit) that drive the coord-peer handshake and the
# 6a2 methodology pack load on context entry.
#
# Loopback bind: 127.0.0.1:1066. The Idris2 ABI (abi/Oo7Mcp/SafeCli.idr)
# proves bind-address is loopback-only at compile time via the IsLoopback
# sum type — the only constructors are Ipv4Loopback and Ipv6Loopback, so
# binding to any other address is type-impossible.

let mk_tool = fun n d input_props req => {
  name = n,
  description = d,
  inputSchema = {
    type = "object",
    properties = input_props,
    required = req,
  },
} in

let str_prop = fun desc => { type = "string", description = desc } in
let bool_prop = fun desc => { type = "boolean", description = desc } in
let int_prop = fun desc => { type = "integer", description = desc } in

# Optional args slot — recipes that accept `*args` get this.
let args_prop = str_prop "Optional extra arguments forwarded to the recipe" in

{
  "$schema" = "https://boj.dev/schemas/cartridge/v1.json",
  spdx = "MPL-2.0",
  copyright = "Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>",
  name = "007-mcp",
  version = "0.1.0",
  description = "007 agent meta-language cartridge — exposes the full oo7 CLI surface (parse/run/trace/build/test/lint/verify/contractile verbs/canonical-proof-suite/groove/self-assess) plus on-enter and on-exit lifecycle hooks that register the session as a coord peer, load the 6a2 methodology pack (STATE, META, ECOSYSTEM, AGENTIC, NEUROSYM, PLAYBOOK), and perform drift checks on exit.",
  domain = "dezig",
  tier = "Ayo",
  protocols = ["MCP", "Agentic"],
  federation = "none",
  bind = {
    address = "127.0.0.1",
    port = 1066,
    loopback_only = true,
  },
  auth = {
    method = "none",
    env_var | optional = null,
    credential_source | optional = null,
    description = "No auth for local-loopback; the Idris2 ABI proves bind is loopback-only so the port is unreachable from off-box.",
  },
  api = {
    base_url = "local://007-mcp",
    content_type = "application/json",
  },

  # Coord integration — the cartridge acts as a *client* to local-coord-mcp
  # during its on-enter hook. Used only for peer registration + status.
  coord = {
    client_kind = "claude",
    context = "007-lang",
    default_role = "journeyman",  # per task #32 (role rename 2026-04-20): master/journeyman/apprentice
    affinity_tags = [
      "007",
      "oo7",
      "language-implementation",
      "proof-analysis",
      "canonical-proof-suite",
      "coquelicot",
      "idris2",
      "rust",
    ],
    graceful_degrade = true,  # If coord server is down on enter, log a warning and continue
    coord_url = "http://127.0.0.1:7745",  # loopback-only; TLS not needed or used on localhost
  },

  # Memory auto-lift (task #12) — static-mapping fallback per DD-26 option (b).
  # When VeriSimDB FFI lands (DD-31 Task #7b), swap the adapter's lookup
  # function to a VeriSimDB query; the on-enter contract and the tag-map
  # schema stay stable.
  memory_autolift = {
    enabled = true,
    tag_map_path = "schemas/memory-tag-map.a2ml",
    # Repo-derived tags that trigger lookups on on-enter.
    base_tags = ["007", "oo7", "canonical-proof-suite", "coquelicot", "m3", "dogfooding"],
    # Max memory files returned per enter — prevents flooding the context.
    max_hits = 8,
  },

  tools = [
    # ─── Lifecycle hooks ──────────────────────────────────────────────
    mk_tool
      "oo7_on_enter"
      "Lifecycle hook — invoke when entering the 007-lang context. Registers this session as a coord peer (graceful degrade if local-coord-mcp is down), loads the 6a2 methodology pack (STATE, META, ECOSYSTEM, AGENTIC, NEUROSYM, PLAYBOOK), runs the memory auto-lift using repo-derived tags, and returns a structured A2ML payload with peer_id, session_token, methodology digests, and memory hits. Idempotent: calling twice returns the same peer_id/token."
      { session_hint = str_prop "Optional free-form label for the session (e.g. 'afternoon m3-dispatch work')" }
      [],
    mk_tool
      "oo7_on_exit"
      "Lifecycle hook — invoke before leaving the 007-lang context. Updates STATE.a2ml's last-session fields, runs a drift check (open claims? uncommitted contractile edits? stale 6a2 files?), releases any coord task claims held by this peer, and deregisters from local-coord-mcp. Returns A2ML summary with drift findings. Safe to call even if on_enter was never invoked."
      { reason = str_prop "Optional reason (e.g. 'context switch', 'session close', 'SAFE TO CLOSE')" }
      [],

    # ─── Core language runtime ────────────────────────────────────────
    mk_tool
      "oo7_parse"
      "Parse a .007 source file and return the AST as JSON. Wraps `just parse <file>`."
      { file = str_prop "Path to the .007 source file (relative to repo root)" }
      ["file"],
    mk_tool
      "oo7_run"
      "Run a .007 program and return stdout/stderr + exit code. Wraps `just run <file> <args>`."
      {
        file = str_prop "Path to the .007 source file",
        args = args_prop,
      }
      ["file"],
    mk_tool
      "oo7_trace"
      "Run a .007 program and return its decision trace (branch strategy, agent moves, exchanges). Wraps `just trace <file>`."
      { file = str_prop "Path to the .007 source file" }
      ["file"],
    mk_tool
      "oo7_demo"
      "Run the built-in 007 demo (produces a decision trace). Wraps `just demo`."
      {}
      [],
    mk_tool
      "oo7_run_examples"
      "Run every program in the examples/ directory. Wraps `just run-examples`."
      {}
      [],

    # ─── Build ────────────────────────────────────────────────────────
    mk_tool
      "oo7_build"
      "Build the entire workspace in debug mode. Wraps `just build <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_build_cli"
      "Build only the CLI binary (debug). Wraps `just build-cli`."
      {}
      [],
    mk_tool
      "oo7_build_cli_release"
      "Build only the CLI binary (release). Wraps `just build-cli-release`."
      {}
      [],
    mk_tool
      "oo7_build_watch"
      "Build and watch for changes (requires cargo-watch). Wraps `just build-watch`. Long-running; the adapter spawns + captures initial output then returns a handle."
      {}
      [],
    mk_tool
      "oo7_release"
      "Build in release mode with optimizations. Wraps `just release <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_clean"
      "Remove all build artifacts. Reversible via a subsequent build. Wraps `just clean`."
      {}
      [],
    mk_tool
      "oo7_clean_all"
      "Deep clean, including any generated files. Reversible via a subsequent build. Wraps `just clean-all`."
      {}
      [],

    # ─── Tests ────────────────────────────────────────────────────────
    mk_tool
      "oo7_test"
      "Run all tests across the workspace. Wraps `just test <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_test_parser"
      "Run only parser tests (grammar and AST). Wraps `just test-parser`."
      {}
      [],
    mk_tool
      "oo7_test_eval"
      "Run only evaluator tests. Wraps `just test-eval`."
      {}
      [],
    mk_tool
      "oo7_test_trace"
      "Run only trace tests (decision trace output). Wraps `just test-trace`."
      {}
      [],
    mk_tool
      "oo7_test_aspect"
      "Run aspect-focused integration tests. Wraps `just test-aspect`."
      {}
      [],
    mk_tool
      "oo7_test_filter"
      "Run tests matching a name pattern. Wraps `just test-filter <pattern>`."
      { pattern = str_prop "Test name substring pattern" }
      ["pattern"],
    mk_tool
      "oo7_test_verbose"
      "Run tests with full output (no capture). Wraps `just test-verbose`."
      {}
      [],

    # ─── Quality gates ────────────────────────────────────────────────
    mk_tool
      "oo7_check"
      "Pre-commit quality gate: format check + lint + test. Wraps `just check`."
      {}
      [],
    mk_tool
      "oo7_ci"
      "Full CI simulation: build + test + lint + verify + audit. Wraps `just ci`."
      {}
      [],
    mk_tool
      "oo7_preflight"
      "Full pre-release check: all quality gates + verification + spec sync. Wraps `just preflight`."
      {}
      [],
    mk_tool
      "oo7_fmt"
      "Format all Rust source files. Wraps `just fmt`."
      {}
      [],
    mk_tool
      "oo7_fmt_check"
      "Check formatting without modifying files. Wraps `just fmt-check`."
      {}
      [],
    mk_tool
      "oo7_lint"
      "Run clippy lints with warnings as errors. Wraps `just lint`."
      {}
      [],

    # ─── Dependency audits ────────────────────────────────────────────
    mk_tool
      "oo7_audit"
      "Audit dependencies for known vulnerabilities. Wraps `just audit`."
      {}
      [],
    mk_tool
      "oo7_deny"
      "Check dependency licenses and bans. Wraps `just deny`."
      {}
      [],
    mk_tool
      "oo7_outdated"
      "List outdated dependencies. Wraps `just outdated`."
      {}
      [],

    # ─── Pre-commit / security scan ───────────────────────────────────
    mk_tool
      "oo7_assail"
      "Run panic-attacker pre-commit scan (RSR mandatory). Wraps `just assail`."
      {}
      [],

    # ─── Toolchain / healing ──────────────────────────────────────────
    mk_tool
      "oo7_doctor"
      "Check all required toolchain dependencies and report health. Wraps `just doctor`."
      {}
      [],
    mk_tool
      "oo7_heal"
      "Attempt to automatically install missing tools. Wraps `just heal`."
      {}
      [],

    # ─── Contractile suite ────────────────────────────────────────────
    mk_tool
      "oo7_contractile_check"
      "Run all contractile checks (must + trust + intend + adjust + bust + dust). Wraps `just contractile-check`."
      {}
      [],
    mk_tool
      "oo7_must_check"
      "Run all must checks (hard requirements that block release). Wraps `just must-check`."
      {}
      [],
    mk_tool
      "oo7_must_check_local"
      "Run local must-contract checks only. Wraps `just must-check-local`."
      {}
      [],
    mk_tool
      "oo7_must_license_present"
      "Assert LICENSE file exists. Wraps `just must-license-present`."
      {}
      [],
    mk_tool
      "oo7_must_no_banned_files"
      "Assert no Dockerfiles or Makefiles. Wraps `just must-no-banned-files`."
      {}
      [],
    mk_tool
      "oo7_must_readme_present"
      "Assert README exists. Wraps `just must-readme-present`."
      {}
      [],
    mk_tool
      "oo7_must_spdx_headers"
      "Assert source files have SPDX license headers. Wraps `just must-spdx-headers`."
      {}
      [],
    mk_tool
      "oo7_trust_verify"
      "Run all trust verifications. Wraps `just trust-verify`."
      {}
      [],
    mk_tool
      "oo7_trust_verify_local"
      "Verify trust-contracts (delegated quality expectations). Wraps `just trust-verify-local`."
      {}
      [],
    mk_tool
      "oo7_trust_no_secrets_committed"
      "Assert no .env or credential files in repo. Wraps `just trust-no-secrets-committed`."
      {}
      [],
    mk_tool
      "oo7_trust_container_images_pinned"
      "Assert Containerfile base images use pinned digests. Wraps `just trust-container-images-pinned`."
      {}
      [],
    mk_tool
      "oo7_trust_license_content"
      "Assert LICENSE contains the expected SPDX identifier. Wraps `just trust-license-content`."
      {}
      [],
    mk_tool
      "oo7_intend_list"
      "Display declared future intents. Wraps `just intend-list`."
      {}
      [],
    mk_tool
      "oo7_intend_list_local"
      "List all intend-contracts (planned but not yet implemented). Wraps `just intend-list-local`."
      {}
      [],
    mk_tool
      "oo7_dust_status"
      "List available dust recovery actions. Wraps `just dust-status`."
      {}
      [],
    mk_tool
      "oo7_dust_status_local"
      "Show dust-contract status (deprecated or decaying items). Wraps `just dust-status-local`."
      {}
      [],
    mk_tool
      "oo7_dust_source_rollback"
      "Revert all source changes to last commit. DESTRUCTIVE — the adapter rejects this tool unless the caller holds a Tier-3 master approval. Wraps `just dust-source-rollback`."
      {}
      [],

    # ─── Verification ─────────────────────────────────────────────────
    mk_tool
      "oo7_verify"
      "Verify OpenSSF Best Practices prerequisites — fails if required files are missing. Wraps `just verify`."
      {}
      [],
    mk_tool
      "oo7_verify_harvard"
      "Verify the Harvard architecture invariant — data expressions must not contain control flow. Wraps `just verify-harvard`."
      {}
      [],
    mk_tool
      "oo7_verify_template"
      "Check for unreplaced template placeholders. Wraps `just verify-template`."
      {}
      [],

    # ─── Grammar / spec ───────────────────────────────────────────────
    mk_tool
      "oo7_grammar_check"
      "Validate Pest grammar consistency (unreachable/undefined rules). Wraps `just grammar-check`."
      {}
      [],
    mk_tool
      "oo7_spec_check"
      "Compare EBNF and Pest rule counts to identify specification drift. Wraps `just spec-check`."
      {}
      [],

    # ─── Canonical proof suite + differentials ────────────────────────
    mk_tool
      "oo7_canonical_proof_suite"
      "Aggregate canonical-proof-suite report to audits/canonical-proof-suite/REPORT.a2ml. Wraps `just canonical-proof-suite`."
      {}
      [],
    mk_tool
      "oo7_v0_differential"
      "Run the M3-v0 differential (v0 Rust oracle vs production). Floor: 17/17. Wraps `just v0-differential`."
      {}
      [],
    mk_tool
      "oo7_v1_differential"
      "Run the v1 differential corpus check (v0-vs-production agreement). Wraps `just v1-differential`."
      {}
      [],
    mk_tool
      "oo7_v1_differential_full"
      "Run the full v1 differential (nightly-grade). Wraps `just v1-differential-full`."
      {}
      [],

    # ─── Groove / control plane ───────────────────────────────────────
    mk_tool
      "oo7_groove_daemon"
      "Start the 007 Groove Daemon (control plane). Long-running; the adapter spawns + returns a handle. Wraps `just groove-daemon`."
      {}
      [],
    mk_tool
      "oo7_groove_setup"
      "Configure the Groove protocol manifest and build the control plane. Wraps `just groove-setup`."
      {}
      [],

    # ─── Containers ───────────────────────────────────────────────────
    mk_tool
      "oo7_container_build"
      "Build the container image with Podman and Chainguard base. Wraps `just container-build <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_container_run"
      "Run the container image interactively. Wraps `just container-run <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_container_verify"
      "Verify the container image builds and runs a basic health check. Wraps `just container-verify`."
      {}
      [],

    # ─── Docs / help / meta ───────────────────────────────────────────
    mk_tool
      "oo7_docs"
      "Generate Rust API documentation. Wraps `just docs <args>`."
      { args = args_prop }
      [],
    mk_tool
      "oo7_cookbook"
      "Generate the Justfile cookbook documentation in AsciiDoc. Wraps `just cookbook`."
      {}
      [],
    mk_tool
      "oo7_info"
      "Show this project's metadata and build status. Wraps `just info`."
      {}
      [],
    mk_tool
      "oo7_tour"
      "Guided tour of the project structure and key concepts. Wraps `just tour`."
      {}
      [],
    mk_tool
      "oo7_help_me"
      "Show help for common workflows. Wraps `just help-me`."
      {}
      [],
    mk_tool
      "oo7_help"
      "Show detailed help for a specific recipe, or list all if no recipe given. Wraps `just help <recipe>`."
      { recipe = str_prop "Recipe name (empty string for the full list)" }
      [],
    mk_tool
      "oo7_self_assess"
      "Analyse this project and advise what is present, missing, or needs attention. Wraps `just self-assess`."
      {}
      [],

    # ─── CRG grading ──────────────────────────────────────────────────
    mk_tool
      "oo7_crg_badge"
      "Print the CRG badge (looks for '**Current Grade:** X' in READINESS.md). Wraps `just crg-badge`."
      {}
      [],
    mk_tool
      "oo7_crg_grade"
      "Print the current CRG grade. Wraps `just crg-grade`."
      {}
      [],
  ],
}
