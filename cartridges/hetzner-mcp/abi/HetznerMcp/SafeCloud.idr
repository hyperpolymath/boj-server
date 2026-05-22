-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- HetznerMcp.SafeCloud — Type-safe ABI for hetzner-mcp cartridge.
--
-- Dependent-type state machine governing Hetzner Cloud API access.
-- Encodes Bearer token auth flow, server/volume/firewall/network management,
-- and per-second rate limiting as compile-time invariants.
-- REST API: https://api.hetzner.cloud/v1/
-- No unsafe escape hatches.

module HetznerMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Hetzner MCP operations.
||| Unauthenticated: no API token loaded.
||| Authenticated: Bearer token active, obtained via vault-mcp.
||| RateLimited: Hetzner per-second rate limit hit; must wait.
||| Error: unrecoverable error (invalid token, permission denied, etc.).
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
hetzner_mcp_can_transition : Int -> Int -> Int
hetzner_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Hetzner resource categories
-- ---------------------------------------------------------------------------

||| Hetzner Cloud resource categories managed by this cartridge.
public export
data HetznerResource
  = Servers
  | Images
  | SSHKeys
  | Volumes
  | Firewalls
  | Networks

||| Encode resource category as C-compatible integer for FFI.
export
resourceToInt : HetznerResource -> Int
resourceToInt Servers   = 0
resourceToInt Images    = 1
resourceToInt SSHKeys   = 2
resourceToInt Volumes   = 3
resourceToInt Firewalls = 4
resourceToInt Networks  = 5

||| Decode integer to resource category.
export
intToResource : Int -> Maybe HetznerResource
intToResource 0 = Just Servers
intToResource 1 = Just Images
intToResource 2 = Just SSHKeys
intToResource 3 = Just Volumes
intToResource 4 = Just Firewalls
intToResource 5 = Just Networks
intToResource _ = Nothing

-- ---------------------------------------------------------------------------
-- Hetzner actions
-- ---------------------------------------------------------------------------

||| Actions available through the Hetzner MCP cartridge.
||| Grouped by resource: Servers (CRUD + power), Images, SSH Keys,
||| Volumes (CRUD + attach), Firewalls, Networks.
public export
data HetznerAction
  = ListServers
  | GetServer
  | CreateServer
  | DeleteServer
  | PowerOn
  | PowerOff
  | Reboot
  | ListImages
  | ListSSHKeys
  | CreateSSHKey
  | ListVolumes
  | CreateVolume
  | AttachVolume
  | ListFirewalls
  | CreateFirewall
  | ListNetworks

||| Which resource category handles a given action.
export
actionResource : HetznerAction -> HetznerResource
actionResource ListServers    = Servers
actionResource GetServer      = Servers
actionResource CreateServer   = Servers
actionResource DeleteServer   = Servers
actionResource PowerOn        = Servers
actionResource PowerOff       = Servers
actionResource Reboot         = Servers
actionResource ListImages     = Images
actionResource ListSSHKeys    = SSHKeys
actionResource CreateSSHKey   = SSHKeys
actionResource ListVolumes    = Volumes
actionResource CreateVolume   = Volumes
actionResource AttachVolume   = Volumes
actionResource ListFirewalls  = Firewalls
actionResource CreateFirewall = Firewalls
actionResource ListNetworks   = Networks

||| Encode action as C-compatible integer for FFI.
export
actionToInt : HetznerAction -> Int
actionToInt ListServers    = 0
actionToInt GetServer      = 1
actionToInt CreateServer   = 2
actionToInt DeleteServer   = 3
actionToInt PowerOn        = 4
actionToInt PowerOff       = 5
actionToInt Reboot         = 6
actionToInt ListImages     = 7
actionToInt ListSSHKeys    = 8
actionToInt CreateSSHKey   = 9
actionToInt ListVolumes    = 10
actionToInt CreateVolume   = 11
actionToInt AttachVolume   = 12
actionToInt ListFirewalls  = 13
actionToInt CreateFirewall = 14
actionToInt ListNetworks   = 15

||| Decode integer to Hetzner action.
export
intToAction : Int -> Maybe HetznerAction
intToAction 0  = Just ListServers
intToAction 1  = Just GetServer
intToAction 2  = Just CreateServer
intToAction 3  = Just DeleteServer
intToAction 4  = Just PowerOn
intToAction 5  = Just PowerOff
intToAction 6  = Just Reboot
intToAction 7  = Just ListImages
intToAction 8  = Just ListSSHKeys
intToAction 9  = Just CreateSSHKey
intToAction 10 = Just ListVolumes
intToAction 11 = Just CreateVolume
intToAction 12 = Just AttachVolume
intToAction 13 = Just ListFirewalls
intToAction 14 = Just CreateFirewall
intToAction 15 = Just ListNetworks
intToAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All Hetzner actions require authentication.
export
actionRequiresAuth : HetznerAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : HetznerAction -> Bool
actionIsMutating CreateServer   = True
actionIsMutating DeleteServer   = True
actionIsMutating PowerOn        = True
actionIsMutating PowerOff       = True
actionIsMutating Reboot         = True
actionIsMutating CreateSSHKey   = True
actionIsMutating CreateVolume   = True
actionIsMutating AttachVolume   = True
actionIsMutating CreateFirewall = True
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
  | ToolListResources
  | ToolListActions

||| Check if a tool requires an authenticated session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolAuthenticate   = False
toolRequiresSession ToolDeauthenticate = True
toolRequiresSession ToolStatus         = False
toolRequiresSession ToolInvoke         = True
toolRequiresSession ToolListResources  = False
toolRequiresSession ToolListActions    = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 6

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 16

||| Total resource category count for this cartridge.
export
resourceCount : Nat
resourceCount = 6
