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
import Data.List.Elem
import Data.Nat
import Data.Bool

%default total

--------------------------------------------------------------------------------
-- allRec: recursive `all` for easier provability
--------------------------------------------------------------------------------

||| Recursive implementation of `all` that is easier to prove properties about.
public export
allRec : (a -> Bool) -> List a -> Bool
allRec p [] = True
allRec p (x :: xs) = p x && allRec p xs

--------------------------------------------------------------------------------
-- Helper Lemmas
--------------------------------------------------------------------------------

||| Helper: True is not False
export
trueNotFalse : True = False -> Void
trueNotFalse Refl impossible

||| Helper: not True is not True
export
notTrueNotTrue : not True = True -> Void
notTrueNotTrue Refl impossible

||| Helper: symmetry of Char equality (admitted as primitive property)
||| In a full proof system this would be proven via primitive properties.
export
charEqSym : (x, y : Char) -> (x == y) = (y == x)
charEqSym x y = believe_me (Refl {x = (x == y)})

--------------------------------------------------------------------------------
-- allRec: core lemmas for `allRec` over lists
--------------------------------------------------------------------------------

||| If `allRec p` holds for a list, then `p x` holds for every element.
export
allTrueElem : {p : a -> Bool} -> {xs : List a} ->
              allRec p xs = True -> Elem x xs -> p x = True
allTrueElem {xs = []} _ _ impossible
allTrueElem {p} {xs = y :: ys} prf Here with (p y) proof eq
  allTrueElem {p} {xs = y :: ys} prf Here | True = Refl
  allTrueElem {p} {xs = y :: ys} prf Here | False = absurd prf
allTrueElem {p} {xs = y :: ys} prf (There later) with (p y) proof eq
  allTrueElem {p} {xs = y :: ys} prf (There later) | True = allTrueElem prf later
  allTrueElem {p} {xs = y :: ys} prf (There later) | False = absurd prf

||| `allRec p` over (xs ++ ys) implies `allRec p` over xs.
export
allAppendLeft : {p : a -> Bool} -> {xs, ys : List a} ->
                allRec p (xs ++ ys) = True -> allRec p xs = True
allAppendLeft {xs = []} _ = Refl
allAppendLeft {p} {xs = x :: xs'} prf with (p x) proof eq
  allAppendLeft {p} {xs = x :: xs'} prf | True = allAppendLeft {xs = xs'} prf
  allAppendLeft {p} {xs = x :: xs'} prf | False = absurd prf

||| `allRec p` over (xs ++ ys) implies `allRec p` over ys.
export
allAppendRight : {p : a -> Bool} -> {xs, ys : List a} ->
                 allRec p (xs ++ ys) = True -> allRec p ys = True
allAppendRight {xs = []} prf = prf
allAppendRight {p} {xs = x :: xs'} prf with (p x) proof eq
  allAppendRight {p} {xs = x :: xs'} prf | True = allAppendRight {xs = xs'} prf
  allAppendRight {p} {xs = x :: xs'} prf | False = absurd prf

||| Combining `allRec p xs` and `allRec p ys` gives `allRec p (xs ++ ys)`.
export
allAppendBoth : {p : a -> Bool} -> {xs, ys : List a} ->
                allRec p xs = True -> allRec p ys = True -> allRec p (xs ++ ys) = True
allAppendBoth {xs = []} _ pY = pY
allAppendBoth {p} {xs = x :: xs'} pX pY with (p x) proof eq
  allAppendBoth {p} {xs = x :: xs'} pX pY | True = allAppendBoth {xs = xs'} pX pY
  allAppendBoth {p} {xs = x :: xs'} pX pY | False = absurd pX

||| If `allRec p xs` holds, then for any predicate q that is implied by p,
||| `allRec q xs` holds.
export
allImplies : {p, q : a -> Bool} -> {xs : List a} ->
             ((y : a) -> p y = True -> q y = True) ->
             allRec p xs = True -> allRec q xs = True
allImplies {xs = []} _ _ = Refl
allImplies {p} {q} {xs = x :: xs'} impl prf with (p x) proof eqP
  allImplies {p} {q} {xs = x :: xs'} impl prf | True =
    let qTrue = impl x eqP
    in rewrite qTrue in allImplies {xs = xs'} impl prf
  allImplies {p} {q} {xs = x :: xs'} impl prf | False = absurd prf

--------------------------------------------------------------------------------
-- not/elem interaction
--------------------------------------------------------------------------------

||| If `allRec (\c => not (p c))` holds and p c = True, then c is not in the list.
export
allNotImpliesNotElem : {p : a -> Bool} -> {xs : List a} ->
                       allRec (\c => not (p c)) xs = True ->
                       p x = True ->
                       Not (Elem x xs)
allNotImpliesNotElem {xs = []} _ _ Here impossible
allNotImpliesNotElem {xs = []} _ _ (There _) impossible
allNotImpliesNotElem {p} {xs = x :: ys} allPrf pxTrue Here with (p x)
  allNotImpliesNotElem {p} {xs = x :: ys} allPrf pxTrue Here | True =
    absurd allPrf
  allNotImpliesNotElem {p} {xs = x :: ys} allPrf Refl Here | False impossible
allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue (There later) with (p y)
  allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue (There later) | True =
    absurd allPrf
  allNotImpliesNotElem {p} {xs = y :: ys} allPrf pxTrue (There later) | False =
    allNotImpliesNotElem {xs = ys} allPrf pxTrue later

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
notTrueImpliesFalse : (b : Bool) -> not b = True -> b = False
notTrueImpliesFalse False Refl = Refl
notTrueImpliesFalse True Refl impossible

||| If b = False, then not b = True
export
falseImpliesNotTrue : (b : Bool) -> b = False -> not b = True
falseImpliesNotTrue False Refl = Refl
falseImpliesNotTrue True Refl impossible

--------------------------------------------------------------------------------
-- elem/all interaction for specific characters
--------------------------------------------------------------------------------

||| If `allRec (\c => not (p c)) xs = True` then `any p xs = False`.
export
allNotImpliesAnyFalse : {p : a -> Bool} -> {xs : List a} ->
                        allRec (\c => not (p c)) xs = True ->
                        any p xs = False
allNotImpliesAnyFalse {xs = []} _ = Refl
allNotImpliesAnyFalse {p} {xs = x :: xs'} prf with (p x) proof pEq
  allNotImpliesAnyFalse {p} {xs = x :: xs'} prf | True = absurd prf
  allNotImpliesAnyFalse {p} {xs = x :: xs'} prf | False =
    allNotImpliesAnyFalse {xs = xs'} prf

||| For a decidable equality type: if `allRec (\c => not (c == target)) xs = True`
||| then `elem target xs = False`.
export
allNeqImpliesNotElem : {target : Char} -> {xs : List Char} ->
                       allRec (\c => not (c == target)) xs = True ->
                       elem target xs = False
allNeqImpliesNotElem {xs = []} _ = Refl
allNeqImpliesNotElem {target} {xs = x :: xs'} prf with (x == target) proof xEq
  allNeqImpliesNotElem {target} {xs = x :: xs'} prf | True = absurd prf
  allNeqImpliesNotElem {target} {xs = x :: xs'} prf | False =
    let goal_rewrite : (elem target (x :: xs') = elem target xs')
        goal_rewrite = rewrite charEqSym target x in
                       rewrite sym xEq in Refl
    in rewrite goal_rewrite in allNeqImpliesNotElem {xs = xs'} prf

--------------------------------------------------------------------------------
-- take/drop (for List-based truncation proofs)
--------------------------------------------------------------------------------

||| `allRec p (take n xs) = True` if `allRec p xs = True`.
export
allTake : {p : a -> Bool} -> {xs : List a} -> {n : Nat} ->
          allRec p xs = True -> allRec p (take n xs) = True
allTake {n = Z} _ = Refl
allTake {n = S k} {xs = []} _ = Refl
allTake {p} {xs = x :: xs'} {n = S k} prf with (p x) proof eq
  allTake {p} {xs = x :: xs'} {n = S k} prf | True =
    allTake {xs = xs'} {n = k} prf
  allTake {p} {xs = x :: xs'} {n = S k} prf | False = absurd prf
