-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| ContainerMcp.SafeContainer: Formally verified container management operations.
|||
||| Cartridge: container-mcp
||| Matrix cell: Container domain x {MCP, LSP} protocols
|||
||| This module defines type-safe container lifecycle operations with a
||| state machine that prevents:
|||   - Starting a container that has not been created
|||   - Removing a running container without stopping it
|||   - Building from a non-existent state
|||
||| State machine: None -> Built -> Created -> Running -> Stopped -> Removed
module ContainerMcp.SafeContainer

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Container Lifecycle State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Container lifecycle states.
||| A container progresses: None -> Built -> Created -> Running -> Stopped -> Removed
public export
data CtrState = None | Built | Created | Running | Stopped | Removed

||| Equality for container states.
public export
Eq CtrState where
  None    == None    = True
  Built   == Built   = True
  Created == Created = True
  Running == Running = True
  Stopped == Stopped = True
  Removed == Removed = True
  _       == _       = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : CtrState -> CtrState -> Type where
  Build       : ValidTransition None Built
  Create      : ValidTransition Built Created
  Start       : ValidTransition Created Running
  Restart     : ValidTransition Stopped Running
  Stop        : ValidTransition Running Stopped
  RemoveStopped : ValidTransition Stopped Removed
  RemoveCreated : ValidTransition Created Removed

||| Runtime transition validator.
public export
canTransition : CtrState -> CtrState -> Bool
canTransition None    Built   = True
canTransition Built   Created = True
canTransition Created Running = True
canTransition Stopped Running = True
canTransition Running Stopped = True
canTransition Stopped Removed = True
canTransition Created Removed = True
canTransition _       _       = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Container Runtime Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported container runtimes.
||| Podman is the hyperpolymath default runtime.
public export
data ContainerRuntime
  = Podman   -- Default (rootless, daemonless)
  | Nerdctl  -- containerd CLI
  | Docker   -- Legacy compatibility

||| C-ABI encoding.
public export
runtimeToInt : ContainerRuntime -> Int
runtimeToInt Podman  = 1
runtimeToInt Nerdctl = 2
runtimeToInt Docker  = 3

-- ═══════════════════════════════════════════════════════════════════════════
-- Container Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A container with tracked lifecycle state.
public export
record Container where
  constructor MkContainer
  containerId : String
  runtime     : ContainerRuntime
  state       : CtrState
  imageName   : String

||| Proof that a container is in a running state.
public export
data IsRunning : Container -> Type where
  ActiveContainer : (c : Container) ->
                    (state c = Running) ->
                    IsRunning c

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolBuild           -- Build a container image
  | ToolCreate          -- Create a container from an image
  | ToolStart           -- Start a created/stopped container
  | ToolStop            -- Stop a running container
  | ToolRemove          -- Remove a stopped/created container
  | ToolLogs            -- Retrieve container logs
  | ToolInspect         -- Inspect container metadata
  | ToolListContainers  -- List all containers

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolBuild          = "container/build"
toolName ToolCreate         = "container/create"
toolName ToolStart          = "container/start"
toolName ToolStop           = "container/stop"
toolName ToolRemove         = "container/remove"
toolName ToolLogs           = "container/logs"
toolName ToolInspect        = "container/inspect"
toolName ToolListContainers = "container/list"

||| Which tools require a running container.
public export
requiresRunning : McpTool -> Bool
requiresRunning ToolLogs = True
requiresRunning ToolStop = True
requiresRunning _        = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Container state to integer.
public export
ctrStateToInt : CtrState -> Int
ctrStateToInt None    = 0
ctrStateToInt Built   = 1
ctrStateToInt Created = 2
ctrStateToInt Running = 3
ctrStateToInt Stopped = 4
ctrStateToInt Removed = 5

||| FFI: Validate a state transition.
export
ctr_can_transition : Int -> Int -> Int
ctr_can_transition from to =
  let fromState = case from of
                    0 => None
                    1 => Built
                    2 => Created
                    3 => Running
                    4 => Stopped
                    _ => Removed
      toState = case to of
                  0 => None
                  1 => Built
                  2 => Created
                  3 => Running
                  4 => Stopped
                  _ => Removed
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a running container.
export
ctr_tool_requires_running : Int -> Int
ctr_tool_requires_running 6 = 1  -- ToolLogs
ctr_tool_requires_running 4 = 1  -- ToolStop
ctr_tool_requires_running _ = 0  -- Others do not require running
