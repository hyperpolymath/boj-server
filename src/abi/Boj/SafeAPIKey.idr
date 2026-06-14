-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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
toLogSafeShortEq s prf with (length s <= 8)
  toLogSafeShortEq _ _ | True  = Refl
  toLogSafeShortEq _ prf | False = absurd prf

-- Reduce toLogSafe s to the concat form when the long-path condition holds.
private
toLogSafeLongEq : (s : String) -> (length s <= 8 = False) ->
  toLogSafe s = substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s
toLogSafeLongEq s prf with (length s <= 8)
  toLogSafeLongEq _ prf | True  = absurd prf
  toLogSafeLongEq _ _ | False = Refl

-- Length bound on the redacted-short marker. Lifted out of `logSafeBounded`'s
-- with-block so the elaborator reduces `length "***"` against the witness
-- `LTE 3 11`. Inside the with-block the reduction does not fire on Idris2
-- 0.8.0 (the goal is exposed as
--   `LTE (integerToNat (prim__cast_IntInteger (prim__strLength (if ...))))`
-- and the `if`-arm is not reduced before unification).
private
shortMarkerBounded : LTE (length "***") 11
shortMarkerBounded = LTESucc (LTESucc (LTESucc (LTEZero {right = 8})))

-- Length bound on the long-path ellipsis marker. Same lift-out reason as
-- `shortMarkerBounded`.
private
ellipsisLen3 : LTE (length "...") 3
ellipsisLen3 = LTESucc (LTESucc (LTESucc LTEZero))

-- Short path of `logSafeBounded`, lifted out of the with-block. The return
-- type uses the *literal* `"***"` rather than `toLogSafe s`, which matches
-- what the with-block's True-branch substitution rewrites the goal to.
private
logSafeBoundedShort : (s : String) -> (length s <= 8 = True) ->
                      LTE (length "***") 11
logSafeBoundedShort _ _ = shortMarkerBounded

-- Long path of `logSafeBounded`, lifted out of the with-block. The return
-- type carries the substr-form directly (matching what the with-block False-
-- branch rewrites the goal to via `if False`-evaluation of `toLogSafe`). The
-- substr arguments are repeated rather than let-bound because Idris2 0.8.0's
-- elaborator doesn't always propagate `let`-binding equalities through
-- `appendLengthSum`'s implicit arguments. The proof is right-associated to
-- match `++`'s associativity (`a ++ b ++ c = a ++ (b ++ c)`).
private
logSafeBoundedLong : (s : String) -> (length s <= 8 = False) ->
                     LTE (length (substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s)) 11
logSafeBoundedLong s _ =
  let l1 : LTE (length (substr 0 4 s)) 4
      l1 = substrLengthBound s 0 4
      l3 : LTE (length (substr (length s `minus` 4) 4 s)) 4
      l3 = substrLengthBound s (length s `minus` 4) 4
      -- Length of "..." ++ p3
      eq23 : length ("..." ++ substr (length s `minus` 4) 4 s)
           = length "..." + length (substr (length s `minus` 4) 4 s)
      eq23 = appendLengthSum "..." (substr (length s `minus` 4) 4 s)
      step23 : LTE (length "..." + length (substr (length s `minus` 4) 4 s)) (3 + 4)
      step23 = plusLteMonotone ellipsisLen3 l3
      l23 : LTE (length ("..." ++ substr (length s `minus` 4) 4 s)) 7
      l23 = replace {p = \n => LTE n 7} (sym eq23) step23
      -- Length of p1 ++ ("..." ++ p3)
      eq123 : length (substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s)
            = length (substr 0 4 s) + length ("..." ++ substr (length s `minus` 4) 4 s)
      eq123 = appendLengthSum (substr 0 4 s) ("..." ++ substr (length s `minus` 4) 4 s)
      step123 : LTE (length (substr 0 4 s) + length ("..." ++ substr (length s `minus` 4) 4 s)) (4 + 7)
      step123 = plusLteMonotone l1 l23
      l123 : LTE (length (substr 0 4 s ++ "..." ++ substr (length s `minus` 4) 4 s)) 11
      l123 = replace {p = \n => LTE n 11} (sym eq123) step123
  in l123

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
  logSafeBounded s | True  = logSafeBoundedShort s cond
  logSafeBounded s | False = logSafeBoundedLong s cond

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
