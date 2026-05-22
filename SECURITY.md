<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Security Policy

We take security seriously. BoJ-server is an MCP (Model Context Protocol) server
that orchestrates browser automation, cloud provider access, GitHub/GitLab
integrations, cartridge execution, and AI-assisted research. The attack surface
is broad and the trust assumptions are significant. We appreciate your efforts
to responsibly disclose vulnerabilities and will make every effort to acknowledge
your contributions.

---

## Table of Contents

- [Supported Versions](#supported-versions)
- [Reporting a Vulnerability](#reporting-a-vulnerability)
- [What to Include](#what-to-include)
- [Response Timeline](#response-timeline)
- [Severity Classification](#severity-classification)
- [Incident Response Phases](#incident-response-phases)
- [Disclosure Policy](#disclosure-policy)
- [Scope](#scope)
- [Safe Harbour](#safe-harbour)
- [Reporter Credits](#reporter-credits)
- [Security Architecture](#security-architecture)
- [Formal Verification](#formal-verification)
- [Container Security](#container-security)
- [Dependency Management](#dependency-management)
- [Security Best Practices for Operators](#security-best-practices-for-operators)
- [Security Updates](#security-updates)
- [Contact](#contact)

---

## Supported Versions

| Version | Supported | Notes |
|---------|-----------|-------|
| Latest `main` | Yes — full support | All security fixes applied here first |
| Latest tagged release | Yes — full support | Backported critical and high fixes |
| Previous minor release | Critical/High only | Patches for P0 and P1 vulnerabilities |
| Older releases | No | Please upgrade to a supported version |

We follow semantic versioning. Security fixes are released as patch versions
(e.g., `1.2.3` -> `1.2.4`). Critical vulnerabilities may trigger out-of-band
releases.

---

## Reporting a Vulnerability

### Preferred Method: GitHub Security Advisories

The preferred method for reporting security vulnerabilities is through GitHub's
Security Advisory feature:

1. Navigate to [Report a Vulnerability](https://github.com/hyperpolymath/boj-server/security/advisories/new)
2. Click **"Report a vulnerability"**
3. Complete the form with as much detail as possible
4. Submit — we will receive a private notification

This method ensures:

- End-to-end encryption of your report
- Private discussion space for collaboration
- Coordinated disclosure tooling
- Automatic credit when the advisory is published

### Alternative: Encrypted Email

If you cannot use GitHub Security Advisories, you may email us directly:

| | |
|---|---|
| **Email** | j.d.a.jewell@open.ac.uk |
| **PGP Key** | [Download Public Key](https://github.com/hyperpolymath.gpg) |
| **Fingerprint** | See GitHub profile |

```bash
# Import our PGP key
curl -sSL https://github.com/hyperpolymath.gpg | gpg --import

# Verify fingerprint
gpg --fingerprint j.d.a.jewell@open.ac.uk

# Encrypt your report
gpg --armor --encrypt --recipient j.d.a.jewell@open.ac.uk report.txt
```

### Do NOT Report Via

- Public GitHub issues
- Pull requests
- GitHub Discussions
- Social media
- Third-party vulnerability disclosure platforms (without prior coordination)

---

## What to Include

A good vulnerability report helps us understand and reproduce the issue quickly.

### Required Information

- **Description**: Clear explanation of the vulnerability
- **Impact**: What an attacker could achieve (confidentiality, integrity, availability)
- **Affected component**: Which part of boj-server is affected (MCP core, cartridges, browser automation, FFI layer, etc.)
- **Affected versions**: Which versions or commits are affected
- **Reproduction steps**: Detailed steps to reproduce the issue

### Helpful Additional Information

- **Proof of concept**: Code, scripts, MCP tool calls, or screenshots
- **Attack scenario**: Realistic attack scenario showing exploitability
- **CVSS score**: Your assessment of severity (use [CVSS 3.1 Calculator](https://www.first.org/cvss/calculator/3.1))
- **CWE ID**: Common Weakness Enumeration identifier if known
- **Suggested fix**: If you have ideas for remediation
- **References**: Links to related vulnerabilities, research, or advisories

### Example Report Structure

```markdown
## Summary
[One-sentence description of the vulnerability]

## Vulnerability Type
[e.g., Command Injection, SSRF, Path Traversal, Privilege Escalation, etc.]

## Affected Component
[e.g., src/browser/, cartridges/cloudflare/, ffi/zig/src/, mcp-bridge/]

## Affected Versions
[Version range or specific commits]

## Severity Assessment
- CVSS 3.1 Score: [X.X]
- CVSS Vector: [CVSS:3.1/AV:X/AC:X/PR:X/UI:X/S:X/C:X/I:X/A:X]

## Description
[Detailed technical description]

## Steps to Reproduce
1. [First step]
2. [Second step]
3. [...]

## Proof of Concept
[Code, MCP tool invocations, curl commands, screenshots, etc.]

## Impact
[What can an attacker achieve?]

## Suggested Remediation
[Optional: your ideas for fixing]

## References
[Links to related issues, CVEs, research]
```

---

## Response Timeline

We commit to the following response times:

| Stage | Timeframe | Description |
|-------|-----------|-------------|
| **Acknowledgement** | 48 hours | We acknowledge receipt and confirm we are investigating |
| **Triage** | 72 hours | We assess severity, confirm the vulnerability, and classify priority |
| **Status Update** | Every 7 days | Regular updates on remediation progress |
| **Resolution (P0)** | 7 days | Critical vulnerabilities — emergency patch |
| **Resolution (P1)** | 30 days | High severity — expedited fix |
| **Resolution (P2)** | 60 days | Medium severity — scheduled fix |
| **Resolution (P3)** | 90 days | Low severity — included in next release |
| **Disclosure** | 90 days max | Public disclosure after fix is available (coordinated with reporter) |

These are targets, not guarantees. Complex vulnerabilities may require more time.
We will communicate openly about any delays.

---

## Severity Classification

### P0 — Critical

**Response time:** < 4 hours acknowledgement, < 7 days fix

Active exploitation or imminent threat. Requires immediate attention and
potentially an out-of-band release.

**Examples:**
- Remote code execution via MCP tool invocation
- Credential exfiltration from environment variables or secrets store
- Browser automation sandbox escape allowing arbitrary system access
- Cartridge execution allowing arbitrary code outside sandbox
- Supply chain compromise of a direct dependency
- Authentication bypass granting full MCP server control

### P1 — High

**Response time:** < 24 hours acknowledgement, < 30 days fix

Exploitable vulnerability with significant impact, but no evidence of active
exploitation.

**Examples:**
- Server-side request forgery (SSRF) via browser navigation tools
- Path traversal in cartridge loading or file operations
- Injection attacks in GitHub/GitLab API proxy calls
- Privilege escalation between cartridge isolation boundaries
- Unsafe deserialisation of MCP messages
- FFI memory safety violations (buffer overflow, use-after-free)
- Credential leakage in logs or error messages

### P2 — Medium

**Response time:** < 7 days acknowledgement, < 60 days fix

Vulnerability requiring specific conditions or user interaction to exploit.

**Examples:**
- Cross-site scripting (XSS) in PanLL tray interface
- Information disclosure through verbose error responses
- Denial of service via malformed MCP requests
- Insecure default configuration options
- Missing input validation on non-critical endpoints
- Race conditions in concurrent cartridge execution

### P3 — Low

**Response time:** Next scheduled release

Minor issues with limited security impact.

**Examples:**
- Missing security headers on informational endpoints
- Software version disclosure in responses
- Verbose stack traces in non-production modes
- Suboptimal cryptographic parameter choices (but still safe)
- Best practice deviations without demonstrable impact

---

## Incident Response Phases

### Phase 1 — Detection and Triage (0-4 hours)

1. Acknowledge the report via GitHub Security Advisory or encrypted email
2. Classify severity using the priority table above
3. Assign an owner from the response team
4. Create a private security advisory on GitHub
5. Determine affected components and blast radius

### Phase 2 — Containment (4-48 hours)

1. Assess blast radius — which versions, deployments, and users are affected
2. If actively exploited: issue an emergency advisory with mitigation steps
3. Disable affected functionality if necessary (cartridge disable, feature flag, hotfix)
4. Preserve evidence (logs, artefacts) for root cause analysis
5. For FFI/ABI issues: verify whether the Idris2 proof obligations still hold

### Phase 3 — Remediation (48 hours - 14 days)

1. Develop fix on a private branch (GitHub Security Advisory fork)
2. Write regression tests covering the vulnerability
3. If FFI-related: update Zig safety gates and re-verify ABI proofs
4. If cartridge-related: audit all cartridges for similar patterns
5. Peer review the fix (at least one other contributor)
6. Backport to supported versions if applicable
7. Run full CI pipeline including Hypatia security scan

### Phase 4 — Disclosure and Recovery (14-90 days)

1. Coordinate disclosure date with the reporter
2. Publish GitHub Security Advisory with CVE (if applicable)
3. Release patched versions to all supported channels
4. Update CHANGELOG.md and release notes
5. Credit the reporter (unless anonymity requested)
6. Notify downstream consumers if the vulnerability affects the MCP protocol surface

### Phase 5 — Post-Incident Review

1. Conduct a blameless post-mortem within 7 days of disclosure
2. Document root cause, timeline, and lessons learned
3. Identify systemic improvements (CI checks, code patterns, formal verification gaps)
4. Update this security policy if gaps are found
5. Feed findings back into Hypatia scan rules

### Response Team

The incident response team consists of the project maintainer
(Jonathan D.A. Jewell) and any active contributors with commit access.

### Communication Channels

During an active incident:

- **Internal**: GitHub Security Advisory private discussion
- **Reporter**: Direct replies in the advisory or encrypted email
- **Public**: Advisory published only after fix is available
- **Users**: GitHub release notes + repository watch notifications

---

## Disclosure Policy

We follow **coordinated disclosure** (also known as responsible disclosure):

1. **You report** the vulnerability privately
2. **We acknowledge** and begin investigation
3. **We develop** a fix and prepare a release
4. **We coordinate** disclosure timing with you
5. **We publish** security advisory and fix simultaneously
6. **You may publish** your research after disclosure

### Disclosure Timeline

```
Day 0          You report vulnerability
Day 1-2        We acknowledge receipt
Day 3          We confirm vulnerability and share initial assessment
Day 3-90       We develop and test fix
Day 90         Coordinated public disclosure
               (earlier if fix is ready; later by mutual agreement)
```

If we cannot reach agreement on disclosure timing, we default to 90 days from
your initial report.

---

## Scope

### In Scope

The following are within scope for security research:

- **MCP server core** — message handling, tool dispatch, authentication
- **Browser automation** — Playwright-based navigation, screenshot, JS execution, tab management
- **Cartridge system** — cartridge loading, isolation, invocation, and the cartridge SDK
- **Cloud provider integrations** — Cloudflare, Vercel, Verpex API proxies
- **GitHub/GitLab integrations** — API proxying, repository operations, PR/issue management
- **Communication tools** — Gmail and Calendar integrations
- **FFI layer** — Zig FFI implementations in `ffi/`
- **ABI definitions** — Idris2 ABI proofs in `src/abi/`
- **MCP bridge** — protocol translation layer in `mcp-bridge/`
- **PanLL tray interface** — system tray UI in `tray/`
- **Container images** — Containerfile, build scripts, runtime configuration
- **CI/CD workflows** — GitHub Actions, deployment scripts
- **Configuration files** — `openapi.yaml`, `smithery.yaml`, `ai-plugin.json`, `glama.json`
- **Dependencies** — report here, we will coordinate with upstream
- **Documentation** that could lead to security issues (e.g., unsafe examples)

### Out of Scope

The following are **not** in scope:

- Third-party services we integrate with (report directly to them: GitHub, GitLab, Cloudflare, Vercel, Google)
- Social engineering attacks against maintainers
- Physical security
- Denial of service attacks against production infrastructure
- Spam, phishing, or other non-technical attacks
- Issues already reported or publicly known
- Theoretical vulnerabilities without proof of concept
- The MCP protocol specification itself (report to the MCP specification maintainers)
- Vulnerabilities in AI/LLM models invoked through boj-server (report to model providers)

### Qualifying Vulnerabilities

We are particularly interested in:

- Remote code execution via MCP tool calls
- Command injection through tool parameters
- Sandbox escape from cartridge execution
- Authentication or authorisation bypass
- Server-side request forgery (SSRF) via browser automation
- Path traversal or local file inclusion
- Credential or secret exfiltration
- Memory safety issues in FFI layer (buffer overflows, use-after-free)
- Supply chain vulnerabilities (dependency confusion, typosquatting)
- Cross-site scripting (XSS) in tray or web interfaces
- Deserialisation vulnerabilities in MCP message handling
- Information disclosure (API keys, tokens, PII)
- Cryptographic weaknesses
- Container escape or privilege escalation

### Non-Qualifying Issues

The following generally do not qualify as security vulnerabilities:

- Missing security headers on non-sensitive endpoints
- Software version disclosure
- Self-XSS (requires user to paste malicious code)
- Missing rate limiting (unless it enables a specific attack)
- Verbose error messages (unless exposing secrets)
- Best practice deviations without demonstrable impact
- Issues that require physical access to the host machine
- Attacks requiring the attacker to already have MCP server credentials

---

## Safe Harbour

We support security research conducted in good faith.

### Our Promise

If you conduct security research in accordance with this policy:

- We will not initiate legal action against you
- We will not report your activity to law enforcement
- We will work with you in good faith to resolve issues
- We consider your research authorised under the Computer Fraud and Abuse Act
  (CFAA), UK Computer Misuse Act 1990, and equivalent legislation in other
  jurisdictions
- We waive any potential claim against you for circumvention of security controls

### Good Faith Requirements

To qualify for safe harbour, you must:

- Comply with this security policy
- Report vulnerabilities promptly after discovery
- Avoid privacy violations (do not access others' data)
- Avoid service degradation (no destructive testing)
- Not exploit vulnerabilities beyond proof-of-concept
- Not use vulnerabilities for profit (beyond bug bounties where offered)
- Not access, modify, or delete data beyond what is necessary to demonstrate
  the vulnerability

This safe harbour does not extend to third-party systems. Always check their
policies before testing.

---

## Reporter Credits

### Hall of Fame

Researchers who report valid vulnerabilities will be acknowledged in our
[Security Acknowledgments](SECURITY-ACKNOWLEDGMENTS.md) file (unless they
prefer anonymity).

Recognition includes:

- Your name (or chosen alias)
- Link to your website or profile (optional)
- Brief description of the vulnerability class
- Date of report and severity level

### What We Offer

- Public credit in security advisories
- Acknowledgment in release notes and CHANGELOG.md
- Entry in our Hall of Fame
- Reference or recommendation letter upon request (for significant findings)

### What We Do Not Currently Offer

- Monetary bug bounties
- Hardware or swag
- Paid security research contracts

We are an open-source project. Your contributions help everyone who uses this
software.

---

## Security Architecture

BoJ-server operates with multiple trust boundaries that security researchers
should understand.

### Trust Boundaries

```
                    +---------------------------+
                    |   LLM / AI Client         |
                    |   (Claude, etc.)           |
                    +----------+----------------+
                               |
                          MCP Protocol
                               |
                    +----------v----------------+
                    |   MCP Server Core          |
                    |   (tool dispatch,          |
                    |    auth, rate limiting)     |
                    +--+------+------+----------+
                       |      |      |
            +----------+  +---+---+  +----------+
            |             |       |             |
    +-------v------+ +---v----+ +v-----------+ |
    | Browser      | |Cartridge| |Cloud/API   | |
    | Automation   | |Engine   | |Integrations| |
    | (Playwright) | |(sandbox)| |(GitHub,    | |
    +--------------+ +--------+ | GitLab,    | |
                                | Cloudflare)| |
                                +------------+ |
                                               |
                                    +----------v---+
                                    | FFI Layer     |
                                    | (Zig impl,    |
                                    |  Idris2 ABI)  |
                                    +--------------+
```

### Key Security Properties

1. **MCP tool dispatch** — All tool invocations pass through a central dispatcher
   that validates parameters before execution
2. **Cartridge isolation** — Cartridges execute in a controlled environment with
   declared capabilities; they cannot access resources outside their manifest
3. **Browser sandbox** — Playwright browser automation runs in a sandboxed
   context with configurable navigation restrictions
4. **API credential isolation** — Cloud provider and service credentials are
   stored separately and accessed only by their respective integration modules
5. **FFI safety gates** — The Zig FFI layer enforces memory safety invariants
   proven by the Idris2 ABI definitions

For a complete threat model, see [THREAT-MODEL.md](docs/THREAT-MODEL.md) (if
available) or request one via a GitHub issue.

---

## Formal Verification

BoJ-server uses a layered formal verification approach for its ABI and FFI
boundaries.

### Idris2 ABI Proofs

The `src/abi/` directory contains Idris2 definitions that provide:

- **Dependent type proofs** for interface correctness at compile time
- **Memory layout verification** ensuring data structures are correctly aligned
  across language boundaries
- **Platform-specific ABI selection** with compile-time guarantees
- **Backward compatibility proofs** when interfaces evolve

### Zig FFI Safety Gates

The `ffi/zig/` directory implements C-compatible FFI functions with:

- **Bounds checking** on all buffer operations
- **Null pointer guards** at every FFI entry point
- **No runtime dependencies** — zero-cost abstractions
- **Cross-compilation support** for reproducible builds

### Dangerous Pattern Ban

The following patterns are banned across the entire codebase and enforced by CI:

- `believe_me`, `assert_total` (Idris2)
- `unsafeCoerce`, `Obj.magic` (OCaml/ReScript)
- `Admitted`, `sorry` (Coq/Lean)
- `unsafe` blocks without justification comments (Rust/Zig)

The Hypatia neurosymbolic scanner checks for these patterns on every commit.

---

## Container Security

### Base Images

All container images use **Chainguard** base images, which provide:

- Minimal attack surface (no shell, no package manager in production images)
- Daily CVE scanning and patching by Chainguard
- SBOM (Software Bill of Materials) included with every image
- Signed images with cosign for supply chain integrity

### Build Process

- The `Containerfile` (not `Dockerfile`) defines the build
- Multi-stage builds separate build dependencies from runtime
- No secrets baked into images — all credentials injected at runtime
- Images are scanned with **Trivy** before release

### Runtime Hardening

- Containers run as non-root user
- Read-only root filesystem where possible
- Seccomp and AppArmor profiles applied
- Network access restricted to declared integrations
- Resource limits (CPU, memory) enforced

---

## Dependency Management

### Hypatia Neurosymbolic Scanning

Every commit is scanned by **Hypatia**, our neurosymbolic CI/CD intelligence
system, which checks for:

- Known CVEs in direct and transitive dependencies
- Licence compliance violations
- Dangerous code patterns (see Formal Verification section)
- Supply chain anomalies (unexpected dependency changes, typosquatting)
- Secret leakage (API keys, tokens, credentials in source)

### SHA-Pinned GitHub Actions

All GitHub Actions workflows use SHA-pinned action references (not mutable tags)
to prevent supply chain attacks via tag mutation:

```yaml
# Correct — SHA-pinned
- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

# Incorrect — mutable tag (NEVER used)
- uses: actions/checkout@v4
```

### Additional Scanning

| Tool | Purpose | Frequency |
|------|---------|-----------|
| **Hypatia** | Neurosymbolic security analysis | Every commit |
| **CodeQL** | Static analysis and variant detection | Every commit |
| **TruffleHog** | Secret detection in source and history | Every commit |
| **Trivy** | Container image vulnerability scanning | Every build |
| **OpenSSF Scorecard** | Supply chain security posture | Weekly |
| **Dependabot** | Dependency update alerts | Continuous |
| **panic-attacker** | Pre-commit security assurance | Every commit (local) |

### Dependency Policy

- Direct dependencies are reviewed before adoption
- Transitive dependency trees are audited periodically
- Dependencies with known unpatched vulnerabilities are replaced or vendored
  with patches
- No dependencies from untrusted registries

---

## Security Best Practices for Operators

If you are deploying boj-server, follow these guidelines:

### Credential Management

- Store API keys and tokens in environment variables or a secrets manager
- Never commit credentials to the repository
- Rotate credentials regularly (at least quarterly)
- Use scoped API tokens with minimum required permissions

### Network Configuration

- Run boj-server behind a reverse proxy with TLS termination
- Restrict MCP endpoint access to trusted clients only
- Use firewall rules to limit outbound connections to declared integrations
- Monitor network traffic for anomalous patterns

### Logging and Monitoring

- Enable structured logging for audit trails
- Forward logs to a centralised logging system
- Set up alerts for authentication failures and unusual tool invocations
- Retain logs for at least 90 days

### Update Policy

- Subscribe to GitHub release notifications for this repository
- Apply security patches within the timeframes matching their severity
- Test updates in a staging environment before production deployment

---

## Security Updates

### Receiving Updates

To stay informed about security updates:

- **Watch this repository**: Click "Watch" then "Custom" then select "Security alerts"
- **GitHub Security Advisories**: Published at [Security Advisories](https://github.com/hyperpolymath/boj-server/security/advisories)
- **Release notes**: Security fixes noted in [CHANGELOG.md](CHANGELOG.md)

### Update Urgency by Severity

| Severity | Action Required |
|----------|----------------|
| **P0 — Critical** | Patch immediately; out-of-band release issued |
| **P1 — High** | Patch within 7 days of release |
| **P2 — Medium** | Patch at next maintenance window |
| **P3 — Low** | Patch at next scheduled upgrade |

---

## Contact

| | |
|---|---|
| **Maintainer** | Jonathan D.A. Jewell |
| **Security email** | j.d.a.jewell@open.ac.uk |
| **GitHub** | [@hyperpolymath](https://github.com/hyperpolymath) |
| **PGP Key** | [https://github.com/hyperpolymath.gpg](https://github.com/hyperpolymath.gpg) |
| **Security Advisories** | [github.com/hyperpolymath/boj-server/security/advisories](https://github.com/hyperpolymath/boj-server/security/advisories) |

---

*This security policy is reviewed and updated at least annually, or whenever
a significant change to the project's security posture occurs.*

*Last updated: 2026-03-23*
