-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.Protocol: Protocol type definitions for the 2D capability matrix.
|||
||| These are the COLUMNS of the matrix — how you talk to a server.
||| Each protocol type represents a wire protocol that cartridges can expose.
module Boj.Protocol

%default total

||| Protocol types supported by BoJ cartridges.
||| These form the columns of the 2D capability matrix.
public export
data ProtocolType
  = MCP       -- Model Context Protocol (AI tool integration)
  | LSP       -- Language Server Protocol (editor integration)
  | DAP       -- Debug Adapter Protocol (debugger integration)
  | BSP       -- Build Server Protocol (build system integration)
  | NeSy      -- Neurosymbolic Protocol (proven-neurosym)
  | Agentic   -- Agentic Protocol (proven-agentic, OODA loops)
  | Fleet     -- Fleet Protocol (gitbot-fleet orchestration)
  | GRPC      -- gRPC (high-performance RPC)
  | REST      -- REST/HTTP (universal fallback)

||| Human-readable label for display in the Teranga menu.
public export
protocolLabel : ProtocolType -> String
protocolLabel MCP     = "MCP"
protocolLabel LSP     = "LSP"
protocolLabel DAP     = "DAP"
protocolLabel BSP     = "BSP"
protocolLabel NeSy    = "NeSy"
protocolLabel Agentic = "Agentic"
protocolLabel Fleet   = "Fleet"
protocolLabel GRPC    = "gRPC"
protocolLabel REST    = "REST"

||| C-ABI encoding: protocol type to integer.
public export
protocolToInt : ProtocolType -> Int
protocolToInt MCP     = 1
protocolToInt LSP     = 2
protocolToInt DAP     = 3
protocolToInt BSP     = 4
protocolToInt NeSy    = 5
protocolToInt Agentic = 6
protocolToInt Fleet   = 7
protocolToInt GRPC    = 8
protocolToInt REST    = 9

||| C-ABI decoding: integer to protocol type (with safe default).
public export
intToProtocol : Int -> Maybe ProtocolType
intToProtocol 1 = Just MCP
intToProtocol 2 = Just LSP
intToProtocol 3 = Just DAP
intToProtocol 4 = Just BSP
intToProtocol 5 = Just NeSy
intToProtocol 6 = Just Agentic
intToProtocol 7 = Just Fleet
intToProtocol 8 = Just GRPC
intToProtocol 9 = Just REST
intToProtocol _ = Nothing

||| Equality for protocol types (needed for list membership checks).
public export
Eq ProtocolType where
  MCP     == MCP     = True
  LSP     == LSP     = True
  DAP     == DAP     = True
  BSP     == BSP     = True
  NeSy    == NeSy    = True
  Agentic == Agentic = True
  Fleet   == Fleet   = True
  GRPC    == GRPC    = True
  REST    == REST    = True
  _       == _       = False
