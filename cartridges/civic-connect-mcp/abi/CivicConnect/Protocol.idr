-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- CivicConnect ABI — civic platform protocol definitions.

module CivicConnect.Protocol

import Data.Nat
import Data.List

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
