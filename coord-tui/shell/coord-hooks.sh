# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ coord-tui — shell launcher hooks and helper commands
#
# Source from ~/.bashrc / ~/.zshrc (the installer does this automatically):
#   [ -f "$HOME/.config/coord-tui/coord-hooks.sh" ] \
#       && source "$HOME/.config/coord-tui/coord-hooks.sh"
#
# What this gives you:
#   - Auto-registration + window title when you type: claude / gemini / cursor / codex / vibe
#   - coord-peers     — list all active peers (no TUI needed)
#   - coord-claims    — list all active task claims
#   - coord-claim     — claim a task from the command line
#   - coord-worktree  — claim a task + provision an isolated git worktree
#   - coord-status    — set your status from the command line
#   - coord-whoami    — print your current peer ID

# ── Internal helpers ──────────────────────────────────────────────────────────

_coord_env() {
    local env_file="$HOME/.cache/coord-tui/peer.env"
    [ -f "$env_file" ] && source "$env_file"
}

_coord_token() {
    _coord_env
    printf '%s' "${BOJ_COORD_TOKEN:-}"
}

_coord_post() {
    local tool="$1"; shift
    local payload="$1"
    curl -sf -X POST "http://127.0.0.1:7745/tools/${tool}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

_coord_auto_register() {
    local kind="$1"
    # Registers silently, writes ~/.cache/coord-tui/peer.env, sets window title.
    # Falls through silently if the adapter is not running.
    coord-tui --id --kind "$kind" 2>/dev/null || true
    _coord_env
    # Fallback title set in case the binary already emitted it before the env loaded.
    [ -n "${BOJ_COORD_PEER_ID:-}" ] \
        && printf '\033]0;%s [%s]\007' "$kind" "$BOJ_COORD_PEER_ID"
}

# ── Tool launchers (auto-register on invocation) ──────────────────────────────

claude() { _coord_auto_register claude;  command claude  "$@"; }
gemini() { _coord_auto_register gemini;  command gemini  "$@"; }
cursor() { _coord_auto_register cursor;  command cursor  "$@"; }
codex()  { _coord_auto_register openai;  command codex   "$@"; }
vibe()   { _coord_auto_register vibe;    command vibe    "$@"; }

# ── Convenience commands (work in any shell without the TUI) ──────────────────

# List all active peers.
coord-peers() {
    local tok; tok="$(_coord_token)"
    if [ -z "$tok" ]; then
        echo "Not registered — run: coord-tui --id --kind claude" >&2; return 1
    fi
    _coord_post coord_list_peers "{\"token\":\"$tok\"}" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
peers = d.get('peers', [])
print(f'  {len(peers)} peer(s):')
for p in peers:
    status = p.get('status','') or '—'
    print(f'  {p[\"peer_id\"]:30s}  {p[\"kind\"]:8s}  {status}')
" 2>/dev/null || echo "(no peers or adapter not running)"
}

# List all active task claims.
coord-claims() {
    local tok; tok="$(_coord_token)"
    if [ -z "$tok" ]; then
        echo "Not registered — run: coord-tui --id --kind claude" >&2; return 1
    fi
    _coord_post coord_list_claims "{\"token\":\"$tok\"}" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
claims = d.get('active_claims', [])
if not claims:
    print('  No active claims.')
else:
    print(f'  {len(claims)} claim(s):')
    for c in claims:
        print(f'  {c[\"task\"]:40s}  holder={c.get(\"holder\",\"?\")}')
" 2>/dev/null || echo "(adapter not running)"
}

# Claim a task: coord-claim hypatia/my-task
coord-claim() {
    local task="${1:?Usage: coord-claim <task-name>}"
    local tok; tok="$(_coord_token)"
    if [ -z "$tok" ]; then
        echo "Not registered — run: coord-tui --id --kind claude" >&2; return 1
    fi
    local result
    result=$(_coord_post coord_claim_task \
        "{\"token\":\"$tok\",\"task\":\"$task\"}" 2>/dev/null)
    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success'):
    msg = d.get('message','')
    if msg == 'granted':
        print(f'  ✓ Claimed: $task')
    else:
        print(f'  ✗ {msg}')
else:
    print(f'  ✗ {d.get(\"error\",\"unknown error\")}')
" 2>/dev/null || echo "  ✗ Failed (adapter not running?)"
}

# Claim a task AND provision an isolated git worktree for it.
#
#   coord-worktree refactor/dispatcher-rewrite
#
# Creates ../<repo>-worktrees/<sanitised-task> on a branch named
# agent/<peer-id>/<sanitised-task>. The current directory must be a git
# repository — the worktree is created as a sibling directory so the
# main checkout is untouched. If the branch already exists it is reused
# (idempotent for resuming a claim).
coord-worktree() {
    local task="${1:?Usage: coord-worktree <task-name>}"
    _coord_env
    local peer="${BOJ_COORD_PEER_ID:-}"
    if [ -z "$peer" ]; then
        echo "  ✗ Not registered. Run: coord-tui --id --kind claude" >&2
        return 1
    fi
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "  ✗ Not inside a git repository." >&2
        return 1
    fi
    local toplevel; toplevel="$(git rev-parse --show-toplevel)"
    local reponame; reponame="$(basename "$toplevel")"
    # Sanitise task for use in path/branch: keep alnum/_-/, collapse rest.
    local safe; safe="$(printf '%s' "$task" | tr -c 'A-Za-z0-9._/-' '-' \
        | sed 's|/$||;s|^/||')"
    local wt_dir="${toplevel}/../${reponame}-worktrees/${safe}"
    local branch="agent/${peer}/${safe}"

    # Claim first — if the backend says no, don't touch the working tree.
    local tok; tok="$(_coord_token)"
    if [ -n "$tok" ]; then
        local claim
        claim=$(_coord_post coord_claim_task \
            "{\"token\":\"$tok\",\"task\":\"$task\"}" 2>/dev/null)
        local ok
        ok=$(echo "$claim" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if d.get('success') else 'no')
except Exception:
    print('no')
" 2>/dev/null)
        if [ "$ok" != "yes" ]; then
            echo "  ✗ Claim refused — not provisioning worktree." >&2
            echo "$claim" >&2
            return 1
        fi
    else
        echo "  ! No coord token — provisioning worktree without claim." >&2
    fi

    mkdir -p "$(dirname "$wt_dir")"
    if [ -d "$wt_dir" ]; then
        echo "  → Worktree already exists: $wt_dir"
    elif git -C "$toplevel" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "$toplevel" worktree add "$wt_dir" "$branch" >/dev/null \
            && echo "  ✓ Worktree (existing branch): $wt_dir" \
            || { echo "  ✗ git worktree add failed" >&2; return 1; }
    else
        git -C "$toplevel" worktree add -b "$branch" "$wt_dir" >/dev/null \
            && echo "  ✓ Worktree + new branch ${branch}: $wt_dir" \
            || { echo "  ✗ git worktree add failed" >&2; return 1; }
    fi
    echo "  → cd $wt_dir"
}

# Set your status: coord-status "doing the thing"
coord-status() {
    local status="${1:?Usage: coord-status <status text>}"
    local tok; tok="$(_coord_token)"
    if [ -z "$tok" ]; then
        echo "Not registered — run: coord-tui --id --kind claude" >&2; return 1
    fi
    _coord_post coord_status \
        "{\"token\":\"$tok\",\"status\":$(python3 -c "import json,sys; print(json.dumps('$status'))")}" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('  ✓ Status set.' if d.get('success') else '  ✗ Failed.')
" 2>/dev/null
}

# Print your current peer ID and token.
coord-whoami() {
    _coord_env
    if [ -n "${BOJ_COORD_PEER_ID:-}" ]; then
        echo "  Peer:  ${BOJ_COORD_PEER_ID}"
        echo "  Token: ${BOJ_COORD_TOKEN:0:8}… (truncated)"
    else
        echo "  Not registered. Run: coord-tui --id --kind claude"
    fi
}
