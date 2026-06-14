<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# BOJ Server - Claude Code Instructions

This repository contains the BOJ (Battle of the Judges) server application.

## Project Structure

```
boj-server/
├── .claude/         # AI assistant instructions
├── .git/           # Version control
├── .gitignore      # Git ignore rules
├── .editorconfig   # Editor configuration
└── ...             # Server files
```

## Build Commands

Refer to project-specific documentation.

## Coding Conventions

- Follow hyperpolymath standards
- All code must have SPDX license headers
- Use approved languages only (see CLAUDE.md)
- Document all non-obvious decisions

## Security

- No hardcoded secrets
- All secrets through environment variables or secret management
- SHA-pinned dependencies where applicable
- HTTPS only, no HTTP URLs
- No MD5/SHA1 for security purposes
