-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ SafeWebSocket — Formal verification of WebSocket transport safety
module Boj.SafeWebSocket

import Data.List
import Data.Nat
import Data.String
import Boj.SafetyLemmas

%default total

--------------------------------------------------------------------------------
-- WebSocket Frame Types (RFC 6455 §5.2)
--------------------------------------------------------------------------------

public export
data WSOpcode : Type where
  Continuation : WSOpcode
  TextFrame    : WSOpcode
  BinaryFrame  : WSOpcode
  CloseFrame   : WSOpcode
  PingFrame    : WSOpcode
  PongFrame    : WSOpcode

public export
isDataFrame : WSOpcode -> Bool
isDataFrame Continuation = True
isDataFrame TextFrame    = True
isDataFrame BinaryFrame  = True
isDataFrame _            = False

public export
isControlFrame : WSOpcode -> Bool
isControlFrame CloseFrame = True
isControlFrame PingFrame  = True
isControlFrame PongFrame  = True
isControlFrame _          = False

export
dataOrControl : (op : WSOpcode) -> Either (isDataFrame op = True) (isControlFrame op = True)
dataOrControl Continuation = Left Refl
dataOrControl TextFrame    = Left Refl
dataOrControl BinaryFrame  = Left Refl
dataOrControl CloseFrame   = Right Refl
dataOrControl PingFrame    = Right Refl
dataOrControl PongFrame    = Right Refl

export
dataNotControl : (op : WSOpcode) -> isDataFrame op = True -> isControlFrame op = False
dataNotControl Continuation Refl = Refl
dataNotControl TextFrame Refl = Refl
dataNotControl BinaryFrame Refl = Refl

export
controlNotData : (op : WSOpcode) -> isControlFrame op = True -> isDataFrame op = False
controlNotData CloseFrame Refl = Refl
controlNotData PingFrame Refl = Refl
controlNotData PongFrame Refl = Refl

export
dataControlExclusive : (op : WSOpcode) ->
                       isDataFrame op = True ->
                       isControlFrame op = True ->
                       Void
dataControlExclusive op dPrf cPrf =
  let contra = dataNotControl op dPrf
  in trueNotFalse (trans (sym cPrf) contra)

--------------------------------------------------------------------------------
-- Connection State Machine
--------------------------------------------------------------------------------

public export
data WSState : Type where
  Connecting : WSState
  Open       : WSState
  Closing    : WSState
  Closed     : WSState

public export
data WSTransition : WSState -> WSState -> Type where
  HandshakeComplete : WSTransition Connecting Open
  InitiateClose     : WSTransition Open Closing
  ReceiveClose      : WSTransition Open Closing
  CloseComplete     : WSTransition Closing Closed
  AbortConnection   : WSTransition Open Closed
  AbortHandshake    : WSTransition Connecting Closed

public export
data ValidLifecycle : WSState -> WSState -> Type where
  Done : ValidLifecycle s s
  Step : WSTransition s1 s2 -> ValidLifecycle s2 s3 -> ValidLifecycle s1 s3

export
normalLifecycle : ValidLifecycle Connecting Closed
normalLifecycle = Step HandshakeComplete (Step InitiateClose (Step CloseComplete Done))

export
abortedHandshakeLifecycle : ValidLifecycle Connecting Closed
abortedHandshakeLifecycle = Step AbortHandshake Done

export
abnormalClosureLifecycle : ValidLifecycle Connecting Closed
abnormalClosureLifecycle = Step HandshakeComplete (Step AbortConnection Done)

export
composeLifecycles : ValidLifecycle s1 s2 -> ValidLifecycle s2 s3 -> ValidLifecycle s1 s3
composeLifecycles Done lc2 = lc2
composeLifecycles (Step t rest) lc2 = Step t (composeLifecycles rest lc2)

--------------------------------------------------------------------------------
-- Frame Size Safety
--------------------------------------------------------------------------------

public export
maxFrameSize : Nat
maxFrameSize = 16777216

public export
maxControlFrameSize : Nat
maxControlFrameSize = 125

||| A frame whose payload length `n` is bounded by an arbitrary `bound`.
|||
||| The bound is a *parameter*, deliberately not a baked-in literal: keeping it
||| symbolic in the constructor's `LTE n bound` index stops the elaborator from
||| forcing the 16 MiB `maxFrameSize` into unary form at data-declaration time
||| (which exhausts memory in Idris2 0.8.0). The concrete data- and control-frame
||| predicates are recovered as nullary type synonyms below — `maxFrameSize` then
||| appears only in an *application* position, which the elaborator handles lazily.
public export
data FrameSizeSafeUpTo : (bound : Nat) -> Nat -> Type where
  MkSizeSafe : (n : Nat) ->
               {auto prf : LTE n bound} ->
               FrameSizeSafeUpTo bound n

||| A data frame is size-safe when its length is within `maxFrameSize`.
public export
FrameSizeSafe : Nat -> Type
FrameSizeSafe = FrameSizeSafeUpTo Boj.SafeWebSocket.maxFrameSize

||| A control frame is size-safe when its length is within `maxControlFrameSize`.
public export
ControlFrameSizeSafe : Nat -> Type
ControlFrameSizeSafe = FrameSizeSafeUpTo Boj.SafeWebSocket.maxControlFrameSize

||| maxControlFrameSize (125) ≤ maxFrameSize (16 777 216).
maxControlLeqMaxFrame : LTE Boj.SafeWebSocket.maxControlFrameSize Boj.SafeWebSocket.maxFrameSize
maxControlLeqMaxFrame = lteReflectsLTE 125 16777216 Refl

||| Control-frame size-safety implies data-frame size-safety: a payload within
||| the 125-byte control limit is a fortiori within the data-frame limit. Proved
||| by transitivity of `LTE` (bound weakening), not by re-checking the literal.
export
controlImpliesFrameSafe : ControlFrameSizeSafe n -> FrameSizeSafe n
controlImpliesFrameSafe (MkSizeSafe n {prf}) =
  MkSizeSafe n {prf = transitive prf maxControlLeqMaxFrame}

export
emptyFrameSafe : FrameSizeSafe 0
emptyFrameSafe = MkSizeSafe 0 {prf = LTEZero}

export
emptyControlFrameSafe : ControlFrameSizeSafe 0
emptyControlFrameSafe = MkSizeSafe 0 {prf = LTEZero}

--------------------------------------------------------------------------------
-- Origin Validation
--------------------------------------------------------------------------------

public export
data WSOriginChecked : String -> Type where
  MkWSOriginChecked : (origin : String) ->
                      {auto nonEmpty : NonEmpty (unpack origin)} ->
                      WSOriginChecked origin

public export
data SecureHandshake : Type where
  MkSecureHandshake : (origin : String) ->
                      (0 _ : WSOriginChecked origin) ->
                      (0 _ : WSTransition Connecting Open) ->
                      SecureHandshake

export
0 secureHandshakeIsLifecycleStart : SecureHandshake -> ValidLifecycle Connecting Open
secureHandshakeIsLifecycleStart (MkSecureHandshake _ _ t) = Step t Done

--------------------------------------------------------------------------------
-- Close Code Safety
--------------------------------------------------------------------------------

public export
data WSCloseCode : Type where
  NormalClosure    : WSCloseCode
  GoingAway        : WSCloseCode
  ProtocolError    : WSCloseCode
  UnsupportedData  : WSCloseCode
  InvalidPayload   : WSCloseCode
  PolicyViolation  : WSCloseCode
  MessageTooBig    : WSCloseCode
  InternalError    : WSCloseCode

export
closeCodeToNat : WSCloseCode -> Nat
closeCodeToNat NormalClosure   = 1000
closeCodeToNat GoingAway       = 1001
closeCodeToNat ProtocolError   = 1002
closeCodeToNat UnsupportedData = 1003
closeCodeToNat InvalidPayload  = 1007
closeCodeToNat PolicyViolation = 1008
closeCodeToNat MessageTooBig   = 1009
closeCodeToNat InternalError   = 1011

export
parseCloseCode : Nat -> Maybe WSCloseCode
parseCloseCode 1000 = Just NormalClosure
parseCloseCode 1001 = Just GoingAway
parseCloseCode 1002 = Just ProtocolError
parseCloseCode 1003 = Just UnsupportedData
parseCloseCode 1007 = Just InvalidPayload
parseCloseCode 1008 = Just PolicyViolation
parseCloseCode 1009 = Just MessageTooBig
parseCloseCode 1011 = Just InternalError
parseCloseCode _    = Nothing

export
parseRoundtrips : (c : WSCloseCode) -> parseCloseCode (closeCodeToNat c) = Just c
parseRoundtrips NormalClosure   = Refl
parseRoundtrips GoingAway       = Refl
parseRoundtrips ProtocolError   = Refl
parseRoundtrips UnsupportedData = Refl
parseRoundtrips InvalidPayload  = Refl
parseRoundtrips PolicyViolation = Refl
parseRoundtrips MessageTooBig   = Refl
parseRoundtrips InternalError   = Refl

||| Every RFC 6455 close code lies in the range [1000, 1011].
||| Proofs constructed via lteReflectsLTE on the closed-form values.
export
closeCodeInRange : (c : WSCloseCode) -> (LTE 1000 (closeCodeToNat c), LTE (closeCodeToNat c) 1011)
closeCodeInRange NormalClosure   = (lteReflectsLTE 1000 1000 Refl, lteReflectsLTE 1000 1011 Refl)
closeCodeInRange GoingAway       = (lteReflectsLTE 1000 1001 Refl, lteReflectsLTE 1001 1011 Refl)
closeCodeInRange ProtocolError   = (lteReflectsLTE 1000 1002 Refl, lteReflectsLTE 1002 1011 Refl)
closeCodeInRange UnsupportedData = (lteReflectsLTE 1000 1003 Refl, lteReflectsLTE 1003 1011 Refl)
closeCodeInRange InvalidPayload  = (lteReflectsLTE 1000 1007 Refl, lteReflectsLTE 1007 1011 Refl)
closeCodeInRange PolicyViolation = (lteReflectsLTE 1000 1008 Refl, lteReflectsLTE 1008 1011 Refl)
closeCodeInRange MessageTooBig   = (lteReflectsLTE 1000 1009 Refl, lteReflectsLTE 1009 1011 Refl)
closeCodeInRange InternalError   = (lteReflectsLTE 1000 1011 Refl, lteReflectsLTE 1011 1011 Refl)

--------------------------------------------------------------------------------
-- Message Ordering
--------------------------------------------------------------------------------

public export
record WSSequence where
  constructor MkWSSequence
  seqNum : Nat

public export
data InOrder : WSSequence -> WSSequence -> Type where
  MkInOrder : {auto prf : LT a.seqNum b.seqNum} -> InOrder a b

export
inOrderTrans : {a, b, c : WSSequence} -> InOrder a b -> InOrder b c -> InOrder a c
inOrderTrans (MkInOrder {prf = ab}) (MkInOrder {prf = bc}) =
  MkInOrder {prf = transitive (lteSuccRight ab) bc}

export
inOrderIrreflexive : {a : WSSequence} -> Not (InOrder a a)
inOrderIrreflexive (MkInOrder {prf}) = absurd (succNotLTEpred a.seqNum prf)
  where
    succNotLTEpred : (n : Nat) -> LTE (S n) n -> Void
    succNotLTEpred Z prf = absurd prf
    succNotLTEpred (S k) (LTESucc p) = succNotLTEpred k p

--------------------------------------------------------------------------------
-- FFI Bridge Declarations
--------------------------------------------------------------------------------

export
%foreign "C:boj_safety_check_ws_origin,libbozsafety"
boj_safety_check_ws_origin : (originPtr : AnyPtr) -> (originLen : Int) -> (allowedPtr : AnyPtr) -> Int

export
%foreign "C:boj_safety_check_ws_frame,libbozsafety"
boj_safety_check_ws_frame : (opcode : Int) -> (payloadLen : Int) -> (isControl : Int) -> Int

export
%foreign "C:boj_safety_check_ws_close,libbozsafety"
boj_safety_check_ws_close : (code : Int) -> Int
