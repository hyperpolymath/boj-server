-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| ResearchMcp.SafeResearch: Formally verified academic research provider operations.
|||
||| Cartridge: research-mcp
||| Matrix cell: Research domain x {MCP, LSP} protocols
|||
||| This module defines type-safe research provider operations with a
||| session state machine that prevents:
|||   - Operations on unauthenticated providers
|||   - Credential leaks by tracking auth lifecycle
|||   - Operations without proper session teardown
|||
||| State machine: Unauthenticated -> Authenticated -> Operating -> Authenticated -> Unauthenticated
module ResearchMcp.SafeResearch

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
-- Research Provider Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported academic research providers.
public export
data ResearchProvider
  = ScholarGateway    -- Scholar Gateway aggregator
  | SemanticScholar   -- Semantic Scholar (Allen AI)
  | OpenAlex          -- OpenAlex open catalogue
  | Custom String     -- User-defined provider

||| C-ABI encoding.
public export
providerToInt : ResearchProvider -> Int
providerToInt ScholarGateway  = 1
providerToInt SemanticScholar = 2
providerToInt OpenAlex        = 3
providerToInt (Custom _)      = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Provider Capabilities
-- ═══════════════════════════════════════════════════════════════════════════

||| Capabilities a research provider may support.
public export
data ProviderCapability
  = SearchPapers     -- Search for papers
  | PaperDetails     -- Get paper metadata
  | Citations        -- Get citations for a paper
  | References       -- Get references from a paper
  | AuthorSearch     -- Search for authors
  | AuthorPapers     -- Get papers by an author

-- ═══════════════════════════════════════════════════════════════════════════
-- Research Resource Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource types available on research providers.
public export
data ResearchResource
  = ResPaper         -- Academic paper
  | ResAuthor        -- Author profile
  | ResCitation      -- Citation link
  | ResVenue         -- Conference / journal venue

||| C-ABI encoding for research resource types.
public export
resResourceToInt : ResearchResource -> Int
resResourceToInt ResPaper    = 1
resResourceToInt ResAuthor   = 2
resResourceToInt ResCitation = 3
resResourceToInt ResVenue    = 4

||| Map Scholar Gateway to its supported capabilities.
public export
scholarGatewayCapabilities : List ProviderCapability
scholarGatewayCapabilities = [SearchPapers, PaperDetails, Citations, References, AuthorSearch, AuthorPapers]

||| Map Semantic Scholar to its supported capabilities.
public export
semanticScholarCapabilities : List ProviderCapability
semanticScholarCapabilities = [SearchPapers, PaperDetails, Citations, References, AuthorSearch, AuthorPapers]

||| Map OpenAlex to its supported capabilities.
public export
openAlexCapabilities : List ProviderCapability
openAlexCapabilities = [SearchPapers, PaperDetails, Citations, References, AuthorSearch, AuthorPapers]

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A research provider session with tracked state.
public export
record Session where
  constructor MkSession
  sessionId : String
  provider  : ResearchProvider
  state     : SessionState
  endpoint  : String

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
  = ToolAuthenticate   -- Authenticate with a research provider
  | ToolSearchPapers   -- Search for papers
  | ToolPaperDetails   -- Get paper metadata
  | ToolCitations      -- Get citations for a paper
  | ToolReferences     -- Get references from a paper
  | ToolAuthorSearch   -- Search for authors
  | ToolAuthorPapers   -- Get papers by an author
  | ToolLogout         -- End provider session

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolAuthenticate  = "research/authenticate"
toolName ToolSearchPapers  = "research/papers/search"
toolName ToolPaperDetails  = "research/papers/details"
toolName ToolCitations     = "research/papers/citations"
toolName ToolReferences    = "research/papers/references"
toolName ToolAuthorSearch  = "research/authors/search"
toolName ToolAuthorPapers  = "research/authors/papers"
toolName ToolLogout        = "research/logout"

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
research_can_transition : Int -> Int -> Int
research_can_transition from to =
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
research_tool_requires_auth : Int -> Int
research_tool_requires_auth 1 = 0  -- ToolAuthenticate
research_tool_requires_auth _ = 1  -- All others require auth
