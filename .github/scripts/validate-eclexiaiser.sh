#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-eclexiaiser.sh — structural validation for ./eclexiaiser.toml.
# Bash replacement for the prior Python implementation; Python is wholly
# outlawed estate-wide (hyperpolymath/standards [Language Policy]) and the
# governance / Language / package anti-pattern policy gate fails on any
# in-tree `.py` file. This validator does the same three checks the Python
# version did, purely via POSIX text tools — no TOML parser dependency.
#
# Checks:
#   1. [project] section has a non-empty `name`
#   2. At least one `[[functions]]` table is declared
#   3. Each `[[functions]]` table has a non-empty `name` and `source`

set -euo pipefail

FILE="${1:-eclexiaiser.toml}"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

# Strip comments + blank lines into a working buffer
buf=$(sed -E 's/[[:space:]]*#.*$//' "$FILE" | grep -v '^[[:space:]]*$')

# Extract `name` under [project] — the value on the first `name = "..."` line
# that appears AFTER [project] and BEFORE the next [section] header.
project_name=$(
  printf '%s\n' "$buf" \
    | awk '
        /^\[project\][[:space:]]*$/ {in_project=1; next}
        /^\[/                       {in_project=0}
        in_project && /^[[:space:]]*name[[:space:]]*=/ {
          sub(/^[^=]*=[[:space:]]*/, "")
          gsub(/^"|"$/, "")
          print
          exit
        }
      '
)

if [ -z "$project_name" ]; then
  echo "ERROR: project.name is required" >&2
  exit 1
fi

# Count [[functions]] tables and validate each one's name + source.
# Each [[functions]] header opens a table that runs until the next header.
errors=$(
  printf '%s\n' "$buf" \
    | awk '
        function flush(  ok_name, ok_source) {
          if (!in_fn) return
          if (fn_name == "")   print "ERROR: function name cannot be empty"
          if (fn_source == "") print "ERROR: function `" (fn_name ? fn_name : "<unnamed>") "` has no source path"
        }
        /^\[\[functions\]\][[:space:]]*$/ {
          flush()
          in_fn = 1
          fn_count++
          fn_name = ""
          fn_source = ""
          next
        }
        /^\[/ { flush(); in_fn = 0; next }
        in_fn && /^[[:space:]]*name[[:space:]]*=/ {
          v = $0
          sub(/^[^=]*=[[:space:]]*/, "", v)
          gsub(/^"|"$/, "", v)
          fn_name = v
        }
        in_fn && /^[[:space:]]*source[[:space:]]*=/ {
          v = $0
          sub(/^[^=]*=[[:space:]]*/, "", v)
          gsub(/^"|"$/, "", v)
          fn_source = v
        }
        END {
          flush()
          if (fn_count == 0) print "ERROR: at least one [[functions]] entry is required"
          printf "__COUNT__=%d\n", fn_count
        }
      '
)

count=$(printf '%s\n' "$errors" | sed -n 's/^__COUNT__=//p')
errs=$(printf '%s\n' "$errors" | grep -v '^__COUNT__=' || true)

if [ -n "$errs" ]; then
  printf '%s\n' "$errs" >&2
  exit 1
fi

printf 'Valid: %s (%s function(s))\n' "$project_name" "$count"
