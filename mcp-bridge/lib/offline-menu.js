// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Offline menu
//
// Static cartridge manifest for offline/inspection mode.
// Generated from cartridges/ directory structure.
// Run `node mcp-bridge/lib/generate-offline-menu.js` to regenerate.

export const OFFLINE_MENU = {
  tier_teranga: [
    { name: "database-mcp", version: "0.2.0", domain: "Database", protocols: ["MCP","REST","gRPC"], status: "Available", available: true, backends: ["VeriSimDB (VQL)", "QuandleDB (KQL)", "LithoGlyph (GQL)", "SQLite", "PostgreSQL", "Redis"] },
    { name: "nesy-mcp", version: "0.1.0", domain: "NeSy", protocols: ["NeSy","MCP","REST"], status: "Available", available: true },
    { name: "fleet-mcp", version: "0.1.0", domain: "Fleet", protocols: ["Fleet","MCP","REST"], status: "Available", available: true },
    { name: "agent-mcp", version: "0.1.0", domain: "Cloud", protocols: ["Agentic","MCP","REST","gRPC"], status: "Available", available: true },
    { name: "cloud-mcp", version: "0.1.0", domain: "Cloud", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "container-mcp", version: "0.1.0", domain: "Container", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "k8s-mcp", version: "0.1.0", domain: "Kubernetes", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "git-mcp", version: "0.1.0", domain: "Git/VCS", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "queues-mcp", version: "0.1.0", domain: "Queues", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "iac-mcp", version: "0.1.0", domain: "IaC", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "observe-mcp", version: "0.1.0", domain: "Observability", protocols: ["MCP","REST","gRPC"], status: "Available", available: true },
    { name: "ssg-mcp", version: "0.1.0", domain: "SSG", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "lsp-mcp", version: "0.1.0", domain: "Cloud", protocols: ["LSP","MCP","REST"], status: "Available", available: true },
    { name: "dap-mcp", version: "0.1.0", domain: "Cloud", protocols: ["DAP","MCP","REST"], status: "Available", available: true },
    { name: "bsp-mcp", version: "0.1.0", domain: "Cloud", protocols: ["BSP","MCP","REST"], status: "Available", available: true },
    { name: "feedback-mcp", version: "0.1.0", domain: "Feedback", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "comms-mcp", version: "0.1.0", domain: "Communications", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "ml-mcp", version: "0.1.0", domain: "ML/AI", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "research-mcp", version: "0.1.0", domain: "Research", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "codeseeker-mcp", version: "0.1.0", domain: "Code Intelligence", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "lang-mcp", version: "0.1.0", domain: "Languages", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_shield: [
    { name: "secrets-mcp", version: "0.1.0", domain: "Secrets", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "proof-mcp", version: "0.1.0", domain: "Proof", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_ayo: [],
  summary: { total: 23, ready: 23, mounted: 0 },
};
