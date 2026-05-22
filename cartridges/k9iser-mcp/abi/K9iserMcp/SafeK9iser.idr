-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| K9iserMcp.SafeK9iser: Formally verified K9-contract generation pipeline.
|||
||| Cartridge: k9iser-mcp
||| Matrix cell: config domain x {MCP, REST} protocols
|||
||| This module defines a regeneration pipeline state machine that prevents:
|||   - Applying (committing) contracts that were never validated
|||   - Validating contracts that were never generated
|||   - Generating from an unloaded manifest
|||
||| State machine: Empty -> ManifestLoaded -> Generated -> Validated -> Applied
module K9iserMcp.SafeK9iser

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- K9iser Pipeline State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| k9iser regeneration lifecycle states.
||| Progresses: Empty -> ManifestLoaded -> Generated -> Validated -> Applied
public export
data K9State
  = Empty
  | ManifestLoaded
  | Generated
  | Validated
  | Applied
  | K9Error

||| Equality for K9 states.
public export
Eq K9State where
  Empty          == Empty          = True
  ManifestLoaded == ManifestLoaded = True
  Generated      == Generated      = True
  Validated      == Validated      = True
  Applied        == Applied        = True
  K9Error        == K9Error        = True
  _              == _              = False

||| Valid state transitions (enforced at the type level).
||| Critically, Generated -> Applied is NOT valid (must validate first).
||| And ManifestLoaded -> Validated is NOT valid (must generate first).
public export
data ValidTransition : K9State -> K9State -> Type where
  LoadManifest  : ValidTransition Empty ManifestLoaded
  Generate      : ValidTransition ManifestLoaded Generated
  Regenerate    : ValidTransition Generated Generated
  Validate      : ValidTransition Generated Validated
  Apply         : ValidTransition Validated Applied
  CleanApplied  : ValidTransition Applied Empty
  CleanReady    : ValidTransition Validated Empty
  ManifestErr   : ValidTransition ManifestLoaded K9Error
  GenerateErr   : ValidTransition Generated K9Error
  Recover       : ValidTransition K9Error Empty

||| Runtime transition validator (matches the Zig FFI isValidTransition).
public export
canTransition : K9State -> K9State -> Bool
canTransition Empty          ManifestLoaded = True
canTransition ManifestLoaded  Generated     = True
canTransition Generated       Generated     = True   -- regenerate
canTransition Generated       Validated     = True
canTransition Validated       Applied       = True
canTransition Applied         Empty         = True   -- clean
canTransition Validated       Empty         = True   -- clean without applying
canTransition ManifestLoaded  K9Error       = True   -- parse error
canTransition Generated       K9Error       = True   -- generation error
canTransition K9Error         Empty         = True   -- recover
canTransition _               _             = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Config Format Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Config formats k9iser can wrap (mirrors k9iser's ConfigFormat).
public export
data K9Format
  = Toml
  | Yaml
  | Json
  | Ini
  | Custom String

||| C-ABI encoding.
public export
formatToInt : K9Format -> Int
formatToInt Toml       = 1
formatToInt Yaml       = 2
formatToInt Json       = 3
formatToInt Ini        = 4
formatToInt (Custom _) = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
public export
data McpTool
  = ToolLoadManifest   -- Load the k9iser.toml manifest
  | ToolGenerate       -- Generate K9 contracts from configs
  | ToolValidate       -- Validate contracts (K9! magic + pedigree)
  | ToolApply          -- Commit + push regenerated contracts
  | ToolClean          -- Clean the session
  | ToolStatus         -- Pipeline health check

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolLoadManifest = "k9/load_manifest"
toolName ToolGenerate     = "k9/generate"
toolName ToolValidate     = "k9/validate"
toolName ToolApply        = "k9/apply"
toolName ToolClean        = "k9/clean"
toolName ToolStatus       = "k9/status"

||| Which tools require generated contracts already present.
||| Validate and Apply both require a successful generate first.
public export
toolRequiresGenerate : McpTool -> Bool
toolRequiresGenerate ToolValidate = True
toolRequiresGenerate ToolApply    = True
toolRequiresGenerate _            = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| K9 state to integer.
public export
k9StateToInt : K9State -> Int
k9StateToInt Empty          = 0
k9StateToInt ManifestLoaded = 1
k9StateToInt Generated      = 2
k9StateToInt Validated      = 3
k9StateToInt Applied        = 4
k9StateToInt K9Error        = 5

||| FFI: Validate a state transition.
export
k9_can_transition : Int -> Int -> Int
k9_can_transition from to =
  let fromState = case from of
                    0 => Empty
                    1 => ManifestLoaded
                    2 => Generated
                    3 => Validated
                    4 => Applied
                    _ => K9Error
      toState = case to of
                  0 => Empty
                  1 => ManifestLoaded
                  2 => Generated
                  3 => Validated
                  4 => Applied
                  _ => K9Error
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires generated contracts.
export
k9_tool_requires_generate : Int -> Int
k9_tool_requires_generate 2 = 1  -- ToolValidate
k9_tool_requires_generate 3 = 1  -- ToolApply
k9_tool_requires_generate _ = 0  -- All others do not

-- ═══════════════════════════════════════════════════════════════════════════
-- Exposure / transaction-gating contract (BoJ interface-safety policy)
-- ═══════════════════════════════════════════════════════════════════════════
-- A port boundary must never be a gatekeeperless gateway: every adapter
-- exposes the unified ABI ONLY behind this transaction gate. Mirrors
-- BojRest.TrustPolicy: caller exposure derived from the cartridge's
-- auth.method, loopback callers locally trusted, X-Trust-Level enforced.

||| Caller trust the gateway/sidecar has established.
public export
data Exposure = Public | Authenticated | Internal

||| Required exposure inferred from cartridge auth.method.
||| "none"/absent → Public; any credential-bearing method → Authenticated.
public export
requiredExposure : (authMethodIsNone : Bool) -> Exposure
requiredExposure True  = Public
requiredExposure False = Authenticated

||| The transaction gate. Loopback callers are locally trusted (mcp-bridge,
||| local curl). Otherwise the presented X-Trust-Level must meet the
||| required exposure. This is the total relation the Zig transaction layer
||| mirrors; no dispatch may occur unless it returns True.
public export
exposureSatisfied : (required : Exposure) -> (presented : Exposure) -> (isLocal : Bool) -> Bool
exposureSatisfied _             _             True  = True
exposureSatisfied Public        _             _     = True
exposureSatisfied Authenticated Authenticated _     = True
exposureSatisfied Authenticated Internal      _     = True
exposureSatisfied Internal      Internal      _     = True
exposureSatisfied _             _             _     = False

||| FFI: 1 if dispatch is permitted, 0 if the gate rejects.
||| req/pres encoding: 0=Public 1=Authenticated 2=Internal; isLocal: 1/0.
export
k9_exposure_satisfied : Int -> Int -> Int -> Int
k9_exposure_satisfied req pres isLocal =
  let r = case req  of { 0 => Public; 1 => Authenticated; _ => Internal }
      p = case pres of { 0 => Public; 1 => Authenticated; _ => Internal }
  in if exposureSatisfied r p (isLocal /= 0) then 1 else 0
