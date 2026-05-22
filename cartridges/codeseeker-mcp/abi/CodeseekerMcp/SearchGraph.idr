-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| CodeseekerMcp.SearchGraph: Formally verified code intelligence operations.
|||
||| Cartridge: codeseeker-mcp
||| Matrix cell: Code Intelligence domain x {MCP, REST} protocols
|||
||| This module defines type-safe interfaces for CodeSeeker's local code
||| intelligence capabilities:
|||   - Hybrid search (vector + text + path, fused via Reciprocal Rank Fusion)
|||   - Knowledge graph traversal (imports, calls, extends, implements)
|||   - Auto-detected pattern retrieval
|||   - Graph RAG context retrieval
|||
||| State machine prevents:
|||   - Searches before a codebase is indexed
|||   - Graph traversal on uninitialised indices
|||   - Concurrent index operations on the same path
|||
||| CodeSeeker stores all data locally in .codeseeker/ — no external services.
module CodeseekerMcp.SearchGraph

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Indexer State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Lifecycle states for a CodeSeeker index session.
||| Uninitialised: No index loaded for this path.
||| Indexing: Index is being built/updated (blocks queries).
||| Ready: Index is available for search and graph traversal.
||| Querying: A search or graph traversal is in flight.
||| IndexError: The indexer encountered an unrecoverable error.
public export
data IndexState
  = Uninitialised
  | Indexing
  | Ready
  | Querying
  | IndexError

||| Equality for index states.
public export
Eq IndexState where
  Uninitialised == Uninitialised = True
  Indexing      == Indexing      = True
  Ready         == Ready         = True
  Querying      == Querying      = True
  IndexError    == IndexError    = True
  _             == _             = False

||| Valid state transitions (enforced at the type level).
||| Uninitialised -> Indexing  : start an index build
||| Indexing      -> Ready     : index build succeeded
||| Indexing      -> IndexError: index build failed
||| Ready         -> Querying  : begin a search or traversal
||| Querying      -> Ready     : query completed
||| Querying      -> IndexError: query failed
||| IndexError    -> Uninitialised : reset to try again
public export
data ValidIndexTransition : IndexState -> IndexState -> Type where
  StartIndex    : ValidIndexTransition Uninitialised Indexing
  IndexComplete : ValidIndexTransition Indexing      Ready
  IndexFail     : ValidIndexTransition Indexing      IndexError
  BeginQuery    : ValidIndexTransition Ready          Querying
  QueryDone     : ValidIndexTransition Querying       Ready
  QueryFail     : ValidIndexTransition Querying       IndexError
  ResetError    : ValidIndexTransition IndexError     Uninitialised

||| Runtime transition validator.
public export
canIndexTransition : IndexState -> IndexState -> Bool
canIndexTransition Uninitialised Indexing      = True
canIndexTransition Indexing      Ready         = True
canIndexTransition Indexing      IndexError    = True
canIndexTransition Ready         Querying      = True
canIndexTransition Querying      Ready         = True
canIndexTransition Querying      IndexError    = True
canIndexTransition IndexError    Uninitialised = True
canIndexTransition _             _             = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Search Mode
-- ═══════════════════════════════════════════════════════════════════════════

||| Search strategies available in CodeSeeker.
||| Vector: Semantic similarity via embeddings.
||| Text: Literal/regex text matching.
||| Path: File path pattern matching.
||| Hybrid: All three fused with Reciprocal Rank Fusion.
public export
data SearchMode
  = Vector   -- Semantic embedding similarity
  | Text     -- Literal / regex text search
  | Path     -- File path pattern match
  | Hybrid   -- RRF fusion of all three

||| C-ABI encoding for search modes.
public export
searchModeToInt : SearchMode -> Int
searchModeToInt Vector = 1
searchModeToInt Text   = 2
searchModeToInt Path   = 3
searchModeToInt Hybrid = 4

||| C-ABI decoding for search modes.
public export
intToSearchMode : Int -> Maybe SearchMode
intToSearchMode 1 = Just Vector
intToSearchMode 2 = Just Text
intToSearchMode 3 = Just Path
intToSearchMode 4 = Just Hybrid
intToSearchMode _ = Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- Knowledge Graph Relationship Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Edge types in CodeSeeker's knowledge graph.
||| These correspond to structural relationships in source code.
public export
data GraphRelation
  = Imports     -- Module/file imports another
  | Calls       -- Function/method calls another
  | Extends     -- Class extends a base class
  | Implements  -- Class implements an interface
  | Uses        -- Generic usage / reference relationship

||| C-ABI encoding for graph relations.
public export
relationToInt : GraphRelation -> Int
relationToInt Imports    = 1
relationToInt Calls      = 2
relationToInt Extends    = 3
relationToInt Implements = 4
relationToInt Uses       = 5

||| C-ABI decoding for graph relations.
public export
intToRelation : Int -> Maybe GraphRelation
intToRelation 1 = Just Imports
intToRelation 2 = Just Calls
intToRelation 3 = Just Extends
intToRelation 4 = Just Implements
intToRelation 5 = Just Uses
intToRelation _ = Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- Index Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| An active CodeSeeker index session for a codebase path.
public export
record IndexSession where
  constructor MkIndexSession
  sessionId    : String    -- Unique session identifier
  codebasePath : String    -- Absolute path to the indexed codebase
  state        : IndexState
  fileCount    : Nat       -- Number of files in the index (0 if not Ready)

||| Proof that an index session is ready for querying.
public export
data IsReady : IndexSession -> Type where
  IndexReady : (s : IndexSession) ->
               (state s = Ready) ->
               IsReady s

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by the codeseeker-mcp cartridge.
public export
data McpTool
  = ToolIndex       -- Index a codebase at a given path
  | ToolSearch      -- Hybrid search (vector + text + path)
  | ToolTraverse    -- Traverse knowledge graph from a symbol
  | ToolPatterns    -- Retrieve auto-detected coding patterns
  | ToolGraphRag    -- Graph RAG context for a query
  | ToolStatus      -- Session and index status

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolIndex    = "codeseeker/index"
toolName ToolSearch   = "codeseeker/search"
toolName ToolTraverse = "codeseeker/traverse"
toolName ToolPatterns = "codeseeker/patterns"
toolName ToolGraphRag = "codeseeker/graph-rag"
toolName ToolStatus   = "codeseeker/status"

||| Which tools require a Ready index (cannot run during Indexing).
public export
requiresReadyIndex : McpTool -> Bool
requiresReadyIndex ToolIndex    = False
requiresReadyIndex ToolStatus   = False
requiresReadyIndex _            = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Index state to integer.
public export
indexStateToInt : IndexState -> Int
indexStateToInt Uninitialised = 0
indexStateToInt Indexing      = 1
indexStateToInt Ready         = 2
indexStateToInt Querying      = 3
indexStateToInt IndexError    = 4

||| FFI: Validate an index state transition.
export
codeseeker_can_transition : Int -> Int -> Int
codeseeker_can_transition from to =
  let fromState = case from of
                    0 => Uninitialised
                    1 => Indexing
                    2 => Ready
                    3 => Querying
                    _ => IndexError
      toState = case to of
                  0 => Uninitialised
                  1 => Indexing
                  2 => Ready
                  3 => Querying
                  _ => IndexError
  in if canIndexTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a ready index.
export
codeseeker_tool_requires_ready : Int -> Int
codeseeker_tool_requires_ready 1 = 0  -- ToolIndex
codeseeker_tool_requires_ready 6 = 0  -- ToolStatus
codeseeker_tool_requires_ready _ = 1  -- All others require Ready
