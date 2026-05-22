// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opsm-mcp/mod.js -- Odds-and-Sods Package Manager gateway cartridge.
//
// Delegates all package operations to the OPSM Elixir backend (opsm_ex)
// via HTTP.  The Zig FFI state machine enforces valid registry slot lifecycles
// and is consulted before issuing backend requests.
//
// Supported registries include all 103 OPSM adapters; the AffineScript and
// RattleScript registries are first-class entries.
//
// Backend: OPSM Elixir (opsm_ex) on http://127.0.0.1:7700 (configurable)
// Auth: None required — local service.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const OPSM_BASE_URL = Deno.env.get("OPSM_BACKEND_URL") ?? "http://127.0.0.1:7700";
const OPSM_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// HTTP helper — POST to the OPSM Elixir backend
// ---------------------------------------------------------------------------

async function opsmPost(path, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), OPSM_TIMEOUT_MS);
  try {
    const resp = await fetch(`${OPSM_BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const data = await resp.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: resp.status, data };
  } catch (e) {
    if (e.name === "AbortError") {
      return { status: 504, data: { success: false, error: "OPSM backend timed out" } };
    }
    return { status: 503, data: { success: false, error: `OPSM backend unavailable: ${e.message}` } };
  } finally {
    clearTimeout(timer);
  }
}

async function opsmGet(path) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), OPSM_TIMEOUT_MS);
  try {
    const resp = await fetch(`${OPSM_BASE_URL}${path}`, {
      method: "GET",
      signal: controller.signal,
    });
    const data = await resp.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: resp.status, data };
  } catch (e) {
    if (e.name === "AbortError") {
      return { status: 504, data: { success: false, error: "OPSM backend timed out" } };
    }
    return { status: 503, data: { success: false, error: `OPSM backend unavailable: ${e.message}` } };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Registry name → OPSM forth atom normaliser
// ---------------------------------------------------------------------------

const REGISTRY_ALIASES = {
  // AffineScript and RattleScript (first-class)
  affinescript: "affinescript", affine: "affinescript", afs: "affinescript",
  rattlescript: "rattlescript", rattle: "rattlescript", rts: "rattlescript",
  // Hyperpolymath nextgen languages
  eclexia: "eclexia", ecl: "eclexia",
  ephapax: "ephapax", mylang: "my_lang", wokelang: "wokelang",
  julia_the_viper: "julia_the_viper", viper: "julia_the_viper",
  error_lang: "error_lang", oblibeny: "oblibeny", idris2: "idris2", idris: "idris2",
  // Major ecosystems
  cargo: "cargo", rust: "cargo", crates: "cargo",
  npm: "npm", node: "npm",
  hex: "hex", elixir: "hex",
  pypi: "pypi", python: "pypi", pip: "pypi",
  gem: "gem", ruby: "gem",
  go: "go", golang: "go",
  hackage: "hackage", haskell: "hackage",
  nuget: "nuget", dotnet: "nuget",
  maven: "maven", java: "maven",
};

function normaliseRegistry(r) {
  if (!r) return null;
  return REGISTRY_ALIASES[r.toLowerCase()] ?? r.toLowerCase();
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- opsm_search ---------------------------------------------------------
    case "opsm_search": {
      const { query, registry, limit = 20 } = args;
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query, limit };
      if (registry) payload.registry = normaliseRegistry(registry);
      return opsmPost("/api/v1/search", payload);
    }

    // -- opsm_install --------------------------------------------------------
    case "opsm_install": {
      const { package_name, registry, version = "latest", workspace_root } = args;
      if (!package_name) return { status: 400, data: { error: "package_name is required" } };
      const payload = { package: package_name, version };
      if (registry) payload.registry = normaliseRegistry(registry);
      if (workspace_root) payload.workspace_root = workspace_root;
      return opsmPost("/api/v1/install", payload);
    }

    // -- opsm_resolve --------------------------------------------------------
    case "opsm_resolve": {
      const { manifest, manifest_format } = args;
      if (!manifest) return { status: 400, data: { error: "manifest is required" } };
      const payload = { manifest };
      if (manifest_format) payload.format = manifest_format;
      return opsmPost("/api/v1/resolve", payload);
    }

    // -- opsm_info -----------------------------------------------------------
    case "opsm_info": {
      const { package_name, registry, version = "latest" } = args;
      if (!package_name) return { status: 400, data: { error: "package_name is required" } };
      const forth = registry ? normaliseRegistry(registry) : "auto";
      return opsmGet(`/api/v1/packages/${encodeURIComponent(package_name)}?forth=${forth}&version=${encodeURIComponent(version)}`);
    }

    // -- opsm_list -----------------------------------------------------------
    case "opsm_list": {
      const { workspace_root, include_transitive = false } = args ?? {};
      const payload = { include_transitive };
      if (workspace_root) payload.workspace_root = workspace_root;
      return opsmPost("/api/v1/list", payload);
    }

    // -- opsm_registries -----------------------------------------------------
    case "opsm_registries": {
      const { filter_state } = args ?? {};
      const url = filter_state
        ? `/api/v1/registries?state=${encodeURIComponent(filter_state)}`
        : "/api/v1/registries";
      return opsmGet(url);
    }

    // -- opsm_status ---------------------------------------------------------
    case "opsm_status": {
      return opsmGet("/api/v1/status");
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
