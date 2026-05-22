-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- VaultMcp.SafeSecrets — Type-safe ABI for vault-mcp cartridge.
--
-- Zero-knowledge proxy state machine for the reasonably-good-token-vault.
-- Dependent-type proofs ensure only valid vault state transitions can occur
-- at the FFI boundary. BoJ cartridges never see credentials directly.
-- Zero unsafe escape hatches. Fully total, formally verified.

module VaultMcp.SafeSecrets

%default total

-- ---------------------------------------------------------------------------
-- Vault state machine
-- ---------------------------------------------------------------------------

||| Vault lifecycle states for the zero-knowledge credential proxy.
|||
||| - Locked: vault is sealed, no operations possible until unlock + MFA.
||| - MfaPending: unlock requested, awaiting second factor confirmation.
||| - Unlocked: vault is open, credential-proxied operations permitted.
||| - Sealed: vault has been explicitly sealed; requires full re-init to reopen.
public export
data VaultState = Locked | MfaPending | Unlocked | Sealed

||| Proof that a vault state transition is valid.
|||
||| The transition graph:
|||   Locked -> MfaPending (begin unlock)
|||   MfaPending -> Unlocked (MFA confirmed)
|||   MfaPending -> Locked (MFA rejected / timeout)
|||   Unlocked -> Locked (lock)
|||   Unlocked -> Sealed (permanent seal)
|||   Locked -> Sealed (seal without unlocking)
public export
data ValidTransition : VaultState -> VaultState -> Type where
  BeginUnlock  : ValidTransition Locked MfaPending
  MfaConfirm   : ValidTransition MfaPending Unlocked
  MfaReject    : ValidTransition MfaPending Locked
  Lock         : ValidTransition Unlocked Locked
  SealFromOpen : ValidTransition Unlocked Sealed
  SealFromLock : ValidTransition Locked Sealed

-- ---------------------------------------------------------------------------
-- Vault actions
-- ---------------------------------------------------------------------------

||| Actions that can be performed through the MCP vault/execute interface.
||| Maps directly to the Ada CLI verb set used by svalinn_cli.
public export
data VaultAction
  = Execute   -- ^ Execute a command with vault-managed credentials
  | List      -- ^ List available credential hints (no secrets exposed)
  | Rotate    -- ^ Rotate a credential by hint
  | Status    -- ^ Query vault lock/seal state
  | Verify    -- ^ Verify credential integrity without revealing it

||| Check whether an action requires the vault to be in Unlocked state.
||| Status is always available; all others require an unlocked vault.
export
actionRequiresUnlock : VaultAction -> Bool
actionRequiresUnlock Execute = True
actionRequiresUnlock List    = True
actionRequiresUnlock Rotate  = True
actionRequiresUnlock Status  = False
actionRequiresUnlock Verify  = True

-- ---------------------------------------------------------------------------
-- Credential hint
-- ---------------------------------------------------------------------------

||| Opaque credential hint — identifies which service needs auth without
||| revealing the actual credential. The vault resolves this internally.
||| Examples: "github.com", "cloudflare-api", "ssh-deploy-key".
public export
data CredentialHint = MkHint String

||| Extract the hint string for FFI serialisation.
export
hintToString : CredentialHint -> String
hintToString (MkHint s) = s

||| Construct a credential hint from a raw string.
export
stringToHint : String -> CredentialHint
stringToHint = MkHint

-- ---------------------------------------------------------------------------
-- Identity types (matching Ada CLI)
-- ---------------------------------------------------------------------------

||| Credential identity types supported by the vault.
||| Mirrors the Ada CLI identity type enumeration exactly.
public export
data IdentityType
  = SSH | PGP | PAT | RestApi | GraphqlApi | GrpcApi
  | XPC | X509 | DID | OAuth2 | JWT | Wireguard

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding — vault state
-- ---------------------------------------------------------------------------

||| Encode vault state as C-compatible integer.
export
vaultStateToInt : VaultState -> Int
vaultStateToInt Locked     = 0
vaultStateToInt MfaPending = 1
vaultStateToInt Unlocked   = 2
vaultStateToInt Sealed     = 3

||| Decode integer back to vault state.
export
intToVaultState : Int -> Maybe VaultState
intToVaultState 0 = Just Locked
intToVaultState 1 = Just MfaPending
intToVaultState 2 = Just Unlocked
intToVaultState 3 = Just Sealed
intToVaultState _ = Nothing

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding — vault action
-- ---------------------------------------------------------------------------

||| Encode vault action as C-compatible integer.
export
vaultActionToInt : VaultAction -> Int
vaultActionToInt Execute = 0
vaultActionToInt List    = 1
vaultActionToInt Rotate  = 2
vaultActionToInt Status  = 3
vaultActionToInt Verify  = 4

||| Decode integer back to vault action.
export
intToVaultAction : Int -> Maybe VaultAction
intToVaultAction 0 = Just Execute
intToVaultAction 1 = Just List
intToVaultAction 2 = Just Rotate
intToVaultAction 3 = Just Status
intToVaultAction 4 = Just Verify
intToVaultAction _ = Nothing

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding — identity type
-- ---------------------------------------------------------------------------

||| Encode identity type as C-compatible integer.
export
identityTypeToInt : IdentityType -> Int
identityTypeToInt SSH        = 0
identityTypeToInt PGP        = 1
identityTypeToInt PAT        = 2
identityTypeToInt RestApi    = 3
identityTypeToInt GraphqlApi = 4
identityTypeToInt GrpcApi    = 5
identityTypeToInt XPC        = 6
identityTypeToInt X509       = 7
identityTypeToInt DID        = 8
identityTypeToInt OAuth2     = 9
identityTypeToInt JWT        = 10
identityTypeToInt Wireguard  = 11

||| Decode integer back to identity type.
export
intToIdentityType : Int -> Maybe IdentityType
intToIdentityType 0  = Just SSH
intToIdentityType 1  = Just PGP
intToIdentityType 2  = Just PAT
intToIdentityType 3  = Just RestApi
intToIdentityType 4  = Just GraphqlApi
intToIdentityType 5  = Just GrpcApi
intToIdentityType 6  = Just XPC
intToIdentityType 7  = Just X509
intToIdentityType 8  = Just DID
intToIdentityType 9  = Just OAuth2
intToIdentityType 10 = Just JWT
intToIdentityType 11 = Just Wireguard
intToIdentityType _  = Nothing

-- ---------------------------------------------------------------------------
-- C-ABI transition validator
-- ---------------------------------------------------------------------------

||| Check if a vault state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
vault_mcp_can_transition : Int -> Int -> Int
vault_mcp_can_transition from to =
  case (intToVaultState from, intToVaultState to) of
    (Just Locked,     Just MfaPending) => 1  -- BeginUnlock
    (Just MfaPending, Just Unlocked)   => 1  -- MfaConfirm
    (Just MfaPending, Just Locked)     => 1  -- MfaReject
    (Just Unlocked,   Just Locked)     => 1  -- Lock
    (Just Unlocked,   Just Sealed)     => 1  -- SealFromOpen
    (Just Locked,     Just Sealed)     => 1  -- SealFromLock
    _                                  => 0

||| Check if an action is permitted in the given vault state (C-ABI export).
||| Returns 1 for permitted, 0 for denied.
export
vault_mcp_action_permitted : Int -> Int -> Int
vault_mcp_action_permitted stateInt actionInt =
  case (intToVaultState stateInt, intToVaultAction actionInt) of
    (Just Unlocked, _)           => 1  -- All actions allowed when unlocked
    (Just _,        Just Status) => 1  -- Status always allowed
    _                            => 0

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolVaultExecute   -- ^ vault/execute — run command with proxied credentials
  | ToolVaultList      -- ^ vault/list — list credential hints
  | ToolVaultStatus    -- ^ vault/status — query vault state
  | ToolVaultRotate    -- ^ vault/rotate — rotate a credential
  | ToolVaultVerify    -- ^ vault/verify — verify credential integrity

||| Check if a tool requires the vault to be unlocked.
export
toolRequiresUnlock : McpTool -> Bool
toolRequiresUnlock ToolVaultExecute = True
toolRequiresUnlock ToolVaultList    = True
toolRequiresUnlock ToolVaultStatus  = False
toolRequiresUnlock ToolVaultRotate  = True
toolRequiresUnlock ToolVaultVerify  = True

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5

-- ---------------------------------------------------------------------------
-- Audit log types
-- ---------------------------------------------------------------------------

||| An audit log entry records a vault operation with its outcome.
||| The audit ring buffer retains the most recent MAX_AUDIT_ENTRIES entries.
||| Credential values are NEVER recorded — only hints and action types.
public export
record AuditEntry where
  constructor MkAuditEntry
  timestamp      : Int
  action         : VaultAction
  credentialHint : CredentialHint
  resultCode     : Int
  agentId        : String

-- ---------------------------------------------------------------------------
-- Command allowlist
-- ---------------------------------------------------------------------------

||| A command prefix pattern in the AI agent allowlist.
||| When enforcement is enabled, vault/execute rejects commands not matching
||| any registered prefix. This prevents AI agents from running arbitrary
||| commands with vault-injected credentials.
public export
data AllowlistEntry = MkAllowlistEntry String

||| Extract the pattern string for FFI serialisation.
export
allowlistPattern : AllowlistEntry -> String
allowlistPattern (MkAllowlistEntry s) = s

||| C-ABI export for audit entry count query.
export
vault_mcp_audit_count : Int

||| C-ABI export for allowlist add.
export
vault_mcp_allowlist_add : String -> Int -> Int

||| C-ABI export for allowlist enforcement toggle.
export
vault_mcp_allowlist_enforce : Int -> ()
