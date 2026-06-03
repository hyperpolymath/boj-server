-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ SafePromptInjection — Formal verification of prompt injection defences
module Boj.SafePromptInjection

import Data.List
import Data.List.Elem
import Data.Nat
import Data.String
import Boj.SafetyLemmas

%default total

--------------------------------------------------------------------------------
-- Injection Pattern Detection
--------------------------------------------------------------------------------

public export
injectionPatterns : List String
injectionPatterns =
  [ "ignore previous instructions"
  , "ignore all instructions"
  , "disregard previous"
  , "forget your instructions"
  , "you are now"
  , "new instructions:"
  , "system prompt:"
  , "### system"
  , "[system]"
  , "<|im_start|>system"
  , "```system"
  ]

public export
containsInjectionPattern : String -> Bool
containsInjectionPattern s =
  let lower = toLower s
  in any (\pat => isInfixOf pat lower) injectionPatterns

public export
data PromptSafe : String -> Type where
  MkPromptSafe : (s : String) ->
                 {auto prf : containsInjectionPattern s = False} ->
                 PromptSafe s

export
decidePromptSafe : (s : String) ->
                   Either (PromptSafe s)
                          (containsInjectionPattern s = True)
decidePromptSafe s with (containsInjectionPattern s) proof prf
  decidePromptSafe s | False = Left (MkPromptSafe s {prf = prf})
  -- `with` rewrote `containsInjectionPattern s` to `True` in the goal, so the
  -- residual obligation is `True = True`.
  decidePromptSafe s | True = Right Refl

--------------------------------------------------------------------------------
-- Role Boundary Safety
--------------------------------------------------------------------------------

public export
isRoleBoundary : String -> Bool
isRoleBoundary s =
  let lower = toLower s
  in isInfixOf "<|im_start|>" lower ||
     isInfixOf "<|im_end|>" lower ||
     isInfixOf "### assistant" lower ||
     isInfixOf "### system" lower ||
     isInfixOf "### user" lower ||
     isInfixOf "<system>" lower ||
     isInfixOf "</system>" lower ||
     isInfixOf "<assistant>" lower ||
     isInfixOf "</assistant>" lower

public export
data RoleBoundarySafe : String -> Type where
  MkRoleBoundarySafe : (s : String) ->
                       {auto prf : isRoleBoundary s = False} ->
                       RoleBoundarySafe s

export
decideRoleBoundarySafe : (s : String) ->
                         Either (RoleBoundarySafe s)
                                (isRoleBoundary s = True)
decideRoleBoundarySafe s with (isRoleBoundary s) proof prf
  decideRoleBoundarySafe s | False = Left (MkRoleBoundarySafe s {prf = prf})
  -- `with` rewrote `isRoleBoundary s` to `True` in the goal.
  decideRoleBoundarySafe s | True = Right Refl

--------------------------------------------------------------------------------
-- Delimiter Escape Safety
--------------------------------------------------------------------------------

public export
isDelimiterEscape : Char -> Bool
isDelimiterEscape c =
  c == '`' || c == '<' || c == '>' || c == '{' || c == '}' ||
  c == '[' || c == ']'

public export
data DelimiterCharsafe : List Char -> Type where
  MkDelimiterCharsafe : (cs : List Char) ->
                        {auto prf : allRec (\c => not (isDelimiterEscape c)) cs = True} ->
                        DelimiterCharsafe cs

public export
data DelimiterSafe : String -> Type where
  MkDelimiterSafe : (s : String) ->
                    {auto prf : allRec (\c => not (isDelimiterEscape c)) (unpack s) = True} ->
                    DelimiterSafe s

export
nilIsDelimiterCharsafe : DelimiterCharsafe []
nilIsDelimiterCharsafe = MkDelimiterCharsafe []

export
delimiterCharsafeNoBacktick : DelimiterCharsafe cs -> Not (Elem '`' cs)
delimiterCharsafeNoBacktick (MkDelimiterCharsafe cs {prf}) elemPrf =
  let charFails : (not (isDelimiterEscape '`') = True)
      charFails = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

export
delimiterCharsafeNoAngle : DelimiterCharsafe cs -> Not (Elem '<' cs)
delimiterCharsafeNoAngle (MkDelimiterCharsafe cs {prf}) elemPrf =
  let charFails : (not (isDelimiterEscape '<') = True)
      charFails = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

export
delimiterCharsafeNoCloseAngle : DelimiterCharsafe cs -> Not (Elem '>' cs)
delimiterCharsafeNoCloseAngle (MkDelimiterCharsafe cs {prf}) elemPrf =
  let charFails : (not (isDelimiterEscape '>') = True)
      charFails = allTrueElem prf elemPrf
  in trueNotFalse (sym charFails)

export
delimiterCharsafeNoBraces : DelimiterCharsafe cs -> (Not (Elem '{' cs), Not (Elem '}' cs))
delimiterCharsafeNoBraces (MkDelimiterCharsafe cs {prf}) =
  let noOpen = \elemPrf =>
        let cf : (not (isDelimiterEscape '{') = True) = allTrueElem prf elemPrf
        in trueNotFalse (sym cf)
      noClose = \elemPrf =>
        let cf : (not (isDelimiterEscape '}') = True) = allTrueElem prf elemPrf
        in trueNotFalse (sym cf)
  in (noOpen, noClose)

export
delimiterCharsafeNoBrackets : DelimiterCharsafe cs -> (Not (Elem '[' cs), Not (Elem ']' cs))
delimiterCharsafeNoBrackets (MkDelimiterCharsafe cs {prf}) =
  let noOpen = \elemPrf =>
        let cf : (not (isDelimiterEscape '[') = True) = allTrueElem prf elemPrf
        in trueNotFalse (sym cf)
      noClose = \elemPrf =>
        let cf : (not (isDelimiterEscape ']') = True) = allTrueElem prf elemPrf
        in trueNotFalse (sym cf)
  in (noOpen, noClose)

export
concatDelimiterCharsafe : DelimiterCharsafe xs -> DelimiterCharsafe ys ->
                          DelimiterCharsafe (xs ++ ys)
concatDelimiterCharsafe (MkDelimiterCharsafe xs {prf = pX})
                        (MkDelimiterCharsafe ys {prf = pY}) =
  MkDelimiterCharsafe (xs ++ ys) {prf = allAppendBoth pX pY}

export
takeDelimiterCharsafe : DelimiterCharsafe cs -> (n : Nat) -> DelimiterCharsafe (take n cs)
takeDelimiterCharsafe (MkDelimiterCharsafe cs {prf}) n =
  MkDelimiterCharsafe (take n cs) {prf = allTake prf}

--------------------------------------------------------------------------------
-- Length Bounding
--------------------------------------------------------------------------------

public export
maxPromptSegmentLength : Nat
maxPromptSegmentLength = 4096

public export
data LengthBounded : String -> Type where
  MkLengthBounded : (s : String) ->
                    {auto prf : LTE (length s) Boj.SafePromptInjection.maxPromptSegmentLength} ->
                    LengthBounded s

--------------------------------------------------------------------------------
-- Composite Safety
--------------------------------------------------------------------------------

public export
record SafePromptSegment where
  constructor MkSafePromptSegment
  text          : String
  0 noInject    : PromptSafe text
  0 noRoles     : RoleBoundarySafe text
  0 noDelimiter : DelimiterSafe text
  0 bounded     : LengthBounded text

public export
data PromptCheckFailure : Type where
  InjectionDetected   : PromptCheckFailure
  RoleBoundaryFound   : PromptCheckFailure
  DelimiterUnsafe     : PromptCheckFailure
  TooLong             : PromptCheckFailure

export
checkPromptSegment : (s : String) -> Either PromptCheckFailure SafePromptSegment
checkPromptSegment s with (containsInjectionPattern s) proof injPrf
  checkPromptSegment s | True = Left InjectionDetected
  checkPromptSegment s | False with (isRoleBoundary s) proof rolePrf
    checkPromptSegment s | False | True = Left RoleBoundaryFound
    checkPromptSegment s | False | False
      with (allRec (\c => not (isDelimiterEscape c)) (unpack s)) proof delimPrf
      checkPromptSegment s | False | False | False = Left DelimiterUnsafe
      checkPromptSegment s | False | False | True
        with (isLTE (length s) Boj.SafePromptInjection.maxPromptSegmentLength)
        checkPromptSegment s | False | False | True | Yes ltePrf =
          Right (MkSafePromptSegment s
                   (MkPromptSafe s {prf = injPrf})
                   (MkRoleBoundarySafe s {prf = rolePrf})
                   (MkDelimiterSafe s {prf = delimPrf})
                   (MkLengthBounded s {prf = ltePrf}))
        checkPromptSegment s | False | False | True | No _ = Left TooLong

--------------------------------------------------------------------------------
-- Core Theorems
--------------------------------------------------------------------------------

export
emptyIsPromptSafe : PromptSafe ""
emptyIsPromptSafe = MkPromptSafe ""

export
emptyIsRoleSafe : RoleBoundarySafe ""
emptyIsRoleSafe = MkRoleBoundarySafe ""

export
emptyIsDelimiterSafe : DelimiterSafe ""
emptyIsDelimiterSafe = MkDelimiterSafe ""

export
emptyIsSafeSegment : SafePromptSegment
emptyIsSafeSegment = MkSafePromptSegment ""
  emptyIsPromptSafe
  emptyIsRoleSafe
  emptyIsDelimiterSafe
  (MkLengthBounded "" {prf = LTEZero})

--------------------------------------------------------------------------------
-- FFI Bridge Declarations
--------------------------------------------------------------------------------

export
%foreign "C:boj_safety_check_prompt,libbozsafety"
boj_safety_check_prompt : (ptr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_check_delimiters,libbozsafety"
boj_safety_check_delimiters : (ptr : AnyPtr) -> (len : Int) -> Int
