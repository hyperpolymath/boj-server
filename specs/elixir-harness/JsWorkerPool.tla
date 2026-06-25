-------------------------- MODULE JsWorkerPool --------------------------
\* SPDX-License-Identifier: MPL-2.0
\* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
(***************************************************************************)
(* Formal model of `BojRest.JsWorkerPool`                                   *)
(* (elixir/lib/boj_rest/js_worker_pool.ex + js_worker.ex).                  *)
(*                                                                          *)
(* A JsWorkerPool is a :one_for_one Supervisor over N JsWorker GenServers,  *)
(* each wrapping one persistent Deno OS process (a Port).  The pool         *)
(* dispatches requests via :erlang.phash2 (consistent hash): the same       *)
(* mod_js_path always routes to the same worker slot, maximising Deno       *)
(* module-cache hits.  If the hashed slot is down, the pool falls back to   *)
(* JsInvoker (fork-per-call), which always terminates independently.        *)
(*                                                                          *)
(* This model composes with JsWorker.tla: it re-uses the same              *)
(* status/reply/replyCount discipline but lifts it to N workers, adding    *)
(* two pool-level properties:                                               *)
(*                                                                          *)
(*  CRASH-ISOLATION: a crash at worker w terminates only the requests       *)
(*  assigned to w; every other in-flight request is completely unaffected.  *)
(*                                                                          *)
(*  ROUTE-CONSISTENCY: a request that enters a pool slot is always at the   *)
(*  slot its Route function maps it to — never a wrong slot.               *)
(*                                                                          *)
(* ReplyOnce (no double GenServer.reply) and EventuallyReplied (every       *)
(* pending request eventually gets a reply) continue to hold over the pool. *)
(*                                                                          *)
(* Abstraction:                                                             *)
(*   - Requests are opaque ids; Route is a fixed [Requests -> Workers]      *)
(*     constant (the phash2 function, frozen at model-check time).          *)
(*   - Each Deno process is a nondeterministic oracle: ok / jsErr / silent  *)
(*     (timer fires) / crash.  JSON, HTTP, and Zig FFI are out of scope.   *)
(*   - The fallback JsInvoker is modelled as an atomic "always-terminates"  *)
(*     action; its internal state is not modelled here.                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Requests,  \* finite set of opaque request ids
  Workers,   \* finite set of worker ids (e.g., {w0,w1,w2,w3,w4})
  Route      \* [Requests -> Workers]: the phash2 routing table (fixed)

ASSUME Route \in [Requests -> Workers]

Replies  == {"none", "ok", "jsErr", "timeout", "crashed", "fallback"}
Statuses == {"new", "pending", "done"}

\* Sentinel: a value guaranteed to be outside Workers.  Used to mark
\* requests that have not yet been assigned to a pool slot.
NoWorker == CHOOSE x : x \notin Workers

VARIABLES
  status,      \* [Requests -> Statuses]
  reply,       \* [Requests -> Replies]   (classification once done)
  replyCount,  \* [Requests -> 0..2]      (double-reply detector)
  assigned,    \* [Requests -> Workers ∪ {NoWorker}]
  wup          \* [Workers  -> BOOLEAN]   (Deno process alive?)

vars == <<status, reply, replyCount, assigned, wup>>

TypeOK ==
  /\ status     \in [Requests -> Statuses]
  /\ reply      \in [Requests -> Replies]
  /\ replyCount \in [Requests -> 0..2]
  /\ assigned   \in [Requests -> Workers \cup {NoWorker}]
  /\ wup        \in [Workers  -> BOOLEAN]

Init ==
  /\ status     = [r \in Requests |-> "new"]
  /\ reply      = [r \in Requests |-> "none"]
  /\ replyCount = [r \in Requests |-> 0]
  /\ assigned   = [r \in Requests |-> NoWorker]
  /\ wup        = [w \in Workers  |-> TRUE]

(*-------------------------- DISPATCH ACTIONS ----------------------------*)

\* pick_worker/1: hashed slot is alive → route to pool.
\* js_worker_pool.ex `invoke/4` → `JsWorker.handle_call({:invoke,...})`.
ArrivePool(r) ==
  LET w == Route[r] IN
  /\ status[r] = "new"
  /\ wup[w]
  /\ status'   = [status   EXCEPT ![r] = "pending"]
  /\ assigned' = [assigned EXCEPT ![r] = w]
  /\ UNCHANGED <<reply, replyCount, wup>>

\* pick_worker/1 returns nil → fall back to JsInvoker (fork-per-call).
\* Modelled as atomic: JsInvoker always terminates, so we skip its
\* internal state and deliver "fallback" directly.
ArriveFallback(r) ==
  /\ status[r] = "new"
  /\ ~wup[Route[r]]
  /\ status'     = [status     EXCEPT ![r] = "done"]
  /\ reply'      = [reply      EXCEPT ![r] = "fallback"]
  /\ replyCount' = [replyCount EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<assigned, wup>>

(*-------------------------- DELIVERY ACTIONS ----------------------------*)

\* The single guarded reply path — the same Map.pop discipline as
\* JsWorker.tla: status[r]="pending" guard + atomic move to "done"
\* disables all racing actions (RespondOk/RespondErr/Timeout/Crash).
Deliver(r, kind) ==
  LET w == assigned[r] IN
  /\ w \in Workers
  /\ wup[w]
  /\ status[r] = "pending"
  /\ status'     = [status     EXCEPT ![r] = "done"]
  /\ reply'      = [reply      EXCEPT ![r] = kind]
  /\ replyCount' = [replyCount EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<assigned, wup>>

\* js_worker.ex `dispatch_response/2`, status 2xx.
RespondOk(r)  == Deliver(r, "ok")

\* js_worker.ex `dispatch_response/2`, status not 2xx.
RespondErr(r) == Deliver(r, "jsErr")

\* js_worker.ex `handle_info({:timeout, id})`.
\* The 30s timer fires; no response arrived in time.
Timeout(r)    == Deliver(r, "timeout")

(*------------------------ CRASH AND RESTART ----------------------------*)

\* js_worker.ex `handle_info({port,{:exit_status,_}})`:
\* reply-all-pending then :stop.
\*
\* Crash(w) touches ONLY requests whose assigned[r] = w.  Requests at
\* other workers are not mentioned in this action — CRASH-ISOLATION is
\* enforced structurally, not by an external invariant.
Crash(w) ==
  /\ wup[w]
  /\ wup'        = [wup        EXCEPT ![w] = FALSE]
  /\ status'     = [r \in Requests |->
                      IF status[r] = "pending" /\ assigned[r] = w
                      THEN "done"     ELSE status[r]]
  /\ reply'      = [r \in Requests |->
                      IF status[r] = "pending" /\ assigned[r] = w
                      THEN "crashed"  ELSE reply[r]]
  /\ replyCount' = [r \in Requests |->
                      IF status[r] = "pending" /\ assigned[r] = w
                      THEN replyCount[r] + 1 ELSE replyCount[r]]
  /\ UNCHANGED assigned

\* :one_for_one restart: a fresh Deno process for worker w only.
\* The other workers' states and all already-replied requests are unchanged.
Restart(w) ==
  /\ ~wup[w]
  /\ wup' = [wup EXCEPT ![w] = TRUE]
  /\ UNCHANGED <<status, reply, replyCount, assigned>>

Next ==
  \/ \E r \in Requests :
       ArrivePool(r) \/ ArriveFallback(r) \/
       RespondOk(r) \/ RespondErr(r) \/ Timeout(r)
  \/ \E w \in Workers : Crash(w) \/ Restart(w)

\* Fairness:
\*   - Each request's 30s timer eventually fires (WF on Timeout).
\*   - ArriveFallback is available whenever the slot is down; WF ensures it
\*     eventually fires for a new request stranded by a crashed slot.
\*   - The :one_for_one Supervisor eventually restarts every stopped worker.
Spec ==
  /\ Init /\ [][Next]_vars
  /\ \A r \in Requests : WF_vars(Timeout(r))
  /\ \A r \in Requests : WF_vars(ArriveFallback(r))
  /\ \A w \in Workers  : WF_vars(Restart(w))

(*-------------------------------- SAFETY --------------------------------*)

\* Inherited from JsWorker.tla — held pool-wide.
ReplyOnce == \A r \in Requests : replyCount[r] <= 1

Consistent ==
  /\ \A r \in Requests : (status[r] = "pending") => (reply[r] = "none")
  /\ \A r \in Requests : (status[r] = "done")    => (reply[r] # "none")
  /\ \A r \in Requests : (status[r] = "new")     => (reply[r] = "none")

\* Pool-specific: Crash(w) atomically clears every request at w, so no
\* pending request remains after the worker stops.
NoPendingWhileDown ==
  \A w \in Workers, r \in Requests :
    (status[r] = "pending" /\ assigned[r] = w) => wup[w]

\* ROUTE-CONSISTENCY: the phash2 invariant.  If a request is in-flight at
\* a pool slot, it is at the slot Route maps it to — guaranteed by ArrivePool
\* assigning `assigned[r] := Route[r]` and no action ever changing assigned.
RouteConsistency ==
  \A r \in Requests :
    (status[r] = "pending" /\ assigned[r] \in Workers) =>
      assigned[r] = Route[r]

(*------------------------------ LIVENESS --------------------------------*)

\* Every pending request eventually terminates (ok / jsErr / timeout /
\* crashed).  Guaranteed by the 30s timer (WF_vars(Timeout)) or by
\* worker crash, whichever fires first.
EventuallyReplied ==
  \A r \in Requests : (status[r] = "pending") ~> (status[r] = "done")

(*------------------------ SANITY CONTROLS (non-vacuity) ----------------*)
\* Each of these is EXPECTED TO BE VIOLATED when checked as an invariant
\* (see the loop in README.adoc).  TLC refutes them with short witness
\* traces, proving all four terminal outcomes are genuinely reachable.
\* They are NOT in JsWorkerPool.cfg.
ReachOk       == \A r \in Requests : reply[r] # "ok"
ReachTimeout  == \A r \in Requests : reply[r] # "timeout"
ReachCrashed  == \A r \in Requests : reply[r] # "crashed"
ReachFallback == \A r \in Requests : reply[r] # "fallback"

============================================================================
