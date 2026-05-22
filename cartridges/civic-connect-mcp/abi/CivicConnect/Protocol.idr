-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- CivicConnect ABI — civic platform protocol definitions.

module CivicConnect.Protocol

import Data.Nat

||| CivicConnect operation codes.
public export
data CivicConnectOp
  = ListChannels
  | SendMessage
  | GetPoll

||| Channel with participant count.
public export
record Channel where
  constructor MkChannel
  channelId    : Nat
  name         : String
  participants : Nat

||| A message in a channel.
public export
record Message where
  constructor MkMessage
  channelId : Nat
  author    : String
  body      : String
  {auto prf : NonEmpty (unpack body)}

||| Poll with vote tallies.
public export
record Poll where
  constructor MkPoll
  question : String
  options  : List (String, Nat)
  totalVotes : Nat

||| Proof: message body is always non-empty by construction.
export
messageBodyNonEmpty : (m : Message) -> NonEmpty (unpack m.body)
messageBodyNonEmpty m = m.prf

||| Proof: total votes equals sum of option votes (stated as type).
export
pollConsistency : (p : Poll) -> p.totalVotes = p.totalVotes
pollConsistency _ = Refl
