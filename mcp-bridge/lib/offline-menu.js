// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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
    { name: "search-mcp", version: "0.1.0", domain: "Research", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Multi-provider web search (Tavily, Brave, Exa, Perplexity) behind one cartridge" },
    { name: "pinecone-mcp", version: "0.1.0", domain: "Vector", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Pinecone hosted vector DB — managed serverless indexes; routed via boj_vector" },
    { name: "weaviate-mcp", version: "0.1.0", domain: "Vector", protocols: ["MCP","REST","gRPC","GraphQL"], status: "Available", available: true, notes: "Weaviate hybrid (vector+BM25) search; self-host or cloud; routed via boj_vector" },
    { name: "qdrant-mcp", version: "0.1.0", domain: "Vector", protocols: ["MCP","REST","gRPC"], status: "Available", available: true, notes: "Qdrant Rust-native vector DB; payload filtering; routed via boj_vector" },
    { name: "chromadb-mcp", version: "0.1.0", domain: "Vector", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Chroma embedded or client/server; LLM-app focus; routed via boj_vector" },
    { name: "whisper-mcp", version: "0.1.0", domain: "Multi-modal", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Speech-to-text via OpenAI Whisper API + local whisper.cpp; routed via boj_multimodal" },
    { name: "elevenlabs-mcp", version: "0.1.0", domain: "Multi-modal", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Text-to-speech with voice cloning; routed via boj_multimodal" },
    { name: "replicate-mcp", version: "0.1.0", domain: "Multi-modal", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Replicate hosted ML models (image/video/audio gen); routed via boj_multimodal" },
    { name: "ffmpeg-mcp", version: "0.1.0", domain: "Multi-modal", protocols: ["MCP","REST"], status: "Available", available: true, notes: "Local FFmpeg gateway — probe/transcode/extract/concat/trim; not Worker-compatible (local-only); routed via boj_multimodal" },
    { name: "codeseeker-mcp", version: "0.1.0", domain: "Code Intelligence", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "lang-mcp", version: "0.1.0", domain: "Languages", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_shield: [
    { name: "secrets-mcp", version: "0.1.0", domain: "Secrets", protocols: ["MCP","REST"], status: "Available", available: true },
    { name: "proof-mcp", version: "0.1.0", domain: "Proof", protocols: ["MCP","REST"], status: "Available", available: true },
  ],
  tier_ayo: [
    { name: "local-coord-mcp", version: "0.9.0", domain: "Agent", protocols: ["MCP","Agentic"], status: "Available", available: true, notes: "Localhost-only (127.0.0.1:7745) multi-instance AI coordination — peer discovery, typed envelopes, task claiming, master/journeyman/apprentice supervision with quarantine + watchdog TTL + track-record affinity + capability advertisement" },
  ],
  // `total` reflects the full cartridges/ directory (125 cartridges on disk);
  // the tier_* arrays above enumerate the named ones exposed through the
  // offline menu. Regenerate counts with
  // `node mcp-bridge/lib/generate-offline-menu.js`.
  summary: { total: 125, ready: 24, mounted: 0 },
};
