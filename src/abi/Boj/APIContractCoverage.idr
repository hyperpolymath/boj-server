-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Boj.APIContractCoverage: API contract compliance proof (BJ3).
|||
||| REQUIREMENTS-MASTER.md: BJ3 | API contract compliance | TP | I2 | P2
|||
||| Proves three classes of contract invariants over a representative catalogue
||| of 17 cartridges (one per core domain/protocol cell):
|||
|||   1. ProtocolCompliance — every cartridge in the representative catalogue
|||      declares at least one protocol (NonEmpty protocols).
|||
|||   2. DomainCoverage — each of the 15 currently-deployed CapabilityDomains
|||      has at least one witness cartridge with status Ready.
|||
|||   3. ProtocolCoverage — each of the 7 deployed ProtocolTypes has at least
|||      one witness cartridge that lists it.
|||
||| Three domains are not yet deployed (Development status):
|||   Dap, Bsp, CodeIntel — excluded from DomainCoverage proof.
|||
||| BJ3 connects to BJ1 (CartridgeDispatch type safety): for every witnessed
||| (domain, protocol) pair the `dispatch` function will return `Routed`.
module Boj.APIContractCoverage

import Data.List
import Data.List.Elem
import Boj.Protocol
import Boj.Domain
import Boj.Catalogue

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Representative Catalogue
-- ═══════════════════════════════════════════════════════════════════════════

||| Seventeen concrete cartridge witnesses — one per deployed domain/protocol
||| cell.  These are the compile-time stand-ins for the runtime catalogue.
public export
cloudCart : Cartridge
cloudCart = MkCartridge "cloud-mcp" "1.0.0" Ready Teranga Cloud [REST, MCP] "" "universal"

public export
containerCart : Cartridge
containerCart = MkCartridge "container-mcp" "1.0.0" Ready Teranga Container [MCP] "" "universal"

public export
databaseCart : Cartridge
databaseCart = MkCartridge "database-mcp" "1.0.0" Ready Teranga Database [MCP] "" "universal"

public export
fleetCart : Cartridge
fleetCart = MkCartridge "fleet-mcp" "1.0.0" Ready Teranga FleetDom [Fleet, MCP] "" "universal"

public export
nesyCart : Cartridge
nesyCart = MkCartridge "nesy-mcp" "1.0.0" Ready Teranga NeSyDom [NeSy, MCP] "" "universal"

public export
agentCart : Cartridge
agentCart = MkCartridge "agent-mcp" "1.0.0" Ready Teranga Agent [Agentic, MCP] "" "universal"

public export
k8sCart : Cartridge
k8sCart = MkCartridge "k8s-mcp" "1.0.0" Ready Teranga K8s [GRPC, MCP] "" "universal"

public export
gitCart : Cartridge
gitCart = MkCartridge "git-mcp" "1.0.0" Ready Teranga Git [MCP] "" "universal"

public export
secretsCart : Cartridge
secretsCart = MkCartridge "secrets-mcp" "1.0.0" Ready Shield Secrets [MCP] "" "universal"

public export
queuesCart : Cartridge
queuesCart = MkCartridge "queues-mcp" "1.0.0" Ready Teranga Queues [MCP] "" "universal"

public export
iacCart : Cartridge
iacCart = MkCartridge "iac-mcp" "1.0.0" Ready Teranga IaC [MCP] "" "universal"

public export
observeCart : Cartridge
observeCart = MkCartridge "observe-mcp" "1.0.0" Ready Teranga Observe [MCP] "" "universal"

public export
ssgCart : Cartridge
ssgCart = MkCartridge "ssg-mcp" "1.0.0" Ready Teranga SSG [MCP] "" "universal"

public export
proofCart : Cartridge
proofCart = MkCartridge "proof-mcp" "1.0.0" Ready Shield Proof [MCP] "" "universal"

public export
lspCart : Cartridge
lspCart = MkCartridge "lsp-mcp" "1.0.0" Ready Teranga Lsp [LSP, MCP] "" "universal"

public export
bojHealthCart : Cartridge
bojHealthCart = MkCartridge "boj_health" "1.0.0" Ready Teranga FleetDom [MCP] "" "universal"

public export
bojCartridgesCart : Cartridge
bojCartridgesCart = MkCartridge "boj_cartridges" "1.0.0" Ready Teranga FleetDom [MCP] "" "universal"

||| The representative catalogue as a flat list.
public export
representativeCatalogue : List Cartridge
representativeCatalogue =
  [ cloudCart, containerCart, databaseCart, fleetCart, nesyCart
  , agentCart, k8sCart, gitCart, secretsCart, queuesCart
  , iacCart, observeCart, ssgCart, proofCart, lspCart
  , bojHealthCart, bojCartridgesCart
  ]

-- ═══════════════════════════════════════════════════════════════════════════
-- BJ3-1: Protocol Compliance
-- ═══════════════════════════════════════════════════════════════════════════

||| Every cartridge must declare at least one protocol.
public export
CartridgeHasProtocol : Cartridge -> Type
CartridgeHasProtocol c = NonEmpty (protocols c)

||| Proof that every cartridge in `representativeCatalogue` has at least one
||| declared protocol.  Follows by computation since all protocols lists are
||| non-empty concrete values.
export
repCatalogueProtocolCompliance :
  (c : Cartridge) -> Elem c Boj.APIContractCoverage.representativeCatalogue -> CartridgeHasProtocol c
repCatalogueProtocolCompliance _ Here                                                              = IsNonEmpty
repCatalogueProtocolCompliance _ (There Here)                                                      = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There Here))                                              = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There Here)))                                      = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There Here))))                              = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There Here)))))                      = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There Here))))))              = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There Here)))))))      = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There Here)))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There Here))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There Here)))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There Here))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))) = IsNonEmpty
repCatalogueProtocolCompliance _ (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There _))))))))))))))))) impossible

-- ═══════════════════════════════════════════════════════════════════════════
-- BJ3-2: Domain Coverage
-- ═══════════════════════════════════════════════════════════════════════════

||| There exists a Ready cartridge serving domain `d`.
public export
DomainHasReadyCartridge : CapabilityDomain -> Type
DomainHasReadyCartridge d = (c : Cartridge ** (domain c = d, status c = Ready))

-- Explicit witnesses for the 15 deployed domains.
export bj3_cloud     : DomainHasReadyCartridge Cloud     ; bj3_cloud     = (cloudCart     ** (Refl, Refl))
export bj3_container : DomainHasReadyCartridge Container ; bj3_container = (containerCart ** (Refl, Refl))
export bj3_database  : DomainHasReadyCartridge Database  ; bj3_database  = (databaseCart  ** (Refl, Refl))
export bj3_fleet     : DomainHasReadyCartridge FleetDom  ; bj3_fleet     = (fleetCart     ** (Refl, Refl))
export bj3_nesy      : DomainHasReadyCartridge NeSyDom   ; bj3_nesy      = (nesyCart      ** (Refl, Refl))
export bj3_agent     : DomainHasReadyCartridge Agent     ; bj3_agent     = (agentCart     ** (Refl, Refl))
export bj3_k8s       : DomainHasReadyCartridge K8s       ; bj3_k8s       = (k8sCart       ** (Refl, Refl))
export bj3_git       : DomainHasReadyCartridge Git       ; bj3_git       = (gitCart       ** (Refl, Refl))
export bj3_secrets   : DomainHasReadyCartridge Secrets   ; bj3_secrets   = (secretsCart   ** (Refl, Refl))
export bj3_queues    : DomainHasReadyCartridge Queues    ; bj3_queues    = (queuesCart    ** (Refl, Refl))
export bj3_iac       : DomainHasReadyCartridge IaC       ; bj3_iac       = (iacCart       ** (Refl, Refl))
export bj3_observe   : DomainHasReadyCartridge Observe   ; bj3_observe   = (observeCart   ** (Refl, Refl))
export bj3_ssg       : DomainHasReadyCartridge SSG       ; bj3_ssg       = (ssgCart       ** (Refl, Refl))
export bj3_proof     : DomainHasReadyCartridge Proof     ; bj3_proof     = (proofCart     ** (Refl, Refl))
export bj3_lsp       : DomainHasReadyCartridge Lsp       ; bj3_lsp       = (lspCart       ** (Refl, Refl))

-- ═══════════════════════════════════════════════════════════════════════════
-- BJ3-3: Protocol Coverage
-- ═══════════════════════════════════════════════════════════════════════════

||| There exists a Ready cartridge advertising protocol `p`.
public export
ProtocolHasCartridge : ProtocolType -> Type
ProtocolHasCartridge p = (c : Cartridge ** (p `elem` protocols c = True, status c = Ready))

export bj3_proto_MCP     : ProtocolHasCartridge MCP     ; bj3_proto_MCP     = (gitCart     ** (Refl, Refl))
export bj3_proto_LSP     : ProtocolHasCartridge LSP     ; bj3_proto_LSP     = (lspCart     ** (Refl, Refl))
export bj3_proto_REST    : ProtocolHasCartridge REST    ; bj3_proto_REST    = (cloudCart   ** (Refl, Refl))
export bj3_proto_GRPC    : ProtocolHasCartridge GRPC    ; bj3_proto_GRPC    = (k8sCart     ** (Refl, Refl))
export bj3_proto_NeSy    : ProtocolHasCartridge NeSy    ; bj3_proto_NeSy    = (nesyCart    ** (Refl, Refl))
export bj3_proto_Agentic : ProtocolHasCartridge Agentic ; bj3_proto_Agentic = (agentCart   ** (Refl, Refl))
export bj3_proto_Fleet   : ProtocolHasCartridge Fleet   ; bj3_proto_Fleet   = (fleetCart   ** (Refl, Refl))

-- ═══════════════════════════════════════════════════════════════════════════
-- BJ3 Summary Theorem
-- ═══════════════════════════════════════════════════════════════════════════

||| BJ3 — API Contract Compliance Record
|||
||| A single type bundling the three compliance properties.  Construct one
||| to assert that the representative catalogue satisfies all three
||| contract obligations.
public export
record BJ3Compliance where
  constructor MkBJ3Compliance
  protocolCompliance : (c : Cartridge) -> Elem c Boj.APIContractCoverage.representativeCatalogue -> CartridgeHasProtocol c
  domainCoverage     : (d : CapabilityDomain) ->
                       Not (d = Dap) -> Not (d = Bsp) -> Not (d = CodeIntel) ->
                       DomainHasReadyCartridge d
  protocolCoverage   : (p : ProtocolType) ->
                       Not (p = DAP) -> Not (p = BSP) ->
                       ProtocolHasCartridge p

||| BJ3 is fully established.
export
bj3 : BJ3Compliance
bj3 = MkBJ3Compliance
  repCatalogueProtocolCompliance
  (\d, notDap, notBsp, notCI => case d of
    Cloud     => bj3_cloud
    Container => bj3_container
    Database  => bj3_database
    K8s       => bj3_k8s
    Git       => bj3_git
    Secrets   => bj3_secrets
    Queues    => bj3_queues
    IaC       => bj3_iac
    Observe   => bj3_observe
    SSG       => bj3_ssg
    Proof     => bj3_proof
    FleetDom  => bj3_fleet
    NeSyDom   => bj3_nesy
    Agent     => bj3_agent
    Lsp       => bj3_lsp
    Dap       => absurd (notDap Refl)
    Bsp       => absurd (notBsp Refl)
    CodeIntel => absurd (notCI Refl))
  (\p, notDAP, notBSP => case p of
    MCP     => bj3_proto_MCP
    LSP     => bj3_proto_LSP
    REST    => bj3_proto_REST
    GRPC    => bj3_proto_GRPC
    NeSy    => bj3_proto_NeSy
    Agentic => bj3_proto_Agentic
    Fleet   => bj3_proto_Fleet
    DAP     => absurd (notDAP Refl)
    BSP     => absurd (notBSP Refl))
