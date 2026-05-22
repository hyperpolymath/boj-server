-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- AffinescriptMcp.SafeCompiler — Type-safe ABI for affinescript-mcp cartridge.
--
-- Dependent-type state machine governing AffineScript compiler invocations.
-- Encodes type checking, parsing, formatting, error explanation,
-- stdlib browsing, syntax reference, and snippet evaluation
-- as compile-time invariants.
-- Local compiler: `affinescript` CLI (OCaml)
-- No auth required — local tool invocation.

module AffinescriptMcp.SafeCompiler

%default total

-- ---------------------------------------------------------------------------
-- Session state machine
-- ---------------------------------------------------------------------------

||| Session state for AffineScript MCP operations.
||| Ready:       compiler available, ready for invocations.
||| Busy:        compiler invocation in progress.
||| Error:       compiler not found or crashed.
public export
data SessionState
  = Ready
  | Busy
  | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  StartInvocation : ValidTransition Ready Busy
  FinishSuccess   : ValidTransition Busy Ready
  FinishError     : ValidTransition Busy Error
  Recover         : ValidTransition Error Ready

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Ready = 0
sessionStateToInt Busy  = 1
sessionStateToInt Error = 2

||| Decode integer back to session state.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Ready
intToSessionState 1 = Just Busy
intToSessionState 2 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
afs_mcp_can_transition : Int -> Int -> Int
afs_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Ready, Just Busy)  => 1
    (Just Busy,  Just Ready) => 1
    (Just Busy,  Just Error) => 1
    (Just Error, Just Ready) => 1
    _                        => 0

-- ---------------------------------------------------------------------------
-- Compiler actions
-- ---------------------------------------------------------------------------

||| Actions available through the AffineScript MCP cartridge.
public export
data CompilerAction
  = Check
  | Parse
  | Format
  | ExplainError
  | StdlibSearch
  | SyntaxRef
  | EvalSnippet

||| Whether an action requires authentication.
||| Local compiler — no auth needed.
export
actionRequiresAuth : CompilerAction -> Bool
actionRequiresAuth _ = False

||| Whether an action mutates state.
||| All actions are read-only compiler queries.
export
actionIsMutating : CompilerAction -> Bool
actionIsMutating _ = False

||| Whether an action invokes the external compiler.
||| Some actions (ExplainError, StdlibSearch, SyntaxRef) are pure lookups.
export
actionNeedsCompiler : CompilerAction -> Bool
actionNeedsCompiler Check       = True
actionNeedsCompiler Parse       = True
actionNeedsCompiler Format      = False
actionNeedsCompiler ExplainError = False
actionNeedsCompiler StdlibSearch = False
actionNeedsCompiler SyntaxRef   = False
actionNeedsCompiler EvalSnippet = True

||| Encode action as C-compatible integer for FFI.
export
actionToInt : CompilerAction -> Int
actionToInt Check        = 0
actionToInt Parse        = 1
actionToInt Format       = 2
actionToInt ExplainError = 3
actionToInt StdlibSearch = 4
actionToInt SyntaxRef    = 5
actionToInt EvalSnippet  = 6

||| Decode integer to compiler action.
export
intToAction : Int -> Maybe CompilerAction
intToAction 0 = Just Check
intToAction 1 = Just Parse
intToAction 2 = Just Format
intToAction 3 = Just ExplainError
intToAction 4 = Just StdlibSearch
intToAction 5 = Just SyntaxRef
intToAction 6 = Just EvalSnippet
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol.
public export
data McpTool
  = ToolCheck
  | ToolParse
  | ToolFormat
  | ToolExplainError
  | ToolStdlib
  | ToolSyntaxRef
  | ToolSnippet

||| Check if a tool needs the compiler subprocess.
export
toolNeedsCompiler : McpTool -> Bool
toolNeedsCompiler ToolCheck      = True
toolNeedsCompiler ToolParse      = True
toolNeedsCompiler ToolFormat     = False
toolNeedsCompiler ToolExplainError = False
toolNeedsCompiler ToolStdlib     = False
toolNeedsCompiler ToolSyntaxRef  = False
toolNeedsCompiler ToolSnippet    = True

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 7

||| Total action count.
export
actionCount : Nat
actionCount = 7
