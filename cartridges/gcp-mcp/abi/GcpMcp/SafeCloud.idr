-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GcpMcp.SafeCloud — Type-safe ABI for gcp-mcp cartridge.
--
-- Dependent-type state machine governing Google Cloud Platform API access.
-- Encodes service account / OAuth2 auth flow, multi-service routing
-- (Compute, Storage, Functions, Pub/Sub, BigQuery, IAM), and quota
-- back-pressure as compile-time invariants. No unsafe escape hatches.

module GcpMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for GCP MCP operations.
||| Unauthenticated: no credentials loaded.
||| Authenticated: service account JSON key or OAuth2 token active.
||| RateLimited: GCP quota exceeded; must wait before retry.
||| Error: unrecoverable error (invalid credentials, permission denied, etc.).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Only these six edges are permitted in the session lifecycle.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate   : ValidTransition Unauthenticated Authenticated
  Deauthenticate : ValidTransition Authenticated Unauthenticated
  Throttle       : ValidTransition Authenticated RateLimited
  Unthrottle     : ValidTransition RateLimited Authenticated
  AuthError      : ValidTransition Authenticated Error
  Recover        : ValidTransition Error Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for the Zig FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
gcp_mcp_can_transition : Int -> Int -> Int
gcp_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- GCP service routing
-- ---------------------------------------------------------------------------

||| GCP services accessible through this cartridge.
public export
data GcpService
  = Compute
  | Storage
  | Functions
  | PubSub
  | BigQuery
  | IAM

||| Map service to its googleapis.com endpoint prefix.
export
serviceEndpoint : GcpService -> String
serviceEndpoint Compute   = "compute.googleapis.com"
serviceEndpoint Storage   = "storage.googleapis.com"
serviceEndpoint Functions = "cloudfunctions.googleapis.com"
serviceEndpoint PubSub    = "pubsub.googleapis.com"
serviceEndpoint BigQuery  = "bigquery.googleapis.com"
serviceEndpoint IAM       = "iam.googleapis.com"

||| Encode service as C-compatible integer for FFI.
export
serviceToInt : GcpService -> Int
serviceToInt Compute   = 0
serviceToInt Storage   = 1
serviceToInt Functions = 2
serviceToInt PubSub    = 3
serviceToInt BigQuery  = 4
serviceToInt IAM       = 5

||| Decode integer to GCP service.
export
intToService : Int -> Maybe GcpService
intToService 0 = Just Compute
intToService 1 = Just Storage
intToService 2 = Just Functions
intToService 3 = Just PubSub
intToService 4 = Just BigQuery
intToService 5 = Just IAM
intToService _ = Nothing

-- ---------------------------------------------------------------------------
-- GCP actions
-- ---------------------------------------------------------------------------

||| Actions available through the GCP MCP cartridge.
||| Grouped by service: Compute (instances), Storage (buckets/objects),
||| Functions (cloud functions), Pub/Sub (topics/subscriptions),
||| BigQuery (datasets/queries), IAM (policies).
public export
data GcpAction
  = ListProjects
  | ListInstances
  | StartInstance
  | StopInstance
  | ListBuckets
  | GetObject
  | PutObject
  | ListFunctions
  | InvokeFunction
  | ListPubSubTopics
  | PublishMessage
  | ListSubscriptions
  | RunQuery
  | ListDatasets
  | CreateDataset
  | GetIamPolicy

||| Which service handles a given action.
export
actionService : GcpAction -> GcpService
actionService ListProjects      = Compute
actionService ListInstances     = Compute
actionService StartInstance     = Compute
actionService StopInstance      = Compute
actionService ListBuckets       = Storage
actionService GetObject         = Storage
actionService PutObject         = Storage
actionService ListFunctions     = Functions
actionService InvokeFunction    = Functions
actionService ListPubSubTopics  = PubSub
actionService PublishMessage    = PubSub
actionService ListSubscriptions = PubSub
actionService RunQuery          = BigQuery
actionService ListDatasets      = BigQuery
actionService CreateDataset     = BigQuery
actionService GetIamPolicy      = IAM

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GcpAction -> Int
actionToInt ListProjects      = 0
actionToInt ListInstances     = 1
actionToInt StartInstance     = 2
actionToInt StopInstance      = 3
actionToInt ListBuckets       = 4
actionToInt GetObject         = 5
actionToInt PutObject         = 6
actionToInt ListFunctions     = 7
actionToInt InvokeFunction    = 8
actionToInt ListPubSubTopics  = 9
actionToInt PublishMessage    = 10
actionToInt ListSubscriptions = 11
actionToInt RunQuery          = 12
actionToInt ListDatasets      = 13
actionToInt CreateDataset     = 14
actionToInt GetIamPolicy      = 15

||| Decode integer to GCP action.
export
intToAction : Int -> Maybe GcpAction
intToAction 0  = Just ListProjects
intToAction 1  = Just ListInstances
intToAction 2  = Just StartInstance
intToAction 3  = Just StopInstance
intToAction 4  = Just ListBuckets
intToAction 5  = Just GetObject
intToAction 6  = Just PutObject
intToAction 7  = Just ListFunctions
intToAction 8  = Just InvokeFunction
intToAction 9  = Just ListPubSubTopics
intToAction 10 = Just PublishMessage
intToAction 11 = Just ListSubscriptions
intToAction 12 = Just RunQuery
intToAction 13 = Just ListDatasets
intToAction 14 = Just CreateDataset
intToAction 15 = Just GetIamPolicy
intToAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All GCP actions require authentication.
export
actionRequiresAuth : GcpAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : GcpAction -> Bool
actionIsMutating StartInstance  = True
actionIsMutating StopInstance   = True
actionIsMutating PutObject      = True
actionIsMutating InvokeFunction = True
actionIsMutating PublishMessage = True
actionIsMutating CreateDataset  = True
actionIsMutating _              = False

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolAuthenticate
  | ToolDeauthenticate
  | ToolStatus
  | ToolInvoke
  | ToolListServices
  | ToolListActions

||| Check if a tool requires an authenticated session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolAuthenticate   = False
toolRequiresSession ToolDeauthenticate = True
toolRequiresSession ToolStatus         = False
toolRequiresSession ToolInvoke         = True
toolRequiresSession ToolListServices   = False
toolRequiresSession ToolListActions    = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 6

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 16

||| Total service count for this cartridge.
export
serviceCount : Nat
serviceCount = 6
