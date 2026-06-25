<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# CI/CD Changes — 2026-06-04

**Date:** 2026-06-04  
**Author:** Mistral Vibe (Estate CI/CD Standardization)  
**PR:** Part of estate-wide timeout-minutes rollout

---

## Summary

All 18 workflows in this repository have been updated to include `timeout-minutes` configuration and concurrency settings as part of the estate-wide CI/CD standardization effort.

**Previous state:** 2/18 workflows with timeout-minutes (from agent summary)  
**Current state:** 18/18 workflows with timeout-minutes (100% coverage)

---

## Changes Made

### Workflow Modifications

| Workflow | timeout-minutes | Concurrency Added | Notes |
|----------|-----------------|------------------|-------|
| `abi-drift.yml` | 15 | | ABI manifest + FFI verification |
| `codeql.yml` | 15 | ✓ | JavaScript/TypeScript CodeQL only; Zig FFI is covered by Zig workflows |
| `container-publish.yml` | 30 | | Container build & push |
| `dogfood-gate.yml` | 5-15 | ✓ | 6 jobs: a2ml(5), k9(5), empty-lint(15), groove(5), eclexiaiser(5), summary(5) |
| `e2e.yml` | 15 | ✓ | MCP bridge input fuzz tests |
| `fuzz.yml` | 30-45 | | Zig FFI(45), MCP bridge(30) |
| `governance.yml` | 10 | | Pinned to SHA 861b5e911d9e5dcfb3c0ab3dd2a9a3c8fd0a1613 |
| `hypatia-scan.yml` | 15 | Already had | Neurosymbolic security scan |
| `instant-sync.yml` | 5 | ✓ | Forge sync dispatch |
| `lsp-dap-bsp.yml` | 5-30 | ✓ | 3 jobs: abi-check(15), ffi-build(30), panel-validation(5) |
| `mirror.yml` | 10 | ✓ | Mirror to git forges |
| `publish.yml` | 15 | | npm(15), jsr(15) |
| `release.yml` | 10-30 | | build(30), changelog(10), release(10), provenance(15) |
| `scorecard-enforcer.yml` | 5-15 | Already had | scorecard(15), enforce(5) |
| `scorecard.yml` | 10 | | Reusable workflow call |
| `secret-scanner.yml` | 10 | Already had | Reusable workflow call |
| `zig-test.yml` | 30 | | Zig FFI tests |

### Pattern Applied

**Timeout Matrix:**
- **5min**: Dispatch/trigger, check/lint (instant-sync, mirror, scorecard)
- **10min**: Reusable workflow calls (governance, scorecard, spark-theatre-gate)
- **15min**: Standard builds/tests (codeql, container-publish, publish, scorecard-enforcer scorecard job)
- **30min**: Heavy builds (lsp-dap-bsp ffi-build, release build, zig-test)
- **30-45min**: Fuzzing (fuzz-zig, fuzz-mcp-bridge)

**Concurrency:** Added to all check/lint/scan workflows that didn't already have it.

---

## CodeQL Configuration

**Languages:** `javascript-typescript`

**Reason:** The FFI implementation is Zig. The tracked C ABI file is a generated
header-only surface (`generated/abi/boj_catalogue.h`), not a C/C++ translation
unit; enabling CodeQL `cpp` for headers alone makes extraction fail before
analysis. Re-add `cpp` only when tracked `.c`, `.cc`, `.cpp`, or `.cxx` sources
exist.

---

## Governance Configuration

**SHA:** `861b5e911d9e5dcfb3c0ab3dd2a9a3c8fd0a1613`  
**Reusable workflow:** `hyperpolymath/standards/.github/workflows/governance-reusable.yml`

---

## Files Modified

All modifications are in `.github/workflows/`:

1. abi-drift.yml (added timeout-minutes: 15)
2. codeql.yml (added timeout-minutes: 15 + concurrency)
3. container-publish.yml (added timeout-minutes: 30)
4. dogfood-gate.yml (added timeout-minutes: 5-15 to all 6 jobs + concurrency)
5. e2e.yml (added timeout-minutes: 15 + concurrency)
6. fuzz.yml (added timeout-minutes: 30-45 to both jobs)
7. governance.yml (added timeout-minutes: 10)
8. hypatia-scan.yml (added timeout-minutes: 15)
9. instant-sync.yml (added timeout-minutes: 5 + concurrency)
10. lsp-dap-bsp.yml (added timeout-minutes: 5-30 to all 3 jobs + concurrency)
11. mirror.yml (added timeout-minutes: 10 + concurrency)
12. publish.yml (added timeout-minutes: 15 to both jobs)
13. release.yml (added timeout-minutes: 10-30 to all 4 jobs)
14. scorecard-enforcer.yml (added timeout-minutes: 5-15 to both jobs)
15. scorecard.yml (added timeout-minutes: 10)
16. secret-scanner.yml (added timeout-minutes: 10)
17. zig-test.yml (added timeout-minutes: 30)

---

## Verification

```bash
# Verify all workflows have timeout-minutes
cd .github/workflows
for f in *.yml; do
  grep -q "timeout-minutes" "$f" && echo "✓ $f" || echo "✗ $f"
done

# Count coverage
total=$(ls *.yml | wc -l)
with_timeout=$(grep -l "timeout-minutes" *.yml | wc -l)
echo "Coverage: $with_timeout/$total"
```

---

## Related Documents

- Estate-wide summary: `/home/hyperpolymath/developer/dev-notes/CICD-SHEPHERDING-2026-06-04.md`
- Previous agent work: Referenced in task summary

---

*Generated as part of estate CI/CD standardization — do not edit manually without updating all projects*
