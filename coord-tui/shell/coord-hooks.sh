# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ coord-tui — shell launcher hooks
#
# Source from ~/.bashrc / ~/.zshrc (the installer does this automatically):
#   [ -f "$HOME/.config/coord-tui/coord-hooks.sh" ] \
#       && source "$HOME/.config/coord-tui/coord-hooks.sh"
#
# Effect: calling `claude`, `gemini`, `cursor`, or `codex` silently registers
# this shell as a coord peer, then sets the terminal window title to:
#   <tool> [<peer_id>]
# so you can identify which shell maps to which peer in the coord TUI.

_coord_auto_register() {
    local kind="$1"
    # coord-tui --id: registers silently, writes ~/.cache/coord-tui/peer.env,
    # prints peer_id to stdout. Falls through silently if adapter is down.
    coord-tui --id --kind "$kind" 2>/dev/null || true

    local env_file="$HOME/.cache/coord-tui/peer.env"
    # shellcheck disable=SC1090
    [ -f "$env_file" ] && source "$env_file"

    # Set terminal window title — visible in taskbar / tab / tmux title bar.
    # Format: "claude [peer-a1b2c3]" so you can find this shell at a glance.
    [ -n "${BOJ_COORD_PEER_ID:-}" ] \
        && printf '\033]0;%s [%s]\007' "$kind" "$BOJ_COORD_PEER_ID"
}

claude() { _coord_auto_register claude;  command claude  "$@"; }
gemini() { _coord_auto_register gemini;  command gemini  "$@"; }
cursor() { _coord_auto_register custom;  command cursor  "$@"; }
codex()  { _coord_auto_register openai;  command codex   "$@"; }
