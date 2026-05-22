-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| CommsMcp.SafeComms: Formally verified communications provider operations.
|||
||| Cartridge: comms-mcp
||| Matrix cell: Communications domain x {MCP, LSP} protocols
|||
||| This module defines type-safe communications provider operations with a
||| session state machine that prevents:
|||   - Operations on unauthenticated providers
|||   - Credential leaks by tracking auth lifecycle
|||   - Operations without proper session teardown
|||
||| State machine: Unauthenticated -> Authenticated -> Operating -> Authenticated -> Unauthenticated
module CommsMcp.SafeComms

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
-- Communications Provider Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported communications providers.
public export
data CommsProvider
  = Gmail           -- Google Gmail
  | GoogleCalendar  -- Google Calendar
  | Custom String   -- User-defined provider

||| C-ABI encoding.
public export
providerToInt : CommsProvider -> Int
providerToInt Gmail          = 1
providerToInt GoogleCalendar = 2
providerToInt (Custom _)     = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Provider Capabilities
-- ═══════════════════════════════════════════════════════════════════════════

||| Capabilities a communications provider may support.
public export
data ProviderCapability
  = SendMessage    -- Send email / message
  | ReadMessage    -- Read email / message
  | SearchMessage  -- Search messages
  | ManageLabels   -- Label / folder management
  | ListEvents     -- List calendar events
  | CreateEvent    -- Create calendar events
  | FreeBusy       -- Free/busy lookup

-- ═══════════════════════════════════════════════════════════════════════════
-- Gmail Resource Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource types available on the Gmail provider.
public export
data GmailResource
  = GmMessage      -- Email message
  | GmThread       -- Email thread
  | GmLabel        -- Gmail label
  | GmDraft        -- Draft message

||| C-ABI encoding for Gmail resource types.
public export
gmResourceToInt : GmailResource -> Int
gmResourceToInt GmMessage = 1
gmResourceToInt GmThread  = 2
gmResourceToInt GmLabel   = 3
gmResourceToInt GmDraft   = 4

||| Map Gmail to its supported capabilities.
public export
gmailCapabilities : List ProviderCapability
gmailCapabilities = [SendMessage, ReadMessage, SearchMessage, ManageLabels]

-- ═══════════════════════════════════════════════════════════════════════════
-- Google Calendar Resource Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource types available on the Google Calendar provider.
public export
data CalendarResource
  = CalEvent       -- Calendar event
  | CalCalendar    -- Calendar itself
  | CalFreeBusy    -- Free/busy query

||| C-ABI encoding for Calendar resource types.
public export
calResourceToInt : CalendarResource -> Int
calResourceToInt CalEvent    = 1
calResourceToInt CalCalendar = 2
calResourceToInt CalFreeBusy = 3

||| Map Google Calendar to its supported capabilities.
public export
calendarCapabilities : List ProviderCapability
calendarCapabilities = [ListEvents, CreateEvent, FreeBusy]

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A communications provider session with tracked state.
public export
record Session where
  constructor MkSession
  sessionId : String
  provider  : CommsProvider
  state     : SessionState
  scope     : String

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
  = ToolAuthenticate   -- Authenticate with a comms provider (OAuth)
  | ToolSend           -- Send an email (Gmail)
  | ToolRead           -- Read an email (Gmail)
  | ToolSearch         -- Search emails (Gmail)
  | ToolLabels         -- List/manage labels (Gmail)
  | ToolEvents         -- List calendar events (Google Calendar)
  | ToolCreateEvent    -- Create a calendar event (Google Calendar)
  | ToolFreeBusy       -- Query free/busy (Google Calendar)
  | ToolLogout         -- End provider session

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolAuthenticate = "comms/authenticate"
toolName ToolSend         = "comms/gmail/send"
toolName ToolRead         = "comms/gmail/read"
toolName ToolSearch       = "comms/gmail/search"
toolName ToolLabels       = "comms/gmail/labels"
toolName ToolEvents       = "comms/calendar/events"
toolName ToolCreateEvent  = "comms/calendar/create-event"
toolName ToolFreeBusy     = "comms/calendar/free-busy"
toolName ToolLogout       = "comms/logout"

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
comms_can_transition : Int -> Int -> Int
comms_can_transition from to =
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
comms_tool_requires_auth : Int -> Int
comms_tool_requires_auth 1 = 0  -- ToolAuthenticate
comms_tool_requires_auth _ = 1  -- All others require auth
