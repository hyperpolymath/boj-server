---------------------------- MODULE JsWorker ----------------------------
\* SPDX-License-Identifier: MPL-2.0
\* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
(***************************************************************************)
(* Formal model of `BojRest.JsWorker`                                       *)
(* (elixir/lib/boj_rest/js_worker.ex).                                      *)
(*                                                                          *)
(* A JsWorker is a GenServer wrapping one persistent Deno OS process (a     *)
(* Port).  It PIPELINES several concurrent requests to that one process,    *)
(* keeping a `pending` map of id -> {caller, timer}; replies are matched by  *)
(* id.  Each request carries a 30s timeout.  If the Deno process exits, all  *)
(* pending callers are replied `:worker_crashed` and the GenServer stops so  *)
(* the :one_for_one pool Supervisor can restart it with a fresh process.     *)
(*                                                                          *)
(* This model abstracts the Deno process to a nondeterministic oracle that, *)
(* for any pending request, may: respond ok, respond error, stay silent     *)
(* (so the timer fires), or crash.  Requests are opaque ids.  JSON, the     *)
(* HTTP layer and the Zig FFI are out of scope.                             *)
(*                                                                          *)
(* The headline property is REPLY-ONCE: a response, a timeout and a crash   *)
(* race for every in-flight id, yet each caller must be replied EXACTLY     *)
(* once.  In the code this is enforced by `Map.pop` (whoever pops the id     *)
(* first replies; the loser sees `nil`) plus `Process.cancel_timer`.  Here   *)
(* it is enforced by every delivering action requiring `status[r]="pending"` *)
(* and atomically moving it to `"done"`, which disables the racing actions.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Requests          \* finite set of opaque request ids

Replies == {"none", "ok", "jsErr", "timeout", "crashed"}

VARIABLES
  status,      \* [Requests -> {"new","pending","done"}]
  reply,       \* [Requests -> Replies]   (classification once done)
  replyCount,  \* [Requests -> 0..2]      (how many replies were delivered)
  up           \* BOOLEAN                 (worker process alive)

vars == <<status, reply, replyCount, up>>

TypeOK ==
  /\ status     \in [Requests -> {"new", "pending", "done"}]
  /\ reply      \in [Requests -> Replies]
  /\ replyCount \in [Requests -> 0..2]
  /\ up         \in BOOLEAN

Init ==
  /\ status     = [r \in Requests |-> "new"]
  /\ reply      = [r \in Requests |-> "none"]
  /\ replyCount = [r \in Requests |-> 0]
  /\ up         = TRUE

(* handle_call({:invoke, ...}): a fresh request is accepted; timer armed.   *)
Arrive(r) ==
  /\ up
  /\ status[r] = "new"
  /\ status' = [status EXCEPT ![r] = "pending"]
  /\ UNCHANGED <<reply, replyCount, up>>

(* The single guarded reply path. `Map.pop` is modelled by the              *)
(* status[r]="pending" guard + atomic move to "done": once delivered, the   *)
(* racing actions for r are disabled, so reply-once holds by construction.  *)
Deliver(r, kind) ==
  /\ up
  /\ status[r] = "pending"
  /\ status'     = [status     EXCEPT ![r] = "done"]
  /\ reply'      = [reply      EXCEPT ![r] = kind]
  /\ replyCount' = [replyCount EXCEPT ![r] = @ + 1]
  /\ UNCHANGED up

RespondOk(r)  == Deliver(r, "ok")        \* dispatch_response, status 2xx
RespondErr(r) == Deliver(r, "jsErr")     \* dispatch_response, status not 2xx
Timeout(r)    == Deliver(r, "timeout")   \* handle_info({:timeout, id})

(* handle_info({port,{:exit_status,_}}): reply-all pending, then :stop.     *)
Crash ==
  /\ up
  /\ up' = FALSE
  /\ status'     = [r \in Requests |->
                      IF status[r] = "pending" THEN "done" ELSE status[r]]
  /\ reply'      = [r \in Requests |->
                      IF status[r] = "pending" THEN "crashed" ELSE reply[r]]
  /\ replyCount' = [r \in Requests |->
                      IF status[r] = "pending" THEN replyCount[r] + 1 ELSE replyCount[r]]

(* Supervisor :one_for_one restart: a fresh worker with empty `pending`.    *)
(* Requests already replied stay replied; no pending is carried across.     *)
Restart ==
  /\ ~up
  /\ up' = TRUE
  /\ UNCHANGED <<status, reply, replyCount>>

Next ==
  \/ \E r \in Requests : Arrive(r) \/ RespondOk(r) \/ RespondErr(r) \/ Timeout(r)
  \/ Crash
  \/ Restart

Spec ==
  /\ Init /\ [][Next]_vars
  /\ \A r \in Requests : WF_vars(Timeout(r))  \* the 30s timer guarantees progress
  /\ WF_vars(Restart)                         \* the supervisor eventually restarts

(*-------------------------------- SAFETY --------------------------------*)

(* A pending request has no reply yet; a done request has exactly one.      *)
Consistent ==
  /\ \A r \in Requests : (status[r] = "pending") => (reply[r] = "none")
  /\ \A r \in Requests : (status[r] = "done")    => (reply[r] # "none")
  /\ \A r \in Requests : (status[r] = "new")     => (reply[r] = "none")

(* The headline: no caller is ever replied twice (no double GenServer.reply).*)
ReplyOnce == \A r \in Requests : replyCount[r] <= 1

(* Crash clears `pending` atomically: while the worker is down, nothing is   *)
(* left in-flight (so a stale message cannot be replied after :stop).        *)
NoPendingWhileDown == (~ up) => (\A r \in Requests : status[r] # "pending")

(*------------------------------- LIVENESS -------------------------------*)

(* Every request that enters the worker eventually gets a reply — the        *)
(* per-request timeout guarantees this even if Deno hangs forever.           *)
EventuallyReplied ==
  \A r \in Requests : (status[r] = "pending") ~> (status[r] = "done")

(*--------------------------- SANITY CONTROLS ----------------------------*)
(* Each of these is EXPECTED TO BE VIOLATED when checked as an invariant    *)
(* (see the loop in README.adoc).  Each asserts a terminal reply kind is    *)
(* never reached; TLC refuting it returns a short witness trace, proving    *)
(* the model is non-vacuous and that the ok / timeout / crashed outcomes    *)
(* are all genuinely reachable.  They are NOT part of JsWorker.cfg.         *)
ReachOk      == \A r \in Requests : reply[r] # "ok"
ReachTimeout == \A r \in Requests : reply[r] # "timeout"
ReachCrashed == \A r \in Requests : reply[r] # "crashed"

============================================================================
