// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP resources surface
//
// Implements MCP resources/list + resources/read. Resources let clients
// inspect BoJ's state (cartridge manifest, capability matrix, proof
// obligations) without round-tripping through tools/call.
//
// URI scheme: boj://<namespace>/<identifier>
//
// Read-only by design. Never returns mutable handles.

import { OFFLINE_MENU } from "./offline-menu.js";
import { fetchMenu, fetchCartridges, fetchCartridgeInfo } from "./api-clients.js";

const STATIC_RESOURCES = [
  {
    uri: "boj://cartridges",
    name: "Cartridge index",
    description: "Full list of all installed BoJ cartridges with trust tier, domain, protocols, and availability. JSON. Returns the offline manifest when the REST backend is unreachable.",
    mimeType: "application/json",
  },
  {
    uri: "boj://capabilities/matrix",
    name: "Capability matrix",
    description: "Protocol × domain grid showing which cartridges serve each combination (e.g. MCP+Database → database-mcp). JSON.",
    mimeType: "application/json",
  },
  {
    uri: "boj://capabilities/tools",
    name: "Tool surface",
    description: "Bridge-level tools (boj_*, coord_*) grouped by domain with arity and side-effect classification. JSON.",
    mimeType: "application/json",
  },
  {
    uri: "boj://proofs/manifest",
    name: "Proof obligation manifest",
    description: "Idris2 ABI proof obligations (P-01..P-07 for local-coord-mcp; per-cartridge obligations for verified cartridges). Discharge status + believe_me audit. JSON.",
    mimeType: "application/json",
  },
  {
    uri: "boj://server/info",
    name: "Server identity",
    description: "Server name, version, runtime, supported protocol versions, advertised MCP capabilities. JSON.",
    mimeType: "application/json",
  },
  {
    uri: "boj://docs/architecture",
    name: "Architecture overview",
    description: "Pointers to ADRs and TOPOLOGY.md describing BoJ's cartridge architecture, trust-tier model, and federation policy. Markdown.",
    mimeType: "text/markdown",
  },
];

const SERVER_INFO_RESOURCE = {
  name: "boj-server",
  description: "Bundle of Joy MCP Server — cartridge-based DevOps + multi-agent coordination toolkit.",
  runtime: "deno-or-node",
  protocol_versions: ["2024-11-05"],
  capabilities: {
    tools: { listChanged: true },
    resources: { subscribe: false },
    prompts: { listChanged: false },
    logging: { levels: ["debug", "info", "warn", "error"] },
  },
  trust_tiers: ["teranga", "shield", "ayo"],
  links: {
    repo: "https://github.com/hyperpolymath/boj-server",
    glama: "https://glama.ai/mcp/servers/hyperpolymath/boj-server",
    docs: "https://github.com/hyperpolymath/boj-server/blob/main/README.md",
  },
};

const PROOFS_MANIFEST = {
  generated: "2026-05-20",
  obligations: [
    { id: "P-01", cartridge: "local-coord-mcp", title: "Peer-id uniqueness", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Identity.idr" },
    { id: "P-02", cartridge: "local-coord-mcp", title: "Token authenticity", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Auth.idr" },
    { id: "P-03", cartridge: "local-coord-mcp", title: "Watchdog termination", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Watchdog.idr" },
    { id: "P-04", cartridge: "local-coord-mcp", title: "Master-uniqueness invariant", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Supervision.idr" },
    { id: "P-05", cartridge: "local-coord-mcp", title: "Quarantine isolation", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Quarantine.idr" },
    { id: "P-06", cartridge: "local-coord-mcp", title: "Track-record monotonicity", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/TrackRecord.idr" },
    { id: "P-07", cartridge: "local-coord-mcp", title: "Reassignment soundness", status: "discharged", evidence: "cartridges/local-coord-mcp/abi/LocalCoord/Reassignment.idr" },
  ],
  believe_me_audit: {
    initial_count: 31,
    current_count: 4,
    reduced_in: "v0.4.0",
    notes: "Remaining 4 axioms tracked for full discharge in epic #87 (item 11)",
  },
};

const ARCHITECTURE_DOC = `# BoJ Architecture (resource view)

This is a discoverable, machine-readable pointer to the architecture surface. Full content lives in the repo.

## Core decisions

- **ADR-0002** — BoJ is the single MCP gateway for the hyperpolymath estate. No standalone MCPs. Path: \`docs/decisions/0002-align-unified-zig-api-stack.md\`.
- **ADR-0004** — Unified trust-gated dispatch (one Cowboy listener, protocol-routed REST + SSE + GraphQL + gRPC-compat → single Zig ABI). Replaces the 3-parallel-port anti-pattern.

## Trust tiers

- **Teranga** (hospitality) — verified, formally proven cartridges with full ABI discharge.
- **Shield** — operationally hardened with explicit security review.
- **Ayo** (joy) — community contributions; gated by master-approval flow.

## Topology

See \`TOPOLOGY.md\` for the full cartridge + adapter layout. Cartridge architecture: Idris2 ABI → Zig FFI → Deno/JS adapter, with the MCP bridge as the unified stdio surface.

## Multi-agent coordination

\`local-coord-mcp\` provides a loopback bus (127.0.0.1:7745) with master/journeyman/apprentice supervision, typed Nickel-validated envelopes, watchdog-TTL claims, and track-record-driven reassignment. Cross-machine federation tracked in epic #87 (item 3).

## Formal verification

Per-cartridge Idris2 ABIs with proof obligations. Current discharge state: see \`boj://proofs/manifest\`. Outstanding axioms: 4 (down from 31 in v0.4.0). Cross-cartridge composition proof is research-grade work, tracked in epic #87 (item 12).
`;

function listResources() {
  return STATIC_RESOURCES.map((r) => ({ ...r }));
}

async function readResource(uri) {
  if (typeof uri !== "string") {
    return null;
  }

  if (uri === "boj://cartridges") {
    let menu;
    try {
      menu = await fetchMenu();
    } catch {
      menu = OFFLINE_MENU;
    }
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(menu, null, 2),
        },
      ],
    };
  }

  if (uri.startsWith("boj://cartridges/")) {
    const name = uri.slice("boj://cartridges/".length);
    if (!/^[a-z0-9][a-z0-9-]*-mcp$/.test(name)) {
      return null;
    }
    let info;
    try {
      info = await fetchCartridgeInfo(name);
    } catch {
      info = { name, available: false, hint: "Backend offline; live manifest unavailable. Use boj://cartridges for the static index." };
    }
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(info, null, 2),
        },
      ],
    };
  }

  if (uri === "boj://capabilities/matrix") {
    let matrix;
    try {
      matrix = await fetchCartridges();
    } catch {
      matrix = { offline: true, hint: "Backend offline; matrix snapshot unavailable. Use boj://cartridges for the static cartridge index." };
    }
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(matrix, null, 2),
        },
      ],
    };
  }

  if (uri === "boj://capabilities/tools") {
    const { buildToolList } = await import("./tools.js");
    const tools = buildToolList();
    const grouped = {};
    for (const t of tools) {
      const prefix = t.name.split("_").slice(0, 2).join("_");
      const domain = prefix.startsWith("coord_") ? "coord" : prefix;
      if (!grouped[domain]) grouped[domain] = [];
      grouped[domain].push({
        name: t.name,
        purpose: t.description.split(".")[0],
        annotations: t.annotations,
      });
    }
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify({ total: tools.length, by_domain: grouped }, null, 2),
        },
      ],
    };
  }

  if (uri === "boj://proofs/manifest") {
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(PROOFS_MANIFEST, null, 2),
        },
      ],
    };
  }

  if (uri === "boj://server/info") {
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(SERVER_INFO_RESOURCE, null, 2),
        },
      ],
    };
  }

  if (uri === "boj://docs/architecture") {
    return {
      contents: [
        {
          uri,
          mimeType: "text/markdown",
          text: ARCHITECTURE_DOC,
        },
      ],
    };
  }

  return null;
}

export { listResources, readResource };
