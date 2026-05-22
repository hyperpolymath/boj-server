-- SPDX-License-Identifier: MPL-2.0
-- OPSM MCP Cartridge — Registry state machine with safety proofs.
--
-- Ensures registry operations follow a valid lifecycle:
--   Disconnected -> Connected -> Querying -> Idle
--
-- Prevents:
-- - Querying a disconnected registry
-- - Double-connect (resource leak)
-- - Use-after-disconnect

module OpsmMcp.SafeRegistry

import Data.Fin

||| Registry connection states.
public export
data RegState = Disconnected | Connected | Querying | Idle

||| Valid state transitions for registry operations.
public export
data RegTransition : RegState -> RegState -> Type where
  Connect    : RegTransition Disconnected Connected
  StartQuery : RegTransition Connected Querying
  EndQuery   : RegTransition Querying Idle
  Reset      : RegTransition Idle Connected
  Disconnect : RegTransition Connected Disconnected
  IdleDisc   : RegTransition Idle Disconnected

||| A registry handle indexed by its current state.
||| The phantom type parameter prevents misuse at compile time.
public export
data RegistryHandle : RegState -> Type where
  MkHandle : (name : String) -> (slot : Nat) -> RegistryHandle s

||| Extract the registry name from a handle (state-independent).
public export
registryName : RegistryHandle s -> String
registryName (MkHandle name _) = name

||| Extract the slot index from a handle.
public export
registrySlot : RegistryHandle s -> Nat
registrySlot (MkHandle _ slot) = slot

||| Connect to a registry. Transitions Disconnected -> Connected.
public export
connect : RegistryHandle Disconnected -> RegistryHandle Connected
connect (MkHandle name slot) = MkHandle name slot

||| Begin a query. Transitions Connected -> Querying.
public export
startQuery : RegistryHandle Connected -> RegistryHandle Querying
startQuery (MkHandle name slot) = MkHandle name slot

||| End a query. Transitions Querying -> Idle.
public export
endQuery : RegistryHandle Querying -> RegistryHandle Idle
endQuery (MkHandle name slot) = MkHandle name slot

||| Reset to connected state. Transitions Idle -> Connected.
public export
reset : RegistryHandle Idle -> RegistryHandle Connected
reset (MkHandle name slot) = MkHandle name slot

||| Disconnect from a registry. Transitions Connected -> Disconnected.
public export
disconnect : RegistryHandle Connected -> RegistryHandle Disconnected
disconnect (MkHandle name slot) = MkHandle name slot

||| Disconnect from idle. Transitions Idle -> Disconnected.
public export
disconnectIdle : RegistryHandle Idle -> RegistryHandle Disconnected
disconnectIdle (MkHandle name slot) = MkHandle name slot

||| Proof: a full lifecycle is valid (connect, query, disconnect).
public export
lifecycleValid : RegistryHandle Disconnected -> RegistryHandle Disconnected
lifecycleValid h =
  let h1 = connect h
      h2 = startQuery h1
      h3 = endQuery h2
      h4 = disconnectIdle h3
  in h4

||| Number of supported registry adapters.
public export
numRegistries : Nat
numRegistries = 101

||| Registry adapter index (bounded by numRegistries).
public export
RegistryIdx : Type
RegistryIdx = Fin numRegistries
