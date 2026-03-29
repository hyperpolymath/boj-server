# SPDX-License-Identifier: PMPL-1.0-or-later
# TOPOLOGY.md — BoJ Server Component Matrix
#
# Auto-generated 2026-03-29. 92 cartridges across 6 tiers.

## Ports

| Port | Protocol | Status |
|------|----------|--------|
| 7700 | REST (HTTP) | Running |
| 7701 | gRPC | Running |
| 7702 | GraphQL | Running |
| 7703 | SSE (Server-Sent Events) | Running |

## Cartridge Matrix (92 total)

### Tier 1 — High-Value APIs (11)
| Cartridge | Domain |
|-----------|--------|
| github-api-mcp | Source control |
| gitlab-api-mcp | Source control |
| browser-mcp | Web automation |
| slack-mcp | Communication |
| vault-mcp | Secrets |
| linear-mcp | Project management |
| notion-mcp | Knowledge base |
| jira-mcp | Project management |
| discord-mcp | Communication |
| telegram-mcp | Communication |
| matrix-mcp | Communication |

### Tier 2 — Databases (10)
| Cartridge | Domain |
|-----------|--------|
| postgresql-mcp | Relational DB |
| redis-mcp | Cache/KV |
| mongodb-mcp | Document DB |
| neon-mcp | Serverless Postgres |
| turso-mcp | Edge SQLite |
| supabase-mcp | Backend-as-Service |
| arango-mcp | Multi-model DB |
| neo4j-mcp | Graph DB |
| clickhouse-mcp | Analytics DB |
| duckdb-mcp | Embedded OLAP |

### Tier 3 — Cloud Providers (8)
| Cartridge | Domain |
|-----------|--------|
| aws-mcp | Cloud |
| gcp-mcp | Cloud |
| hetzner-mcp | Cloud |
| fly-mcp | Edge compute |
| railway-mcp | PaaS |
| render-mcp | PaaS |
| digitalocean-mcp | Cloud |
| linode-mcp | Cloud |

### Tier 4 — Dev Tools & Registries (13)
| Cartridge | Domain |
|-----------|--------|
| docker-hub-mcp | Container registry |
| npm-registry-mcp | JS packages |
| crates-mcp | Rust packages |
| pypi-mcp | Python packages |
| hex-mcp | Elixir packages |
| opam-mcp | OCaml packages |
| hackage-mcp | Haskell packages |
| github-actions-mcp | CI/CD |
| buildkite-mcp | CI/CD |
| circleci-mcp | CI/CD |
| git-mcp | Version control |
| lsp-mcp | Language Server Protocol |
| dap-mcp | Debug Adapter Protocol |

### Tier 5 — Productivity & Comms (8)
| Cartridge | Domain |
|-----------|--------|
| comms-mcp | Unified messaging |
| google-docs-mcp | Documents |
| google-sheets-mcp | Spreadsheets |
| obsidian-mcp | Notes |
| todoist-mcp | Task management |
| airtable-mcp | Low-code DB |
| zotero-mcp | Research |
| feedback-mcp | User feedback |

### Tier 6 — Monitoring & Observability (6)
| Cartridge | Domain |
|-----------|--------|
| grafana-mcp | Dashboards |
| prometheus-mcp | Metrics |
| sentry-mcp | Error tracking |
| observe-mcp | Observability |
| laminar-mcp | Flow monitoring |
| ums-mcp | Unified monitoring |

### Hyperpolymath Ecosystem (26)
| Cartridge | Domain |
|-----------|--------|
| agent-mcp | Agent orchestration |
| affinescript-mcp | Language tooling |
| aerie-mcp | Deployment |
| bsp-mcp | Build Server Protocol |
| burble-admin-mcp | Voice platform |
| civic-connect-mcp | Civic engagement |
| cloud-mcp | Multi-cloud |
| conflow-mcp | Config flow |
| container-mcp | Container ops |
| database-mcp | Multi-DB |
| echidna-llm-mcp | LLM prover |
| fleet-mcp | Bot fleet |
| game-admin-mcp | Game servers |
| gossamer-mcp | Webview shell |
| hypatia-mcp | Neurosymbolic CI |
| iac-mcp | Infrastructure-as-Code |
| idaptik-admin-mcp | Game admin |
| k8s-mcp | Kubernetes |
| kategoria-mcp | Categorisation |
| lang-mcp | Language services |
| ml-mcp | Machine learning |
| model-router-mcp | Model routing |
| nesy-mcp | Neurosymbolic |
| opsm-mcp | Operations |
| panic-attack-mcp | Security scanning |
| proof-mcp | Formal verification |

### Infrastructure & Utility (10)
| Cartridge | Domain |
|-----------|--------|
| queues-mcp | Message queues |
| railway-mcp | PaaS |
| render-mcp | PaaS |
| reposystem-mcp | Repo management |
| research-mcp | Research tools |
| rokur-mcp | Deployment |
| secrets-mcp | Secret management |
| ssg-mcp | Static site gen |
| stapeln-mcp | Container stack |
| typed-wasm-mcp | WASM types |
| verisimdb-mcp | 8-modality DB |
| vext-mcp | Extensions |

## CI/CD

| Workflow | Purpose |
|----------|---------|
| zig-test.yml | Zig FFI tests |
| release.yml | Release pipeline |
| lsp-dap-bsp.yml | Protocol column tests |

## PanLL Integration

| Module | Location |
|--------|----------|
| BojCmd.res | panll/src/commands/ |
| BojLiveCmd.res | panll/src/commands/ |
| CartridgeAbi.res | panll/src/generated/ |
