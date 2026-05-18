#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-eclexiaiser.py — structural validation for eclexiaiser.toml
# Extracted from dogfood-gate.yml: an inline `python3 -c` heredoc at column 1
# cannot satisfy both YAML block-scalar indentation and Python's no-indent
# rule for top-level statements, so the workflow failed YAML validation at
# startup (0s, no jobs). Keeping the validator in a real file fixes that and
# makes the logic testable on its own.
"""Validate the structure of ./eclexiaiser.toml (Python 3.11+ tomllib)."""
import tomllib
import sys

with open("eclexiaiser.toml", "rb") as f:
    data = tomllib.load(f)

project = data.get("project", {})
if not project.get("name", "").strip():
    print("ERROR: project.name is required", file=sys.stderr)
    sys.exit(1)

functions = data.get("functions", [])
if not functions:
    print("ERROR: at least one [[functions]] entry is required", file=sys.stderr)
    sys.exit(1)

for fn in functions:
    if not fn.get("name", "").strip():
        print("ERROR: function name cannot be empty", file=sys.stderr)
        sys.exit(1)
    if not fn.get("source", "").strip():
        print(f'ERROR: function {fn["name"]} has no source path', file=sys.stderr)
        sys.exit(1)

print(f'Valid: {project["name"]} ({len(functions)} function(s))')
