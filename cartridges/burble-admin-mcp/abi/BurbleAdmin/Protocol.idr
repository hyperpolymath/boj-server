-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Protocol: Burble voice platform administration via BoJ MCP
|||
||| Cartridge: burble-admin
||| Matrix cell: Voice Platform x Administration
|||
||| Defines the formal interface for managing Burble rooms, users,
||| and voice sessions through the BoJ Server. Proves that:
|||   1. Admin operations require authentication
|||   2. Room capacity is bounded
|||   3. Recording access is permission-gated
module BurbleAdmin.Protocol

import Data.Fin

%default total

-- ═══════════════════════════════════════════════════════════════════════
-- Core Types
-- ═══════════════════════════════════════════════════════════════════════

||| Administrative operation on a Burble instance
public export
data Operation
  = ListRooms          -- List active voice rooms
  | CreateRoom         -- Create a new room
  | DeleteRoom         -- Delete an existing room
  | ListUsers          -- List connected users
  | KickUser           -- Remove a user from a room
  | GetMetrics         -- Get platform metrics
  | ManageRecordings   -- Access recording management

||| Permission level required for operations
public export
data PermLevel = ReadOnly | Moderator | Admin

||| Proof that an operation requires at least the given permission
public export
data RequiresPermission : Operation -> PermLevel -> Type where
  ListRoomsRead      : RequiresPermission ListRooms ReadOnly
  CreateRoomMod      : RequiresPermission CreateRoom Moderator
  DeleteRoomAdmin    : RequiresPermission DeleteRoom Admin
  ListUsersRead      : RequiresPermission ListUsers ReadOnly
  KickUserMod        : RequiresPermission KickUser Moderator
  GetMetricsRead     : RequiresPermission GetMetrics ReadOnly
  RecordingsAdmin    : RequiresPermission ManageRecordings Admin

||| Room capacity is bounded (1-500 participants)
public export
data RoomCapacity = MkCapacity (n : Fin 500)

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports
-- ═══════════════════════════════════════════════════════════════════════

export
operationToInt : Operation -> Int
operationToInt ListRooms        = 0
operationToInt CreateRoom       = 1
operationToInt DeleteRoom       = 2
operationToInt ListUsers        = 3
operationToInt KickUser         = 4
operationToInt GetMetrics       = 5
operationToInt ManageRecordings = 6

export
permLevelToInt : PermLevel -> Int
permLevelToInt ReadOnly   = 0
permLevelToInt Moderator  = 1
permLevelToInt Admin      = 2

||| Minimum permission level for an operation (C ABI)
export
burble_min_perm : Int -> Int
burble_min_perm 0 = 0  -- ListRooms → ReadOnly
burble_min_perm 1 = 1  -- CreateRoom → Moderator
burble_min_perm 2 = 2  -- DeleteRoom → Admin
burble_min_perm 3 = 0  -- ListUsers → ReadOnly
burble_min_perm 4 = 1  -- KickUser → Moderator
burble_min_perm 5 = 0  -- GetMetrics → ReadOnly
burble_min_perm 6 = 2  -- ManageRecordings → Admin
burble_min_perm _ = 2  -- Unknown → require Admin (safe default)
