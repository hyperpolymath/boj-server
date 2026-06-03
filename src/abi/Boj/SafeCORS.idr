-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ SafeCORS — Formal verification of CORS policy enforcement
module Boj.SafeCORS

import Data.List
import Data.List.Elem
import Data.Nat
import Data.String
import Boj.SafetyLemmas

%default total

--------------------------------------------------------------------------------
-- Origin Validation
--------------------------------------------------------------------------------

public export
isOriginChar : Char -> Bool
isOriginChar c =
  isAlphaNum c || c == '-' || c == '.' || c == ':' || c == '/' ||
  c == '[' || c == ']'

public export
data OriginCharsValid : List Char -> Type where
  MkOriginCharsValid : (cs : List Char) ->
                       {auto nonEmpty : NonEmpty cs} ->
                       {auto prf : allRec Boj.SafeCORS.isOriginChar cs = True} ->
                       OriginCharsValid cs

public export
data OriginValid : String -> Type where
  MkOriginValid : (s : String) ->
                  {auto nonEmpty : NonEmpty (unpack s)} ->
                  {auto prf : allRec Boj.SafeCORS.isOriginChar (unpack s) = True} ->
                  OriginValid s

public export
wildcardOrigin : String
wildcardOrigin = "*"

public export
data NotWildcard : String -> Type where
  MkNotWildcard : (s : String) ->
                  {auto prf : (s == Boj.SafeCORS.wildcardOrigin) = False} ->
                  NotWildcard s

export
originCharsNoSpace : OriginCharsValid cs -> Not (Elem ' ' cs)
originCharsNoSpace (MkOriginCharsValid cs {prf}) elemPrf =
  let charFails : (Boj.SafeCORS.isOriginChar ' ' = True) = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

export
originCharsNoNewline : OriginCharsValid cs -> Not (Elem '\n' cs)
originCharsNoNewline (MkOriginCharsValid cs {prf}) elemPrf =
  let charFails : (Boj.SafeCORS.isOriginChar '\n' = True) = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

export
originCharsNoCR : OriginCharsValid cs -> Not (Elem '\r' cs)
originCharsNoCR (MkOriginCharsValid cs {prf}) elemPrf =
  let charFails : (Boj.SafeCORS.isOriginChar '\r' = True) = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

--------------------------------------------------------------------------------
-- CORS Policy Types
--------------------------------------------------------------------------------

public export
data CORSMethod : Type where
  CORSGet     : CORSMethod
  CORSPost    : CORSMethod
  CORSOptions : CORSMethod

public export
data CORSHeader : Type where
  ContentType   : CORSHeader
  Authorization : CORSHeader
  XRequestId    : CORSHeader

public export
record SafeCORSPolicy where
  constructor MkSafeCORSPolicy
  allowedOrigins   : List String
  allowedMethods   : List CORSMethod
  allowedHeaders   : List CORSHeader
  allowCredentials : Bool
  maxAge           : Nat

--------------------------------------------------------------------------------
-- Safety Predicates
--------------------------------------------------------------------------------

public export
data CORSCredentialSafe : SafeCORSPolicy -> Type where
  NoCredentials : (p : SafeCORSPolicy) ->
                  {auto prf : p.allowCredentials = False} ->
                  CORSCredentialSafe p
  NoWildcard    : (p : SafeCORSPolicy) ->
                  {auto prf : not (elem Boj.SafeCORS.wildcardOrigin p.allowedOrigins) = True} ->
                  CORSCredentialSafe p

public export
data AllOriginsValid : List String -> Type where
  NilOrigins  : AllOriginsValid []
  ConsOrigins : OriginValid o -> AllOriginsValid os -> AllOriginsValid (o :: os)

public export
data ReasonableMaxAge : Nat -> Type where
  MkReasonableMaxAge : (n : Nat) -> {auto prf : LTE n 86400} -> ReasonableMaxAge n

public export
record ValidatedCORSPolicy where
  constructor MkValidatedCORSPolicy
  policy          : SafeCORSPolicy
  0 credSafe      : CORSCredentialSafe policy
  0 originsValid  : AllOriginsValid policy.allowedOrigins
  0 maxAgeBounded : ReasonableMaxAge policy.maxAge

--------------------------------------------------------------------------------
-- Core Theorems
--------------------------------------------------------------------------------

export
noCredsAlwaysSafe : (p : SafeCORSPolicy) ->
                    {auto prf : p.allowCredentials = False} ->
                    CORSCredentialSafe p
noCredsAlwaysSafe p = NoCredentials p

export
emptyOriginsValid : AllOriginsValid []
emptyOriginsValid = NilOrigins

export
decideCredentialSafe : (p : SafeCORSPolicy) ->
                       Either (CORSCredentialSafe p)
                              (p.allowCredentials = True, elem Boj.SafeCORS.wildcardOrigin p.allowedOrigins = True)
decideCredentialSafe p with (p.allowCredentials) proof credPrf
  decideCredentialSafe p | False = Left (NoCredentials p {prf = credPrf})
  decideCredentialSafe p | True with (elem Boj.SafeCORS.wildcardOrigin p.allowedOrigins) proof elemPrf
    decideCredentialSafe p | True | False =
      Left (NoWildcard p {prf = falseImpliesNotTrue _ elemPrf})
    -- Both `with` scrutinees were rewritten to `True` in the goal, leaving the
    -- pair of reflexive obligations `(True = True, True = True)`.
    decideCredentialSafe p | True | True =
      Right (Refl, Refl)

export
consOriginsValid : OriginValid o -> AllOriginsValid os -> AllOriginsValid (o :: os)
consOriginsValid = ConsOrigins

export
zeroMaxAgeReasonable : ReasonableMaxAge 0
zeroMaxAgeReasonable = MkReasonableMaxAge 0 {prf = LTEZero}

export
oneHourMaxAgeReasonable : ReasonableMaxAge 3600
oneHourMaxAgeReasonable = MkReasonableMaxAge 3600 {prf = lteReflectsLTE 3600 86400 Refl}

--------------------------------------------------------------------------------
-- Default Policies
--------------------------------------------------------------------------------

public export
bojDefaultCORS : SafeCORSPolicy
bojDefaultCORS = MkSafeCORSPolicy
  { allowedOrigins  = ["http://localhost:3000", "http://localhost:5173"]
  , allowedMethods  = [CORSPost, CORSOptions]
  , allowedHeaders  = [ContentType, XRequestId]
  , allowCredentials = False
  , maxAge          = 3600
  }

export
bojDefaultCORSIsSafe : CORSCredentialSafe Boj.SafeCORS.bojDefaultCORS
bojDefaultCORSIsSafe = NoCredentials bojDefaultCORS

public export
bojProductionCORS : SafeCORSPolicy
bojProductionCORS = MkSafeCORSPolicy
  { allowedOrigins  = []
  , allowedMethods  = [CORSGet, CORSPost, CORSOptions]
  , allowedHeaders  = [ContentType, Authorization, XRequestId]
  , allowCredentials = True
  , maxAge          = 7200
  }

export
bojProductionCORSIsSafe : CORSCredentialSafe Boj.SafeCORS.bojProductionCORS
bojProductionCORSIsSafe = NoWildcard bojProductionCORS

--------------------------------------------------------------------------------
-- FFI Bridge Declarations
--------------------------------------------------------------------------------

export
%foreign "C:boj_safety_check_cors_origin,libbozsafety"
boj_safety_check_cors_origin : (ptr : AnyPtr) -> (len : Int) -> (creds : Int) -> Int

export
%foreign "C:boj_safety_check_cors_policy,libbozsafety"
boj_safety_check_cors_policy : (originsPtr : AnyPtr) -> (methodsPtr : AnyPtr) -> (creds : Int) -> (maxAge : Int) -> Int
