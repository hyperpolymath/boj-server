-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| UmsMcp.SafeUms: Formally verified level lifecycle operations for IDApTIK
||| Level Architect (UMS — Universal Map System).
|||
||| Cartridge: ums-mcp
||| Matrix cell: Cloud domain x {MCP, REST} protocols
|||
||| This module defines type-safe level architect operations with a
||| session state machine that prevents:
|||   - Level operations without an open project
|||   - Saves without prior validation
|||   - Validation on unloaded levels
|||   - Project deletion while a level is loaded
|||
||| State machine:
|||   Idle -> ProjectOpen -> LevelLoaded -> Validating -> Valid | Invalid
|||   Valid -> Saved
|||   Any -> Idle (close project)
module UmsMcp.SafeUms

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Session State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| UMS session lifecycle states.
||| A session progresses: Idle -> ProjectOpen -> LevelLoaded -> Validating -> Valid/Invalid
||| Valid -> Saved.  Any state can transition back to Idle (close project).
public export
data UmsState
  = Idle          -- No project open
  | ProjectOpen   -- Project loaded, no level selected
  | LevelLoaded   -- A level is loaded into the editor
  | Validating    -- ABI validation in progress
  | Valid         -- Level passed ABI validation
  | Invalid       -- Level failed ABI validation
  | Saved         -- Level saved to disk after validation

||| Equality for UMS states.
public export
Eq UmsState where
  Idle        == Idle        = True
  ProjectOpen == ProjectOpen = True
  LevelLoaded == LevelLoaded = True
  Validating  == Validating  = True
  Valid       == Valid       = True
  Invalid     == Invalid     = True
  Saved       == Saved       = True
  _           == _           = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : UmsState -> UmsState -> Type where
  OpenProject     : ValidTransition Idle ProjectOpen
  LoadLevel       : ValidTransition ProjectOpen LevelLoaded
  BeginValidation : ValidTransition LevelLoaded Validating
  PassValidation  : ValidTransition Validating Valid
  FailValidation  : ValidTransition Validating Invalid
  SaveLevel       : ValidTransition Valid Saved
  ReloadAfterSave : ValidTransition Saved LevelLoaded
  ReloadInvalid   : ValidTransition Invalid LevelLoaded
  UnloadLevel     : ValidTransition LevelLoaded ProjectOpen
  CloseProject    : ValidTransition ProjectOpen Idle
  -- Emergency close from any loaded state
  ForceCloseLoad  : ValidTransition LevelLoaded Idle
  ForceCloseValid : ValidTransition Validating Idle
  ForceCloseOk    : ValidTransition Valid Idle
  ForceCloseFail  : ValidTransition Invalid Idle
  ForceCloseSaved : ValidTransition Saved Idle

||| Runtime transition validator.
public export
canTransition : UmsState -> UmsState -> Bool
canTransition Idle        ProjectOpen = True
canTransition ProjectOpen LevelLoaded = True
canTransition LevelLoaded Validating  = True
canTransition Validating  Valid       = True
canTransition Validating  Invalid     = True
canTransition Valid       Saved       = True
canTransition Saved       LevelLoaded = True
canTransition Invalid     LevelLoaded = True
canTransition LevelLoaded ProjectOpen = True
canTransition ProjectOpen Idle        = True
-- Force close from any loaded state
canTransition LevelLoaded Idle        = True
canTransition Validating  Idle        = True
canTransition Valid       Idle        = True
canTransition Invalid     Idle        = True
canTransition Saved       Idle        = True
canTransition _           _           = False

-- ═══════════════════════════════════════════════════════════════════════════
-- UMS Resource Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Resources managed by UMS.
public export
data UmsResource
  = UmsProject    -- A level-architect project (contains levels)
  | UmsLevel      -- A single level within a project
  | UmsTemplate   -- A reusable level template
  | UmsConfig     -- Level configuration / export data

||| C-ABI encoding for UMS resource types.
public export
umsResourceToInt : UmsResource -> Int
umsResourceToInt UmsProject  = 1
umsResourceToInt UmsLevel    = 2
umsResourceToInt UmsTemplate = 3
umsResourceToInt UmsConfig   = 4

-- ═══════════════════════════════════════════════════════════════════════════
-- Validation Result
-- ═══════════════════════════════════════════════════════════════════════════

||| ABI validation result detail.
public export
data ValidationSeverity = VError | VWarning | VInfo

||| C-ABI encoding for validation severity.
public export
severityToInt : ValidationSeverity -> Int
severityToInt VError   = 0
severityToInt VWarning = 1
severityToInt VInfo    = 2

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A UMS session with tracked state.
public export
record UmsSession where
  constructor MkUmsSession
  sessionId   : String
  state       : UmsState
  projectName : String
  levelName   : String

||| Proof that a session has a project open (ready for level operations).
public export
data HasProject : UmsSession -> Type where
  ActiveProject : (s : UmsSession) ->
                  (state s = ProjectOpen) ->
                  HasProject s

||| Proof that a session has a level loaded (ready for validation).
public export
data HasLevel : UmsSession -> Type where
  ActiveLevel : (s : UmsSession) ->
                (state s = LevelLoaded) ->
                HasLevel s

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to the 10 MCP tools that AI agents can call.
public export
data McpTool
  = ToolLoadLevel            -- Load a level into the editor
  | ToolSaveLevel            -- Save level (requires Valid state)
  | ToolValidateLevelAbi     -- Run Idris2 ABI validation on level data
  | ToolListLevels           -- List levels in current project
  | ToolExportLevelConfig    -- Export level configuration
  | ToolCreateProject        -- Create a new project
  | ToolOpenProject          -- Open an existing project
  | ToolDeleteProject        -- Delete a project (requires Idle or ProjectOpen)
  | ToolLoadTemplates        -- Load available templates
  | ToolInstantiateTemplate  -- Create a level from a template

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolLoadLevel           = "ums/load_level"
toolName ToolSaveLevel           = "ums/save_level"
toolName ToolValidateLevelAbi    = "ums/validate_level_abi"
toolName ToolListLevels          = "ums/list_levels"
toolName ToolExportLevelConfig   = "ums/export_level_config"
toolName ToolCreateProject       = "ums/create_project"
toolName ToolOpenProject         = "ums/open_project"
toolName ToolDeleteProject       = "ums/delete_project"
toolName ToolLoadTemplates       = "ums/load_templates"
toolName ToolInstantiateTemplate = "ums/instantiate_template"

||| Which tools require a project to be open.
public export
requiresProject : McpTool -> Bool
requiresProject ToolCreateProject = False
requiresProject ToolOpenProject   = False
requiresProject ToolDeleteProject = False
requiresProject ToolLoadTemplates = False
requiresProject _                 = True

||| Which tools require a level to be loaded.
public export
requiresLevel : McpTool -> Bool
requiresLevel ToolSaveLevel        = True
requiresLevel ToolValidateLevelAbi = True
requiresLevel ToolExportLevelConfig = True
requiresLevel _                    = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Session state to integer.
public export
umsStateToInt : UmsState -> Int
umsStateToInt Idle        = 0
umsStateToInt ProjectOpen = 1
umsStateToInt LevelLoaded = 2
umsStateToInt Validating  = 3
umsStateToInt Valid       = 4
umsStateToInt Invalid     = 5
umsStateToInt Saved       = 6

||| Integer to session state.
public export
intToUmsState : Int -> UmsState
intToUmsState 0 = Idle
intToUmsState 1 = ProjectOpen
intToUmsState 2 = LevelLoaded
intToUmsState 3 = Validating
intToUmsState 4 = Valid
intToUmsState 5 = Invalid
intToUmsState 6 = Saved
intToUmsState _ = Idle

||| FFI: Validate a state transition.
export
ums_can_transition : Int -> Int -> Int
ums_can_transition from to =
  if canTransition (intToUmsState from) (intToUmsState to) then 1 else 0

||| FFI: Check if a tool requires a project.
export
ums_tool_requires_project : Int -> Int
ums_tool_requires_project 5 = 0  -- ToolCreateProject
ums_tool_requires_project 6 = 0  -- ToolOpenProject
ums_tool_requires_project 7 = 0  -- ToolDeleteProject
ums_tool_requires_project 8 = 0  -- ToolLoadTemplates
ums_tool_requires_project _ = 1  -- All others require project

||| FFI: Check if a tool requires a level.
export
ums_tool_requires_level : Int -> Int
ums_tool_requires_level 1 = 1  -- ToolSaveLevel
ums_tool_requires_level 2 = 1  -- ToolValidateLevelAbi
ums_tool_requires_level 4 = 1  -- ToolExportLevelConfig
ums_tool_requires_level _ = 0
