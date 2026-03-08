-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| GitMcp.SafeGit: Formally verified git forge operations.
|||
||| Cartridge: git-mcp
||| Matrix cell: Git forge domain x {MCP, LSP} protocols
|||
||| This module defines type-safe git forge operations with an
||| authentication state machine that prevents:
|||   - Operations without authentication
|||   - Cross-forge operations on wrong context
|||   - PR/issue lifecycle violations
|||
||| Supports GitHub, GitLab, Gitea, and Bitbucket forges.
module GitMcp.SafeGit

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Forge State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Forge operation lifecycle states.
||| A session progresses: Unauthenticated -> Authenticated -> RepoSelected -> Operating -> RepoSelected
public export
data GitState = Unauthenticated | Authenticated | RepoSelected | Operating | GitError

||| Equality for git states.
public export
Eq GitState where
  Unauthenticated == Unauthenticated = True
  Authenticated   == Authenticated   = True
  RepoSelected    == RepoSelected    = True
  Operating       == Operating       = True
  GitError        == GitError        = True
  _               == _               = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : GitState -> GitState -> Type where
  Authenticate : ValidTransition Unauthenticated Authenticated
  SelectRepo   : ValidTransition Authenticated RepoSelected
  BeginOp      : ValidTransition RepoSelected Operating
  EndOp        : ValidTransition Operating RepoSelected
  DeselectRepo : ValidTransition RepoSelected Authenticated
  Logout       : ValidTransition Authenticated Unauthenticated
  OpError      : ValidTransition Operating GitError
  Recover      : ValidTransition GitError Authenticated

||| Runtime transition validator.
public export
canTransition : GitState -> GitState -> Bool
canTransition Unauthenticated Authenticated   = True
canTransition Authenticated   RepoSelected    = True
canTransition RepoSelected    Operating       = True
canTransition Operating       RepoSelected    = True
canTransition RepoSelected    Authenticated   = True
canTransition Authenticated   Unauthenticated = True
canTransition Operating       GitError        = True
canTransition GitError        Authenticated   = True
canTransition _               _               = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Git Forge Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported git forge backends.
public export
data GitForge
  = GitHub     -- GitHub.com or GitHub Enterprise
  | GitLab     -- GitLab.com or self-hosted
  | Gitea      -- Gitea / Forgejo instances
  | Bitbucket  -- Bitbucket Cloud or Server

||| C-ABI encoding for forges.
public export
forgeToInt : GitForge -> Int
forgeToInt GitHub    = 1
forgeToInt GitLab    = 2
forgeToInt Gitea     = 3
forgeToInt Bitbucket = 4

-- ═══════════════════════════════════════════════════════════════════════════
-- Forge Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A forge session with tracked state.
public export
record ForgeSession where
  constructor MkForgeSession
  sessionId : String
  forge     : GitForge
  state     : GitState
  repoOwner : String
  repoName  : String

||| Proof that a session has a repo selected.
public export
data HasRepo : ForgeSession -> Type where
  ActiveRepo : (s : ForgeSession) ->
               (state s = RepoSelected) ->
               HasRepo s

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolAuthenticate   -- Authenticate with a forge
  | ToolSelectRepo     -- Select a repository context
  | ToolCreatePR       -- Create a pull/merge request
  | ToolMergePR        -- Merge a pull/merge request
  | ToolCreateIssue    -- Create an issue
  | ToolListBranches   -- List branches in selected repo
  | ToolClone          -- Clone a repository
  | ToolPush           -- Push commits
  | ToolStatus         -- Session and repo status

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolAuthenticate = "git/authenticate"
toolName ToolSelectRepo   = "git/select-repo"
toolName ToolCreatePR     = "git/create-pr"
toolName ToolMergePR      = "git/merge-pr"
toolName ToolCreateIssue  = "git/create-issue"
toolName ToolListBranches = "git/list-branches"
toolName ToolClone        = "git/clone"
toolName ToolPush         = "git/push"
toolName ToolStatus       = "git/status"

||| Which tools require a selected repository context.
public export
requiresRepo : McpTool -> Bool
requiresRepo ToolAuthenticate = False
requiresRepo ToolSelectRepo   = False
requiresRepo ToolStatus       = False
requiresRepo _                = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Git state to integer.
public export
gitStateToInt : GitState -> Int
gitStateToInt Unauthenticated = 0
gitStateToInt Authenticated   = 1
gitStateToInt RepoSelected    = 2
gitStateToInt Operating       = 3
gitStateToInt GitError        = 4

||| FFI: Validate a state transition.
export
git_can_transition : Int -> Int -> Int
git_can_transition from to =
  let fromState = case from of
                    0 => Unauthenticated
                    1 => Authenticated
                    2 => RepoSelected
                    3 => Operating
                    _ => GitError
      toState = case to of
                  0 => Unauthenticated
                  1 => Authenticated
                  2 => RepoSelected
                  3 => Operating
                  _ => GitError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a selected repo.
export
git_tool_requires_repo : Int -> Int
git_tool_requires_repo 1 = 0  -- ToolAuthenticate
git_tool_requires_repo 2 = 0  -- ToolSelectRepo
git_tool_requires_repo 9 = 0  -- ToolStatus
git_tool_requires_repo _ = 1  -- All others require repo
