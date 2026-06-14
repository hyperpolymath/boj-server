#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Shebangs are only interpreter directives when they are the first line.
# A license header above "#!" makes Node, Deno, Bun, and POSIX shells parse it
# as source text instead, so executable scripts must keep "#!" at line 1.

set -euo pipefail

fail=0

while IFS= read -r -d '' path; do
  case "$path" in
    *.awk|*.bash|*.cjs|*.exs|*.fish|*.js|*.mjs|*.pl|*.py|*.rb|*.scm|*.sh|*.ts|*.zsh) ;;
    *) continue ;;
  esac

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      '#!'*)
        if [ "$line_no" != "1" ]; then
          printf 'ERROR: %s:%s has a shebang after line 1\n' "$path" "$line_no" >&2
          fail=1
        fi
        ;;
    esac
  done < "$path"
done < <(git ls-files -z)

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

Shebangs must be the first line of executable scripts. Put SPDX and copyright
comments immediately after the shebang.
EOF
  exit 1
fi

echo "OK: all tracked shebangs are on line 1"
