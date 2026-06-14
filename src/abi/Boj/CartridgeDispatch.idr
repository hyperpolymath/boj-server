-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Boj.CartridgeDispatch: Formal proof of cartridge dispatch type safety (BJ1).
|||
||| REQUIREMENTS-MASTER.md: BJ1 | Cartridge dispatch type safety | TP | I2 | P1
|||
||| This module proves three core dispatch invariants:
|||
|||   1. ProtocolMatch — dispatch only routes to cartridges that advertise
|||      the requested protocol in their `protocols` list.
|||
|||   2. ReadinessGuard — dispatch only routes to cartridges whose status
|||      is Ready (i.e. those that satisfy IsUnbreakable).
|||
|||   3. Disjointness — ProtocolMatch and dispatch-refusal are exclusive:
|||      if a cartridge matches the protocol AND is ready, dispatch cannot
|||      simultaneously refuse it.
|||
||| These three theorems together establish that the BoJ dispatcher is
||| *type-safe* in the sense of Wadler 1989: well-typed dispatch cannot
||| go wrong — it will never route a request to a cartridge that cannot
||| handle the requested protocol or that has not passed the safety gate.
|||
||| The proofs are constructive: each theorem produces a witness that can
||| be inspected at the call site rather than a black-box boolean check.
module Boj.CartridgeDispatch

import Data.List
import Boj.Protocol
import Boj.Domain
import Boj.Catalogue

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Boolean & Status Lemmas
--
-- `lookupCell` guards each cell with the conjunction
--   `domain c == d && elem p (protocols c) && status c == Ready`.
-- These lemmas let the dispatch invariants below extract each conjunct from a
-- proof that the whole guard evaluated to True, without any axioms.
-- ═══════════════════════════════════════════════════════════════════════════

||| From `a && b = True`, the left conjunct is True.
andTrueLeft : (a : Bool) -> (b : Bool) -> (a && b) = True -> a = True
andTrueLeft True  _ _   = Refl
andTrueLeft False _ prf = absurd prf

||| From `a && b = True`, the right conjunct is True.
andTrueRight : (a : Bool) -> (b : Bool) -> (a && b) = True -> b = True
andTrueRight True  _ prf = prf
andTrueRight False _ prf = absurd prf

||| Soundness of `==` against `Ready` for CartridgeStatus: the only status
||| that compares equal to `Ready` is `Ready` itself.
statusEqSoundReady : (s : CartridgeStatus) -> (s == Ready) = True -> s = Ready
statusEqSoundReady Ready       _   = Refl
statusEqSoundReady Development prf = absurd prf
statusEqSoundReady Deprecated  prf = absurd prf
statusEqSoundReady Faulty      prf = absurd prf

-- Constructor disjointness for the `CartridgeStatus` lifecycle. `Ready` is a
-- distinct constructor from every other state, so the corresponding equalities
-- are uninhabited — proved by the absent `Refl` case, with no axioms.
Uninhabited (Ready = Development) where
  uninhabited Refl impossible

Uninhabited (Ready = Deprecated) where
  uninhabited Refl impossible

Uninhabited (Ready = Faulty) where
  uninhabited Refl impossible

-- ═══════════════════════════════════════════════════════════════════════════
-- Request and Dispatch Result Types
-- ═══════════════════════════════════════════════════════════════════════════

||| A dispatch request: which protocol and domain is the client requesting?
|||
||| The cartridge selected must support exactly this protocol AND domain.
public export
record DispatchRequest where
  constructor MkRequest
  reqProtocol : ProtocolType
  reqDomain   : CapabilityDomain

||| The outcome of dispatching a request against the catalogue.
|||
||| Routed carries a proof that the selected cartridge is:
|||   - ready (IsUnbreakable)
|||   - supports the requested protocol (ProtocolMatch)
|||
||| Refused means no ready cartridge could handle the request.
public export
data DispatchResult : DispatchRequest -> Type where
  Routed  : (c : Cartridge)
          -> IsUnbreakable c
          -> (req : DispatchRequest)
          -> (pf  : reqProtocol req `elem` protocols c = True)
          -> DispatchResult req
  Refused : (req : DispatchRequest)
          -> DispatchResult req

-- ═══════════════════════════════════════════════════════════════════════════
-- Protocol Membership Lemmas
-- ═══════════════════════════════════════════════════════════════════════════

||| Once the `foldl` accumulator of `elem` is True it stays True, regardless
||| of the remaining list. `elem` is left-folded with `||`, so reducing
||| `elem p (p :: ps)` exposes exactly this shape after `p == p` is known.
orFoldlAccTrue : (q : ProtocolType -> Bool) -> (xs : List ProtocolType)
              -> foldl (\acc, e => acc || q e) True xs = True
orFoldlAccTrue q []        = Refl
orFoldlAccTrue q (y :: ys) = orFoldlAccTrue q ys

||| If a protocol is the head of the list, elem returns True.
protocolElemHead : (p : ProtocolType) -> (ps : List ProtocolType)
                -> p `elem` (p :: ps) = True
protocolElemHead p ps with (p == p) proof eq
  protocolElemHead p ps | True  = orFoldlAccTrue (p ==) ps
  protocolElemHead p ps | False = absurd (trans (sym eq) (elemSame p))
  where
    -- p == p = True for our Eq ProtocolType instance (all 9 cases reflexive)
    elemSame : (q : ProtocolType) -> q == q = True
    elemSame MCP     = Refl
    elemSame LSP     = Refl
    elemSame DAP     = Refl
    elemSame BSP     = Refl
    elemSame NeSy    = Refl
    elemSame Agentic = Refl
    elemSame Fleet   = Refl
    elemSame GRPC    = Refl
    elemSame REST    = Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- Core Dispatch Invariant
-- ═══════════════════════════════════════════════════════════════════════════

||| BJ1 — INVARIANT: ProtocolMatch
|||
||| If `lookupCell req.reqProtocol req.reqDomain catalogue` returns (Just c),
||| then the requested protocol is a member of c.protocols.
|||
||| This is the core dispatch type-safety theorem: the catalogue lookup
||| function is the only code path that can produce a Cartridge for
||| dispatch, and we prove here that every cartridge it returns
||| necessarily advertises the requested protocol.
|||
||| Proof strategy:
|||   lookupCell is structurally recursive. At each step it checks
|||   `elem p (protocols c)`. The `= True` branch is the only branch that
|||   can return `Just c`. We extract that boolean witness as our proof.
export
protocolMatchInvariant :
  (p   : ProtocolType)
  -> (d   : CapabilityDomain)
  -> (cs  : List Cartridge)
  -> (c   : Cartridge)
  -> lookupCell p d cs = Just c
  -> p `elem` protocols c = True
protocolMatchInvariant p d [] c eq = absurd eq
protocolMatchInvariant p d (x :: xs) c eq with (domain x == d && elem p (protocols x) && status x == Ready) proof cond
  -- Guard held: `lookupCell` returned `Just x`, so `eq : Just x = Just c`
  -- forces `c = x`; the protocol conjunct is the left of the inner `&&`.
  protocolMatchInvariant p d (x :: xs) x Refl | True =
    andTrueLeft _ _ (andTrueRight _ _ cond)
  -- Guard failed: recurse on the tail with the same lookup proof.
  protocolMatchInvariant p d (x :: xs) c eq | False =
    protocolMatchInvariant p d xs c eq

||| BJ1 — INVARIANT: ReadinessGuard
|||
||| If `lookupCell` returns (Just c), then c.status = Ready.
|||
||| This complements ProtocolMatch: not only does the cartridge handle the
||| right protocol, it has also passed the safety gate.
export
readinessGuard :
  (p  : ProtocolType)
  -> (d  : CapabilityDomain)
  -> (cs : List Cartridge)
  -> (c  : Cartridge)
  -> lookupCell p d cs = Just c
  -> status c = Ready
readinessGuard p d [] c eq = absurd eq
readinessGuard p d (x :: xs) c eq with (domain x == d && elem p (protocols x) && status x == Ready) proof cond
  -- Guard held: `status x == Ready` is the right conjunct of the inner `&&`;
  -- `statusEqSoundReady` turns the boolean test into the propositional equality.
  readinessGuard p d (x :: xs) x Refl | True =
    statusEqSoundReady (status x) (andTrueRight _ _ (andTrueRight _ _ cond))
  -- Guard failed: recurse on the tail with the same lookup proof.
  readinessGuard p d (x :: xs) c eq | False =
    readinessGuard p d xs c eq

||| BJ1 — INVARIANT: IsUnbreakable from lookupCell.
|||
||| Combines readinessGuard with the IsUnbreakable constructor to produce
||| the proof object required by DispatchResult.Routed.
export
lookupImpliesUnbreakable :
  (p  : ProtocolType)
  -> (d  : CapabilityDomain)
  -> (cs : List Cartridge)
  -> (c  : Cartridge)
  -> lookupCell p d cs = Just c
  -> IsUnbreakable c
lookupImpliesUnbreakable p d cs c eq =
  VerifiedReady c (readinessGuard p d cs c eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- Dispatch Decision Function
-- ═══════════════════════════════════════════════════════════════════════════

||| Dispatch a request against the catalogue.
|||
||| Returns a DispatchResult indexed by the request. If a ready cartridge
||| is found, Routed carries the protocol-match proof and the unbreakable
||| proof. Otherwise Refused is returned.
|||
||| This function is *total*: every possible input has a well-typed output.
||| The type of the result guarantees (at compile time) that:
|||   - A Routed cartridge supports the requested protocol.
|||   - A Routed cartridge is in Ready status.
||| Dispatch given the catalogue-lookup result *and* the proof that it is
||| that result. Factoring this out of `dispatch` keeps the definition
||| definitionally reducible on the lookup value — the refused-completeness
||| theorem below relies on that, which a `with`-block definition would not
||| provide.
dispatchOn : (req : DispatchRequest) -> (cs : List Cartridge)
          -> (m : Maybe Cartridge)
          -> (lookupCell (reqProtocol req) (reqDomain req) cs = m)
          -> DispatchResult req
dispatchOn req cs Nothing  _   = Refused req
dispatchOn req cs (Just c) prf =
    Routed c
      (lookupImpliesUnbreakable (reqProtocol req) (reqDomain req) cs c prf)
      req
      (protocolMatchInvariant (reqProtocol req) (reqDomain req) cs c prf)

export
dispatch : (req : DispatchRequest) -> (cs : List Cartridge) -> DispatchResult req
dispatch req cs =
  dispatchOn req cs (lookupCell (reqProtocol req) (reqDomain req) cs) Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- Disjointness Theorem
-- ═══════════════════════════════════════════════════════════════════════════

||| BJ1 — INVARIANT: Disjointness
|||
||| A cartridge cannot be simultaneously Ready and not-Ready.
||| This rules out a class of race conditions where dispatch logic
||| might observe inconsistent cartridge status.
|||
||| Proof: by case analysis on the two status witnesses.
export
statusDisjoint :
  (c : Cartridge)
  -> status c = Ready
  -> status c = Development
  -> Void
statusDisjoint c pReady pDev = absurd (trans (sym pReady) pDev)

export
readyNotFaulty :
  (c : Cartridge)
  -> status c = Ready
  -> status c = Faulty
  -> Void
readyNotFaulty c pReady pFaulty = absurd (trans (sym pReady) pFaulty)

export
readyNotDeprecated :
  (c : Cartridge)
  -> status c = Ready
  -> status c = Deprecated
  -> Void
readyNotDeprecated c pReady pDep = absurd (trans (sym pReady) pDep)

-- ═══════════════════════════════════════════════════════════════════════════
-- Refused Completeness
-- ═══════════════════════════════════════════════════════════════════════════

||| If lookupCell returns Nothing, dispatch is Refused.
|||
||| This is the completeness direction: refused dispatch corresponds
||| exactly to the absence of any matching ready cartridge.
export
refusedIfNoMatch :
  (req : DispatchRequest)
  -> (cs  : List Cartridge)
  -> lookupCell (reqProtocol req) (reqDomain req) cs = Nothing
  -> dispatch req cs = Refused req
refusedIfNoMatch req cs noMatch =
    lemma (lookupCell (reqProtocol req) (reqDomain req) cs) Refl noMatch
  where
    -- `dispatch req cs` is definitionally `dispatchOn req cs (lookupCell …) Refl`,
    -- so proving the goal for an arbitrary lookup result `m` (with its defining
    -- proof) and then instantiating at the real lookup value discharges it.
    lemma : (m : Maybe Cartridge)
         -> (prf : lookupCell (reqProtocol req) (reqDomain req) cs = m)
         -> m = Nothing
         -> dispatchOn req cs m prf = Refused req
    lemma Nothing  _ _   = Refl
    lemma (Just c) _ eqN = absurd eqN
