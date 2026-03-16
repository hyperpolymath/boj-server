-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- AwsMcp.SafeCloud — Type-safe ABI for aws-mcp cartridge.
--
-- Dependent-type state machine governing AWS API access through vault-mcp
-- credential proxy. Encodes AWS Signature V4 auth flow, multi-service
-- routing (S3, EC2, Lambda, SQS, DynamoDB), and rate-limit back-pressure
-- as compile-time invariants. No unsafe escape hatches.

module AwsMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for AWS MCP operations.
||| Unauthenticated: no credentials loaded.
||| Authenticated: AWS Signature V4 credentials active (access_key_id +
|||   secret_access_key + region), obtained via vault-mcp.
||| RateLimited: AWS throttling response received; must wait before retry.
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
aws_mcp_can_transition : Int -> Int -> Int
aws_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- AWS service routing
-- ---------------------------------------------------------------------------

||| AWS services accessible through this cartridge.
public export
data AwsService
  = S3
  | EC2
  | Lambda
  | SQS
  | DynamoDB

||| Map service to its API endpoint prefix.
export
serviceEndpoint : AwsService -> String
serviceEndpoint S3       = "s3"
serviceEndpoint EC2      = "ec2"
serviceEndpoint Lambda   = "lambda"
serviceEndpoint SQS      = "sqs"
serviceEndpoint DynamoDB = "dynamodb"

||| Encode service as C-compatible integer for FFI.
export
serviceToInt : AwsService -> Int
serviceToInt S3       = 0
serviceToInt EC2      = 1
serviceToInt Lambda   = 2
serviceToInt SQS      = 3
serviceToInt DynamoDB = 4

||| Decode integer to AWS service.
export
intToService : Int -> Maybe AwsService
intToService 0 = Just S3
intToService 1 = Just EC2
intToService 2 = Just Lambda
intToService 3 = Just SQS
intToService 4 = Just DynamoDB
intToService _ = Nothing

-- ---------------------------------------------------------------------------
-- AWS actions
-- ---------------------------------------------------------------------------

||| Actions available through the AWS MCP cartridge.
||| Grouped by service: S3 (bucket/object), EC2 (instance), Lambda (function),
||| SQS (queue/message), DynamoDB (table/item).
public export
data AwsAction
  = ListBuckets
  | GetObject
  | PutObject
  | DeleteObject
  | ListInstances
  | StartInstance
  | StopInstance
  | ListFunctions
  | InvokeFunction
  | ListQueues
  | SendMessage
  | ReceiveMessage
  | ListTables
  | PutItem
  | GetItem
  | QueryTable

||| Which service handles a given action.
export
actionService : AwsAction -> AwsService
actionService ListBuckets    = S3
actionService GetObject      = S3
actionService PutObject      = S3
actionService DeleteObject   = S3
actionService ListInstances  = EC2
actionService StartInstance  = EC2
actionService StopInstance   = EC2
actionService ListFunctions  = Lambda
actionService InvokeFunction = Lambda
actionService ListQueues     = SQS
actionService SendMessage    = SQS
actionService ReceiveMessage = SQS
actionService ListTables     = DynamoDB
actionService PutItem        = DynamoDB
actionService GetItem        = DynamoDB
actionService QueryTable     = DynamoDB

||| Encode action as C-compatible integer for FFI.
export
actionToInt : AwsAction -> Int
actionToInt ListBuckets    = 0
actionToInt GetObject      = 1
actionToInt PutObject      = 2
actionToInt DeleteObject   = 3
actionToInt ListInstances  = 4
actionToInt StartInstance  = 5
actionToInt StopInstance   = 6
actionToInt ListFunctions  = 7
actionToInt InvokeFunction = 8
actionToInt ListQueues     = 9
actionToInt SendMessage    = 10
actionToInt ReceiveMessage = 11
actionToInt ListTables     = 12
actionToInt PutItem        = 13
actionToInt GetItem        = 14
actionToInt QueryTable     = 15

||| Decode integer to AWS action.
export
intToAction : Int -> Maybe AwsAction
intToAction 0  = Just ListBuckets
intToAction 1  = Just GetObject
intToAction 2  = Just PutObject
intToAction 3  = Just DeleteObject
intToAction 4  = Just ListInstances
intToAction 5  = Just StartInstance
intToAction 6  = Just StopInstance
intToAction 7  = Just ListFunctions
intToAction 8  = Just InvokeFunction
intToAction 9  = Just ListQueues
intToAction 10 = Just SendMessage
intToAction 11 = Just ReceiveMessage
intToAction 12 = Just ListTables
intToAction 13 = Just PutItem
intToAction 14 = Just GetItem
intToAction 15 = Just QueryTable
intToAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All AWS actions require authentication.
export
actionRequiresAuth : AwsAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : AwsAction -> Bool
actionIsMutating PutObject      = True
actionIsMutating DeleteObject   = True
actionIsMutating StartInstance  = True
actionIsMutating StopInstance   = True
actionIsMutating InvokeFunction = True
actionIsMutating SendMessage    = True
actionIsMutating PutItem        = True
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
serviceCount = 5
