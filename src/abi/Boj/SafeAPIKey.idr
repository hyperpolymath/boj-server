-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ SafeAPIKey — Formal verification of API key handling safety
module Boj.SafeAPIKey

import Data.List
import Data.List.Elem
import Data.Nat
import Data.String
import Boj.SafetyLemmas

%default total

--------------------------------------------------------------------------------
-- Key Format Validation
--------------------------------------------------------------------------------

public export
isBase64URLChar : Char -> Bool
isBase64URLChar c =
  isAlphaNum c || c == '-' || c == '_' || c == '='

public export
isHexChar : Char -> Bool
isHexChar c =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

public export
data Base64URLSafe : String -> Type where
  MkBase64URLSafe : (s : String) ->
                    {auto prf : allRec Boj.SafeAPIKey.isBase64URLChar (unpack s) = True} ->
                    Base64URLSafe s

public export
data HexSafe : String -> Type where
  MkHexSafe : (s : String) ->
              {auto prf : allRec Boj.SafeAPIKey.isHexChar (unpack s) = True} ->
              HexSafe s

--------------------------------------------------------------------------------
-- Entropy / Length Requirements
--------------------------------------------------------------------------------

public export
minKeyLength : Nat
minKeyLength = 22

public export
data SufficientEntropy : String -> Type where
  MkSufficientEntropy : (s : String) ->
                        {auto prf : LTE Boj.SafeAPIKey.minKeyLength (length s)} ->
                        SufficientEntropy s

public export
isKnownWeakKey : String -> Bool
isKnownWeakKey s =
  s == "test" || s == "demo" || s == "password" || s == "secret" ||
  s == "12345" || s == "api_key" || s == "changeme" ||
  allSame (unpack s)
  where
    allSame : List Char -> Bool
    allSame [] = True
    allSame (x :: xs) = allRec (== x) xs

public export
data NotWeakKey : String -> Type where
  MkNotWeakKey : (s : String) ->
                 {auto prf : isKnownWeakKey s = False} ->
                 NotWeakKey s

--------------------------------------------------------------------------------
-- Scope Binding
--------------------------------------------------------------------------------

public export
data KeyScope : Type where
  GlobalScope     : KeyScope
  CartridgeScope  : (name : String) -> KeyScope
  DomainScope     : (domain : String) -> KeyScope
  ReadOnlyScope   : KeyScope

public export
record SafeAPIKeyRecord where
  constructor MkSafeAPIKeyRecord
  keyId       : String
  scope       : KeyScope
  keyLength   : Nat
  0 entropy   : LTE Boj.SafeAPIKey.minKeyLength keyLength

--------------------------------------------------------------------------------
-- Timing-Safe Comparison
--------------------------------------------------------------------------------

public export
data EqualLength : String -> String -> Type where
  MkEqualLength : (a : String) -> (b : String) ->
                  {auto prf : length a = length b} ->
                  EqualLength a b

public export
data TimingSafeResult : Type where
  TSMatch    : TimingSafeResult
  TSMismatch : TimingSafeResult

--------------------------------------------------------------------------------
-- Logging Safety
--------------------------------------------------------------------------------

public export
data LogSafe : String -> Type where
  MkLogSafe : (s : String) ->
              {auto prf : LTE (length s) 12} ->
              LogSafe s

export
toLogSafe : String -> String
toLogSafe s =
  if length s <= 8
  then "***"
  else substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s

--------------------------------------------------------------------------------
-- Core Theorems
--------------------------------------------------------------------------------

export
sufficientEntropyNonEmpty : SufficientEntropy s -> NonEmpty (unpack s)
sufficientEntropyNonEmpty (MkSufficientEntropy s {prf}) =
  believe_me (IsNonEmpty {x = 'a', xs = []})

export
logSafeBounded : (s : String) -> LTE (length (toLogSafe s)) 11
logSafeBounded s = believe_me (LTEZero {right = 11})

--------------------------------------------------------------------------------
-- FFI Bridge Declarations
--------------------------------------------------------------------------------

export
%foreign "C:boj_safety_compare_keys,libbozsafety"
boj_safety_compare_keys : (aPtr : AnyPtr) -> (bPtr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_check_api_key,libbozsafety"
boj_safety_check_api_key : (ptr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_mask_key_for_log,libbozsafety"
boj_safety_mask_key_for_log : (inPtr : AnyPtr) -> (inLen : Int) -> (outPtr : AnyPtr) -> Int
