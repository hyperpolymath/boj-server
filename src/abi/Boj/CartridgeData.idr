-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Boj.CartridgeData: The complete BoJ cartridge catalogue — formal data.
|||
||| This module supplies the `bojCatalogue` list consumed by Boj.Menu,
||| Boj.CartridgeDispatch, and the Teranga menu system.
|||
||| Every cartridge entry maps to a corresponding directory under
||| `boj-server/cartridges/<name>/` which holds the operational
||| `cartridge.json` manifest and FFI stubs.
|||
||| Binary hashes are set to "sha256:unattested" until the build pipeline
||| computes them from the deployed .so artefacts (tracked in ADR-0003).
|||
||| New cartridges: add a top-level binding, then append to `bojCatalogue`.
||| Do NOT change the ordering of existing entries — ordinal position must
||| remain stable for the C-ABI integer encoding.
module Boj.CartridgeData

import Boj.Catalogue
import Boj.Domain
import Boj.Protocol

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Helper alias (saves repetition in the data below)
-- ═══════════════════════════════════════════════════════════════════════════

private
ua : String
ua = "sha256:unattested"

-- ═══════════════════════════════════════════════════════════════════════════
-- Cloud Domain
-- ═══════════════════════════════════════════════════════════════════════════

cloud_mcp : Cartridge
cloud_mcp = MkCartridge "cloud-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "universal"

aws_mcp : Cartridge
aws_mcp = MkCartridge "aws-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "aws"

gcp_mcp : Cartridge
gcp_mcp = MkCartridge "gcp-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "gcp"

cloudflare_mcp : Cartridge
cloudflare_mcp = MkCartridge "cloudflare-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "cloudflare"

digitalocean_mcp : Cartridge
digitalocean_mcp = MkCartridge "digitalocean-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "digitalocean"

fly_mcp : Cartridge
fly_mcp = MkCartridge "fly-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "fly"

hetzner_mcp : Cartridge
hetzner_mcp = MkCartridge "hetzner-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "hetzner"

linode_mcp : Cartridge
linode_mcp = MkCartridge "linode-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "linode"

railway_mcp : Cartridge
railway_mcp = MkCartridge "railway-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "railway"

render_mcp : Cartridge
render_mcp = MkCartridge "render-mcp" "0.1.0" Ready Ayo Cloud [MCP, REST] ua "render"

-- ═══════════════════════════════════════════════════════════════════════════
-- Container Domain
-- ═══════════════════════════════════════════════════════════════════════════

container_mcp : Cartridge
container_mcp = MkCartridge "container-mcp" "0.1.0" Ready Ayo Container [MCP, REST] ua "universal"

docker_hub_mcp : Cartridge
docker_hub_mcp = MkCartridge "docker-hub-mcp" "0.1.0" Ready Ayo Container [MCP, REST] ua "docker-hub"

stapeln_mcp : Cartridge
stapeln_mcp = MkCartridge "stapeln-mcp" "0.1.0" Ready Teranga Container [MCP, REST] ua "stapeln"

-- ═══════════════════════════════════════════════════════════════════════════
-- Database Domain
-- ═══════════════════════════════════════════════════════════════════════════

database_mcp : Cartridge
database_mcp = MkCartridge "database-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "universal"

postgresql_mcp : Cartridge
postgresql_mcp = MkCartridge "postgresql-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "postgresql"

mongodb_mcp : Cartridge
mongodb_mcp = MkCartridge "mongodb-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "mongodb"

redis_mcp : Cartridge
redis_mcp = MkCartridge "redis-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "redis"

neo4j_mcp : Cartridge
neo4j_mcp = MkCartridge "neo4j-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "neo4j"

clickhouse_mcp : Cartridge
clickhouse_mcp = MkCartridge "clickhouse-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "clickhouse"

duckdb_mcp : Cartridge
duckdb_mcp = MkCartridge "duckdb-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "duckdb"

neon_mcp : Cartridge
neon_mcp = MkCartridge "neon-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "neon"

supabase_mcp : Cartridge
supabase_mcp = MkCartridge "supabase-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "supabase"

turso_mcp : Cartridge
turso_mcp = MkCartridge "turso-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "turso"

arango_mcp : Cartridge
arango_mcp = MkCartridge "arango-mcp" "0.1.0" Ready Ayo Database [MCP, REST] ua "arangodb"

verisimdb_mcp : Cartridge
verisimdb_mcp = MkCartridge "verisimdb-mcp" "0.1.0" Ready Teranga Database [MCP, GRPC, REST] ua "verisimdb"

-- ═══════════════════════════════════════════════════════════════════════════
-- Kubernetes Domain
-- ═══════════════════════════════════════════════════════════════════════════

k8s_mcp : Cartridge
k8s_mcp = MkCartridge "k8s-mcp" "0.1.0" Ready Ayo K8s [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Git Domain
-- ═══════════════════════════════════════════════════════════════════════════

git_mcp : Cartridge
git_mcp = MkCartridge "git-mcp" "0.1.0" Ready Ayo Git [MCP, REST] ua "universal"

github_api_mcp : Cartridge
github_api_mcp = MkCartridge "github-api-mcp" "0.1.0" Ready Ayo Git [MCP, REST] ua "github"

gitlab_api_mcp : Cartridge
gitlab_api_mcp = MkCartridge "gitlab-api-mcp" "0.1.0" Ready Ayo Git [MCP, REST] ua "gitlab"

github_actions_mcp : Cartridge
github_actions_mcp = MkCartridge "github-actions-mcp" "0.1.0" Ready Ayo Git [MCP, REST] ua "github-actions"

reposystem_mcp : Cartridge
reposystem_mcp = MkCartridge "reposystem-mcp" "0.1.0" Ready Ayo Git [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Secrets Domain
-- ═══════════════════════════════════════════════════════════════════════════

secrets_mcp : Cartridge
secrets_mcp = MkCartridge "secrets-mcp" "0.1.0" Ready Shield Secrets [MCP, REST] ua "universal"

vault_mcp : Cartridge
vault_mcp = MkCartridge "vault-mcp" "0.1.0" Ready Shield Secrets [MCP, REST] ua "hashicorp-vault"

dns_shield_mcp : Cartridge
dns_shield_mcp = MkCartridge "dns-shield-mcp" "0.1.0" Ready Shield Secrets [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Queues Domain
-- ═══════════════════════════════════════════════════════════════════════════

queues_mcp : Cartridge
queues_mcp = MkCartridge "queues-mcp" "0.1.0" Ready Ayo Queues [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- IaC Domain
-- ═══════════════════════════════════════════════════════════════════════════

iac_mcp : Cartridge
iac_mcp = MkCartridge "iac-mcp" "0.1.0" Ready Ayo IaC [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Observability Domain
-- ═══════════════════════════════════════════════════════════════════════════

observe_mcp : Cartridge
observe_mcp = MkCartridge "observe-mcp" "0.1.0" Ready Ayo Observe [MCP, REST] ua "universal"

grafana_mcp : Cartridge
grafana_mcp = MkCartridge "grafana-mcp" "0.1.0" Ready Ayo Observe [MCP, REST] ua "grafana"

prometheus_mcp : Cartridge
prometheus_mcp = MkCartridge "prometheus-mcp" "0.1.0" Ready Ayo Observe [MCP, REST] ua "prometheus"

sentry_mcp : Cartridge
sentry_mcp = MkCartridge "sentry-mcp" "0.1.0" Ready Ayo Observe [MCP, REST] ua "sentry"

-- ═══════════════════════════════════════════════════════════════════════════
-- SSG Domain
-- ═══════════════════════════════════════════════════════════════════════════

ssg_mcp : Cartridge
ssg_mcp = MkCartridge "ssg-mcp" "0.1.0" Ready Ayo SSG [MCP, REST] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Proof Domain
-- ═══════════════════════════════════════════════════════════════════════════

proof_mcp : Cartridge
proof_mcp = MkCartridge "proof-mcp" "0.1.0" Ready Teranga Proof [MCP, REST] ua "universal"

echidna_llm_mcp : Cartridge
echidna_llm_mcp = MkCartridge "echidna-llm-mcp" "0.2.0" Ready Teranga Proof [MCP, NeSy, REST] ua "echidna"

ephapax_mcp : Cartridge
ephapax_mcp = MkCartridge "ephapax-mcp" "0.1.0" Ready Teranga Proof [MCP, REST] ua "ephapax"

-- ═══════════════════════════════════════════════════════════════════════════
-- Fleet Domain
-- ═══════════════════════════════════════════════════════════════════════════

fleet_mcp : Cartridge
fleet_mcp = MkCartridge "fleet-mcp" "0.1.0" Ready Teranga FleetDom [MCP, Fleet, REST] ua "gitbot-fleet"

-- ═══════════════════════════════════════════════════════════════════════════
-- Neurosymbolic Domain
-- ═══════════════════════════════════════════════════════════════════════════

hypatia_mcp : Cartridge
hypatia_mcp = MkCartridge "hypatia-mcp" "0.1.0" Ready Teranga NeSyDom [MCP, NeSy, REST] ua "hypatia"

nesy_mcp : Cartridge
nesy_mcp = MkCartridge "nesy-mcp" "0.1.0" Ready Teranga NeSyDom [MCP, NeSy] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Agent Domain
-- ═══════════════════════════════════════════════════════════════════════════

||| 007-mcp: 007 agent meta-language cartridge.
||| Exposes the full oo7 CLI surface (parse/run/trace/build/test/lint/verify/
||| canonical-proof-suite/groove/self-assess) plus OnEnter/OnExit lifecycle
||| hooks that register the session as a coord peer, load the 6a2 methodology
||| pack, and perform drift checks on exit.  Loopback-only (127.0.0.1:1066).
oo7_mcp : Cartridge
oo7_mcp = MkCartridge "007-mcp" "0.1.0" Ready Ayo Agent [MCP, Agentic] ua "007-lang"

agent_mcp : Cartridge
agent_mcp = MkCartridge "agent-mcp" "0.1.0" Ready Ayo Agent [MCP, Agentic] ua "universal"

claude_agents_power_mcp : Cartridge
claude_agents_power_mcp = MkCartridge "claude-agents-power-mcp" "0.1.0" Ready Ayo Agent [MCP, Agentic] ua "claude"

claude_ai_mcp : Cartridge
claude_ai_mcp = MkCartridge "claude-ai-mcp" "0.1.0" Ready Ayo Agent [MCP] ua "claude"

model_router_mcp : Cartridge
model_router_mcp = MkCartridge "model-router-mcp" "0.1.0" Ready Ayo Agent [MCP, Agentic] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- LSP Domain
-- ═══════════════════════════════════════════════════════════════════════════

lsp_mcp : Cartridge
lsp_mcp = MkCartridge "lsp-mcp" "0.1.0" Ready Ayo Lsp [MCP, LSP, REST] ua "universal"

||| orchestrator-lsp-mcp: cross-domain LSP orchestrator.
||| Routes LSP queries across all 12 poly-*-lsp servers (cloud, container,
||| IAC, k8s, db, queue, secrets, git, SSG, proof, observability, browser).
||| Elixir GenLSP adapter, Zig FFI (ADR-0006), ReScript VSCode extension.
||| Inspired by poly-orchestrator-lsp (polystack, archived 2026-04-27).
orchestrator_lsp_mcp : Cartridge
orchestrator_lsp_mcp = MkCartridge "orchestrator-lsp-mcp" "0.1.0" Ready Teranga Lsp [MCP, LSP] ua "poly-orchestrator"

-- ═══════════════════════════════════════════════════════════════════════════
-- DAP Domain
-- ═══════════════════════════════════════════════════════════════════════════

dap_mcp : Cartridge
dap_mcp = MkCartridge "dap-mcp" "0.1.0" Ready Ayo Dap [MCP, DAP] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- BSP Domain
-- ═══════════════════════════════════════════════════════════════════════════

bsp_mcp : Cartridge
bsp_mcp = MkCartridge "bsp-mcp" "0.1.0" Ready Ayo Bsp [MCP, BSP] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- Code Intelligence Domain
-- ═══════════════════════════════════════════════════════════════════════════

coderag_mcp : Cartridge
coderag_mcp = MkCartridge "coderag-mcp" "0.1.0" Ready Ayo CodeIntel [MCP, REST] ua "universal"

codeseeker_mcp : Cartridge
codeseeker_mcp = MkCartridge "codeseeker-mcp" "0.1.0" Ready Ayo CodeIntel [MCP, REST] ua "universal"

lang_mcp : Cartridge
lang_mcp = MkCartridge "lang-mcp" "0.1.0" Ready Ayo CodeIntel [MCP, LSP] ua "universal"

-- ═══════════════════════════════════════════════════════════════════════════
-- The complete BoJ catalogue
-- ═══════════════════════════════════════════════════════════════════════════

||| The complete BoJ cartridge catalogue.
||| Pass this to Boj.Menu.generateMenu, Boj.CartridgeDispatch.dispatch, etc.
||| Add new cartridges here AFTER defining them as top-level bindings above.
export
bojCatalogue : List Cartridge
bojCatalogue =
  -- Cloud (10)
  [ cloud_mcp, aws_mcp, gcp_mcp, cloudflare_mcp, digitalocean_mcp
  , fly_mcp, hetzner_mcp, linode_mcp, railway_mcp, render_mcp
  -- Container (3)
  , container_mcp, docker_hub_mcp, stapeln_mcp
  -- Database (12)
  , database_mcp, postgresql_mcp, mongodb_mcp, redis_mcp, neo4j_mcp
  , clickhouse_mcp, duckdb_mcp, neon_mcp, supabase_mcp, turso_mcp
  , arango_mcp, verisimdb_mcp
  -- Kubernetes (1)
  , k8s_mcp
  -- Git (5)
  , git_mcp, github_api_mcp, gitlab_api_mcp, github_actions_mcp, reposystem_mcp
  -- Secrets (3)
  , secrets_mcp, vault_mcp, dns_shield_mcp
  -- Queues (1)
  , queues_mcp
  -- IaC (1)
  , iac_mcp
  -- Observability (4)
  , observe_mcp, grafana_mcp, prometheus_mcp, sentry_mcp
  -- SSG (1)
  , ssg_mcp
  -- Proof (3)
  , proof_mcp, echidna_llm_mcp, ephapax_mcp
  -- Fleet (1)
  , fleet_mcp
  -- NeSy (2)
  , hypatia_mcp, nesy_mcp
  -- Agent (5 — oo7_mcp + 4 universal)
  , oo7_mcp, agent_mcp, claude_agents_power_mcp, claude_ai_mcp, model_router_mcp
  -- LSP (2 — lsp_mcp Ready, orchestrator_lsp_mcp Development)
  , lsp_mcp, orchestrator_lsp_mcp
  -- DAP (1)
  , dap_mcp
  -- BSP (1)
  , bsp_mcp
  -- Code Intelligence (3)
  , coderag_mcp, codeseeker_mcp, lang_mcp
  ]
