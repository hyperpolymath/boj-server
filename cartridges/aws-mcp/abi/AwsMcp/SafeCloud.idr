-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- AwsMcp.SafeCloud — Type-safe ABI for aws-mcp cartridge.
--
-- Dependent-type state machine governing AWS API access through vault-mcp
-- credential proxy. Encodes AWS Signature V4 auth flow, multi-service
-- routing (S3, Lambda, DynamoDB, SQS, CloudWatch, IAM, STS), and rate-limit
-- back-pressure as compile-time invariants. No unsafe escape hatches.

module AwsMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for AWS MCP operations.
||| Unauthenticated: no credentials loaded.
||| Authenticated: AWS Signature V4 credentials active (access_key_id +
|||   secret_access_key + region + optional session_token), obtained via vault-mcp.
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
||| S3: object storage. Lambda: serverless compute. DynamoDB: NoSQL database.
||| SQS: message queues. CloudWatch: metrics/monitoring.
||| IAM: identity management (read-only). STS: security token service.
public export
data AwsService
  = S3
  | Lambda
  | DynamoDB
  | SQS
  | CloudWatch
  | IAM
  | STS

||| Map service to its API endpoint prefix.
export
serviceEndpoint : AwsService -> String
serviceEndpoint S3         = "s3"
serviceEndpoint Lambda     = "lambda"
serviceEndpoint DynamoDB   = "dynamodb"
serviceEndpoint SQS        = "sqs"
serviceEndpoint CloudWatch = "monitoring"
serviceEndpoint IAM        = "iam"
serviceEndpoint STS        = "sts"

||| Encode service as C-compatible integer for FFI.
export
serviceToInt : AwsService -> Int
serviceToInt S3         = 0
serviceToInt Lambda     = 1
serviceToInt DynamoDB   = 2
serviceToInt SQS        = 3
serviceToInt CloudWatch = 4
serviceToInt IAM        = 5
serviceToInt STS        = 6

||| Decode integer to AWS service.
export
intToService : Int -> Maybe AwsService
intToService 0 = Just S3
intToService 1 = Just Lambda
intToService 2 = Just DynamoDB
intToService 3 = Just SQS
intToService 4 = Just CloudWatch
intToService 5 = Just IAM
intToService 6 = Just STS
intToService _ = Nothing

-- ---------------------------------------------------------------------------
-- AWS actions
-- ---------------------------------------------------------------------------

||| Actions available through the AWS MCP cartridge.
||| Grouped by service:
|||   S3: bucket/object operations including presigned URLs
|||   Lambda: function invocation and listing
|||   DynamoDB: table/item operations (query, scan, get, put)
|||   SQS: queue/message operations
|||   CloudWatch: metrics (get/put)
|||   IAM: read-only user/role listing
|||   STS: caller identity and role assumption
public export
data AwsAction
  -- S3 (0-4)
  = S3ListBuckets
  | S3GetObject
  | S3PutObject
  | S3DeleteObject
  | S3PresignedUrl
  -- Lambda (5-6)
  | LambdaListFunctions
  | LambdaInvoke
  -- DynamoDB (7-10)
  | DynamoQuery
  | DynamoScan
  | DynamoPutItem
  | DynamoGetItem
  -- SQS (11-14)
  | SqsListQueues
  | SqsSendMessage
  | SqsReceiveMessage
  | SqsDeleteMessage
  -- CloudWatch (15-16)
  | CwGetMetrics
  | CwPutMetricData
  -- IAM (17-18) — read-only
  | IamListUsers
  | IamListRoles
  -- STS (19-20)
  | StsGetCallerIdentity
  | StsAssumeRole

||| Which service handles a given action.
export
actionService : AwsAction -> AwsService
actionService S3ListBuckets        = S3
actionService S3GetObject          = S3
actionService S3PutObject          = S3
actionService S3DeleteObject       = S3
actionService S3PresignedUrl       = S3
actionService LambdaListFunctions  = Lambda
actionService LambdaInvoke         = Lambda
actionService DynamoQuery          = DynamoDB
actionService DynamoScan           = DynamoDB
actionService DynamoPutItem        = DynamoDB
actionService DynamoGetItem        = DynamoDB
actionService SqsListQueues        = SQS
actionService SqsSendMessage       = SQS
actionService SqsReceiveMessage    = SQS
actionService SqsDeleteMessage     = SQS
actionService CwGetMetrics         = CloudWatch
actionService CwPutMetricData      = CloudWatch
actionService IamListUsers         = IAM
actionService IamListRoles         = IAM
actionService StsGetCallerIdentity = STS
actionService StsAssumeRole        = STS

||| Encode action as C-compatible integer for FFI.
export
actionToInt : AwsAction -> Int
actionToInt S3ListBuckets        = 0
actionToInt S3GetObject          = 1
actionToInt S3PutObject          = 2
actionToInt S3DeleteObject       = 3
actionToInt S3PresignedUrl       = 4
actionToInt LambdaListFunctions  = 5
actionToInt LambdaInvoke         = 6
actionToInt DynamoQuery          = 7
actionToInt DynamoScan           = 8
actionToInt DynamoPutItem        = 9
actionToInt DynamoGetItem        = 10
actionToInt SqsListQueues        = 11
actionToInt SqsSendMessage       = 12
actionToInt SqsReceiveMessage    = 13
actionToInt SqsDeleteMessage     = 14
actionToInt CwGetMetrics         = 15
actionToInt CwPutMetricData      = 16
actionToInt IamListUsers         = 17
actionToInt IamListRoles         = 18
actionToInt StsGetCallerIdentity = 19
actionToInt StsAssumeRole        = 20

||| Decode integer to AWS action.
export
intToAction : Int -> Maybe AwsAction
intToAction 0  = Just S3ListBuckets
intToAction 1  = Just S3GetObject
intToAction 2  = Just S3PutObject
intToAction 3  = Just S3DeleteObject
intToAction 4  = Just S3PresignedUrl
intToAction 5  = Just LambdaListFunctions
intToAction 6  = Just LambdaInvoke
intToAction 7  = Just DynamoQuery
intToAction 8  = Just DynamoScan
intToAction 9  = Just DynamoPutItem
intToAction 10 = Just DynamoGetItem
intToAction 11 = Just SqsListQueues
intToAction 12 = Just SqsSendMessage
intToAction 13 = Just SqsReceiveMessage
intToAction 14 = Just SqsDeleteMessage
intToAction 15 = Just CwGetMetrics
intToAction 16 = Just CwPutMetricData
intToAction 17 = Just IamListUsers
intToAction 18 = Just IamListRoles
intToAction 19 = Just StsGetCallerIdentity
intToAction 20 = Just StsAssumeRole
intToAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All AWS actions require authentication.
export
actionRequiresAuth : AwsAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
||| IAM listing, STS GetCallerIdentity, S3 reads, DynamoDB reads, SQS reads,
||| and CloudWatch reads are non-mutating. Everything else mutates state.
export
actionIsMutating : AwsAction -> Bool
actionIsMutating S3PutObject      = True
actionIsMutating S3DeleteObject   = True
actionIsMutating LambdaInvoke     = True
actionIsMutating DynamoPutItem    = True
actionIsMutating SqsSendMessage   = True
actionIsMutating SqsDeleteMessage = True
actionIsMutating CwPutMetricData  = True
actionIsMutating StsAssumeRole    = True
actionIsMutating _                = False

||| Whether an action is strictly read-only (safe for audit/inspection).
||| Useful for enforcing least-privilege in IAM policy generation.
export
actionIsReadOnly : AwsAction -> Bool
actionIsReadOnly act = not (actionIsMutating act)

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
actionCount = 21

||| Total service count for this cartridge.
export
serviceCount : Nat
serviceCount = 7
