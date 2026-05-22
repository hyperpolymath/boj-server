-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Protocol: Game Server Administration via BoJ MCP
|||
||| Cartridge: game-admin
||| Matrix cell: Game Servers x Administration
|||
||| Defines the formal interface for managing dedicated game servers
||| (DST, Void Expanse, etc.) through the BoJ Server. Proves that:
|||   1. Server lifecycle operations are admin-only
|||   2. Probe operations are safe (read-only)
|||   3. Config changes require explicit confirmation
module GameAdmin.Protocol

import Data.Fin

%default total

-- ═══════════════════════════════════════════════════════════════════════
-- Core Types
-- ═══════════════════════════════════════════════════════════════════════

||| Administrative operation on a game server
public export
data Operation
  = ListServers        -- List managed game servers
  | GetServerStatus    -- Get server health/status
  | StartServer        -- Start a game server
  | StopServer         -- Stop a game server
  | RestartServer      -- Restart a game server
  | UpdateConfig       -- Modify server configuration
  | GetLogs            -- Retrieve server logs
  | ProbeHealth        -- Quick health probe (Groove)

||| Permission level for game admin ops
public export
data PermLevel = Viewer | Operator | Admin

||| Operations that are read-only (safe to call without side effects)
public export
data IsReadOnly : Operation -> Type where
  ListReadOnly   : IsReadOnly ListServers
  StatusReadOnly : IsReadOnly GetServerStatus
  LogsReadOnly   : IsReadOnly GetLogs
  ProbeReadOnly  : IsReadOnly ProbeHealth

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports
-- ═══════════════════════════════════════════════════════════════════════

export
operationToInt : Operation -> Int
operationToInt ListServers    = 0
operationToInt GetServerStatus = 1
operationToInt StartServer    = 2
operationToInt StopServer     = 3
operationToInt RestartServer  = 4
operationToInt UpdateConfig   = 5
operationToInt GetLogs        = 6
operationToInt ProbeHealth    = 7

export
game_min_perm : Int -> Int
game_min_perm 0 = 0  -- ListServers → Viewer
game_min_perm 1 = 0  -- GetServerStatus → Viewer
game_min_perm 2 = 1  -- StartServer → Operator
game_min_perm 3 = 1  -- StopServer → Operator
game_min_perm 4 = 1  -- RestartServer → Operator
game_min_perm 5 = 2  -- UpdateConfig → Admin
game_min_perm 6 = 0  -- GetLogs → Viewer
game_min_perm 7 = 0  -- ProbeHealth → Viewer
game_min_perm _ = 2  -- Unknown → require Admin

||| Check if operation is read-only (C ABI: 1=yes, 0=no)
export
game_is_readonly : Int -> Int
game_is_readonly 0 = 1  -- ListServers
game_is_readonly 1 = 1  -- GetServerStatus
game_is_readonly 6 = 1  -- GetLogs
game_is_readonly 7 = 1  -- ProbeHealth
game_is_readonly _ = 0  -- All others have side effects
