;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; Echidnabot directives — static analysis, code quality, formal verification,
;; and dependency audit rules for BoJ Server.

(bot-directive
  (bot "echidnabot")
  (scope "formal verification, static analysis, code quality, and dependency audit")

  ;; ─── Static Analysis Rules ─────────────────────────────────────────
  (static-analysis
    (zig
      (require-mutex-on-exports #t
        "Every Zig module with pub export fn MUST declare a std.Thread.Mutex")
      (ban-bare-unreachable #t
        "No bare unreachable in production code — use error returns")
      (require-spdx-header #t
        "All .zig files must have SPDX-License-Identifier in first 5 lines")
      (max-function-complexity 50
        "Cyclomatic complexity limit per function"))
    (idris2
      (ban-believe-me #t
        "believe_me bypasses the type checker — never allowed")
      (ban-assert-total #t
        "assert_total bypasses the totality checker — never allowed")
      (ban-admitted #t
        "Admitted proof holes are never allowed")
      (ban-sorry #t
        "sorry proof holes are never allowed")
      (ban-unsafe-coerce #t
        "unsafeCoerce, unsafePerformIO, Obj.magic are never allowed")
      (require-spdx-header #t))
    (vlang
      (require-spdx-header #t
        "All .v files must have SPDX-License-Identifier")
      (cffi-match-zig-exports #t
        "Every fn C.xxx declaration must have a matching Zig pub export fn"))
    (shell
      (require-set-euo-pipefail #t
        "All shell scripts must use set -euo pipefail")
      (require-spdx-header #t)))

  ;; ─── Code Quality Gates ────────────────────────────────────────────
  (code-quality
    (cartridge-completeness
      (require-abi #t  "Every cartridge must have an abi/ directory with .idr files")
      (require-ffi #t  "Every cartridge must have an ffi/ directory with .zig files")
      (require-adapter #t  "Every cartridge must have an adapter/ directory"))
    (enum-encoding-contract
      (catalogue-status-range '(0 1 2 3)
        "CartridgeStatus: development=0, ready=1, deprecated=2, faulty=3")
      (protocol-range '(1 2 3 4 5 6 7 8 9)
        "ProtocolType: mcp=1 through rest=9, contiguous")
      (domain-range '(1 . 17)
        "CapabilityDomain: cloud=1 through bsp=17"))
    (thread-safety
      (require-mutex-for-globals #t
        "All global mutable state accessed from C-ABI must be mutex-protected")
      (concurrent-test-coverage #t
        "Seams must include concurrent register/mount/unmount tests"))
    (error-handling
      (c-abi-error-sentinel -1
        "All c_int-returning exports use -1 for error")
      (no-crash-on-invalid-input #t
        "Invalid enum values, out-of-bounds indices, and oversized strings must not crash")
      (boundary-validation #t
        "All string length parameters must be bounds-checked")))

  ;; ─── Formal Verification Checks ───────────────────────────────────
  (formal-verification
    (idris2-proofs
      (is-unbreakable-invariant #t
        "Mount gate requires IsUnbreakable proof (status=Ready)")
      (status-to-int-contract #t
        "statusToInt encoding must match Zig CartridgeStatus enum")
      (protocol-to-int-contract #t
        "protocolToInt encoding must match Zig ProtocolType enum")
      (domain-to-int-contract #t
        "domainToInt encoding must match Zig CapabilityDomain enum"))
    (seam-categories
      (point-to-point #t
        "Verify each module's FFI exports are callable and return correct types")
      (aspect #t
        "Cross-cutting: error sentinels, idempotent init, thread safety across modules")
      (boundary #t
        "Input sanitisation: zero-length strings, oversized buffers, invalid enums"))
    (panll-schema-contract
      (cartridge-count 21
        "Catalogue must support exactly 21 cartridges (PanLL CartridgeAbi.cartridgeCount)")
      (all-support-mcp #t
        "Every cartridge must support MCP protocol (protocol 1)")))

  ;; ─── Dependency Audit ──────────────────────────────────────────────
  (dependency-audit
    (zig-dependencies
      (allow-only-std #t
        "Core FFI modules may only import std and internal modules")
      (no-external-packages #t
        "No zig packages from package managers — vendored or stdlib only"))
    (node-dependencies
      (mcp-bridge-minimal #t
        "MCP bridge must have zero runtime dependencies")
      (audit-frequency "weekly"
        "Run npm audit / deno check weekly"))
    (idris2-dependencies
      (no-external-packages #t
        "ABI definitions must be self-contained — no external idris2 packages"))
    (license-compliance
      (primary "PMPL-1.0-or-later")
      (fallback "MPL-2.0" "only where platform requires OSI-approved")
      (banned ("AGPL-3.0" "GPL-2.0-only"))
      (third-party-preserve #t
        "Never relicense third-party dependencies")))

  ;; ─── Permissions ───────────────────────────────────────────────────
  (allow ("analysis" "fuzzing" "proof checks" "seam validation"
          "dependency scanning" "license auditing" "SPDX verification"))
  (deny ("write to core modules" "write to bindings"
         "modify ABI definitions" "modify seam tests without review"))

  (notes
    "Echidnabot may open findings as issues. Code changes require explicit "
    "approval from the maintainer. All seam test additions must cover at "
    "least one of: point-to-point, aspect, or boundary categories."))
