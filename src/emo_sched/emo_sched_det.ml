(* The deterministic scheduler: an own effects runtime built for tests.

   One shallow handler per process step, an explicit run queue, and a
   seeded pick — the same seed replays the same interleaving, and the
   event log pins what happened. Race-sensitive tests reproduce against a
   recorded schedule instead of timing luck.

   The engine is also the phase B scheduler's core: only non-suspending
   effects continue a process inline, so a slice parked in `receive`
   returns to the loop and the stack stays flat across millions of
   message cycles. *)

type event =
  | Spawned of int (* the new pid *)
  | Sent of int * int (* from pid, to pid *)
  | Received of int (* the pid a receive resumed *)
  | Exited of int * string (* pid, "normal" | "raised" | "failed" *)

(* A scheduled process is either a fresh body or a continuation parked in
   `receive`, waiting for a message its select accepts. *)
type runnable =
  | Fresh of Emo_eval.process * (unit -> unit)
  | Resumed of
      Emo_eval.process
      * Emo_eval.selected
      * (Emo_eval.selected, unit) Effect.Shallow.continuation

(* How a scheduled slice ended: parked in receive is None. *)
type outcome = Emo_eval.exit_info option

type state = {
  runq : runnable Queue.t;
  waiters :
    ( int,
      Emo_eval.process
      * (Emo_eval.value -> Emo_eval.selected option)
      * (Emo_eval.selected, unit) Effect.Shallow.continuation )
    Hashtbl.t;
  mutable current : int; (* the pid performing effects right now *)
  rng : Random.State.t;
  log : event list ref;
  root : Emo_eval.process;
}

let log state event = state.log := event :: !(state.log)

(* The seeded pick: choose a random index among the runnable processes.
   Same seed, same choice, same interleaving. *)
let pick_and_take state =
  let n = Queue.length state.runq in
  let i = Random.State.int state.rng n in
  let taken = ref None in
  let keep = Queue.create () in
  for j = 0 to n - 1 do
    let item = Queue.take state.runq in
    if j = i then taken := Some item else Queue.add item keep
  done;
  Queue.transfer keep state.runq;
  match !taken with Some item -> item | None -> assert false

(* Wakes a parked receiver: rescanning its mailbox with its select, the
   first matching message is dequeued and the continuation rejoins the
   run queue. Nothing matching leaves the waiter parked. *)
let wake state pid =
  match Hashtbl.find_opt state.waiters pid with
  | None -> ()
  | Some (proc, select, k) -> (
      match Emo_eval.take_matching proc select with
      | None -> ()
      | Some picked ->
          Hashtbl.remove state.waiters pid;
          log state (Received proc.Emo_eval.pid);
          Queue.add (Resumed (proc, picked, k)) state.runq)

let exit_name = function
  | Emo_eval.Exit_normal -> "normal"
  | Emo_eval.Exit_raised _ -> "raised"
  | Emo_eval.Exit_failed _ -> "failed"

(* The shallow handler for one slice of [proc]. Non-suspending effects
   continue the process inline and propagate the slice's outcome; a
   `receive` with no matching message parks the continuation and reports
   [None], handing the domain back to the loop. *)
let rec handler state (proc : Emo_eval.process) () :
    (unit, outcome) Effect.Shallow.handler =
  {
    Effect.Shallow.retc = (fun () -> Some Emo_eval.Exit_normal);
    exnc =
      (fun exn ->
        match exn with
        | Emo_eval.Halt_signal -> Some Emo_eval.Exit_normal
        | Emo_eval.Emo_raise (v, span, trace) ->
            if proc == state.root then
              raise (Emo_eval.Emo_raise (v, span, trace))
            else Some (Emo_eval.Exit_raised (v, span))
        | Emo_eval.Error diagnostic ->
            if proc == state.root then raise (Emo_eval.Error diagnostic)
            else Some (Emo_eval.Exit_failed diagnostic)
        | e -> raise e);
    effc =
      (fun (type a) (eff : a Effect.t) ->
        match eff with
        | Emo_eval.Spawn (thunk, _span) ->
            Some
              (fun (k : (a, _) Effect.Shallow.continuation) ->
                let child = Emo_eval.spawn_record () in
                Queue.add (Fresh (child, thunk)) state.runq;
                log state (Spawned child.Emo_eval.pid);
                Effect.Shallow.continue_with k child.Emo_eval.pid
                  (handler state proc ()))
        | Emo_eval.Send (pid, v, span) ->
            Some
              (fun (k : (a, _) Effect.Shallow.continuation) ->
                let target = Emo_eval.find_process span pid in
                Emo_eval.deliver target v;
                log state (Sent (state.current, pid));
                wake state pid;
                Effect.Shallow.continue_with k () (handler state proc ()))
        | Emo_eval.Self_pid ->
            Some
              (fun (k : (a, _) Effect.Shallow.continuation) ->
                Effect.Shallow.continue_with k state.current
                  (handler state proc ()))
        | Emo_eval.Receive select ->
            Some
              (fun (k : (a, _) Effect.Shallow.continuation) ->
                match Emo_eval.take_matching proc select with
                | Some picked ->
                    log state (Received proc.Emo_eval.pid);
                    Effect.Shallow.continue_with k picked
                      (handler state proc ())
                | None ->
                    (* Nothing matches: park until a send wakes this
                       select, and give the domain to another process. *)
                    Hashtbl.replace state.waiters proc.Emo_eval.pid
                      (proc, select, k);
                    None)
        | _ -> None);
  }

let rec loop state =
  if Queue.is_empty state.runq then
    if Hashtbl.length state.waiters > 0 then
      (* Every live process is parked in receive with nothing left to wake
         it: the program can never move again. *)
      let span =
        Emo_support.Span.make ~file:"<runtime>" ~line:1 ~col:1 ~start:0 ~stop:0
      in
      Emo_eval.error span "E3012"
        (Printf.sprintf
           "all %d waiting processes are blocked; no message will ever arrive"
           (Hashtbl.length state.waiters))
    else ()
  else
    let item = pick_and_take state in
    let proc = match item with Fresh (p, _) -> p | Resumed (p, _, _) -> p in
    let h = handler state proc () in
    let outcome =
      match item with
      | Fresh (_, body) ->
          Effect.Shallow.continue_with (Effect.Shallow.fiber body) () h
      | Resumed (_, picked, k) -> Effect.Shallow.continue_with k picked h
    in
    (match outcome with
    | None -> ()
    | Some info ->
        let proc =
          match item with Fresh (p, _) -> p | Resumed (p, _, _) -> p
        in
        log state (Exited (proc.Emo_eval.pid, exit_name info));
        Emo_eval.mark_exit proc info);
    loop state

(* Runs [root_body] as the root process under the seeded schedule and
   returns the event log, oldest first. *)
let run ?(seed = 0) (root_body : unit -> unit) : event list =
  Emo_eval.reset_conc ();
  let state =
    {
      runq = Queue.create ();
      waiters = Hashtbl.create 8;
      current = 0;
      rng = Random.State.make [| seed |];
      log = ref [];
      root = Emo_eval.spawn_record ();
    }
  in
  Queue.add (Fresh (state.root, root_body)) state.runq;
  (try loop state with Emo_eval.Halt_signal -> ());
  List.rev !(state.log)
