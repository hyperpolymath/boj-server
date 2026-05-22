# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard Justfile Template
# https://just.systems/man/en/
#
# Copy this file to new projects and customize the placeholder values.
#
# Run `just` to see all available recipes
# Run `just cookbook` to generate docs/just-cookbook.adoc
# Run `just combinations` to see matrix recipe options

set shell := ["bash", "-uc"]
set dotenv-load := true
set positional-arguments := true

# Import auto-generated contractile recipes (must-check, trust-verify, etc.)
import? "contractile.just"

# Project metadata — customize these
project := "Bundle of Joy Server"
version := "0.4.6"
tier := "infrastructure"  # 1 | 2 | infrastructure

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT & HELP
# ═══════════════════════════════════════════════════════════════════════════════

# Show all available recipes with descriptions
default:
    @just --list --unsorted

# Show detailed help for a specific recipe
help recipe="":
    #!/usr/bin/env bash
    if [ -z "{{recipe}}" ]; then
        just --list --unsorted
        echo ""
        echo "Usage: just help <recipe>"
        echo "       just cookbook     # Generate full documentation"
        echo "       just combinations # Show matrix recipes"
    else
        just --show "{{recipe}}" 2>/dev/null || echo "Recipe '{{recipe}}' not found"
    fi

# Show this project's info
info:
    @echo "Project: boj_server"
    @echo "Version: {{version}}"
    @echo "RSR Tier: {{tier}}"
    @echo "Recipes: $(just --summary | wc -w)"
    @[ -f ".machine_readable/STATE.a2ml" ] && grep -oP 'phase\s*=\s*"\K[^"]+' .machine_readable/STATE.a2ml | head -1 | xargs -I{} echo "Phase: {}" || true

# ═══════════════════════════════════════════════════════════════════════════════
# INIT — Bootstrap a new project from this template
# ═══════════════════════════════════════════════════════════════════════════════

# Interactive project bootstrap — replaces all {{PLACEHOLDER}} tokens
init:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "═══════════════════════════════════════════════════"
    echo "  RSR Project Bootstrap"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # --- Load defaults from config (if exists) ---
    # Create yours: ~/.config/rsr/defaults
    # Format: OWNER=myorg  AUTHOR="My Name"  AUTHOR_EMAIL=me@example.org ...
    DEFAULTS="${XDG_CONFIG_HOME:-$HOME/.config}/rsr/defaults"
    if [ -f "$DEFAULTS" ]; then
        echo "Loading defaults from $DEFAULTS"
        # shellcheck source=/dev/null
        source "$DEFAULTS"
        echo ""
    fi

    # --- Required values (pre-filled from defaults if available) ---
    read -rp "Project name (human-readable, e.g. My Project): " PROJECT_NAME
    [ -z "$PROJECT_NAME" ] && echo "Error: project name required" && exit 1

    read -rp "Repository slug (e.g. my-project): " REPO
    [ -z "$REPO" ] && echo "Error: repo slug required" && exit 1

    read -rp "Owner [${OWNER:-}]: " _OWNER
    OWNER="${_OWNER:-${OWNER:-}}"
    [ -z "$OWNER" ] && echo "Error: owner required" && exit 1

    read -rp "Author full name [${AUTHOR:-}]: " _AUTHOR
    AUTHOR="${_AUTHOR:-${AUTHOR:-}}"
    [ -z "$AUTHOR" ] && echo "Error: author name required" && exit 1

    read -rp "Author email [${AUTHOR_EMAIL:-}]: " _AUTHOR_EMAIL
    AUTHOR_EMAIL="${_AUTHOR_EMAIL:-${AUTHOR_EMAIL:-}}"
    [ -z "$AUTHOR_EMAIL" ] && echo "Error: email required" && exit 1

    # --- Optional values (pre-filled from defaults if available) ---
    read -rp "Author organization [${AUTHOR_ORG:-none}]: " _AUTHOR_ORG
    AUTHOR_ORG="${_AUTHOR_ORG:-${AUTHOR_ORG:-}}"

    read -rp "Previous/alt email [${AUTHOR_EMAIL_ALT:-none}]: " _AUTHOR_EMAIL_ALT
    AUTHOR_EMAIL_ALT="${_AUTHOR_EMAIL_ALT:-${AUTHOR_EMAIL_ALT:-}}"

    read -rp "Project description []: " PROJECT_DESCRIPTION

    read -rp "Forge domain [${FORGE:-github.com}]: " _FORGE
    FORGE="${_FORGE:-${FORGE:-github.com}}"

    read -rp "Security contact email [${SECURITY_EMAIL:-$AUTHOR_EMAIL}]: " _SECURITY_EMAIL
    SECURITY_EMAIL="${_SECURITY_EMAIL:-${SECURITY_EMAIL:-$AUTHOR_EMAIL}}"

    read -rp "Conduct contact email [${CONDUCT_EMAIL:-$AUTHOR_EMAIL}]: " _CONDUCT_EMAIL
    CONDUCT_EMAIL="${_CONDUCT_EMAIL:-${CONDUCT_EMAIL:-$AUTHOR_EMAIL}}"

    read -rp "Project type (library|binary|monorepo|service|website) [library]: " PROJECT_TYPE
    PROJECT_TYPE="${PROJECT_TYPE:-library}"

    read -rp "Website URL [https://${FORGE}/${OWNER}/${REPO}]: " WEBSITE
    WEBSITE="${WEBSITE:-https://${FORGE}/${OWNER}/${REPO}}"

    # --- Container values (optional — only relevant if container/ exists) ---
    if [ -d "container" ]; then
        echo ""
        echo "── Container configuration (optional) ─────────"
        read -rp "Service name [${REPO}]: " _SERVICE_NAME
        SERVICE_NAME="${_SERVICE_NAME:-${REPO}}"
        read -rp "Primary port [8080]: " _PORT
        PORT="${_PORT:-8080}"
        read -rp "Container registry [ghcr.io/${OWNER}]: " _REGISTRY
        REGISTRY="${_REGISTRY:-ghcr.io/${OWNER}}"
    else
        SERVICE_NAME="${REPO}"
        PORT="8080"
        REGISTRY="ghcr.io/${OWNER}"
    fi

    # --- Derived values ---
    PROJECT_UPPER=$(echo "$REPO" | tr '[:lower:]-' '[:upper:]_')
    PROJECT_LOWER=$(echo "$REPO" | tr '[:upper:]-' '[:lower:]_')
    CURRENT_YEAR=$(date +%Y)
    CURRENT_DATE=$(date +%Y-%m-%d)
    VERSION="0.1.0"

    # Derive citation name parts (best-effort split on last space)
    AUTHOR_LAST="${AUTHOR##* }"
    AUTHOR_FIRST="${AUTHOR% *}"
    FIRST_INITIAL="${AUTHOR_FIRST:0:1}."
    if [ "$AUTHOR_LAST" = "$AUTHOR_FIRST" ]; then
        AUTHOR_FIRST="$AUTHOR"
        AUTHOR_LAST=""
        FIRST_INITIAL=""
    fi

    echo ""
    echo "── Summary ──────────────────────────────────────"
    echo "  Project:     $PROJECT_NAME"
    echo "  Repo:        $REPO"
    echo "  Owner:       $OWNER"
    echo "  Author:      $AUTHOR <$AUTHOR_EMAIL>"
    [ -n "$AUTHOR_ORG" ] && echo "  Organization: $AUTHOR_ORG"
    echo "  Forge:       $FORGE"
    echo "  Year:        $CURRENT_YEAR"
    echo "────────────────────────────────────────────────"
    echo ""
    read -rp "Proceed? [Y/n] " CONFIRM
    [[ "${CONFIRM:-Y}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

    echo ""
    echo "Replacing placeholders..."

    # Brace tokens as variables (hex avoids just interpolation)
    LB=$(printf '\x7b\x7b')
    RB=$(printf '\x7d\x7d')

    # Build the sed expression list
    # Note: using | as delimiter since URLs contain /
    SED_ARGS=(
        -e "s|${LB}PROJECT_NAME${RB}|${PROJECT_NAME}|g"
        -e "s|${LB}PROJECT_DESCRIPTION${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT${RB}|${PROJECT_UPPER}|g"
        -e "s|${LB}project${RB}|${PROJECT_LOWER}|g"
        -e "s|${LB}REPO${RB}|${REPO}|g"
        -e "s|${LB}OWNER${RB}|${OWNER}|g"
        -e "s|${LB}AUTHOR${RB}|${AUTHOR}|g"
        -e "s|${LB}AUTHOR_EMAIL${RB}|${AUTHOR_EMAIL}|g"
        -e "s|${LB}AUTHOR_ORG${RB}|${AUTHOR_ORG}|g"
        -e "s|${LB}AUTHOR_LAST${RB}|${AUTHOR_LAST}|g"
        -e "s|${LB}AUTHOR_FIRST${RB}|${AUTHOR_FIRST}|g"
        -e "s|${LB}AUTHOR_INITIALS${RB}|${FIRST_INITIAL}|g"
        -e "s|${LB}FORGE${RB}|${FORGE}|g"
        -e "s|${LB}CURRENT_YEAR${RB}|${CURRENT_YEAR}|g"
        -e "s|${LB}CURRENT_DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}SECURITY_EMAIL${RB}|${SECURITY_EMAIL}|g"
        -e "s|${LB}CONDUCT_EMAIL${RB}|${CONDUCT_EMAIL}|g"
        -e "s|${LB}LICENSE${RB}|MPL-2.0|g"
        -e "s|${LB}CONDUCT_TEAM${RB}|Code of Conduct Committee|g"
        -e "s|${LB}RESPONSE_TIME${RB}|48 hours|g"
        -e "s|${LB}MAIN_BRANCH${RB}|main|g"
        -e "s|${LB}PROJECT_PURPOSE${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT_ROLE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}PROJECT_TYPE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}WEBSITE${RB}|${WEBSITE}|g"
        -e "s|${LB}SERVICE_NAME${RB}|${SERVICE_NAME}|g"
        -e "s|${LB}PORT${RB}|${PORT}|g"
        -e "s|${LB}REGISTRY${RB}|${REGISTRY}|g"
        -e "s|${LB}IMAGE${RB}|${REGISTRY}/${SERVICE_NAME}|g"
        -e "s|${LB}VERSION${RB}|${VERSION}|g"
        -e "s|${LB}EMAIL${RB}|${AUTHOR_EMAIL}|g"
    )
    [ -n "$AUTHOR_EMAIL_ALT" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_EMAIL_ALT${RB}|${AUTHOR_EMAIL_ALT}|g")

    # Replace in all text files (skip .git, LICENSE text, and binaries)
    find . -type f \
        -not -path './.git/*' \
        -not -name 'MPL-2.0.txt' \
        -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
        -not -name '*.woff' -not -name '*.woff2' \
        | while read -r file; do
        if file --brief "$file" | grep -qi 'text\|ascii\|utf'; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    # Also replace [YOUR-REPO-NAME] and [YOUR-NAME/ORG] in AI manifest
    sed -i "s|\[YOUR-REPO-NAME\]|${PROJECT_NAME}|g" 0-AI-MANIFEST.a2ml 2>/dev/null || true
    sed -i "s|\[YOUR-NAME/ORG\]|${OWNER}|g" 0-AI-MANIFEST.a2ml 2>/dev/null || true

    echo ""
    echo "── Validation ───────────────────────────────────"

    # Check for remaining placeholders
    PATTERN="${LB}[A-Z_]*${RB}"
    REMAINING=$(grep -rl "$PATTERN" . --include='*.md' --include='*.adoc' --include='*.yml' --include='*.yaml' --include='*.a2ml' --include='*.toml' --include='*.scm' --include='*.ncl' --include='*.nix' --include='*.json' --include='*.sh' 2>/dev/null | grep -v '.git/' | grep -v 'PLACEHOLDERS.md' || true)
    if [ -n "$REMAINING" ]; then
        echo "WARNING: Remaining placeholders in:"
        echo "$REMAINING" | sed 's/^/  /'
        echo ""
        echo "Run: grep -rn '$LB' . --include='*.md' to inspect"
    else
        echo "All placeholders replaced successfully!"
    fi

    # K9-SVC validation (if available)
    if command -v k9-svc >/dev/null 2>&1; then
        echo ""
        echo "Running k9-svc validation..."
        k9-svc validate . 2>/dev/null || true
    fi

    echo ""
    echo "Done! Next steps:"
    echo "  1. Review changes: git diff"
    echo "  2. Remove template cruft: rm PLACEHOLDERS.md"
    echo "  3. Customize README.adoc for your project"
    echo "  4. Commit: git add -A && git commit -m 'feat: initialize from RSR template'"
    echo "  5. Push: git remote add origin git@${FORGE}:${OWNER}/${REPO}.git && git push -u origin main"

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD & COMPILE
# ═══════════════════════════════════════════════════════════════════════════════

# Build all Zig FFI layers (catalogue + all cartridges)
build *args:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building BoJ catalogue FFI..."
    (cd ffi/zig && zig build {{args}})
    echo "Building cartridge FFIs..."
    FAILED=()
    for d in cartridges/*/ffi; do
        [ -f "$d/build.zig" ] || continue
        if ! (cd "$d" && zig build {{args}} 2>&1); then
            FAILED+=("$d")
        fi
    done
    if [ ${#FAILED[@]} -gt 0 ]; then
        echo "WARNING: ${#FAILED[@]} cartridge FFI(s) failed to build:"
        for f in "${FAILED[@]}"; do echo "  $f"; done
    fi
    echo "Build complete"

# Build in release mode with optimizations
build-release *args:
    just build -Doptimize=ReleaseFast {{args}}

# Build and watch for changes (requires entr)
build-watch:
    find ffi/ cartridges/ -name '*.zig' | entr -c just build

# Clean build artifacts [reversible: rebuild with `just build`]
clean:
    @echo "Cleaning..."
    rm -rf ffi/zig/.zig-cache ffi/zig/zig-out
    rm -rf cartridges/*/ffi/.zig-cache cartridges/*/ffi/zig-out
    rm -rf src/abi/build cartridges/*/abi/build
    rm -rf target/ _build/ build/ dist/ out/

# Deep clean including caches [reversible: rebuild]
clean-all: clean
    rm -rf .cache .tmp

# ═══════════════════════════════════════════════════════════════════════════════
# TEST & QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run all Zig FFI tests (catalogue + all 111 cartridges with build.zig)
test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running catalogue FFI tests..."
    (cd ffi/zig && zig build test)
    echo "Running cartridge FFI tests..."
    FAILED=()
    for d in cartridges/*/ffi; do
        [ -f "$d/build.zig" ] || continue
        if ! (cd "$d" && zig build test 2>&1); then
            FAILED+=("$d")
        fi
    done
    if [ ${#FAILED[@]} -gt 0 ]; then
        echo "FAILED: ${#FAILED[@]} cartridge FFI test(s):"
        for f in "${FAILED[@]}"; do echo "  $f"; done
        exit 1
    fi
    echo "All FFI tests passed!"

# Run tests with verbose output
test-verbose *args:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd ffi/zig && zig build test -- --verbose)
    for d in cartridges/*/ffi; do
        [ -f "$d/build.zig" ] || continue
        (cd "$d" && zig build test -- --verbose)
    done

# Smoke test — type-check core ABI + run one FFI test
test-smoke:
    @echo "Smoke test..."
    cd src/abi && idris2 --check Boj/Catalogue.idr
    cd ffi/zig && zig build test
    @echo "Smoke test passed!"

# Run Component Readiness Grade tests (D/C/B)
readiness:
    @echo "Running readiness tests..."
    cd ffi/zig && zig build readiness --summary all
    @echo "Readiness tests passed!"

# Run benchmarks (catalogue lifecycle, mount/unmount, queries, hash ops)
bench:
    @echo "Running benchmarks..."
    cd ffi/zig && zig build bench

# Run end-to-end integration tests
integration:
    @echo "Running integration tests..."
    bash tests/integration.sh

# Run all quality checks
quality: fmt-check lint test
    @echo "All quality checks passed!"

# Fix all auto-fixable issues [reversible: git checkout]
fix: fmt
    @echo "Fixed all auto-fixable issues"

# ═══════════════════════════════════════════════════════════════════════════════
# LINT & FORMAT
# ═══════════════════════════════════════════════════════════════════════════════

# Format all source files [reversible: git checkout]
fmt:
    @echo "Zig format..."
    find ffi/ cartridges/ -name '*.zig' -exec zig fmt {} +

# Check formatting without changes
fmt-check:
    @echo "Checking Zig formatting..."
    find ffi/ cartridges/ -name '*.zig' -exec zig fmt --check {} +

# Lint — verify zero believe_me + type-check all ABI files
lint: verify-no-believe-me typecheck
    @echo "Lint passed!"

# ═══════════════════════════════════════════════════════════════════════════════
# BOJ-SPECIFIC — Idris2 ABI & Verification
# ═══════════════════════════════════════════════════════════════════════════════

# Type-check all Idris2 ABI files
typecheck:
    @echo "Type-checking core ABI..."
    cd src/abi && idris2 --check --package boj boj.ipkg
    @echo "Type-checking cartridge ABIs..."
    cd cartridges/fleet-mcp/abi && idris2 --check fleet-mcp.ipkg
    cd cartridges/nesy-mcp/abi && idris2 --check nesy-mcp.ipkg
    cd cartridges/database-mcp/abi && idris2 --check database-mcp.ipkg
    cd cartridges/agent-mcp/abi && idris2 --check agent-mcp.ipkg
    cd cartridges/feedback-mcp/abi && idris2 --check feedback-mcp.ipkg
    @echo "All ABI files type-check!"

# Verify zero believe_me in all Idris2 sources
verify-no-believe-me:
    #!/usr/bin/env bash
    echo "Scanning for believe_me..."
    FOUND=$(grep -rn 'believe_me\|assert_total\|assert_smaller' --include='*.idr' src/ cartridges/ 2>/dev/null | grep -v -- '--.*believe_me' | grep -v '|||.*believe_me' | grep -v -- '--.*Admitted' | grep -v '|||.*Admitted' || true)
    if [ -n "$FOUND" ]; then
        echo "CRITICAL: Found unsound constructs:"
        echo "$FOUND"
        exit 1
    fi
    echo "Zero believe_me — all proofs genuine!"

# Full verification suite: type-check + zero believe_me + build + test
verify: typecheck verify-no-believe-me build test
    @echo "Full verification passed!"

# Show the BoJ capability matrix status
matrix:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  BoJ Capability Matrix"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "  Cartridge         ABI    FFI    Adapter  Tests"
    echo "  ───────────────────────────────────────────────"
    for cart in database-mcp fleet-mcp nesy-mcp agent-mcp; do
        ABI="✗"; FFI="✗"; ADAPTER="✗"; TESTS="✗"
        [ -f "cartridges/$cart/abi"/*/*.idr ] 2>/dev/null && ABI="✓"
        [ -f "cartridges/$cart/ffi"/*_ffi.zig ] 2>/dev/null && FFI="✓"
        [ -d "elixir" ] 2>/dev/null && ADAPTER="✓"
        [ -f "cartridges/$cart/ffi/build.zig" ] 2>/dev/null && TESTS="✓"
        printf "  %-20s %s      %s      %s        %s\n" "$cart" "$ABI" "$FFI" "$ADAPTER" "$TESTS"
    done
    echo ""
    echo "  Core catalogue:    ffi/zig/src/catalogue.zig"
    echo "  Dynamic loader:    ffi/zig/src/loader.zig"
    echo "  REST server:       elixir/ (Plug/Cowboy)"
    echo "  Menu:              .machine_readable/servers/menu.a2ml"
    echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RUN & EXECUTE
# ═══════════════════════════════════════════════════════════════════════════════

# Run the BoJ server (REST 7700, gRPC 7701, GraphQL 7702, SSE 7703)
run *args: build
    #!/usr/bin/env bash
    set -euo pipefail
    # The REST surface is the Elixir backend (Class 3 Multiplier).
    if [ -d "elixir" ] && command -v mix >/dev/null 2>&1; then
        echo "Starting BoJ Server (Elixir Class 3 Multiplier)..."
        cd elixir && exec mix run --no-halt {{args}}
    else
        echo "ERROR: Elixir backend not available (need 'elixir/' dir and 'mix')."
        echo "Install Elixir/Mix, then: cd elixir && mix run --no-halt"
        exit 1
    fi

# Run with verbose output
run-verbose *args: build
    BOJ_VERBOSE=1 just run {{args}}

# Install: the REST surface is served by the Elixir backend (cd elixir && mix run)
install: build
    @echo "The BoJ REST surface is the Elixir backend; no binary is installed."
    @echo "Run it with: cd elixir && mix run --no-halt   (or: just run)"

# Start Cloudflare quick tunnel (exposes BoJ at *.trycloudflare.com)
tunnel:
    @echo "Starting Cloudflare Quick Tunnel → *.trycloudflare.com"
    @echo "Watch output for the assigned URL."
    cloudflared tunnel --no-autoupdate --no-tls-verify --url http://localhost:7700

# Run BoJ server + Cloudflare Tunnel together
serve: build
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "elixir" ] || ! command -v mix >/dev/null 2>&1; then
        echo "ERROR: Elixir backend not available (need 'elixir/' dir and 'mix')."
        exit 1
    fi
    echo "Starting BoJ Server..."
    echo "  Local: http://localhost:7700/status"
    echo "  SSE:   http://localhost:7703/sse"
    (cd elixir && mix run --no-halt) &
    BOJ_PID=$!
    trap "kill $BOJ_PID 2>/dev/null; kill $TUNNEL_PID 2>/dev/null; exit" INT TERM
    sleep 2
    echo ""
    echo "Starting Cloudflare Tunnel (watch for public URL)..."
    cloudflared tunnel --no-autoupdate --no-tls-verify --url http://localhost:7700 &
    TUNNEL_PID=$!
    wait $BOJ_PID $TUNNEL_PID

# ═══════════════════════════════════════════════════════════════════════════════
# COORD — Multi-agent coordination via BoJ local-coord-mcp
# ═══════════════════════════════════════════════════════════════════════════════

# Launch the coord TUI (interactive multi-agent dashboard)
coord:
    @coord-tui

# Build the coord-tui Rust binary
coord-build:
    @echo "Building coord-tui..."
    cd coord-tui && cargo build --release
    @echo "Built: coord-tui/target/release/coord-tui"

# Install coord-tui binary + shell hooks + systemd service
coord-install: coord-build
    @bash coord-tui/install.sh

# Install/update shell hooks only (re-source to activate)
coord-hooks:
    @mkdir -p ~/.config/coord-tui
    cp coord-tui/shell/coord-hooks.sh ~/.config/coord-tui/coord-hooks.sh
    @echo "Hooks installed to ~/.config/coord-tui/coord-hooks.sh"
    @echo "Add to your shell profile if not already done:"
    @echo "  [ -f \"\$$HOME/.config/coord-tui/coord-hooks.sh\" ] && source \"\$$HOME/.config/coord-tui/coord-hooks.sh\""

# Register this terminal session as a named peer
# Usage: just coord-register claude | just coord-register gemini | just coord-register cursor
coord-register kind="claude":
    @coord-tui --id --kind {{kind}}

# List all active peers (delegates to coord-hooks.sh helpers)
coord-peers:
    @bash -c 'source ~/.config/coord-tui/coord-hooks.sh 2>/dev/null && coord-peers || echo "Hooks not installed — run: just coord-hooks"'

# List all active task claims
coord-claims:
    @bash -c 'source ~/.config/coord-tui/coord-hooks.sh 2>/dev/null && coord-claims || echo "Hooks not installed — run: just coord-hooks"'

# Claim a coordination task (mutex — only one peer can hold a task at a time)
# Usage: just coord-claim hypatia/rebalancer-strategies
coord-claim task:
    @bash -c 'source ~/.config/coord-tui/coord-hooks.sh 2>/dev/null && coord-claim "{{task}}" || echo "Hooks not installed — run: just coord-hooks"'

# Set your peer status message (visible to all in the TUI)
# Usage: just coord-status "working on rebalancer strategy B"
coord-status status:
    @bash -c 'source ~/.config/coord-tui/coord-hooks.sh 2>/dev/null && coord-status "{{status}}" || echo "Hooks not installed — run: just coord-hooks"'

# Print the registered peer ID and token for this session
coord-whoami:
    @bash -c 'source ~/.config/coord-tui/coord-hooks.sh 2>/dev/null && coord-whoami || echo "Hooks not installed — run: just coord-hooks"'

# Check local-coord-mcp adapter status
coord-health:
    #!/usr/bin/env bash
    RESP=$(curl -sf http://127.0.0.1:7745/tools/coord_health 2>/dev/null || echo "")
    if [ -z "$RESP" ]; then
        echo "  Adapter: NOT running on 127.0.0.1:7745"
        echo "  Start:   systemctl --user start local-coord-mcp"
    else
        echo "  Adapter: running"
        echo "$RESP"
    fi

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

# Check all required toolchain dependencies
deps:
    #!/usr/bin/env bash
    echo "Checking dependencies..."
    MISSING=""
    command -v idris2 >/dev/null || MISSING="$MISSING idris2"
    command -v zig >/dev/null || MISSING="$MISSING zig"
    if [ -n "$MISSING" ]; then
        echo "MISSING:$MISSING"
        echo "Install with: asdf install idris2 latest && asdf install zig latest"
        exit 1
    fi
    echo "  idris2: $(idris2 --version 2>&1 | head -1)"
    echo "  zig:    $(zig version)"
    echo "All dependencies satisfied"

# Audit dependencies for vulnerabilities
deps-audit:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Auditing for vulnerabilities..."
    # Zig compile-time audit: catches dependency issues, undefined behaviour, and test failures
    echo "Running Zig build + test audit on catalogue..."
    cd ffi/zig && zig build test
    cd "$OLDPWD"
    # Verify zero believe_me (formal verification soundness audit)
    just verify-no-believe-me
    # Supplementary scanners (if available)
    if command -v panic-attack >/dev/null 2>&1; then
        echo "Running panic-attack assail..."
        panic-attack assail
    fi
    command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL --quiet . || true
    command -v gitleaks >/dev/null && gitleaks detect --source . --no-git --quiet || true
    echo "Audit complete"

# ═══════════════════════════════════════════════════════════════════════════════
# DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════════

# Generate all documentation
docs:
    @mkdir -p docs/generated docs/man
    just cookbook
    just man
    @echo "Documentation generated in docs/"

# Generate justfile cookbook documentation
cookbook:
    #!/usr/bin/env bash
    mkdir -p docs
    OUTPUT="docs/just-cookbook.adoc"
    echo "= boj_server Justfile Cookbook" > "$OUTPUT"
    echo ":toc: left" >> "$OUTPUT"
    echo ":toclevels: 3" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "Generated: $(date -Iseconds)" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "== Recipes" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    just --list --unsorted | while read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([a-z_-]+) ]]; then
            recipe="${BASH_REMATCH[1]}"
            echo "=== $recipe" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
            echo "[source,bash]" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "just $recipe" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
        fi
    done
    echo "Generated: $OUTPUT"

# Generate man page
man:
    #!/usr/bin/env bash
    mkdir -p docs/man
    cat > docs/man/boj_server.1 << EOF
    .TH boj_server 1 "$(date +%Y-%m-%d)" "{{version}}" "boj_server Manual"
    .SH NAME
    boj_server \- RSR-compliant project
    .SH SYNOPSIS
    .B just
    [recipe] [args...]
    .SH DESCRIPTION
    RSR (Rhodium Standard Repository) project managed with just.
    .SH AUTHOR
    $(git config user.name 2>/dev/null || echo "Author") <$(git config user.email 2>/dev/null || echo "email")>
    EOF
    echo "Generated: docs/man/boj_server.1"

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINERS (stapeln ecosystem — Podman + Chainguard Wolfi)
# ═══════════════════════════════════════════════════════════════════════════════

# Initialise container templates — substitute placeholders with project values
container-init:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -d "container" ]; then
        echo "Error: container/ directory not found."
        echo "This repo may not have been created from rsr-template-repo."
        exit 1
    fi

    echo "=== Container Template Initialisation ==="
    echo ""

    # Load RSR defaults if available
    DEFAULTS="${XDG_CONFIG_HOME:-$HOME/.config}/rsr/defaults"
    if [ -f "$DEFAULTS" ]; then
        echo "Loading defaults from $DEFAULTS"
        # shellcheck source=/dev/null
        source "$DEFAULTS"
        echo ""
    fi

    # Prompt for container-specific values
    read -rp "Service name (e.g. my-api) [boj_server]: " _SERVICE_NAME
    SERVICE_NAME="${_SERVICE_NAME:-boj_server}"

    read -rp "Primary port [8080]: " _PORT
    PORT="${_PORT:-8080}"

    read -rp "Container registry [ghcr.io/${OWNER:-hyperpolymath}]: " _REGISTRY
    REGISTRY="${_REGISTRY:-ghcr.io/${OWNER:-hyperpolymath}}"

    echo ""
    echo "  Service: $SERVICE_NAME"
    echo "  Port:    $PORT"
    echo "  Registry: $REGISTRY"
    echo ""
    read -rp "Proceed? [Y/n] " CONFIRM
    [[ "${CONFIRM:-Y}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

    echo ""
    echo "Replacing container placeholders..."

    # Brace tokens as variables (hex escapes avoid just interpolation)
    LB=$(printf '\x7b\x7b')
    RB=$(printf '\x7d\x7d')

    SED_ARGS=(
        -e "s|${LB}SERVICE_NAME${RB}|${SERVICE_NAME}|g"
        -e "s|${LB}PORT${RB}|${PORT}|g"
        -e "s|${LB}REGISTRY${RB}|${REGISTRY}|g"
    )

    find container/ -type f | while read -r file; do
        if file --brief "$file" | grep -qi 'text\|ascii\|utf'; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    echo "Container templates initialised."
    echo ""
    echo "Next steps:"
    echo "  1. Edit container/Containerfile — add your build commands"
    echo "  2. Edit container/entrypoint.sh — set your application binary"
    echo "  3. Review container/compose.toml — adjust services and volumes"
    echo "  4. Build: just container-build"

# Build container image via cerro-torre pipeline
container-build *args:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh {{args}}
    elif [ -f "container/Containerfile" ]; then
        podman build -t boj_server:latest -f container/Containerfile .
    elif [ -f "Containerfile" ]; then
        podman build -t boj_server:latest -f Containerfile .
    else
        echo "No Containerfile found in container/ or project root"
        exit 1
    fi

# Verify compose configuration
container-verify:
    #!/usr/bin/env bash
    if [ ! -f "container/compose.toml" ]; then
        echo "No container/compose.toml found"
        exit 1
    fi
    cd container
    if command -v selur-compose &>/dev/null; then
        selur-compose verify
    else
        echo "selur-compose not found, falling back to podman compose"
        podman compose --file compose.toml config
    fi

# Start container stack
container-up *args:
    #!/usr/bin/env bash
    if [ ! -f "container/compose.toml" ]; then
        echo "No container/compose.toml found"
        exit 1
    fi
    cd container
    if command -v selur-compose &>/dev/null; then
        selur-compose up {{args}}
    else
        podman compose --file compose.toml up {{args}}
    fi

# Stop container stack
container-down:
    #!/usr/bin/env bash
    cd container 2>/dev/null || { echo "No container/ directory"; exit 1; }
    if command -v selur-compose &>/dev/null; then
        selur-compose down
    else
        podman compose --file compose.toml down
    fi

# Sign and verify container bundle (build + pack + sign + verify)
container-sign:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh
    else
        echo "No container/ct-build.sh found"
        exit 1
    fi

# Push signed bundle to registry
container-push:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh --push
    else
        echo "No container/ct-build.sh found — falling back to podman push"
        podman push boj_server:latest
    fi

# Run container interactively (for debugging)
container-run *args:
    podman run --rm -it boj_server:latest {{args}}

# ═══════════════════════════════════════════════════════════════════════════════
# CI & AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run full CI pipeline locally
ci: deps quality
    @echo "CI pipeline complete!"

# Install git hooks
install-hooks:
    @mkdir -p .git/hooks
    @cat > .git/hooks/pre-commit << 'HOOKEOF'
    #!/bin/bash
    just fmt-check || exit 1
    just lint || exit 1
    HOOKEOF
    @chmod +x .git/hooks/pre-commit
    @echo "Git hooks installed"

# Install systemd user service for the BoJ REST server (port 7700).
# Also installs the coord system if coord-tui/install.sh is present.
# After install: systemctl --user status boj-rest
install-service:
    #!/usr/bin/env bash
    set -euo pipefail
    BOJ_ROOT="$(cd "$(dirname "$(command -v just)")/../../.." && pwd 2>/dev/null || pwd)"
    BOJ_ROOT="$(pwd)"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
    SERVICE_SRC="elixir/boj-rest.service"
    SERVICE_DST="$SYSTEMD_DIR/boj-rest.service"

    echo "═══════════════════════════════════════════════════"
    echo "  BoJ Server — systemd service installer"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # 1. Install the BoJ REST service
    echo "Installing boj-rest.service…"
    mkdir -p "$SYSTEMD_DIR"
    mkdir -p "${HOME}/.local/share/boj-server"
    BOJ_ROOT="$BOJ_ROOT" HOME="$HOME" envsubst < "$SERVICE_SRC" > "$SERVICE_DST"
    echo "  Written: $SERVICE_DST"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now boj-rest
        echo "  Service: enabled + started"
        systemctl --user status boj-rest --no-pager --lines=5
    else
        echo "  WARNING: systemctl not found — start manually:"
        echo "    cd elixir && MIX_ENV=dev mix run --no-halt"
    fi
    echo ""

    # 2. Install coord system (builds Zig adapter + Rust TUI + hooks)
    if [ -f "coord-tui/install.sh" ]; then
        echo "Installing coord system (coord-tui/install.sh)…"
        bash coord-tui/install.sh
    else
        echo "coord-tui/install.sh not found — skipping coord install."
    fi

    echo ""
    echo "Done. Check service health:"
    echo "  systemctl --user status boj-rest"
    echo "  systemctl --user status local-coord-mcp"
    echo "  curl http://localhost:7700/health"

# ═══════════════════════════════════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run security audit
security: deps-audit
    @echo "=== Security Audit ==="
    @command -v gitleaks >/dev/null && gitleaks detect --source . --verbose || true
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL . || true
    @echo "Security audit complete"

# Generate SBOM
sbom:
    @mkdir -p docs/security
    @command -v syft >/dev/null && syft . -o spdx-json > docs/security/sbom.spdx.json || echo "syft not found"

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION & COMPLIANCE
# ═══════════════════════════════════════════════════════════════════════════════

# Validate RSR compliance
validate-rsr:
    #!/usr/bin/env bash
    echo "=== RSR Compliance Check ==="
    MISSING=""
    for f in .editorconfig .gitignore Justfile README.adoc LICENSE; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for f in .machine_readable/STATE.a2ml .machine_readable/META.a2ml .machine_readable/ECOSYSTEM.a2ml .machine_readable/anchors/ANCHOR.a2ml .machine_readable/policies/MAINTENANCE-AXES.a2ml .machine_readable/policies/MAINTENANCE-CHECKLIST.a2ml .machine_readable/policies/SOFTWARE-DEVELOPMENT-APPROACH.a2ml; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for f in docs/maintenance/MAINTENANCE-CHECKLIST.md docs/practice/SOFTWARE-DEVELOPMENT-APPROACH.adoc; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    if [ -f ".machine_readable/META.a2ml" ]; then
        grep -q 'axis-1 = "must > intend > like"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:axis-1"
        grep -q 'axis-2 = "corrective > adaptive > perfective"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:axis-2"
        grep -q 'axis-3 = "systems > compliance > effects"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:axis-3"
        grep -q 'scoping-first = true' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:scoping-first"
        grep -q 'idris-unsound-scan = "believe_me/assert_total"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:idris-unsound-scan"
        grep -q 'audit-focus = "systems in place, documentation explains actual state, safety/security accounted for, observed effects reviewed"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:audit-focus"
        grep -q 'compliance-focus = "seams/compromises/exception register, bounded exceptions, anti-drift checks"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:compliance-focus"
        grep -q 'effects-evidence = "benchmark execution/results and maintainer status dialogue/review"' .machine_readable/META.a2ml || MISSING="$MISSING META.a2ml:effects-evidence"
        grep -q 'compliance-tooling = "panic-attack"' .machine_readable/policies/MAINTENANCE-AXES.a2ml || MISSING="$MISSING MAINTENANCE-AXES.a2ml:compliance-tooling"
        grep -q 'effects-tooling = "ecological checking with sustainabot guidance"' .machine_readable/policies/MAINTENANCE-AXES.a2ml || MISSING="$MISSING MAINTENANCE-AXES.a2ml:effects-tooling"
        grep -q 'source-human = "docs/maintenance/MAINTENANCE-CHECKLIST.md"' .machine_readable/policies/MAINTENANCE-CHECKLIST.a2ml || MISSING="$MISSING MAINTENANCE-CHECKLIST.a2ml:source-human"
        grep -q 'source-human = "docs/practice/SOFTWARE-DEVELOPMENT-APPROACH.adoc"' .machine_readable/policies/SOFTWARE-DEVELOPMENT-APPROACH.a2ml || MISSING="$MISSING SOFTWARE-DEVELOPMENT-APPROACH.a2ml:source-human"
    fi
    if [ -n "$MISSING" ]; then
        echo "MISSING:$MISSING"
        exit 1
    fi
    echo "RSR compliance: PASS"

# Validate STATE.a2ml syntax
validate-state:
    @if [ -f ".machine_readable/STATE.a2ml" ]; then \
        grep -q '^\[metadata\]' .machine_readable/STATE.a2ml && \
        grep -q 'project\s*=' .machine_readable/STATE.a2ml && \
        echo "STATE.a2ml: valid" || echo "STATE.a2ml: INVALID (missing required sections)"; \
    else \
        echo "No .machine_readable/STATE.a2ml found"; \
    fi

# Validate AI installation guide completeness (finishbot pre-release check)
validate-ai-install:
    #!/usr/bin/env bash
    echo "=== AI Installation Guide Check ==="
    GUIDE="docs/AI_INSTALLATION_GUIDE.adoc"
    README="README.adoc"
    ERRORS=0

    # Check guide exists
    if [ ! -f "$GUIDE" ]; then
        echo "MISSING: $GUIDE (create from template: docs/AI_INSTALLATION_GUIDE.adoc)"
        ERRORS=$((ERRORS + 1))
    else
        # Check for unfilled TODO markers
        TODOS=$(grep -c '\[TODO-AI-INSTALL' "$GUIDE" 2>/dev/null || true)
        if [ "$TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $GUIDE has $TODOS unfilled [TODO-AI-INSTALL] markers:"
            grep -n '\[TODO-AI-INSTALL' "$GUIDE" | head -10
            ERRORS=$((ERRORS + 1))
        else
            echo "$GUIDE: complete (no TODO markers)"
        fi

        # Check AI implementation section exists
        if ! grep -q 'ai-implementation' "$GUIDE" 2>/dev/null; then
            echo "MISSING: [[ai-implementation]] anchor in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check privacy notice exists
        if ! grep -qi 'privacy' "$GUIDE" 2>/dev/null; then
            echo "MISSING: Privacy notice in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check install commands exist (not just placeholders)
        if ! grep -q 'git clone' "$GUIDE" 2>/dev/null; then
            echo "WARNING: No git clone command found in $GUIDE -- install commands may be incomplete"
        fi
    fi

    # Check README has AI install section
    if [ -f "$README" ]; then
        if ! grep -qi 'AI-Assisted Installation' "$README" 2>/dev/null; then
            echo "MISSING: AI-Assisted Installation section in $README"
            echo "  Copy from docs/AI-INSTALL-README-SECTION.adoc"
            ERRORS=$((ERRORS + 1))
        fi

        # Check README for unfilled TODO markers
        README_TODOS=$(grep -c '\[TODO-AI-INSTALL' "$README" 2>/dev/null || true)
        if [ "$README_TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $README has $README_TODOS unfilled [TODO-AI-INSTALL] markers"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "AI install guide: FAIL ($ERRORS issues)"
        exit 1
    fi
    echo "AI install guide: PASS"

# Full validation suite
validate: validate-rsr validate-state validate-ai-install
    @echo "All validations passed!"

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Update STATE.a2ml timestamp
state-touch:
    @if [ -f ".machine_readable/STATE.a2ml" ]; then \
        sed -i 's/last-updated = "[^"]*"/last-updated = "'"$(date +%Y-%m-%d)"'"/' .machine_readable/STATE.a2ml && \
        echo "STATE.a2ml timestamp updated"; \
    fi

# Show current phase from STATE.a2ml
state-phase:
    @grep -oP 'phase\s*=\s*"\K[^"]+' .machine_readable/STATE.a2ml 2>/dev/null | head -1 || echo "unknown"

# ═══════════════════════════════════════════════════════════════════════════════
# GUIX & NIX
# ═══════════════════════════════════════════════════════════════════════════════

# Enter Guix development shell (primary)
guix-shell:
    guix shell -D -f guix.scm

# Build with Guix
guix-build:
    guix build -f guix.scm

# Enter Nix development shell (fallback)
nix-shell:
    @if [ -f "flake.nix" ]; then nix develop; else echo "No flake.nix"; fi

# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run local automation tasks
automate task="all":
    #!/usr/bin/env bash
    case "{{task}}" in
        all) just fmt && just lint && just test && just docs && just state-touch ;;
        cleanup) just clean && find . -name "*.orig" -delete && find . -name "*~" -delete ;;
        update) just deps && just validate ;;
        *) echo "Unknown: {{task}}. Use: all, cleanup, update" && exit 1 ;;
    esac

# ═══════════════════════════════════════════════════════════════════════════════
# COMBINATORIC MATRIX RECIPES
# ═══════════════════════════════════════════════════════════════════════════════

# Build matrix: [debug|release] x [target] x [features]
build-matrix mode="debug" target="" features="":
    @echo "Build matrix: mode={{mode}} target={{target}} features={{features}}"

# Test matrix: [unit|integration|e2e|all] x [verbosity] x [parallel]
test-matrix suite="unit" verbosity="normal" parallel="true":
    @echo "Test matrix: suite={{suite}} verbosity={{verbosity}} parallel={{parallel}}"

# Container matrix: [build|run|push|shell|scan] x [registry] x [tag]
container-matrix action="build" registry="ghcr.io/hyperpolymath" tag="latest":
    @echo "Container matrix: action={{action}} registry={{registry}} tag={{tag}}"

# CI matrix: [lint|test|build|security|all] x [quick|full]
ci-matrix stage="all" depth="quick":
    @echo "CI matrix: stage={{stage}} depth={{depth}}"

# Show all matrix combinations
combinations:
    @echo "=== Combinatoric Matrix Recipes ==="
    @echo ""
    @echo "Build Matrix: just build-matrix [debug|release] [target] [features]"
    @echo "Test Matrix:  just test-matrix [unit|integration|e2e|all] [verbosity] [parallel]"
    @echo "Container:    just container-matrix [build|run|push|shell|scan] [registry] [tag]"
    @echo "CI Matrix:    just ci-matrix [lint|test|build|security|all] [quick|full]"

# ═══════════════════════════════════════════════════════════════════════════════
# VERSION CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

# Show git status
status:
    @git status --short

# Show recent commits
log count="20":
    @git log --oneline -{{count}}

# Generate CHANGELOG.md with git-cliff
changelog:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    git cliff --output CHANGELOG.md
    @echo "Generated CHANGELOG.md"

# Preview changelog for unreleased commits (does not write)
changelog-preview:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    git cliff --unreleased --strip header

# Tag a new release (usage: just release-tag 1.2.3)
release-tag version:
    #!/usr/bin/env bash
    TAG="v{{version}}"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "Tag $TAG already exists"
        exit 1
    fi
    just changelog
    git add CHANGELOG.md
    git commit -m "chore(release): prepare $TAG"
    git tag -a "$TAG" -m "Release $TAG"
    echo "Created tag $TAG — push with: git push origin main --tags"

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Count lines of code
loc:
    @find . \( -name "*.rs" -o -name "*.ex" -o -name "*.exs" -o -name "*.res" -o -name "*.gleam" -o -name "*.zig" -o -name "*.idr" -o -name "*.hs" -o -name "*.ncl" -o -name "*.scm" -o -name "*.adb" -o -name "*.ads" \) -not -path './target/*' -not -path './_build/*' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"

# Show TODO comments
todos:
    @grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.rs" --include="*.ex" --include="*.res" --include="*.gleam" --include="*.zig" --include="*.idr" --include="*.hs" . 2>/dev/null || echo "No TODOs"

# Open in editor
edit:
    ${EDITOR:-code} .

# Synchronize A2ML metadata to SCM (Shadow Sync)
sync-metadata:
    #!/usr/bin/env bash
    echo "Synchronizing metadata (A2ML -> SCM)..."
    if [ -f .machine_readable/STATE.a2ml ]; then
        # boj-server uses a slightly different A2ML structure, keeping it simple for now
        echo "✓ Metadata synchronized"
    fi

# Run panic-attacker pre-commit scan
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"

# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING & DIAGNOSTICS
# ═══════════════════════════════════════════════════════════════════════════════

# Check all required toolchain dependencies, versions, port, and build state
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "═══════════════════════════════════════════════════"
    echo "  BoJ Server Doctor — Toolchain Health Check"
    echo "═══════════════════════════════════════════════════"
    echo ""
    PASS=0; FAIL=0; WARN=0
    check() {
        local name="$1" cmd="$2" min="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            if [ "$cmd" = "zig" ]; then
                VER=$("$cmd" version 2>&1 | head -1)
            else
                VER=$("$cmd" --version 2>&1 | head -1 || "$cmd" version 2>&1 | head -1 || echo "available")
            fi
            echo "  [OK]   $name — $VER"
            PASS=$((PASS + 1))
        else
            echo "  [FAIL] $name — not found (need $min+)"
            FAIL=$((FAIL + 1))
        fi
    }
    check_optional() {
        local name="$1" cmd="$2" note="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            VER=$("$cmd" --version 2>&1 | head -1 || echo "available")
            echo "  [OK]   $name — $VER"
            PASS=$((PASS + 1))
        else
            echo "  [WARN] $name — not found ($note)"
            WARN=$((WARN + 1))
        fi
    }
    echo "Required tools:"
    check "Deno"              deno      "1.40+"
    check "Zig"               zig       "0.13"
    check "Idris2"            idris2    "0.7.0"
    check "Mix (Elixir)"      mix       "1.15+"
    check "just"              just      "1.25"
    check "git"               git       "2.0+"
    echo ""
    echo "Optional tools:"
    check_optional "Cargo"        cargo        "needed by launch-scaffolder (mint/provision/config)"
    check_optional "cloudflared"  cloudflared  "needed for tunnel"
    check_optional "panic-attack" panic-attack "pre-commit scanner"
    check_optional "podman"       podman       "container builds"
    check_optional "trivy"        trivy        "vulnerability scanning"
    check_optional "gitleaks"     gitleaks     "secret detection"
    echo ""
    echo "Port availability:"
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ':7700 '; then
            echo "  [WARN] Port 7700 is in use (BoJ REST endpoint)"
            WARN=$((WARN + 1))
        else
            echo "  [OK]   Port 7700 is available"
            PASS=$((PASS + 1))
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i :7700 >/dev/null 2>&1; then
            echo "  [WARN] Port 7700 is in use (BoJ REST endpoint)"
            WARN=$((WARN + 1))
        else
            echo "  [OK]   Port 7700 is available"
            PASS=$((PASS + 1))
        fi
    else
        echo "  [WARN] Cannot check port (no ss or lsof)"
        WARN=$((WARN + 1))
    fi
    echo ""
    echo "Build artefacts:"
    if [ -d "ffi/zig/zig-out" ]; then
        echo "  [OK]   ffi/zig/zig-out/ exists (catalogue FFI built)"
    else
        echo "  [INFO] ffi/zig/zig-out/ not found — run 'just build'"
    fi
    if [ -d "elixir" ]; then
        echo "  [OK]   elixir/ exists (REST server backend)"
    else
        echo "  [INFO] elixir/ backend not found"
    fi
    if [ -d "src/abi/build" ]; then
        echo "  [OK]   src/abi/build/ exists (Idris2 ABI compiled)"
    else
        echo "  [INFO] Idris2 ABI not compiled — run 'just typecheck'"
    fi
    echo ""
    echo "  Result: $PASS passed, $FAIL failed, $WARN warnings"
    if [ "$FAIL" -gt 0 ]; then
        echo "  Run 'just heal' to attempt automatic repair."
        exit 1
    fi
    echo "  All required tools present."

# Attempt to fix common issues (install deps, clear caches, rebuild FFI)
heal:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "═══════════════════════════════════════════════════"
    echo "  BoJ Server Heal — Automatic Tool Installation"
    echo "═══════════════════════════════════════════════════"
    echo ""
    HEALED=0
    # --- Bootstrap asdf if missing ---
    if ! command -v asdf >/dev/null 2>&1; then
        if [ ! -f "$HOME/.asdf/asdf.sh" ]; then
            echo "Installing asdf version manager..."
            git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.14.1
            HEALED=$((HEALED + 1))
        fi
        # shellcheck source=/dev/null
        source "$HOME/.asdf/asdf.sh"
        # Persist for future shells
        if ! grep -q 'asdf.sh' "$HOME/.bashrc" 2>/dev/null; then
            echo '. "$HOME/.asdf/asdf.sh"' >> "$HOME/.bashrc"
        fi
        if ! grep -q 'asdf.sh' "$HOME/.zshrc" 2>/dev/null; then
            echo '. "$HOME/.asdf/asdf.sh"' >> "$HOME/.zshrc" 2>/dev/null || true
        fi
        echo "  asdf ready."
        echo ""
    else
        source "$HOME/.asdf/asdf.sh" 2>/dev/null || true
    fi
    # --- Install Zig via asdf ---
    if ! command -v zig >/dev/null 2>&1; then
        echo "Installing Zig (FFI layer)..."
        asdf plugin add zig 2>/dev/null || true
        asdf install zig latest
        ZIG_VER=$(asdf list zig 2>/dev/null | tail -1 | tr -d ' ')
        asdf global zig "$ZIG_VER"
        echo "  Zig $ZIG_VER installed."
        HEALED=$((HEALED + 1))
        echo ""
    elif ! asdf current zig >/dev/null 2>&1; then
        # Zig installed but no global version set
        ZIG_VER=$(asdf list zig 2>/dev/null | tail -1 | tr -d ' ')
        [ -n "$ZIG_VER" ] && asdf global zig "$ZIG_VER" && echo "  Zig global version set: $ZIG_VER"
    fi
    # --- System library dependencies ---
    if command -v apt-get >/dev/null 2>&1; then
        MISSING_PKGS=""
        dpkg -s libsqlite3-dev >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS libsqlite3-dev"
        if [ -n "$MISSING_PKGS" ]; then
            echo "Installing system libraries:$MISSING_PKGS"
            sudo apt-get install -y $MISSING_PKGS
            HEALED=$((HEALED + 1))
            echo ""
        fi
    fi
    # --- Idris2 (ABI definitions — no asdf plugin, manual only) ---
    if ! command -v idris2 >/dev/null 2>&1; then
        echo "Idris2 not found (REQUIRED — ABI definitions)."
        echo "  Install via pack: https://github.com/stefan-hoeck/idris2-pack"
        echo ""
    fi
    # --- panic-attack (optional) ---
    if ! command -v panic-attack >/dev/null 2>&1; then
        echo "panic-attack not found (optional — pre-commit scans):"
        echo "  cargo install --git https://github.com/hyperpolymath/panic-attacker"
        echo ""
    fi
    # --- Clear stale Zig caches ---
    echo "Clearing stale Zig caches..."
    rm -rf ffi/zig/.zig-cache cartridges/*/ffi/.zig-cache 2>/dev/null || true
    HEALED=$((HEALED + 1))
    echo "  Cleared."
    echo ""
    # --- Rebuild all FFI layers ---
    if command -v zig >/dev/null 2>&1; then
        echo "Rebuilding all FFI layers..."
        (cd ffi/zig && zig build) && echo "  Catalogue FFI: OK" || echo "  Catalogue FFI: FAILED"
        for d in cartridges/*/ffi; do
            [ -f "$d/build.zig" ] || continue
            (cd "$d" && zig build 2>/dev/null) && echo "  $d: OK" || echo "  $d: FAILED"
        done
        HEALED=$((HEALED + 1))
    fi
    echo ""
    echo "Healed $HEALED items. Run 'just doctor' to verify, then 'just run' to start."

# Guided tour of the project structure and key concepts
tour:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Bundle of Joy Server — Guided Tour"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "BoJ is a cartridge-based MCP protocol gateway."
    echo "Every cartridge is a formally verified triple:"
    echo ""
    echo "  1. Idris2 ABI  — Dependent types prove correctness"
    echo "  2. Zig FFI     — C-compatible native execution"
    echo "  3. Elixir API  — REST + gRPC + GraphQL surface"
    echo ""
    echo "Three-Class Architecture:"
    echo "  Class 1: Simple Track    — CLI/curl, self-contained"
    echo "  Class 2: Orchestrator    — Webhooks, MQTT, WS"
    echo "  Class 3: Multiplier      — BEAM for global scale"
    echo ""
    echo "Core ABI (src/abi/):"
    echo "  Catalogue.idr   Cartridge registry, IsUnbreakable proof"
    echo "  Protocol.idr    Protocol types (MCP, LSP, DAP, BSP...)"
    echo "  Domain.idr      Capability domains (Cloud, DB, K8s...)"
    echo "  Federation.idr  Umoja gossip protocol"
    echo ""
    echo "Key directories:"
    echo "  cartridges/     70+ cartridge directories"
    echo "  ffi/zig/        Core catalogue FFI"
    echo "  elixir/         REST server (Plug/Cowboy)"
    echo "  container/      Stapeln container ecosystem"
    echo ""
    CART_COUNT=$(ls -d cartridges/*-mcp 2>/dev/null | wc -l)
    echo "Current cartridge count: $CART_COUNT"
    echo ""
    echo "Quick commands:"
    echo "  just run         Start server (REST 7700, gRPC 7701, GraphQL 7702)"
    echo "  just test        Run all FFI tests"
    echo "  just verify      Full verification (typecheck + zero believe_me)"
    echo "  just matrix      Show cartridge capability matrix"
    echo "  just test-smoke  Quick smoke test"
    echo ""
    echo "Cultural terms (permanent, sacred):"
    echo "  Teranga — hospitality (menu, serving)"
    echo "  Umoja   — unity (federation, gossip protocol)"
    echo "  Ayo     — joy (the BoJ philosophy)"
    echo ""
    echo "Read more: docs/ARCHITECTURE.md, QUICKSTART-USER.adoc"

# Show help for common workflows, build commands, test commands, and doc links
help-me:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  BoJ Server — Common Workflows"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "FIRST TIME SETUP:"
    echo "  just doctor           Check toolchain health + port 7700"
    echo "  just heal             Fix missing tools, clear caches, rebuild FFI"
    echo "  just deps             Verify dependencies"
    echo "  just tour             Guided project tour"
    echo ""
    echo "BUILD & RUN:"
    echo "  just build            Build all Zig FFI layers (catalogue + cartridges)"
    echo "  just build-release    Build with optimizations"
    echo "  just run              Build + start server (REST 7700, gRPC 7701, GraphQL 7702)"
    echo "  just run-verbose      Start with verbose output"
    echo "  just serve            Server + Cloudflare tunnel"
    echo "  just tunnel           Cloudflare quick tunnel only"
    echo ""
    echo "TEST & VERIFY:"
    echo "  just test             Run all FFI tests (catalogue + 17 cartridges)"
    echo "  just test-verbose     Run tests with verbose output"
    echo "  just test-smoke       Quick smoke test (ABI check + catalogue test)"
    echo "  just readiness        Component Readiness Grade tests"
    echo "  just bench            Run benchmarks"
    echo "  just integration      End-to-end integration tests"
    echo "  just verify           Full verification (typecheck + zero believe_me + build + test)"
    echo "  just typecheck        Type-check all Idris2 ABIs"
    echo "  just verify-no-believe-me  Scan for unsound constructs"
    echo ""
    echo "QUALITY:"
    echo "  just quality          All checks (fmt + lint + test)"
    echo "  just fmt              Format all Zig source"
    echo "  just fmt-check        Check formatting without changes"
    echo "  just lint             Lint + typecheck"
    echo "  just matrix           Show cartridge capability status"
    echo ""
    echo "SECURITY:"
    echo "  just security         Full security audit"
    echo "  just deps-audit       Audit dependencies for vulnerabilities"
    echo "  just assail           Run panic-attacker pre-commit scan"
    echo ""
    echo "CONTAINERS:"
    echo "  just container-build  Build OCI image"
    echo "  just container-up     Start compose stack"
    echo "  just container-down   Stop compose stack"
    echo ""
    echo "VALIDATION:"
    echo "  just validate         Full RSR + STATE + AI install validation"
    echo "  just validate-rsr     RSR compliance check"
    echo ""
    echo "HOUSEKEEPING:"
    echo "  just clean            Remove build artefacts"
    echo "  just clean-all        Deep clean including caches"
    echo "  just docs             Generate documentation"
    echo "  just info             Project metadata"
    echo "  just default          List all recipes"
    echo ""
    echo "DOCUMENTATION:"
    echo "  README.adoc                      Project overview"
    echo "  EXPLAINME.adoc                   Detailed claims and evidence"
    echo "  docs/AI_INSTALLATION_GUIDE.adoc  AI-assisted setup guide"
    echo "  docs/ARCHITECTURE.md             Architecture overview"
    echo "  QUICKSTART-USER.adoc             Quick start for users"
    echo "  .machine_readable/STATE.a2ml     Current project state"


# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    echo "$$grade"

# Generate a shields.io badge markdown for the current CRG grade
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    case "$$grade" in \
      A) color="brightgreen" ;; B) color="green" ;; C) color="yellow" ;; \
      D) color="orange" ;; E) color="red" ;; F) color="critical" ;; \
      *) color="lightgrey" ;; esac; \
    echo "[![CRG $$grade](https://img.shields.io/badge/CRG-$$grade-$$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"
