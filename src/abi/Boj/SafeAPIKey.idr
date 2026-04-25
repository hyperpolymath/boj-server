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

private
minKeyLengthNotZero : LTE Boj.SafeAPIKey.minKeyLength 0 -> Void
minKeyLengthNotZero LTEZero impossible
minKeyLengthNotZero (LTESucc _) impossible

export
sufficientEntropyNonEmpty : SufficientEntropy s -> NonEmpty (unpack s)
sufficientEntropyNonEmpty (MkSufficientEntropy s {prf}) with (unpack s) proof upEq
  sufficientEntropyNonEmpty (MkSufficientEntropy s {prf}) | [] =
    let len_eq  = unpackLength s
        len_ge  = replace {p = \n => LTE Boj.SafeAPIKey.minKeyLength n}
                          (sym len_eq) prf
        lenNil = cong length upEq
        impossibleLen : LTE Boj.SafeAPIKey.minKeyLength 0
        impossibleLen = replace {p = \n => LTE Boj.SafeAPIKey.minKeyLength n} lenNil len_ge
    in absurd (minKeyLengthNotZero impossibleLen)
  sufficientEntropyNonEmpty (MkSufficientEntropy _ {prf}) | (_ :: _) = IsNonEmpty

-- Reduce toLogSafe s to "***" when the short-path condition holds.
-- Works because toLogSafe is transparent and `if True then x else y = x`.
private
toLogSafeShortEq : (s : String) -> (length s <= 8 = True) -> toLogSafe s = "***"
toLogSafeShortEq s _ with (length s <= 8)
  toLogSafeShortEq _ _ | True  = Refl
  toLogSafeShortEq _ prf | False = absurd prf

-- Reduce toLogSafe s to the concat form when the long-path condition holds.
private
toLogSafeLongEq : (s : String) -> (length s <= 8 = False) ->
  toLogSafe s = substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s
toLogSafeLongEq s _ with (length s <= 8)
  toLogSafeLongEq _ prf | True  = absurd prf
  toLogSafeLongEq _ _ | False = Refl

-- Monotonicity of + over LTE (derived from Data.Nat primitives).
private
plusLteMonotone : {m, n, p, q : Nat} -> LTE m n -> LTE p q -> LTE (m + p) (n + q)
plusLteMonotone lmn lpq =
  lteTransitive (plusLteMonotoneRight _ lmn) (plusLteMonotoneLeft _ lpq)

||| The redacted key from `toLogSafe` is always at most 11 characters long.
|||
||| Proof structure (using `appendLengthSum` + `substrLengthBound` axioms):
|||   short path (length s ≤ 8):  output is "***", length 3 ≤ 11.
|||   long path:                   4 + 3 + 4 = 11 ≤ 11.
|||
||| The two string-primitive axioms are declared in SafetyLemmas.
export
logSafeBounded : (s : String) -> LTE (length (toLogSafe s)) 11
logSafeBounded s with (length s <= 8) proof cond
  logSafeBounded s | True  =
    let eq = toLogSafeShortEq s cond
    in replace {p = \t => LTE (length t) 11} (sym eq)
         (LTESucc (LTESucc (LTESucc (LTEZero {right = 8}))))
  logSafeBounded s | False =
    let p1       = substr 0 4 s
        p3       = substr (length s `minus` 4) 4 s
        eq       = toLogSafeLongEq s cond
        l1       = substrLengthBound s 0 4
        l3       = substrLengthBound s (length s `minus` 4) 4
        eq12     = appendLengthSum p1 "..."
        eq123    = appendLengthSum (p1 ++ "...") p3
        l12      = replace {p = \n => LTE n 7}  (sym eq12)  (plusLteMonotoneRight 3 l1)
        l123     = replace {p = \n => LTE n 11} (sym eq123) (plusLteMonotone l12 l3)
    in replace {p = \t => LTE (length t) 11} (sym eq) l123

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
