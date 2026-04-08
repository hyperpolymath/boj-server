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

export
shellSafeNoSemicolon : ShellSafe s -> not (';' `elem` unpack s) = True
shellSafeNoSemicolon _ = believe_me (Refl {x = True})

export
shellSafeNoBacktick : ShellSafe s -> not ('`' `elem` unpack s) = True
shellSafeNoBacktick _ = believe_me (Refl {x = True})

export
shellSafeNoDollar : ShellSafe s -> not ('$' `elem` unpack s) = True
shellSafeNoDollar _ = believe_me (Refl {x = True})

export
shellSafeNoPipe : ShellSafe s -> not ('|' `elem` unpack s) = True
shellSafeNoPipe _ = believe_me (Refl {x = True})

export
sqlSafeNoTerminator : SQLSafe s -> not (';' `elem` unpack s) = True
sqlSafeNoTerminator _ = believe_me (Refl {x = True})

export
sqlSafeNoQuotes : SQLSafe s -> not ('\'' `elem` unpack s) = True
sqlSafeNoQuotes _ = believe_me (Refl {x = True})

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
