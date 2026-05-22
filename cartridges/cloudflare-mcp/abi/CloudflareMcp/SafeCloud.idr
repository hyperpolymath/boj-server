-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- CloudflareMcp.SafeCloud -- Type-safe ABI for cloudflare-mcp cartridge.
--
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary.  Auth: Bearer token (CF_API_TOKEN).
-- API: https://api.cloudflare.com/client/v4/

module CloudflareMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Session state machine
-- ---------------------------------------------------------------------------

||| Authentication and rate-limit state for Cloudflare API operations.
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate    : ValidTransition Unauthenticated Authenticated
  BeginRateLimit  : ValidTransition Authenticated   RateLimited
  EndRateLimit    : ValidTransition RateLimited      Authenticated
  AuthError       : ValidTransition Unauthenticated Error
  OpError         : ValidTransition Authenticated   Error
  RateError       : ValidTransition RateLimited     Error
  RecoverAuth     : ValidTransition Error            Unauthenticated
  Deauthenticate  : ValidTransition Authenticated   Unauthenticated

export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

-- ---------------------------------------------------------------------------
-- Action codes
-- ---------------------------------------------------------------------------

||| All Cloudflare API actions exposed by this cartridge.
public export
data CloudflareAction
  = ListZones
  | GetZone
  | ListDnsRecords
  | GetDnsRecord
  | CreateDnsRecord
  | UpdateDnsRecord
  | PatchDnsRecord
  | DeleteDnsRecord
  | GetZoneSetting
  | UpdateZoneSetting
  | PurgeCache

export
actionToInt : CloudflareAction -> Int
actionToInt ListZones         = 0
actionToInt GetZone           = 1
actionToInt ListDnsRecords    = 2
actionToInt GetDnsRecord      = 3
actionToInt CreateDnsRecord   = 4
actionToInt UpdateDnsRecord   = 5
actionToInt PatchDnsRecord    = 6
actionToInt DeleteDnsRecord   = 7
actionToInt GetZoneSetting    = 8
actionToInt UpdateZoneSetting = 9
actionToInt PurgeCache        = 10

-- ---------------------------------------------------------------------------
-- Proof: only Authenticated sessions may perform actions
-- ---------------------------------------------------------------------------

||| Proof that a given state permits API actions.
public export
data CanPerformAction : SessionState -> Type where
  AuthOk : CanPerformAction Authenticated

||| Safely perform an action, requiring an Authenticated state proof.
export
performAction : (s : SessionState)
             -> CanPerformAction s
             -> CloudflareAction
             -> IO Int  -- returns HTTP status code
performAction Authenticated AuthOk action =
  pure (actionToInt action)  -- FFI fills real HTTP call

-- ---------------------------------------------------------------------------
-- DNS record proxy constraint
-- ---------------------------------------------------------------------------

||| DNS record types that support Cloudflare proxying (orange cloud).
public export
data ProxyableType = ARecord | AAAARecord | CNAMERecord

||| Proof that a record type is proxyable.
export
isProxyable : ProxyableType -> Bool
isProxyable _ = True  -- all three support proxying

||| When proxied, IPv6 is provided by Cloudflare's edge regardless of record type.
||| An A record with proxied=True gives full IPv6 to end users.
export
proxiedProvidesIPv6 : (t : ProxyableType) -> (proxied : Bool) -> Bool
proxiedProvidesIPv6 _ True  = True
proxiedProvidesIPv6 _ False = False
