-- SPDX-License-Identifier: MPL-2.0
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
  | Firestore
  | PubSub
  | CloudRun
  | BigQuery
  | IAM

||| Map service to its googleapis.com endpoint prefix.
export
serviceEndpoint : GcpService -> String
serviceEndpoint Compute   = "compute.googleapis.com"
serviceEndpoint Storage   = "storage.googleapis.com"
serviceEndpoint Functions = "cloudfunctions.googleapis.com"
serviceEndpoint Firestore = "firestore.googleapis.com"
serviceEndpoint PubSub    = "pubsub.googleapis.com"
serviceEndpoint CloudRun  = "run.googleapis.com"
serviceEndpoint BigQuery  = "bigquery.googleapis.com"
serviceEndpoint IAM       = "iam.googleapis.com"

||| Encode service as C-compatible integer for FFI.
export
serviceToInt : GcpService -> Int
serviceToInt Compute   = 0
serviceToInt Storage   = 1
serviceToInt Functions = 2
serviceToInt Firestore = 3
serviceToInt PubSub    = 4
serviceToInt CloudRun  = 5
serviceToInt BigQuery  = 6
serviceToInt IAM       = 7

||| Decode integer to GCP service.
export
intToService : Int -> Maybe GcpService
intToService 0 = Just Compute
intToService 1 = Just Storage
intToService 2 = Just Functions
intToService 3 = Just Firestore
intToService 4 = Just PubSub
intToService 5 = Just CloudRun
intToService 6 = Just BigQuery
intToService 7 = Just IAM
intToService _ = Nothing

-- ---------------------------------------------------------------------------
-- GCP actions
-- ---------------------------------------------------------------------------

||| Actions available through the GCP MCP cartridge.
||| Grouped by service: Compute (instances), Storage (buckets/objects/signed URLs),
||| Functions (cloud functions), Firestore (document CRUD/queries),
||| Pub/Sub (topics/subscriptions), Cloud Run (services/deploy),
||| BigQuery (datasets/tables/queries), IAM (policies/permissions).
public export
data GcpAction
  -- Compute (0-3)
  = ListProjects
  | ListInstances
  | StartInstance
  | StopInstance
  -- Storage (4-7)
  | ListBuckets
  | GetObject
  | PutObject
  | GenerateSignedUrl
  -- Functions (8-9)
  | ListFunctions
  | InvokeFunction
  -- Firestore (10-14)
  | FirestoreCreateDocument
  | FirestoreGetDocument
  | FirestoreUpdateDocument
  | FirestoreDeleteDocument
  | FirestoreQuery
  -- Pub/Sub (15-18)
  | ListPubSubTopics
  | PublishMessage
  | ListSubscriptions
  | CreateSubscription
  -- Cloud Run (19-20)
  | CloudRunListServices
  | CloudRunDeployService
  -- BigQuery (21-24)
  | RunQuery
  | ListDatasets
  | ListTables
  | CreateDataset
  -- IAM (25-26)
  | GetIamPolicy
  | TestIamPermissions

||| Which service handles a given action.
export
actionService : GcpAction -> GcpService
actionService ListProjects           = Compute
actionService ListInstances          = Compute
actionService StartInstance          = Compute
actionService StopInstance           = Compute
actionService ListBuckets            = Storage
actionService GetObject              = Storage
actionService PutObject              = Storage
actionService GenerateSignedUrl      = Storage
actionService ListFunctions          = Functions
actionService InvokeFunction         = Functions
actionService FirestoreCreateDocument = Firestore
actionService FirestoreGetDocument   = Firestore
actionService FirestoreUpdateDocument = Firestore
actionService FirestoreDeleteDocument = Firestore
actionService FirestoreQuery         = Firestore
actionService ListPubSubTopics       = PubSub
actionService PublishMessage         = PubSub
actionService ListSubscriptions      = PubSub
actionService CreateSubscription     = PubSub
actionService CloudRunListServices   = CloudRun
actionService CloudRunDeployService  = CloudRun
actionService RunQuery               = BigQuery
actionService ListDatasets           = BigQuery
actionService ListTables             = BigQuery
actionService CreateDataset          = BigQuery
actionService GetIamPolicy           = IAM
actionService TestIamPermissions     = IAM

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GcpAction -> Int
actionToInt ListProjects           = 0
actionToInt ListInstances          = 1
actionToInt StartInstance          = 2
actionToInt StopInstance           = 3
actionToInt ListBuckets            = 4
actionToInt GetObject              = 5
actionToInt PutObject              = 6
actionToInt GenerateSignedUrl      = 7
actionToInt ListFunctions          = 8
actionToInt InvokeFunction         = 9
actionToInt FirestoreCreateDocument = 10
actionToInt FirestoreGetDocument   = 11
actionToInt FirestoreUpdateDocument = 12
actionToInt FirestoreDeleteDocument = 13
actionToInt FirestoreQuery         = 14
actionToInt ListPubSubTopics       = 15
actionToInt PublishMessage         = 16
actionToInt ListSubscriptions      = 17
actionToInt CreateSubscription     = 18
actionToInt CloudRunListServices   = 19
actionToInt CloudRunDeployService  = 20
actionToInt RunQuery               = 21
actionToInt ListDatasets           = 22
actionToInt ListTables             = 23
actionToInt CreateDataset          = 24
actionToInt GetIamPolicy           = 25
actionToInt TestIamPermissions     = 26

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
intToAction 7  = Just GenerateSignedUrl
intToAction 8  = Just ListFunctions
intToAction 9  = Just InvokeFunction
intToAction 10 = Just FirestoreCreateDocument
intToAction 11 = Just FirestoreGetDocument
intToAction 12 = Just FirestoreUpdateDocument
intToAction 13 = Just FirestoreDeleteDocument
intToAction 14 = Just FirestoreQuery
intToAction 15 = Just ListPubSubTopics
intToAction 16 = Just PublishMessage
intToAction 17 = Just ListSubscriptions
intToAction 18 = Just CreateSubscription
intToAction 19 = Just CloudRunListServices
intToAction 20 = Just CloudRunDeployService
intToAction 21 = Just RunQuery
intToAction 22 = Just ListDatasets
intToAction 23 = Just ListTables
intToAction 24 = Just CreateDataset
intToAction 25 = Just GetIamPolicy
intToAction 26 = Just TestIamPermissions
intToAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All GCP actions require authentication.
export
actionRequiresAuth : GcpAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : GcpAction -> Bool
actionIsMutating StartInstance           = True
actionIsMutating StopInstance            = True
actionIsMutating PutObject               = True
actionIsMutating InvokeFunction          = True
actionIsMutating FirestoreCreateDocument = True
actionIsMutating FirestoreUpdateDocument = True
actionIsMutating FirestoreDeleteDocument = True
actionIsMutating PublishMessage          = True
actionIsMutating CreateSubscription      = True
actionIsMutating CloudRunDeployService   = True
actionIsMutating CreateDataset           = True
actionIsMutating _                       = False

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
actionCount = 27

||| Total service count for this cartridge.
export
serviceCount : Nat
serviceCount = 8
