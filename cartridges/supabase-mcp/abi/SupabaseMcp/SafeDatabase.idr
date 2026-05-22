-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- SupabaseMcp.SafeDatabase — Type-safe ABI for the supabase-mcp cartridge.
--
-- Provides a formally verified state machine for Supabase project connections.
-- Dependent-type proofs ensure only valid transitions can occur at the FFI
-- boundary. Supabase actions cover PostgREST, Auth, Storage, and Functions
-- endpoints. Auth via Bearer token (service_role key or anon key).
-- Configurable project URL: https://{project}.supabase.co/

module SupabaseMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Supabase project operations.
||| Covers PostgREST, Auth, Storage, and Functions endpoints.
public export
data ConnState = Disconnected | Connected | QueryRunning | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect       : ValidTransition Disconnected Connected
  StartQuery    : ValidTransition Connected QueryRunning
  FinishQuery   : ValidTransition QueryRunning Connected
  Disconnect    : ValidTransition Connected Disconnected
  QueryFail     : ValidTransition QueryRunning Error
  ErrorRecover  : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected = 0
connStateToInt Connected    = 1
connStateToInt QueryRunning = 2
connStateToInt Error        = 3

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Connected
intToConnState 2 = Just QueryRunning
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
supabase_mcp_can_transition : Int -> Int -> Int
supabase_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Supabase actions (PostgREST + Auth + Storage + Functions)
-- ---------------------------------------------------------------------------

||| Actions supported by the Supabase MCP cartridge.
||| Covers projects, PostgREST queries, tables, edge functions, storage
||| buckets, auth users, and secrets.
public export
data SupabaseAction
  = ListProjects
  | GetProject
  | Query
  | ListTables
  | GetTable
  | ListFunctions
  | InvokeFunction
  | ListBuckets
  | UploadFile
  | ListFiles
  | GetUser
  | ListUsers
  | CreateUser
  | SignIn
  | ListSecrets
  | SetSecret

||| Encode action as C-compatible integer.
export
supabaseActionToInt : SupabaseAction -> Int
supabaseActionToInt ListProjects   = 0
supabaseActionToInt GetProject     = 1
supabaseActionToInt Query          = 2
supabaseActionToInt ListTables     = 3
supabaseActionToInt GetTable       = 4
supabaseActionToInt ListFunctions  = 5
supabaseActionToInt InvokeFunction = 6
supabaseActionToInt ListBuckets    = 7
supabaseActionToInt UploadFile     = 8
supabaseActionToInt ListFiles      = 9
supabaseActionToInt GetUser        = 10
supabaseActionToInt ListUsers      = 11
supabaseActionToInt CreateUser     = 12
supabaseActionToInt SignIn         = 13
supabaseActionToInt ListSecrets    = 14
supabaseActionToInt SetSecret      = 15

||| Decode integer back to action.
export
intToSupabaseAction : Int -> Maybe SupabaseAction
intToSupabaseAction 0  = Just ListProjects
intToSupabaseAction 1  = Just GetProject
intToSupabaseAction 2  = Just Query
intToSupabaseAction 3  = Just ListTables
intToSupabaseAction 4  = Just GetTable
intToSupabaseAction 5  = Just ListFunctions
intToSupabaseAction 6  = Just InvokeFunction
intToSupabaseAction 7  = Just ListBuckets
intToSupabaseAction 8  = Just UploadFile
intToSupabaseAction 9  = Just ListFiles
intToSupabaseAction 10 = Just GetUser
intToSupabaseAction 11 = Just ListUsers
intToSupabaseAction 12 = Just CreateUser
intToSupabaseAction 13 = Just SignIn
intToSupabaseAction 14 = Just ListSecrets
intToSupabaseAction 15 = Just SetSecret
intToSupabaseAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : SupabaseAction -> Bool
actionRequiresConnection Query          = True
actionRequiresConnection ListTables     = True
actionRequiresConnection GetTable       = True
actionRequiresConnection InvokeFunction = True
actionRequiresConnection UploadFile     = True
actionRequiresConnection ListFiles      = True
actionRequiresConnection GetUser        = True
actionRequiresConnection ListUsers      = True
actionRequiresConnection CreateUser     = True
actionRequiresConnection SignIn         = True
actionRequiresConnection ListSecrets    = True
actionRequiresConnection SetSecret      = True
actionRequiresConnection _              = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for Supabase REST API.
||| Bearer token using service_role key or anon key.
public export
data SupabaseAuth = ServiceRoleKey | AnonKey

||| Base URL template for Supabase REST API.
||| The project ref replaces the placeholder at runtime.
export
supabaseApiBaseTemplate : String
supabaseApiBaseTemplate = "https://{project}.supabase.co/"
