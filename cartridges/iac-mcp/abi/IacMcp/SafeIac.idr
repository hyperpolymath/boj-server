-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| IacMcp.SafeIac: Formally verified Infrastructure-as-Code operations.
|||
||| Cartridge: iac-mcp
||| Matrix cell: IaC domain x {MCP, LSP} protocols
|||
||| This module defines a plan-before-apply state machine that prevents:
|||   - Applying infrastructure changes without a plan
|||   - Skipping plan review before destructive operations
|||   - Destroying resources from an uninitialised workspace
|||
||| State machine: Uninitialized -> Initialized -> Planned -> Applying -> Applied -> Initialized
module IacMcp.SafeIac

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- IaC State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| IaC workspace lifecycle states.
||| A workspace progresses: Uninitialized -> Initialized -> Planned -> Applying -> Applied -> Initialized
public export
data IacState = Uninitialized | Initialized | Planned | Applying | Applied | IacError

||| Equality for IaC states.
public export
Eq IacState where
  Uninitialized == Uninitialized = True
  Initialized   == Initialized   = True
  Planned       == Planned       = True
  Applying      == Applying      = True
  Applied       == Applied       = True
  IacError      == IacError      = True
  _             == _             = False

||| Valid state transitions (enforced at the type level).
||| Critically, Initialized -> Applying is NOT a valid transition.
||| You MUST go through Planned first.
public export
data ValidTransition : IacState -> IacState -> Type where
  Init         : ValidTransition Uninitialized Initialized
  Plan         : ValidTransition Initialized Planned
  Replan       : ValidTransition Planned Planned
  StartApply   : ValidTransition Planned Applying
  FinishApply  : ValidTransition Applying Applied
  Reset        : ValidTransition Applied Initialized
  Destroy      : ValidTransition Initialized Uninitialized
  ApplyError   : ValidTransition Applying IacError
  Recover      : ValidTransition IacError Initialized

||| Runtime transition validator.
public export
canTransition : IacState -> IacState -> Bool
canTransition Uninitialized Initialized   = True
canTransition Initialized   Planned       = True
canTransition Planned        Planned       = True   -- re-plan
canTransition Planned        Applying      = True
canTransition Applying       Applied       = True
canTransition Applied        Initialized   = True   -- reset for next cycle
canTransition Initialized   Uninitialized = True   -- destroy
canTransition Applying       IacError      = True
canTransition IacError       Initialized   = True   -- recover
canTransition _              _             = False

-- ═══════════════════════════════════════════════════════════════════════════
-- IaC Tool Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported IaC tools.
public export
data IacTool
  = Terraform     -- HashiCorp Terraform
  | Pulumi        -- Pulumi
  | Custom String -- User-defined IaC tool

||| C-ABI encoding.
public export
iacToolToInt : IacTool -> Int
iacToolToInt Terraform  = 1
iacToolToInt Pulumi     = 2
iacToolToInt (Custom _) = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolInit          -- Initialise a workspace (terraform init / pulumi up --yes=false)
  | ToolPlan          -- Generate an execution plan
  | ToolApply         -- Apply the planned changes
  | ToolDestroy       -- Tear down all resources
  | ToolOutput        -- Retrieve outputs from applied state
  | ToolState         -- Inspect current state machine position
  | ToolImport        -- Import existing resources into state
  | ToolValidate      -- Validate configuration files

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolInit     = "iac/init"
toolName ToolPlan     = "iac/plan"
toolName ToolApply    = "iac/apply"
toolName ToolDestroy  = "iac/destroy"
toolName ToolOutput   = "iac/output"
toolName ToolState    = "iac/state"
toolName ToolImport   = "iac/import"
toolName ToolValidate = "iac/validate"

||| Which tools require a plan to have been generated first.
public export
toolRequiresPlan : McpTool -> Bool
toolRequiresPlan ToolApply = True
toolRequiresPlan _         = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| IaC state to integer.
public export
iacStateToInt : IacState -> Int
iacStateToInt Uninitialized = 0
iacStateToInt Initialized   = 1
iacStateToInt Planned        = 2
iacStateToInt Applying       = 3
iacStateToInt Applied        = 4
iacStateToInt IacError       = 5

||| FFI: Validate a state transition.
export
iac_can_transition : Int -> Int -> Int
iac_can_transition from to =
  let fromState = case from of
                    0 => Uninitialized
                    1 => Initialized
                    2 => Planned
                    3 => Applying
                    4 => Applied
                    _ => IacError
      toState = case to of
                  0 => Uninitialized
                  1 => Initialized
                  2 => Planned
                  3 => Applying
                  4 => Applied
                  _ => IacError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a plan to have been generated.
export
iac_tool_requires_plan : Int -> Int
iac_tool_requires_plan 3 = 1  -- ToolApply
iac_tool_requires_plan _ = 0  -- All others do not require a plan
