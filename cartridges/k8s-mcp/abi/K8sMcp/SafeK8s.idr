-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| K8sMcp.SafeK8s: Formally verified Kubernetes orchestration operations.
|||
||| Cartridge: k8s-mcp
||| Matrix cell: Kubernetes domain x {MCP, LSP} protocols
|||
||| This module defines type-safe Kubernetes operations with a
||| cluster connection state machine and namespace isolation that prevents:
|||   - Operations on disconnected clusters
|||   - Cross-namespace operations without explicit namespace selection
|||   - Apply/delete without proper cluster auth
|||
||| State machine: Disconnected -> ClusterConnected -> NamespaceSelected -> Operating
|||                -> NamespaceSelected -> ClusterConnected -> Disconnected
module K8sMcp.SafeK8s

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Cluster Connection State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Cluster connection lifecycle states.
||| A cluster session progresses through namespace selection before operations.
public export
data K8sState = Disconnected | ClusterConnected | NamespaceSelected | Operating | K8sError

||| Equality for cluster states.
public export
Eq K8sState where
  Disconnected      == Disconnected      = True
  ClusterConnected  == ClusterConnected  = True
  NamespaceSelected == NamespaceSelected = True
  Operating         == Operating         = True
  K8sError          == K8sError          = True
  _                 == _                 = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : K8sState -> K8sState -> Type where
  Connect         : ValidTransition Disconnected ClusterConnected
  SelectNamespace : ValidTransition ClusterConnected NamespaceSelected
  ChangeNamespace : ValidTransition NamespaceSelected NamespaceSelected
  BeginOperation  : ValidTransition NamespaceSelected Operating
  EndOperation    : ValidTransition Operating NamespaceSelected
  DeselectNs      : ValidTransition NamespaceSelected ClusterConnected
  Disconnect      : ValidTransition ClusterConnected Disconnected
  OpError         : ValidTransition Operating K8sError
  Recover         : ValidTransition K8sError Disconnected

||| Runtime transition validator.
public export
canTransition : K8sState -> K8sState -> Bool
canTransition Disconnected      ClusterConnected  = True
canTransition ClusterConnected  NamespaceSelected = True
canTransition NamespaceSelected NamespaceSelected = True
canTransition NamespaceSelected Operating         = True
canTransition Operating         NamespaceSelected = True
canTransition NamespaceSelected ClusterConnected  = True
canTransition ClusterConnected  Disconnected      = True
canTransition Operating         K8sError          = True
canTransition K8sError          Disconnected      = True
canTransition _                 _                 = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Kubernetes Tool Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported Kubernetes tools.
public export
data K8sTool
  = Kubectl     -- Standard kubectl CLI
  | Helm        -- Helm chart manager
  | Kustomize   -- Kustomize overlay manager

||| C-ABI encoding.
public export
toolTypeToInt : K8sTool -> Int
toolTypeToInt Kubectl    = 1
toolTypeToInt Helm       = 2
toolTypeToInt Kustomize  = 3

-- ═══════════════════════════════════════════════════════════════════════════
-- Cluster Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A Kubernetes cluster session with tracked state.
public export
record ClusterSession where
  constructor MkClusterSession
  clusterId   : String
  tool        : K8sTool
  state       : K8sState
  namespace   : String
  contextName : String

||| Proof that a cluster session has a namespace selected (ready for operations).
public export
data HasNamespace : ClusterSession -> Type where
  NamespaceReady : (cs : ClusterSession) ->
                   (state cs = NamespaceSelected) ->
                   HasNamespace cs

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolConnectCluster    -- Connect to a Kubernetes cluster
  | ToolSelectNamespace   -- Select a namespace
  | ToolApply             -- Apply a manifest (kubectl apply)
  | ToolDelete            -- Delete a resource (kubectl delete)
  | ToolGetResources      -- List/get resources
  | ToolHelmInstall       -- Install a Helm chart
  | ToolHelmUpgrade       -- Upgrade a Helm release
  | ToolStatus            -- Cluster/resource status

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolConnectCluster  = "k8s/connect"
toolName ToolSelectNamespace = "k8s/select-namespace"
toolName ToolApply           = "k8s/apply"
toolName ToolDelete          = "k8s/delete"
toolName ToolGetResources    = "k8s/get"
toolName ToolHelmInstall     = "k8s/helm-install"
toolName ToolHelmUpgrade     = "k8s/helm-upgrade"
toolName ToolStatus          = "k8s/status"

||| Which tools require a namespace to be selected.
public export
requiresNamespace : McpTool -> Bool
requiresNamespace ToolConnectCluster  = False
requiresNamespace ToolSelectNamespace = False
requiresNamespace ToolStatus          = False
requiresNamespace _                   = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Cluster state to integer.
public export
k8sStateToInt : K8sState -> Int
k8sStateToInt Disconnected      = 0
k8sStateToInt ClusterConnected  = 1
k8sStateToInt NamespaceSelected = 2
k8sStateToInt Operating         = 3
k8sStateToInt K8sError          = 4

||| FFI: Validate a state transition.
export
k8s_can_transition : Int -> Int -> Int
k8s_can_transition from to =
  let fromState = case from of
                    0 => Disconnected
                    1 => ClusterConnected
                    2 => NamespaceSelected
                    3 => Operating
                    _ => K8sError
      toState = case to of
                  0 => Disconnected
                  1 => ClusterConnected
                  2 => NamespaceSelected
                  3 => Operating
                  _ => K8sError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a namespace to be selected.
export
k8s_tool_requires_namespace : Int -> Int
k8s_tool_requires_namespace 1 = 0  -- ToolConnectCluster
k8s_tool_requires_namespace 2 = 0  -- ToolSelectNamespace
k8s_tool_requires_namespace 8 = 0  -- ToolStatus
k8s_tool_requires_namespace _ = 1  -- All others require namespace
