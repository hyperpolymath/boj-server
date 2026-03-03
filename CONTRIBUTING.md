# Clone the repository
git clone https://github.com/hyperpolymath/boj-server.git
cd boj-server

# Enter development environment (Guix primary, Nix fallback)
guix shell -D -f guix.scm
# or: nix develop

# Check toolchain
just deps          # Verify idris2, zig, just are available

# Type-check the Idris2 ABI
just typecheck     # All ABI files must pass with %default total

# Build the Zig FFI layers
just build         # Builds core + all cartridge FFIs

# Run tests
just test          # Runs all Zig FFI test suites

# Full verification (zero believe_me + typecheck + tests)
just verify
```

### Repository Structure
```
boj-server/
├── src/abi/                   # Idris2 ABI — formal proofs (Perimeter 1)
│   ├── Catalogue.idr          # Cartridge registry, IsUnbreakable proof
│   ├── Protocol.idr           # Protocol types (MCP, LSP, DAP, BSP, ...)
│   ├── Domain.idr             # Capability domains (Cloud, DB, K8s, ...)
│   ├── Menu.idr               # Menu generation from catalogue state
│   └── Federation.idr         # Umoja gossip protocol, node attestation
├── ffi/zig/                   # Zig FFI — C-compatible native (Perimeter 1)
├── generated/abi/             # Auto-generated C headers (Perimeter 1)
├── cartridges/                # Matrix cells (Perimeter 1-2)
│   ├── database-mcp/          # MCP x Database (abi/ + ffi/)
│   ├── fleet-mcp/             # MCP x Fleet (abi/ + ffi/)
│   ├── nesy-mcp/              # MCP x NeSy (abi/ + ffi/)
│   └── agent-mcp/             # MCP x Agent (abi/ + ffi/)
├── adapter/v/                 # V-lang triple adapter (Perimeter 2, Phase 3)
├── container/                 # Stapeln container ecosystem (Perimeter 2)
├── docs/                      # Documentation (Perimeter 3)
├── .machine_readable/         # ALL machine-readable content (Perimeter 1)
│   ├── *.a2ml                 # State files (STATE, META, ECOSYSTEM, etc.)
│   ├── servers/               # menu.a2ml + order-ticket.scm
│   ├── bot_directives/        # Bot configs
│   └── contractiles/          # Policy contracts (k9, dust, lust, must, trust)
├── .well-known/               # Protocol files (Perimeter 1-3)
├── .github/workflows/         # 17 mandatory workflows (Perimeter 1)
├── guix.scm                   # Guix package — primary (Perimeter 1)
├── flake.nix                  # Nix flake — fallback (Perimeter 1)
└── Justfile                   # Task runner (Perimeter 1)
```

---

## How to Contribute

### Reporting Bugs

**Before reporting**:
1. Search existing issues
2. Check if it's already fixed in `main`
3. Determine which perimeter the bug affects

**When reporting**:

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include:

- Clear, descriptive title
- Environment details (OS, versions, toolchain)
- Steps to reproduce
- Expected vs actual behaviour
- Logs, screenshots, or minimal reproduction

### Suggesting Features

**Before suggesting**:
1. Check the [roadmap](ROADMAP.md) if available
2. Search existing issues and discussions
3. Consider which perimeter the feature belongs to

**When suggesting**:

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md) and include:

- Problem statement (what pain point does this solve?)
- Proposed solution
- Alternatives considered
- Which perimeter this affects

### Your First Contribution

Look for issues labelled:

- [`good first issue`](https://github.com/hyperpolymath/boj-server/labels/good%20first%20issue) — Simple Perimeter 3 tasks
- [`help wanted`](https://github.com/hyperpolymath/boj-server/labels/help%20wanted) — Community help needed
- [`documentation`](https://github.com/hyperpolymath/boj-server/labels/documentation) — Docs improvements
- [`perimeter-3`](https://github.com/hyperpolymath/boj-server/labels/perimeter-3) — Community sandbox scope

---

## Development Workflow

### Branch Naming
```
docs/short-description       # Documentation (P3)
test/what-added              # Test additions (P3)
feat/short-description       # New features (P2)
fix/issue-number-description # Bug fixes (P2)
refactor/what-changed        # Code improvements (P2)
security/what-fixed          # Security fixes (P1-2)
```

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):
```
<type>(<scope>): <description>

[optional body]

[optional footer]
