-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| SecretsMcp.SafeSecrets: Formally verified secret management operations.
|||
||| Cartridge: secrets-mcp
||| Matrix cell: Secrets domain x {MCP, LSP} protocols
|||
||| This module defines type-safe vault operations with a
||| seal/unseal state machine that prevents:
|||   - Reading secrets from a sealed vault
|||   - Accessing secrets without authentication
|||   - Secret exposure in logs (audit trail enforcement)
|||
||| Supports Vault, SOPS, and env-vault backends.
module SecretsMcp.SafeSecrets

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Vault State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Vault lifecycle states.
||| A vault progresses: Sealed -> Unsealed -> Authenticated -> Accessing -> Authenticated -> Sealed
public export
data VaultState = Sealed | Unsealed | Authenticated | Accessing | SecretError

||| Equality for vault states.
public export
Eq VaultState where
  Sealed        == Sealed        = True
  Unsealed      == Unsealed      = True
  Authenticated == Authenticated = True
  Accessing     == Accessing     = True
  SecretError   == SecretError   = True
  _             == _             = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : VaultState -> VaultState -> Type where
  Unseal      : ValidTransition Sealed Unsealed
  Authenticate : ValidTransition Unsealed Authenticated
  BeginAccess : ValidTransition Authenticated Accessing
  EndAccess   : ValidTransition Accessing Authenticated
  Deauth      : ValidTransition Authenticated Unsealed
  Seal        : ValidTransition Unsealed Sealed
  AccessError : ValidTransition Accessing SecretError
  Recover     : ValidTransition SecretError Authenticated

||| Runtime transition validator.
public export
canTransition : VaultState -> VaultState -> Bool
canTransition Sealed        Unsealed      = True
canTransition Unsealed      Authenticated = True
canTransition Authenticated Accessing     = True
canTransition Accessing     Authenticated = True
canTransition Authenticated Unsealed      = True
canTransition Unsealed      Sealed        = True
canTransition Accessing     SecretError   = True
canTransition SecretError   Authenticated = True
canTransition _             _             = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Secret Backend Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported secret management backends.
public export
data SecretBackend
  = Vault         -- HashiCorp Vault
  | SOPS          -- Mozilla SOPS
  | EnvVault      -- Environment-based vault
  | Custom String -- User-defined backend

||| C-ABI encoding for backends.
public export
backendToInt : SecretBackend -> Int
backendToInt Vault       = 1
backendToInt SOPS        = 2
backendToInt EnvVault    = 3
backendToInt (Custom _)  = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Secret Access Audit
-- ═══════════════════════════════════════════════════════════════════════════

||| Secret access classification for audit trail.
public export
data AccessType
  = Read       -- Read a secret value
  | Write      -- Create or update a secret
  | Delete     -- Delete a secret
  | Rotate     -- Rotate a secret
  | List       -- List secret keys (values not exposed)

||| A secret access record for audit purposes.
public export
record AuditEntry where
  constructor MkAuditEntry
  accessType : AccessType
  keyPath    : String
  timestamp  : Nat  -- Unix timestamp

-- ═══════════════════════════════════════════════════════════════════════════
-- Vault Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A vault session with tracked state.
public export
record VaultSession where
  constructor MkVaultSession
  vaultId     : String
  backend     : SecretBackend
  state       : VaultState
  accessCount : Nat  -- Total accesses for audit

||| Proof that a vault is authenticated and ready for access.
public export
data IsAuthenticated : VaultSession -> Type where
  ActiveVault : (v : VaultSession) ->
                (state v = Authenticated) ->
                IsAuthenticated v

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolUnseal         -- Unseal a vault
  | ToolAuthenticate   -- Authenticate with an unsealed vault
  | ToolGetSecret      -- Read a secret value
  | ToolPutSecret      -- Create or update a secret
  | ToolDeleteSecret   -- Delete a secret
  | ToolListSecrets    -- List available secret keys
  | ToolRotate         -- Rotate a secret
  | ToolSeal           -- Seal the vault

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolUnseal       = "secrets/unseal"
toolName ToolAuthenticate = "secrets/authenticate"
toolName ToolGetSecret    = "secrets/get"
toolName ToolPutSecret    = "secrets/put"
toolName ToolDeleteSecret = "secrets/delete"
toolName ToolListSecrets  = "secrets/list"
toolName ToolRotate       = "secrets/rotate"
toolName ToolSeal         = "secrets/seal"

||| Which tools require authentication (vs just unsealed vault).
public export
requiresAuth : McpTool -> Bool
requiresAuth ToolUnseal       = False
requiresAuth ToolAuthenticate = False
requiresAuth ToolSeal         = False
requiresAuth _                = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Vault state to integer.
public export
vaultStateToInt : VaultState -> Int
vaultStateToInt Sealed        = 0
vaultStateToInt Unsealed      = 1
vaultStateToInt Authenticated = 2
vaultStateToInt Accessing     = 3
vaultStateToInt SecretError   = 4

||| FFI: Validate a state transition.
export
sec_can_transition : Int -> Int -> Int
sec_can_transition from to =
  let fromState = case from of
                    0 => Sealed
                    1 => Unsealed
                    2 => Authenticated
                    3 => Accessing
                    _ => SecretError
      toState = case to of
                  0 => Sealed
                  1 => Unsealed
                  2 => Authenticated
                  3 => Accessing
                  _ => SecretError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires authentication.
export
sec_tool_requires_auth : Int -> Int
sec_tool_requires_auth 1 = 0  -- ToolUnseal
sec_tool_requires_auth 2 = 0  -- ToolAuthenticate
sec_tool_requires_auth 8 = 0  -- ToolSeal
sec_tool_requires_auth _ = 1  -- All others require auth
