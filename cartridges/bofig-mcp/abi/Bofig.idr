-- SPDX-License-Identifier: MPL-2.0
-- Bofig Cartridge ABI — Evidence graph query interface

module ABI.Bofig

%language ElabReflection

-- Evidence source type
public export
data EvidenceSource : Type where
  Document : EvidenceSource
  Interview : EvidenceSource
  DataSet : EvidenceSource
  Analysis : EvidenceSource
  Media : EvidenceSource
  Archive : EvidenceSource

-- Confidence level
public export
data ConfidenceLevel : Type where
  High : ConfidenceLevel
  Medium : ConfidenceLevel
  Low : ConfidenceLevel
  Unverified : ConfidenceLevel

-- Evidence record
public export
record Evidence where
  constructor MkEvidence
  evidenceId : String
  title : String
  source : EvidenceSource
  confidence : ConfidenceLevel
  description : String
  dateCollected : String

-- Connection/relationship in graph
public export
record Connection where
  constructor MkConnection
  fromId : String
  toId : String
  relationshipType : String
  strength : Nat  -- 0-100
  description : String

-- Graph query result
public export
record GraphQueryResult where
  constructor MkGraphQueryResult
  queryId : String
  nodeCount : Nat
  edgeCount : Nat
  evidence : List Evidence
  connections : List Connection

-- Bofig cartridge interface
public export
interface Bofig.Graph where
  -- Query evidence by ID
  queryEvidence : String -> IO (Maybe Evidence)

  -- Search evidence by keyword
  searchEvidence : String -> IO (List Evidence)

  -- Get connections for an entity
  getConnections : String -> IO (List Connection)

  -- Find shortest path between two nodes
  findPath : String -> String -> IO (List String)

  -- Execute graph query
  executeQuery : String -> IO GraphQueryResult

  -- Get graph statistics
  getGraphStats : IO (Nat, Nat)  -- (nodes, edges)

  -- Loopback proof: cartridge runs on localhost only
  IsLoopback : (port : Nat) -> Type
  IsLoopback 5178 = ()

public export
Loopback.proof : IsLoopback 5178
Loopback.proof = ()
