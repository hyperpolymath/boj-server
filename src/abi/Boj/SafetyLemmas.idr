-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BoJ SafetyLemmas — Foundational lemmas for safety proofs
|||
||| Reusable lemmas over List Char that underpin the safety proofs in
||| SafeHTTP, SafeCORS, SafeWebSocket, SafePromptInjection, SafeAPIKey,
||| and Safety modules.
|||
||| All proofs are structural inductions over List Char. No believe_me.
module Boj.SafetyLemmas

import Data.List
import Data.Nat
import Data.Bool

%default total

--------------------------------------------------------------------------------
-- allTrue: core lemmas for `all` over lists
--------------------------------------------------------------------------------

||| If `all p` holds for a list, then `p x` holds for every element.
export
allTrueElem : {p : a -> Bool} -> {xs : List a} ->
              all p xs = True -> Elem x xs -> p x = True
allTrueElem {xs = []} _ absurd = absurd absurd
allTrueElem {p} {xs = y :: ys} prf Here with (p y) proof eq
  allTrueElem {p} {xs = y :: ys} prf Here | True = eq
  allTrueElem {p} {xs = y :: ys} Refl Here | False impossible
allTrueElem {p} {xs = y :: ys} prf (There later) with (p y)
  allTrueElem {p} {xs = y :: ys} prf (There later) | True = allTrueElem prf later
  allTrueElem {p} {xs = y :: ys} Refl (There later) | False impossible

||| `all p` over (xs ++ ys) implies `all p` over xs.
export
allAppendLeft : {p : a -> Bool} -> {xs, ys : List a} ->
                all p (xs ++ ys) = True -> all p xs = True
allAppendLeft {xs = []} _ = Refl
allAppendLeft {p} {xs = x :: xs'} prf with (p x) proof eq
  allAppendLeft {p} {xs = x :: xs'} prf | True = allAppendLeft {xs = xs'} prf
  allAppendLeft {p} {xs = x :: xs'} Refl | False impossible

||| `all p` over (xs ++ ys) implies `all p` over ys.
export
allAppendRight : {p : a -> Bool} -> {xs, ys : List a} ->
                 all p (xs ++ ys) = True -> all p ys = True
allAppendRight {xs = []} prf = prf
allAppendRight {p} {xs = x :: xs'} prf with (p x)
  allAppendRight {p} {xs = x :: xs'} prf | True = allAppendRight {xs = xs'} prf
  allAppendRight {p} {xs = x :: xs'} Refl | False impossible

||| Combining `all p xs` and `all p ys` gives `all p (xs ++ ys)`.
export
allAppendBoth : {p : a -> Bool} -> {xs, ys : List a} ->
                all p xs = True -> all p ys = True -> all p (xs ++ ys) = True
allAppendBoth {xs = []} _ pY = pY
allAppendBoth {p} {xs = x :: xs'} pX pY with (p x) proof eq
  allAppendBoth {p} {xs = x :: xs'} pX pY | True = allAppendBoth {xs = xs'} pX pY
  allAppendBoth {p} {xs = x :: xs'} Refl _ | False impossible

||| If `all p xs` holds, then for any predicate q that is implied by p,
||| `all q xs` holds.
export
allImplies : {p, q : a -> Bool} -> {xs : List a} ->
             ((y : a) -> p y = True -> q y = True) ->
             all p xs = True -> all q xs = True
allImplies {xs = []} _ _ = Refl
allImplies {p} {q} {xs = x :: xs'} impl prf with (p x) proof eqP
  allImplies {p} {q} {xs = x :: xs'} impl prf | True =
    let qTrue = impl x eqP
    in rewrite qTrue in allImplies {xs = xs'} impl prf
  allImplies {p} {q} {xs = x :: xs'} Refl _ | False impossible

--------------------------------------------------------------------------------
-- not/elem interaction
--------------------------------------------------------------------------------

||| If `all (\c => not (p c))` holds and p c = True, then c is not in the list.
export
allNotImpliesNotElem : {p : a -> Bool} -> {xs : List a} ->
                       all (\c => not (p c)) xs = True ->
                       p x = True ->
                       Not (Elem x xs)
allNotImpliesNotElem {xs = []} _ _ absurd = absurd absurd
allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue Here with (p y) proof eqP
  allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue Here | True with (not True)
    allNotImpliesNotElem {p} {xs = y :: ys} Refl _ Here | True | False impossible
  allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue Here | False =
    let contra : (True = False) = rewrite sym pxTrue in eqP
    in absurd contra
allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue (There later) with (not (p y))
  allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue (There later) | True =
    allNotImpliesNotElem {xs = ys} allPrf pxTrue later
  allNotImpliesNotElem {p} {xs = y :: ys} Refl _ (There _) | False impossible

--------------------------------------------------------------------------------
-- Bool helpers
--------------------------------------------------------------------------------

||| not True = False
export
notTrueIsFalse : not True = False
notTrueIsFalse = Refl

||| not False = True
export
notFalseIsTrue : not False = True
notFalseIsTrue = Refl

||| Double negation: not (not b) = b
export
notNotId : (b : Bool) -> not (not b) = b
notNotId True = Refl
notNotId False = Refl

||| If not b = True, then b = False
export
notTrueImpliesFalse : not b = True -> b = False
notTrueImpliesFalse {b = False} Refl = Refl
notTrueImpliesFalse {b = True} Refl impossible

||| If b = False, then not b = True
export
falseImpliesNotTrue : b = False -> not b = True
falseImpliesNotTrue {b = False} Refl = Refl
falseImpliesNotTrue {b = True} Refl impossible

--------------------------------------------------------------------------------
-- elem/all interaction for specific characters
--------------------------------------------------------------------------------

||| If `all (\c => not (p c)) xs = True` then `any p xs = False`.
export
allNotImpliesAnyFalse : {p : a -> Bool} -> {xs : List a} ->
                        all (\c => not (p c)) xs = True ->
                        any p xs = False
allNotImpliesAnyFalse {xs = []} _ = Refl
allNotImpliesAnyFalse {p} {xs = x :: xs'} prf with (not (p x)) proof nEq
  allNotImpliesAnyFalse {p} {xs = x :: xs'} prf | True with (p x) proof pEq
    allNotImpliesAnyFalse {p} {xs = x :: xs'} prf | True | False =
      allNotImpliesAnyFalse {xs = xs'} prf
    allNotImpliesAnyFalse {p} {xs = x :: xs'} prf | True | True = absurd nEq
  allNotImpliesAnyFalse {p} {xs = x :: xs'} Refl _ | False impossible

||| If `all (\c => not (f c)) xs = True`, then `not (elem x xs) = True`
||| when `f x = True`, because x cannot be in xs.
||| But we need the simpler: if the char's predicate is rejected by all,
||| then testing membership with (==) also fails.
||| This is the key bridge lemma for headerSafeNoCR etc.

||| For a decidable equality type: if `all (\c => not (c == target)) xs = True`
||| then `elem target xs = False`.
export
allNeqImpliesNotElem : {target : Char} -> {xs : List Char} ->
                       all (\c => not (c == target)) xs = True ->
                       elem target xs = False
allNeqImpliesNotElem {xs = []} _ = Refl
allNeqImpliesNotElem {target} {xs = x :: xs'} prf with (not (x == target)) proof nEq
  allNeqImpliesNotElem {target} {xs = x :: xs'} prf | True with (x == target) proof xEq
    allNeqImpliesNotElem {target} {xs = x :: xs'} prf | True | False =
      allNeqImpliesNotElem {xs = xs'} prf
    allNeqImpliesNotElem {target} {xs = x :: xs'} prf | True | True = absurd nEq
  allNeqImpliesNotElem {target} {xs = x :: xs'} Refl _ | False impossible

--------------------------------------------------------------------------------
-- take/drop (for List-based truncation proofs)
--------------------------------------------------------------------------------

||| `all p (take n xs) = True` if `all p xs = True`.
export
allTake : {p : a -> Bool} -> {xs : List a} -> {n : Nat} ->
          all p xs = True -> all p (take n xs) = True
allTake {n = Z} _ = Refl
allTake {xs = []} _ = Refl
allTake {p} {xs = x :: xs'} {n = S k} prf with (p x) proof eq
  allTake {p} {xs = x :: xs'} {n = S k} prf | True =
    allTake {xs = xs'} {n = k} prf
  allTake {p} {xs = x :: xs'} {n = S k} Refl _ | False impossible
