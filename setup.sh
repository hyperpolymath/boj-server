#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Boj Server — Universal Setup Script
# Detects platform and shell, installs just, then hands off to Justfile.

set -euo pipefail

echo "═══════════════════════════════════════════════════"
echo "  Boj Server — Setup"
echo "═══════════════════════════════════════════════════"
echo ""

# Platform detection
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Platform: $OS $ARCH"

# Shell detection
CURRENT_SHELL="$(basename "$SHELL" 2>/dev/null || echo "unknown")"
echo "Shell: $CURRENT_SHELL"
echo ""

# Check for just
if ! command -v just >/dev/null 2>&1; then
    echo "just (command runner) is required but not installed."
    echo ""
    case "$OS" in
        Linux)
            if command -v cargo >/dev/null 2>&1; then
                echo "Installing just via cargo..."
                cargo install just
            elif command -v brew >/dev/null 2>&1; then
                echo "Installing just via Homebrew..."
                brew install just
            else
                echo "Install just from: https://just.systems/man/en/installation.html"
                exit 1
            fi
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                echo "Installing just via Homebrew..."
                brew install just
            else
                echo "Install Homebrew first: https://brew.sh"
                echo "Then: brew install just"
                exit 1
            fi
            ;;
        *)
            echo "Install just from: https://just.systems/man/en/installation.html"
            exit 1
            ;;
    esac
    echo ""
fi

echo "Running diagnostics..."
just doctor

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  just help-me          — Common workflows"
echo "  just install-service  — Install systemd services (BoJ REST + coord system)"
echo "                          Keeps the server alive across reboots."
