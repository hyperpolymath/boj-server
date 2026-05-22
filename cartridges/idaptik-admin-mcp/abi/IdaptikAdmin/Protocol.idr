-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Protocol: IDApTIK game administration via BoJ MCP
|||
||| Cartridge: idaptik-admin
||| Matrix cell: Game Platform x Administration
|||
||| Defines the formal interface for managing IDApTIK game instances,
||| levels, and player data through the BoJ Server. Proves that:
|||   1. Level data modifications require admin authority
|||   2. Player data access is permission-scoped
|||   3. Sync operations are idempotent
module IdaptikAdmin.Protocol

import Data.Fin

%default total

-- ═══════════════════════════════════════════════════════════════════════
-- Core Types
-- ═══════════════════════════════════════════════════════════════════════

||| Administrative operation on an IDApTIK instance
public export
data Operation
  = ListLevels         -- List available levels
  | GetLevelState      -- Get a level's current state
  | UpdateLevel        -- Modify level configuration
  | ListPlayers        -- List active players
  | GetPlayerProgress  -- Get player progression data
  | SyncServer         -- Trigger sync server operation
  | GetDiagnostics     -- Get game server diagnostics

||| Permission level for IDApTIK admin ops
public export
data PermLevel = Observer | LevelDesigner | GameAdmin

||| Minimum permission per operation
public export
data RequiresPermission : Operation -> PermLevel -> Type where
  ListLevelsObs       : RequiresPermission ListLevels Observer
  GetLevelStateObs    : RequiresPermission GetLevelState Observer
  UpdateLevelDesigner : RequiresPermission UpdateLevel LevelDesigner
  ListPlayersObs      : RequiresPermission ListPlayers Observer
  GetProgressObs      : RequiresPermission GetPlayerProgress Observer
  SyncAdmin           : RequiresPermission SyncServer GameAdmin
  DiagnosticsObs      : RequiresPermission GetDiagnostics Observer

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports
-- ═══════════════════════════════════════════════════════════════════════

export
operationToInt : Operation -> Int
operationToInt ListLevels        = 0
operationToInt GetLevelState     = 1
operationToInt UpdateLevel       = 2
operationToInt ListPlayers       = 3
operationToInt GetPlayerProgress = 4
operationToInt SyncServer        = 5
operationToInt GetDiagnostics    = 6

export
idaptik_min_perm : Int -> Int
idaptik_min_perm 0 = 0  -- ListLevels → Observer
idaptik_min_perm 1 = 0  -- GetLevelState → Observer
idaptik_min_perm 2 = 1  -- UpdateLevel → LevelDesigner
idaptik_min_perm 3 = 0  -- ListPlayers → Observer
idaptik_min_perm 4 = 0  -- GetPlayerProgress → Observer
idaptik_min_perm 5 = 2  -- SyncServer → GameAdmin
idaptik_min_perm 6 = 0  -- GetDiagnostics → Observer
idaptik_min_perm _ = 2  -- Unknown → require Admin
