-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.Domain: Capability domain definitions for the 2D matrix.
|||
||| These are the ROWS of the matrix — what a server does.
||| Each domain represents a class of infrastructure capability.
module Boj.Domain

%default total

||| Capability domains supported by BoJ cartridges.
||| These form the rows of the 2D capability matrix.
public export
data CapabilityDomain
  = Cloud       -- Cloud provider operations (AWS, GCP, Azure, etc.)
  | Container   -- Container management (Podman, OCI images)
  | Database    -- Database operations (SQL, NoSQL, VeriSimDB)
  | K8s         -- Kubernetes orchestration
  | Git         -- Git/VCS operations (GitHub, GitLab, Bitbucket)
  | Secrets     -- Secret management (Vault, SOPS, sealed-secrets)
  | Queues      -- Message queues (NATS, RabbitMQ, Kafka)
  | IaC         -- Infrastructure as Code (Terraform, Pulumi, Nix)
  | Observe     -- Observability (metrics, logs, traces)
  | SSG         -- Static site generation (Jekyll, Hugo, Zola)
  | Proof       -- Formal proof assistants (Idris2, Lean, Coq)
  | FleetDom    -- Gitbot fleet domain (rhodibot, echidnabot, etc.)
  | NeSyDom     -- Neurosymbolic reasoning domain (hypatia, echidna)

||| Human-readable label for display in the Teranga menu.
public export
domainLabel : CapabilityDomain -> String
domainLabel Cloud     = "Cloud"
domainLabel Container = "Container"
domainLabel Database  = "Database"
domainLabel K8s       = "Kubernetes"
domainLabel Git       = "Git/VCS"
domainLabel Secrets   = "Secrets"
domainLabel Queues    = "Queues"
domainLabel IaC       = "IaC"
domainLabel Observe   = "Observability"
domainLabel SSG       = "SSG"
domainLabel Proof     = "Proof"
domainLabel FleetDom  = "Fleet"
domainLabel NeSyDom   = "NeSy"

||| C-ABI encoding: domain to integer.
public export
domainToInt : CapabilityDomain -> Int
domainToInt Cloud     = 1
domainToInt Container = 2
domainToInt Database  = 3
domainToInt K8s       = 4
domainToInt Git       = 5
domainToInt Secrets   = 6
domainToInt Queues    = 7
domainToInt IaC       = 8
domainToInt Observe   = 9
domainToInt SSG       = 10
domainToInt Proof     = 11
domainToInt FleetDom  = 12
domainToInt NeSyDom   = 13

||| C-ABI decoding: integer to domain (with safe fallback).
public export
intToDomain : Int -> Maybe CapabilityDomain
intToDomain 1  = Just Cloud
intToDomain 2  = Just Container
intToDomain 3  = Just Database
intToDomain 4  = Just K8s
intToDomain 5  = Just Git
intToDomain 6  = Just Secrets
intToDomain 7  = Just Queues
intToDomain 8  = Just IaC
intToDomain 9  = Just Observe
intToDomain 10 = Just SSG
intToDomain 11 = Just Proof
intToDomain 12 = Just FleetDom
intToDomain 13 = Just NeSyDom
intToDomain _  = Nothing

||| Equality for capability domains.
public export
Eq CapabilityDomain where
  Cloud     == Cloud     = True
  Container == Container = True
  Database  == Database  = True
  K8s       == K8s       = True
  Git       == Git       = True
  Secrets   == Secrets   = True
  Queues    == Queues    = True
  IaC       == IaC       = True
  Observe   == Observe   = True
  SSG       == SSG       = True
  Proof     == Proof     = True
  FleetDom  == FleetDom  = True
  NeSyDom   == NeSyDom   = True
  _         == _         = False
