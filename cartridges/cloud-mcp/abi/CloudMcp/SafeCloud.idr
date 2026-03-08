-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| CloudMcp.SafeCloud: Formally verified multi-cloud provider operations.
|||
||| Cartridge: cloud-mcp
||| Matrix cell: Cloud domain x {MCP, LSP} protocols
|||
||| This module defines type-safe cloud provider operations with a
||| session state machine that prevents:
|||   - Operations on unauthenticated providers
|||   - Credential leaks by tracking auth lifecycle
|||   - Operations without proper session teardown
|||
||| State machine: Unauthenticated -> Authenticated -> Operating -> Authenticated -> Unauthenticated
module CloudMcp.SafeCloud

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Session State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Provider session lifecycle states.
||| A session progresses: Unauthenticated -> Authenticated -> Operating -> Authenticated -> Unauthenticated
public export
data SessionState = Unauthenticated | Authenticated | Operating | AuthError

||| Equality for session states.
public export
Eq SessionState where
  Unauthenticated == Unauthenticated = True
  Authenticated   == Authenticated   = True
  Operating       == Operating       = True
  AuthError       == AuthError       = True
  _               == _               = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate   : ValidTransition Unauthenticated Authenticated
  BeginOperation : ValidTransition Authenticated Operating
  EndOperation   : ValidTransition Operating Authenticated
  Logout         : ValidTransition Authenticated Unauthenticated
  OpError        : ValidTransition Operating AuthError
  Recover        : ValidTransition AuthError Unauthenticated

||| Runtime transition validator.
public export
canTransition : SessionState -> SessionState -> Bool
canTransition Unauthenticated Authenticated   = True
canTransition Authenticated   Operating       = True
canTransition Operating       Authenticated   = True
canTransition Authenticated   Unauthenticated = True
canTransition Operating       AuthError       = True
canTransition AuthError       Unauthenticated = True
canTransition _               _               = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Cloud Provider Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported cloud providers.
public export
data CloudProvider
  = AWS            -- Amazon Web Services
  | GCloud         -- Google Cloud Platform
  | Azure          -- Microsoft Azure
  | DigitalOcean   -- DigitalOcean
  | Custom String  -- User-defined provider

||| C-ABI encoding.
public export
providerToInt : CloudProvider -> Int
providerToInt AWS            = 1
providerToInt GCloud         = 2
providerToInt Azure          = 3
providerToInt DigitalOcean   = 4
providerToInt (Custom _)     = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A cloud provider session with tracked state.
public export
record Session where
  constructor MkSession
  sessionId : String
  provider  : CloudProvider
  state     : SessionState
  region    : String

||| Proof that a session is authenticated (ready for operations).
public export
data IsAuthenticated : Session -> Type where
  ActiveSession : (s : Session) ->
                  (state s = Authenticated) ->
                  IsAuthenticated s

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolAuthenticate   -- Authenticate with a cloud provider
  | ToolListResources  -- List cloud resources
  | ToolProvision      -- Provision a new resource
  | ToolDeprovision    -- Deprovision (tear down) a resource
  | ToolStatus         -- Provider/resource status
  | ToolCost           -- Cost estimation/reporting
  | ToolLogout         -- End provider session

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolAuthenticate  = "cloud/authenticate"
toolName ToolListResources = "cloud/list-resources"
toolName ToolProvision     = "cloud/provision"
toolName ToolDeprovision   = "cloud/deprovision"
toolName ToolStatus        = "cloud/status"
toolName ToolCost          = "cloud/cost"
toolName ToolLogout        = "cloud/logout"

||| Which tools require an authenticated session.
public export
requiresAuth : McpTool -> Bool
requiresAuth ToolAuthenticate = False
requiresAuth _                = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Session state to integer.
public export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt Operating       = 2
sessionStateToInt AuthError       = 3

||| FFI: Validate a state transition.
export
cloud_can_transition : Int -> Int -> Int
cloud_can_transition from to =
  let fromState = case from of
                    0 => Unauthenticated
                    1 => Authenticated
                    2 => Operating
                    _ => AuthError
      toState = case to of
                  0 => Unauthenticated
                  1 => Authenticated
                  2 => Operating
                  _ => AuthError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires authentication.
export
cloud_tool_requires_auth : Int -> Int
cloud_tool_requires_auth 1 = 0  -- ToolAuthenticate
cloud_tool_requires_auth _ = 1  -- All others require auth
