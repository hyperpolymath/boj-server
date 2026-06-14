K9!
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# K9 Kennel-level guard: boj-server project metadata and MCP invariants
# Security Level: Kennel (data-only, no execution)
# No signature required

{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "mcp-server-metadata",
    security = {
      leash = 'Kennel,
      trust_level = "data-only",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,
    },
    metadata = {
      name = "boj-server-metadata",
      version = "0.3.1",
      description = "BoJ Server: MCP cartridge host with 96 tools — project invariants",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  # Project configuration
  config = {
    # MCP server invariants
    mcp = {
      # Minimum cartridge count that must be present
      min_cartridge_count = 96,
      # All cartridges must be registered in Containerfile
      containerfile_registration_required = true,
      # Port assignment
      default_port = 7700,
    },

    # Safety module requirements (CRITICAL for MCP security)
    safety_modules = {
      required_modules = [
        "input-validation",
        "rate-limiting",
        "authentication",
        "audit-logging",
        "sandboxing",
        "secret-detection",
        "output-sanitization",
      ],
      min_module_count = 7,
    },

    # Safety invariants
    safety = {
      forbidden_patterns = [
        "unwrap()",
        "expect()",
        "todo!()",
        "unimplemented!()",
      ],
    },

    # Test requirements
    tests = {
      min_unit_tests = 300,
      cartridge_smoke_tests_required = true,
      safety_module_tests_required = true,
    },

    # Build/runtime
    build = {
      primary_language = "deno",
      containerfile_name = "Containerfile",
      runtime = "podman",
    },

    # Language policy
    banned_files = ["Makefile", "Dockerfile"],
    banned_languages = ["python", "typescript", "go"],
  },

  # RSR compliance
  rsr = {
    explainme = true,
    ai_manifest = true,
    machine_readable = true,
    spdx_headers_required = true,
    security_md_required = true,
    idris2_abi = true,
    zig_ffi = true,
  },
}
