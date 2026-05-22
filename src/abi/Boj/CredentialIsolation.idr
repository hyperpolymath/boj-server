-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.CredentialIsolation: Per-cartridge credential-store isolation model (BJ2).
|||
||| This module closes the remaining BJ2 gap by modelling vault partitioning at
||| the type level. Each partition is indexed by cartridge name and only readable
||| through a token carrying the same index.
module Boj.CredentialIsolation

import Data.List
import Data.List.Elem
import Data.String
import Decidable.Equality
import Boj.SafeAPIKey

%default total

--------------------------------------------------------------------------------
-- Partitioned credential model
--------------------------------------------------------------------------------

||| A credential proven to belong to one cartridge partition.
public export
record ScopedCredential (cartridge : String) where
  constructor MkScopedCredential
  apiKey : SafeAPIKeyRecord
  scopeMatches : scope apiKey = CartridgeScope cartridge

||| Capability token authorising reads from exactly one partition.
public export
record VaultToken (cartridge : String) where
  constructor MkVaultToken

||| Partitioned credential store: each cartridge name maps to credentials that
||| are already proven to have that same cartridge scope.
public export
CredentialStore : Type
CredentialStore = (cartridge : String) -> List (ScopedCredential cartridge)

||| Empty store has no credentials in any partition.
export
emptyStore : CredentialStore
emptyStore _ = []

||| Insert into the owner's partition only.
export
insertCredential : {cartridge : String} ->
                   ScopedCredential cartridge ->
                   CredentialStore ->
                   CredentialStore
insertCredential {cartridge} cred store requester =
  case decEq requester cartridge of
    Yes Refl => cred :: store cartridge
    No _ => store requester

||| Read from the partition named by the caller token.
export
readPartition : {cartridge : String} ->
                VaultToken cartridge ->
                CredentialStore ->
                List (ScopedCredential cartridge)
readPartition {cartridge} _ store = store cartridge

--------------------------------------------------------------------------------
-- Core isolation theorems
--------------------------------------------------------------------------------

||| Scope witness carried by ScopedCredential is exactly the owner scope.
export
scopeMatchesPartition : {cartridge : String} ->
                       (cred : ScopedCredential cartridge) ->
                       scope (apiKey cred) = CartridgeScope cartridge
scopeMatchesPartition (MkScopedCredential _ scopeMatches) = scopeMatches

||| CartridgeScope constructor is injective.
export
cartridgeScopeInjective : CartridgeScope left = CartridgeScope right -> left = right
cartridgeScopeInjective Refl = Refl

||| If an external observation sees CartridgeScope observed for a credential,
||| then observed must match the credential's indexed owner.
export
partitionOwnerUnique :
  (cred : ScopedCredential owner) ->
  scope (apiKey cred) = CartridgeScope observed ->
  owner = observed
partitionOwnerUnique (MkScopedCredential _ scopeMatches) observedScope =
  cartridgeScopeInjective (trans (sym scopeMatches) observedScope)

||| Own-partition read sees a newly inserted credential.
export
ownReadSeesInserted :
  {owner : String} ->
  (token : VaultToken owner) ->
  (cred : ScopedCredential owner) ->
  (store : CredentialStore) ->
  Elem cred (readPartition token (insertCredential cred store))
ownReadSeesInserted {owner} _ cred store with (decEq owner owner)
  ownReadSeesInserted {owner} _ cred store | (Yes Refl) = Here
  ownReadSeesInserted {owner} _ cred store | (No contra) =
    absurd (contra Refl)

||| Cross-partition non-interference:
||| inserting into owner's partition does not change any other partition.
export
otherReadUnchanged :
  {requester : String} ->
  {owner : String} ->
  (token : VaultToken requester) ->
  (cred : ScopedCredential owner) ->
  (neq : requester = owner -> Void) ->
  (store : CredentialStore) ->
  readPartition token (insertCredential cred store) = readPartition token store
otherReadUnchanged {requester} {owner} _ cred neq store
    with (decEq requester owner)
  otherReadUnchanged {requester} {owner} _ cred neq store
      | (Yes eq) = absurd (neq eq)
  otherReadUnchanged {requester} {owner} _ cred neq store
      | (No _) = Refl

||| BJ2 closure theorem name for traceability in PROOF-NEEDS and standards docs.
export
vaultIsolation :
  {requester : String} ->
  {owner : String} ->
  (token : VaultToken requester) ->
  (cred : ScopedCredential owner) ->
  (neq : requester = owner -> Void) ->
  (store : CredentialStore) ->
  readPartition token (insertCredential cred store) = readPartition token store
vaultIsolation = otherReadUnchanged
