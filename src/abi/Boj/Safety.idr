-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ Safety Proofs — Formal verification of input validation properties
module Boj.Safety

import Data.List
import Data.Nat
import Data.Maybe
import Data.String
import Boj.SafetyLemmas

%default total

--------------------------------------------------------------------------------
-- Character Classification
--------------------------------------------------------------------------------

public export
isShellSafe : Char -> Bool
isShellSafe c =
  isAlphaNum c ||
  c == '-' || c == '_' || c == '.' || c == '/' ||
  c == ':' || c == '@' || c == '+' || c == '=' ||
  c == ',' || c == '~'

public export
isSQLDangerous : Char -> Bool
isSQLDangerous c =
  c == ';' || c == '\'' || c == '\\' || c == '\0'

public export
isJSONStringSafe : Char -> Bool
isJSONStringSafe c = c >= ' ' && c /= '\\' && c /= '"'

--------------------------------------------------------------------------------
-- Safety Predicates
--------------------------------------------------------------------------------

public export
data ShellSafe : String -> Type where
  MkShellSafe : (s : String) ->
                {auto prf : allRec Boj.Safety.isShellSafe (unpack s) = True} ->
                ShellSafe s

public export
data SQLSafe : String -> Type where
  MkSQLSafe : (s : String) ->
              {auto prf : allRec (\c => not (Boj.Safety.isSQLDangerous c)) (unpack s) = True} ->
              SQLSafe s

public export
data PathSafe : String -> Type where
  MkPathSafe : (s : String) ->
               {auto noTraversal : not (isInfixOf (unpack "..") (unpack s)) = True} ->
               {auto noNull : allRec (\c => c /= '\0') (unpack s) = True} ->
               PathSafe s

public export
data JSONStringSafe : String -> Type where
  MkJSONStringSafe : (s : String) ->
                     {auto prf : allRec Boj.Safety.isJSONStringSafe (unpack s) = True} ->
                     JSONStringSafe s

--------------------------------------------------------------------------------
-- Core Theorems
--------------------------------------------------------------------------------

export
emptyIsShellSafe : ShellSafe ""
emptyIsShellSafe = MkShellSafe ""

export
emptyIsSQLSafe : SQLSafe ""
emptyIsSQLSafe = MkSQLSafe ""

export
emptyIsJSONSafe : JSONStringSafe ""
emptyIsJSONSafe = MkJSONStringSafe ""

-- Helper: given isShellSafe c = True and c == target = True, derive a
-- contradiction using the fact that isShellSafe target = False.
-- Idris2 can reduce isShellSafe on literal Char arguments because
-- isAlphaNum and the char comparison operators are pure Idris2 functions
-- whose values on literals are computed during elaboration.
private
shellContra : (c, target : Char) ->
              isShellSafe c = True ->
              c == target = True ->
              isShellSafe target = False ->
              Void
shellContra c target hp ceq notSafe =
  let cEqTarget = charEqSound c target ceq
      targetHp  = replace {p = \x => isShellSafe x = True} cEqTarget hp
  in trueNotFalse (trans (sym targetHp) notSafe)

-- Helper: given not (isSQLDangerous c) = True and c == target = True,
-- derive a contradiction when isSQLDangerous target = True.
private
sqlContra : (c, target : Char) ->
            not (isSQLDangerous c) = True ->
            c == target = True ->
            isSQLDangerous target = True ->
            Void
sqlContra c target hp ceq isDangerous =
  let cEqTarget    = charEqSound c target ceq
      targetNotDng = replace {p = \x => not (isSQLDangerous x) = True} cEqTarget hp
      -- targetNotDng : not (isSQLDangerous target) = True
      -- isDangerous  : isSQLDangerous target = True
      -- Contradiction: not True = True is False = True
  in trueNotFalse (trans (sym targetNotDng) (cong not isDangerous))

-- Generic proof that a character is not in a shell-safe string.
-- Reduces to: allImplies (notTarget prf) → allNeqImpliesNotElem → falseImpliesNotTrue.
private
shellSafeNotTarget : (target : Char) ->
                     isShellSafe target = False ->
                     ShellSafe s ->
                     not (target `elem` unpack s) = True
shellSafeNotTarget target notSafe (MkShellSafe s {prf}) =
  let notTarget : (c : Char) -> isShellSafe c = True -> not (c == target) = True
      notTarget c hp with (c == target) proof ceq
        notTarget c hp | False = Refl
        notTarget c hp | True  = absurd (shellContra c target hp ceq notSafe)
  in falseImpliesNotTrue _ (allNeqImpliesNotElem (allImplies notTarget prf))

-- Generic proof that a character is not in a SQL-safe string.
private
sqlSafeNotTarget : (target : Char) ->
                   isSQLDangerous target = True ->
                   SQLSafe s ->
                   not (target `elem` unpack s) = True
sqlSafeNotTarget target isDangerous (MkSQLSafe s {prf}) =
  let notTarget : (c : Char) -> not (isSQLDangerous c) = True -> not (c == target) = True
      notTarget c hp with (c == target) proof ceq
        notTarget c hp | False = Refl
        notTarget c hp | True  = absurd (sqlContra c target hp ceq isDangerous)
  in falseImpliesNotTrue _ (allNeqImpliesNotElem (allImplies notTarget prf))

export
shellSafeNoSemicolon : ShellSafe s -> not (';' `elem` unpack s) = True
shellSafeNoSemicolon = shellSafeNotTarget ';' Refl

export
shellSafeNoBacktick : ShellSafe s -> not ('`' `elem` unpack s) = True
shellSafeNoBacktick = shellSafeNotTarget '`' Refl

export
shellSafeNoDollar : ShellSafe s -> not ('$' `elem` unpack s) = True
shellSafeNoDollar = shellSafeNotTarget '$' Refl

export
shellSafeNoPipe : ShellSafe s -> not ('|' `elem` unpack s) = True
shellSafeNoPipe = shellSafeNotTarget '|' Refl

export
sqlSafeNoTerminator : SQLSafe s -> not (';' `elem` unpack s) = True
sqlSafeNoTerminator = sqlSafeNotTarget ';' Refl

export
sqlSafeNoQuotes : SQLSafe s -> not ('\'' `elem` unpack s) = True
sqlSafeNoQuotes = sqlSafeNotTarget '\'' Refl

export
pathSafeNoParent : PathSafe s -> not (isInfixOf (unpack "..") (unpack s)) = True
pathSafeNoParent (MkPathSafe s {noTraversal}) = noTraversal

--------------------------------------------------------------------------------
-- FFI Bridge
--------------------------------------------------------------------------------

export
%foreign "C:boj_safety_check_shell_arg,libbozsafety"
boj_safety_check_shell_arg : (ptr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_check_sql_value,libbozsafety"
boj_safety_check_sql_value : (ptr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_check_path,libbozsafety"
boj_safety_check_path : (ptr : AnyPtr) -> (len : Int) -> Int

export
%foreign "C:boj_safety_check_json_string,libbozsafety"
boj_safety_check_json_string : (ptr : AnyPtr) -> (len : Int) -> Int
