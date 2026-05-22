-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- NotionMcp.SafeComms — Type-safe ABI for the Notion REST API cartridge.
--
-- Dependent-type state machine governing Notion connection lifecycle.
-- All transitions proven valid at compile time. Zero unsafe escape hatches.

module NotionMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection lifecycle states for Notion API interactions.
||| Models the full lifecycle: authentication via integration token,
||| connected operation against https://api.notion.com/v1/, rate limiting
||| (Notion enforces 3 requests/second), and error recovery.
public export
data ConnState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

-- ---------------------------------------------------------------------------
-- Valid state transitions (proven at the type level)
-- ---------------------------------------------------------------------------

||| Proof witness that a state transition is permitted.
||| Only the transitions enumerated here can ever occur at the FFI boundary.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  ||| Authenticate with a Notion integration token (Bearer).
  Authenticate   : ValidTransition Unauthenticated Authenticated
  ||| Hit a Notion rate limit (3 req/s budget exhausted).
  HitRateLimit   : ValidTransition Authenticated RateLimited
  ||| Rate limit window expired — resume operations.
  RateRecovered  : ValidTransition RateLimited Authenticated
  ||| Operational error while authenticated (network, API fault).
  AuthError      : ValidTransition Authenticated Error
  ||| Rate-limited session encounters an unrecoverable error.
  RateLimitError : ValidTransition RateLimited Error
  ||| Error recovery — return to unauthenticated for re-auth.
  ErrorReset     : ValidTransition Error Unauthenticated
  ||| Graceful disconnect from an authenticated session.
  GracefulClose  : ValidTransition Authenticated Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for ConnState
-- ---------------------------------------------------------------------------

||| Encode connection state as a C-compatible integer.
||| Mapping: Unauthenticated=0, Authenticated=1, RateLimited=2, Error=3.
export
connStateToInt : ConnState -> Int
connStateToInt Unauthenticated = 0
connStateToInt Authenticated   = 1
connStateToInt RateLimited     = 2
connStateToInt Error           = 3

||| Decode a C integer back to a connection state.
||| Returns Nothing for out-of-range values.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Unauthenticated
intToConnState 1 = Just Authenticated
intToConnState 2 = Just RateLimited
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| C-ABI export: check whether a state transition is valid.
||| Returns 1 for valid, 0 for invalid. Used by the Zig FFI layer.
export
notion_mcp_can_transition : Int -> Int -> Int
notion_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just RateLimited,     Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Notion action vocabulary
-- ---------------------------------------------------------------------------

||| All actions supported by the notion-mcp cartridge.
||| Each maps to a Notion REST API endpoint under
||| https://api.notion.com/v1/.
public export
data NotionAction
  = SearchPages          -- POST /search
  | GetPage              -- GET /pages/{page_id}
  | CreatePage           -- POST /pages
  | UpdatePage           -- PATCH /pages/{page_id}
  | DeletePage           -- PATCH /pages/{page_id} (archived=true)
  | GetDatabase          -- GET /databases/{database_id}
  | QueryDatabase        -- POST /databases/{database_id}/query
  | CreateDatabase       -- POST /databases
  | ListBlocks           -- GET /blocks/{block_id}/children
  | GetBlock             -- GET /blocks/{block_id}
  | AppendBlocks         -- PATCH /blocks/{block_id}/children
  | DeleteBlock          -- DELETE /blocks/{block_id}
  | ListUsers            -- GET /users
  | GetUser              -- GET /users/{user_id}
  | CreateComment        -- POST /comments
  | ListComments         -- GET /comments?block_id={block_id}

||| Encode a NotionAction as a C integer for FFI.
export
notionActionToInt : NotionAction -> Int
notionActionToInt SearchPages    = 0
notionActionToInt GetPage        = 1
notionActionToInt CreatePage     = 2
notionActionToInt UpdatePage     = 3
notionActionToInt DeletePage     = 4
notionActionToInt GetDatabase    = 5
notionActionToInt QueryDatabase  = 6
notionActionToInt CreateDatabase = 7
notionActionToInt ListBlocks     = 8
notionActionToInt GetBlock       = 9
notionActionToInt AppendBlocks   = 10
notionActionToInt DeleteBlock    = 11
notionActionToInt ListUsers      = 12
notionActionToInt GetUser        = 13
notionActionToInt CreateComment  = 14
notionActionToInt ListComments   = 15

||| Decode a C integer back to a NotionAction.
export
intToNotionAction : Int -> Maybe NotionAction
intToNotionAction 0  = Just SearchPages
intToNotionAction 1  = Just GetPage
intToNotionAction 2  = Just CreatePage
intToNotionAction 3  = Just UpdatePage
intToNotionAction 4  = Just DeletePage
intToNotionAction 5  = Just GetDatabase
intToNotionAction 6  = Just QueryDatabase
intToNotionAction 7  = Just CreateDatabase
intToNotionAction 8  = Just ListBlocks
intToNotionAction 9  = Just GetBlock
intToNotionAction 10 = Just AppendBlocks
intToNotionAction 11 = Just DeleteBlock
intToNotionAction 12 = Just ListUsers
intToNotionAction 13 = Just GetUser
intToNotionAction 14 = Just CreateComment
intToNotionAction 15 = Just ListComments
intToNotionAction _  = Nothing

||| Total action count exposed via C-ABI.
export
notion_mcp_action_count : Int
notion_mcp_action_count = 16

-- ---------------------------------------------------------------------------
-- HTTP method classification
-- ---------------------------------------------------------------------------

||| HTTP methods used by Notion REST API endpoints.
public export
data HttpMethod = GET | POST | PATCH | DELETE

||| Map each action to its HTTP method.
export
actionHttpMethod : NotionAction -> HttpMethod
actionHttpMethod SearchPages    = POST
actionHttpMethod GetPage        = GET
actionHttpMethod CreatePage     = POST
actionHttpMethod UpdatePage     = PATCH
actionHttpMethod DeletePage     = PATCH   -- uses archived=true
actionHttpMethod GetDatabase    = GET
actionHttpMethod QueryDatabase  = POST
actionHttpMethod CreateDatabase = POST
actionHttpMethod ListBlocks     = GET
actionHttpMethod GetBlock       = GET
actionHttpMethod AppendBlocks   = PATCH
actionHttpMethod DeleteBlock    = DELETE
actionHttpMethod ListUsers      = GET
actionHttpMethod GetUser        = GET
actionHttpMethod CreateComment  = POST
actionHttpMethod ListComments   = GET

||| C-ABI export: check if an action requires an authenticated state.
||| All Notion actions require authentication.
export
notion_mcp_action_requires_auth : Int -> Int
notion_mcp_action_requires_auth actionId =
  case intToNotionAction actionId of
    Just _  => 1  -- all actions require Authenticated state
    Nothing => 0  -- unknown action

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via the MCP protocol by this cartridge.
public export
data McpTool
  = ToolConnect
  | ToolDisconnect
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires an authenticated session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolConnect    = False
toolRequiresSession ToolDisconnect = True
toolRequiresSession ToolStatus     = False
toolRequiresSession ToolInvoke     = True
toolRequiresSession ToolList       = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
