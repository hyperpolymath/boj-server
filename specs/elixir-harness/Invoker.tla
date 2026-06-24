------------------------------ MODULE Invoker ------------------------------
\* SPDX-License-Identifier: MPL-2.0
\* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
(***************************************************************************)
(* Formal model of `BojRest.Invoker`                                        *)
(* (elixir/lib/boj_rest/invoker.ex).                                        *)
(*                                                                          *)
(* Invoker is a STATELESS, SYNCHRONOUS dispatcher.  Every call to           *)
(* Invoker.invoke/4 either short-circuits immediately (CLI binary not        *)
(* found → :cli_missing) or blocks on `System.cmd/3` until the `boj-invoke` *)
(* OS subprocess exits.  There is no GenServer, no pool, and no per-         *)
(* invocation timeout in the current Phase 2 implementation (ADR-0005).     *)
(* Because `System.cmd` is blocking, the caller's Erlang process is the     *)
(* only thing waiting — no shared mailbox, no shared ETS, no shared port.   *)
(*                                                                          *)
(* The headline property is ISOLATION: for any two concurrent invocations   *)
(* r1 ≠ r2, the outcome of r1 is entirely independent of r2.  This is      *)
(* structurally guaranteed because every action in Next touches exactly one  *)
(* request id; DoneOnce and Consistent confirm no request is resolved twice. *)
(*                                                                          *)
(* Exit-code → result classification (boj_invoke_cli.zig contract):         *)
(*   CLI not found         → cli_missing  (no subprocess spawned)           *)
(*   exit 0 + valid JSON   → ok                                             *)
(*   exit 0 + invalid JSON → cli_crashed  (JSON parse failure)              *)
(*   exit 2               → args_err                                        *)
(*   exit 3               → open_err                                        *)
(*   exit 4               → missing_symbol_err                              *)
(*   exit 5               → init_failed_err                                 *)
(*   exit other           → cli_crashed                                     *)
(*                                                                          *)
(* Note on timeouts: the current code has NO per-invocation timeout.        *)
(* `System.cmd` blocks indefinitely if the subprocess hangs.  ADR-0005      *)
(* specifies 5 s (future pool) but the Phase 2 skeleton does not implement  *)
(* it.  The liveness property below (EventuallyDone) therefore carries an   *)
(* [ASSUMED] tag: it holds only if the `boj-invoke` subprocess eventually   *)
(* exits on its own.  See README.adoc §"Known gaps".                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Requests  \* finite set of opaque invocation ids

Results == {"none", "ok", "cli_missing", "cli_crashed",
            "args_err", "open_err", "missing_symbol_err", "init_failed_err"}

VARIABLES
  status,    \* [Requests -> {"new", "running", "done"}]
  result,    \* [Requests -> Results]
  doneCount  \* [Requests -> 0..2]  (double-resolution detector)

vars == <<status, result, doneCount>>

TypeOK ==
  /\ status    \in [Requests -> {"new", "running", "done"}]
  /\ result    \in [Requests -> Results]
  /\ doneCount \in [Requests -> 0..2]

Init ==
  /\ status    = [r \in Requests |-> "new"]
  /\ result    = [r \in Requests |-> "none"]
  /\ doneCount = [r \in Requests |-> 0]

(*-------------------------- DISPATCH ACTIONS ----------------------------*)

\* Invoker.run/4 finds the CLI binary → spawns subprocess via System.cmd.
\* Moves the request from "new" to "running" (subprocess is now live).
Invoke(r) ==
  /\ status[r] = "new"
  /\ status' = [status EXCEPT ![r] = "running"]
  /\ UNCHANGED <<result, doneCount>>

\* Invoker.cli_path() returns nil → immediate short-circuit, no subprocess.
\* The request goes from "new" directly to "done".
CliMissing(r) ==
  /\ status[r] = "new"
  /\ status'    = [status    EXCEPT ![r] = "done"]
  /\ result'    = [result    EXCEPT ![r] = "cli_missing"]
  /\ doneCount' = [doneCount EXCEPT ![r] = @ + 1]

(*-------------------------- RESOLUTION ACTIONS --------------------------*)

\* The single guarded resolution path: status[r] = "running" guard +
\* atomic move to "done" disables all competing resolution actions.
\* (The subprocess can only exit once; the Erlang process unblocks once.)
Resolve(r, kind) ==
  /\ status[r] = "running"
  /\ status'    = [status    EXCEPT ![r] = "done"]
  /\ result'    = [result    EXCEPT ![r] = kind]
  /\ doneCount' = [doneCount EXCEPT ![r] = @ + 1]

\* exit 0 + Jason.decode succeeds → {:ok, map}
RespondOk(r)          == Resolve(r, "ok")

\* exit 0 + Jason.decode fails, OR exit code not in {2,3,4,5} → :cli_crashed
RespondCliCrashed(r)  == Resolve(r, "cli_crashed")

\* exit 2 → :args
RespondArgs(r)        == Resolve(r, "args_err")

\* exit 3 → :open
RespondOpen(r)        == Resolve(r, "open_err")

\* exit 4 → :missing_symbol
RespondMissingSym(r)  == Resolve(r, "missing_symbol_err")

\* exit 5 → :init_failed
RespondInitFailed(r)  == Resolve(r, "init_failed_err")

Next ==
  \E r \in Requests :
    Invoke(r) \/ CliMissing(r) \/
    RespondOk(r) \/ RespondCliCrashed(r) \/ RespondArgs(r) \/
    RespondOpen(r) \/ RespondMissingSym(r) \/ RespondInitFailed(r)

\* [ASSUMED] Each subprocess eventually exits on its own (no timeout in
\* Phase 2; the outer Cowboy connection timeout is the de-facto bound).
\* WF_vars on the disjunction of all resolution actions captures: once
\* a subprocess is running, some resolution action eventually fires.
Spec ==
  /\ Init /\ [][Next]_vars
  /\ \A r \in Requests :
       WF_vars(RespondOk(r) \/ RespondCliCrashed(r) \/ RespondArgs(r) \/
               RespondOpen(r) \/ RespondMissingSym(r) \/ RespondInitFailed(r))

(*-------------------------------- SAFETY --------------------------------*)

\* Each invocation resolves at most once (no double System.cmd reply).
DoneOnce == \A r \in Requests : doneCount[r] <= 1

Consistent ==
  /\ \A r \in Requests : (status[r] = "running") => (result[r] = "none")
  /\ \A r \in Requests : (status[r] = "done")    => (result[r] # "none")
  /\ \A r \in Requests : (status[r] = "new")     => (result[r] = "none")

(*------------------------------ LIVENESS --------------------------------*)

\* [ASSUMED] Once a subprocess is spawned, it eventually exits and the
\* invocation resolves.  Relies on well-behaved CLI + WF above.
EventuallyDone ==
  \A r \in Requests : (status[r] = "running") ~> (status[r] = "done")

(*------------------------ SANITY CONTROLS (non-vacuity) ----------------*)
\* Each of these is EXPECTED TO BE VIOLATED when checked as an invariant.
\* TLC refutes them with short witness traces, proving every result kind is
\* genuinely reachable.  They are NOT in Invoker.cfg.
ReachOk          == \A r \in Requests : result[r] # "ok"
ReachCliMissing  == \A r \in Requests : result[r] # "cli_missing"
ReachCliCrashed  == \A r \in Requests : result[r] # "cli_crashed"
ReachArgs        == \A r \in Requests : result[r] # "args_err"
ReachOpen        == \A r \in Requests : result[r] # "open_err"
ReachMissingSym  == \A r \in Requests : result[r] # "missing_symbol_err"
ReachInitFailed  == \A r \in Requests : result[r] # "init_failed_err"

============================================================================
