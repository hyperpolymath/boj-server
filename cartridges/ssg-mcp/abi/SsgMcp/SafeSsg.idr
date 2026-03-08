-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| SsgMcp.SafeSsg: Formally verified static site generation operations.
|||
||| Cartridge: ssg-mcp
||| Matrix cell: SSG domain x {MCP, LSP} protocols
|||
||| This module defines a build pipeline state machine that prevents:
|||   - Deploying unbuilt sites
|||   - Skipping preview before deployment
|||   - Previewing without a successful build
|||
||| State machine: Empty -> ContentLoaded -> Built -> Previewing -> ReadyToDeploy -> Deployed
module SsgMcp.SafeSsg

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- SSG State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| SSG site lifecycle states.
||| A site progresses: Empty -> ContentLoaded -> Built -> Previewing -> ReadyToDeploy -> Deployed
public export
data SsgState = Empty | ContentLoaded | Built | Previewing | ReadyToDeploy | Deployed | SsgError

||| Equality for SSG states.
public export
Eq SsgState where
  Empty          == Empty          = True
  ContentLoaded  == ContentLoaded  = True
  Built          == Built          = True
  Previewing     == Previewing     = True
  ReadyToDeploy  == ReadyToDeploy  = True
  Deployed       == Deployed       = True
  SsgError       == SsgError       = True
  _              == _              = False

||| Valid state transitions (enforced at the type level).
||| Critically, ContentLoaded -> Previewing is NOT valid (must build first).
||| And Built -> Deployed is NOT valid (must preview first).
public export
data ValidTransition : SsgState -> SsgState -> Type where
  LoadContent   : ValidTransition Empty ContentLoaded
  Build         : ValidTransition ContentLoaded Built
  Rebuild       : ValidTransition Built Built
  StartPreview  : ValidTransition Built Previewing
  EndPreview    : ValidTransition Previewing ReadyToDeploy
  Deploy        : ValidTransition ReadyToDeploy Deployed
  Clean         : ValidTransition Deployed Empty
  CleanReady    : ValidTransition ReadyToDeploy Empty
  BuildError    : ValidTransition ContentLoaded SsgError
  DeployError   : ValidTransition ReadyToDeploy SsgError
  Recover       : ValidTransition SsgError Empty

||| Runtime transition validator.
public export
canTransition : SsgState -> SsgState -> Bool
canTransition Empty          ContentLoaded  = True
canTransition ContentLoaded  Built          = True
canTransition Built          Built          = True   -- rebuild
canTransition Built          Previewing     = True
canTransition Previewing     ReadyToDeploy  = True
canTransition ReadyToDeploy  Deployed       = True
canTransition Deployed       Empty          = True   -- clean
canTransition ReadyToDeploy  Empty          = True   -- clean without deploying
canTransition ContentLoaded  SsgError       = True   -- build error
canTransition ReadyToDeploy  SsgError       = True   -- deploy error
canTransition SsgError       Empty          = True   -- recover
canTransition _              _              = False

-- ═══════════════════════════════════════════════════════════════════════════
-- SSG Engine Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported SSG engines.
public export
data SsgEngine
  = Hugo          -- Hugo static site generator
  | Zola          -- Zola (Rust-based SSG)
  | Astro         -- Astro framework
  | Casket        -- Casket (hyperpolymath SSG)
  | Custom String -- User-defined engine

||| C-ABI encoding.
public export
engineToInt : SsgEngine -> Int
engineToInt Hugo        = 1
engineToInt Zola        = 2
engineToInt Astro       = 3
engineToInt Casket      = 4
engineToInt (Custom _)  = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolLoadContent      -- Load content into the site
  | ToolBuild            -- Build the static site
  | ToolPreview          -- Start a local preview server
  | ToolDeploy           -- Deploy to production
  | ToolClean            -- Clean build artifacts and reset
  | ToolStatus           -- Site pipeline health check
  | ToolListTemplates    -- List available templates
  | ToolValidateContent  -- Validate content files (frontmatter, links)

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolLoadContent     = "ssg/load"
toolName ToolBuild           = "ssg/build"
toolName ToolPreview         = "ssg/preview"
toolName ToolDeploy          = "ssg/deploy"
toolName ToolClean           = "ssg/clean"
toolName ToolStatus          = "ssg/status"
toolName ToolListTemplates   = "ssg/templates"
toolName ToolValidateContent = "ssg/validate"

||| Which tools require a successful build.
public export
toolRequiresBuild : McpTool -> Bool
toolRequiresBuild ToolPreview = True
toolRequiresBuild ToolDeploy  = True
toolRequiresBuild _           = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| SSG state to integer.
public export
ssgStateToInt : SsgState -> Int
ssgStateToInt Empty          = 0
ssgStateToInt ContentLoaded  = 1
ssgStateToInt Built          = 2
ssgStateToInt Previewing     = 3
ssgStateToInt ReadyToDeploy  = 4
ssgStateToInt Deployed       = 5
ssgStateToInt SsgError       = 6

||| FFI: Validate a state transition.
export
ssg_can_transition : Int -> Int -> Int
ssg_can_transition from to =
  let fromState = case from of
                    0 => Empty
                    1 => ContentLoaded
                    2 => Built
                    3 => Previewing
                    4 => ReadyToDeploy
                    5 => Deployed
                    _ => SsgError
      toState = case to of
                  0 => Empty
                  1 => ContentLoaded
                  2 => Built
                  3 => Previewing
                  4 => ReadyToDeploy
                  5 => Deployed
                  _ => SsgError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a successful build.
export
ssg_tool_requires_build : Int -> Int
ssg_tool_requires_build 3 = 1  -- ToolPreview
ssg_tool_requires_build 4 = 1  -- ToolDeploy
ssg_tool_requires_build _ = 0  -- All others do not require a build
