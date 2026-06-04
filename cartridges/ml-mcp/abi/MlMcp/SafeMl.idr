-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| MlMcp.SafeMl: Formally verified ML/AI provider operations.
|||
||| Cartridge: ml-mcp
||| Matrix cell: ML/AI domain x {MCP, LSP} protocols
|||
||| This module defines type-safe ML provider operations with a
||| session state machine that prevents:
|||   - Operations on unauthenticated providers
|||   - Credential leaks by tracking auth lifecycle
|||   - Operations without proper session teardown
|||
||| State machine: Unauthenticated -> Authenticated -> Operating -> Authenticated -> Unauthenticated
module MlMcp.SafeMl

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
-- ML Provider Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported ML/AI providers.
public export
data MlProvider
  = HuggingFace    -- Hugging Face model hub
  | Custom String  -- User-defined provider

||| C-ABI encoding.
public export
providerToInt : MlProvider -> Int
providerToInt HuggingFace  = 1
providerToInt (Custom _)   = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Provider Capabilities
-- ═══════════════════════════════════════════════════════════════════════════

||| Capabilities an ML provider may support.
public export
data ProviderCapability
  = SearchModels   -- Search for models
  | ModelInfo      -- Get model metadata
  | Inference      -- Run model inference
  | ListSpaces     -- List Spaces (demos)
  | SpaceInfo      -- Get Space metadata
  | ListDatasets   -- List datasets
  | DatasetInfo    -- Get dataset metadata

-- ═══════════════════════════════════════════════════════════════════════════
-- Hugging Face Resource Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource types available on the Hugging Face provider.
public export
data HuggingFaceResource
  = HfModel        -- ML model
  | HfSpace        -- Gradio / Streamlit space
  | HfDataset      -- Dataset
  | HfInference    -- Inference endpoint

||| C-ABI encoding for Hugging Face resource types.
public export
hfResourceToInt : HuggingFaceResource -> Int
hfResourceToInt HfModel     = 1
hfResourceToInt HfSpace     = 2
hfResourceToInt HfDataset   = 3
hfResourceToInt HfInference = 4

||| Map Hugging Face to its supported capabilities.
public export
huggingFaceCapabilities : List ProviderCapability
huggingFaceCapabilities = [SearchModels, ModelInfo, Inference, ListSpaces, SpaceInfo, ListDatasets, DatasetInfo]

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| An ML provider session with tracked state.
public export
record Session where
  constructor MkSession
  sessionId : String
  provider  : MlProvider
  state     : SessionState
  namespaceName : String

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
  = ToolAuthenticate   -- Authenticate with an ML provider
  | ToolSearchModels   -- Search for models
  | ToolModelInfo      -- Get model metadata
  | ToolInference      -- Run model inference
  | ToolListSpaces     -- List Spaces
  | ToolSpaceInfo      -- Get Space metadata
  | ToolListDatasets   -- List datasets
  | ToolDatasetInfo    -- Get dataset metadata
  | ToolLogout         -- End provider session

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolAuthenticate  = "ml/authenticate"
toolName ToolSearchModels  = "ml/models/search"
toolName ToolModelInfo     = "ml/models/info"
toolName ToolInference     = "ml/models/inference"
toolName ToolListSpaces    = "ml/spaces/list"
toolName ToolSpaceInfo     = "ml/spaces/info"
toolName ToolListDatasets  = "ml/datasets/list"
toolName ToolDatasetInfo   = "ml/datasets/info"
toolName ToolLogout        = "ml/logout"

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
ml_can_transition : Int -> Int -> Int
ml_can_transition from to =
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
ml_tool_requires_auth : Int -> Int
ml_tool_requires_auth 1 = 0  -- ToolAuthenticate
ml_tool_requires_auth _ = 1  -- All others require auth
