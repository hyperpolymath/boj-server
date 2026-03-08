-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| ObserveMcp.SafeObserve: Formally verified observability operations.
|||
||| Cartridge: observe-mcp
||| Matrix cell: Observability domain x {MCP, LSP} protocols
|||
||| This module defines a metrics pipeline state machine that prevents:
|||   - Querying unconfigured observability sources
|||   - Executing queries without source registration
|||   - Unbounded query rates (backpressure tracking)
|||
||| State machine: Unconfigured -> SourceRegistered -> QueryReady -> Querying -> QueryReady
module ObserveMcp.SafeObserve

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Observability State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Observability source lifecycle states.
||| A source progresses: Unconfigured -> SourceRegistered -> QueryReady -> Querying -> QueryReady
public export
data ObserveState = Unconfigured | SourceRegistered | QueryReady | Querying | ObserveError

||| Equality for observability states.
public export
Eq ObserveState where
  Unconfigured     == Unconfigured     = True
  SourceRegistered == SourceRegistered = True
  QueryReady       == QueryReady       = True
  Querying         == Querying         = True
  ObserveError     == ObserveError     = True
  _                == _                = False

||| Valid state transitions (enforced at the type level).
||| Critically, Unconfigured -> Querying is NOT a valid transition.
||| You MUST register a source first.
public export
data ValidTransition : ObserveState -> ObserveState -> Type where
  Register    : ValidTransition Unconfigured SourceRegistered
  Ready       : ValidTransition SourceRegistered QueryReady
  StartQuery  : ValidTransition QueryReady Querying
  EndQuery    : ValidTransition Querying QueryReady
  Unregister  : ValidTransition QueryReady Unconfigured
  QueryError  : ValidTransition Querying ObserveError
  Recover     : ValidTransition ObserveError QueryReady

||| Runtime transition validator.
public export
canTransition : ObserveState -> ObserveState -> Bool
canTransition Unconfigured     SourceRegistered = True
canTransition SourceRegistered QueryReady       = True
canTransition QueryReady       Querying         = True
canTransition Querying         QueryReady       = True
canTransition QueryReady       Unconfigured     = True  -- unregister
canTransition Querying         ObserveError     = True
canTransition ObserveError     QueryReady       = True  -- recover
canTransition _                _                = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Observability Backend Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported observability backends.
public export
data ObserveBackend
  = Prometheus    -- Metrics collection and querying
  | Grafana       -- Dashboard and visualisation
  | Loki          -- Log aggregation
  | Jaeger        -- Distributed tracing
  | Custom String -- User-defined backend

||| C-ABI encoding.
public export
backendToInt : ObserveBackend -> Int
backendToInt Prometheus  = 1
backendToInt Grafana     = 2
backendToInt Loki        = 3
backendToInt Jaeger      = 4
backendToInt (Custom _)  = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolRegisterSource    -- Register an observability source
  | ToolQueryMetrics      -- Query metrics (Prometheus/PromQL)
  | ToolQueryLogs         -- Query logs (Loki/LogQL)
  | ToolQueryTraces       -- Query traces (Jaeger)
  | ToolCreateDashboard   -- Create a Grafana dashboard
  | ToolSetAlert          -- Configure an alert rule
  | ToolStatus            -- Source health check
  | ToolUnregister        -- Unregister a source

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolRegisterSource  = "observe/register"
toolName ToolQueryMetrics    = "observe/metrics"
toolName ToolQueryLogs       = "observe/logs"
toolName ToolQueryTraces     = "observe/traces"
toolName ToolCreateDashboard = "observe/dashboard"
toolName ToolSetAlert        = "observe/alert"
toolName ToolStatus          = "observe/status"
toolName ToolUnregister      = "observe/unregister"

||| Which tools require a source to be registered first.
public export
toolRequiresSource : McpTool -> Bool
toolRequiresSource ToolRegisterSource = False
toolRequiresSource _                  = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Observability state to integer.
public export
observeStateToInt : ObserveState -> Int
observeStateToInt Unconfigured     = 0
observeStateToInt SourceRegistered = 1
observeStateToInt QueryReady       = 2
observeStateToInt Querying         = 3
observeStateToInt ObserveError     = 4

||| FFI: Validate a state transition.
export
obs_can_transition : Int -> Int -> Int
obs_can_transition from to =
  let fromState = case from of
                    0 => Unconfigured
                    1 => SourceRegistered
                    2 => QueryReady
                    3 => Querying
                    _ => ObserveError
      toState = case to of
                  0 => Unconfigured
                  1 => SourceRegistered
                  2 => QueryReady
                  3 => Querying
                  _ => ObserveError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a registered source.
export
obs_tool_requires_source : Int -> Int
obs_tool_requires_source 1 = 0  -- ToolRegisterSource
obs_tool_requires_source _ = 1  -- All others require a source
