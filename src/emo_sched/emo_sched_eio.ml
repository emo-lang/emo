(* Phase A scheduler: Emo processes on Eio fibers.

   The evaluator performs Spawn/Send/Self_pid/Receive; this driver handles
   them at the process boundary. Each process runs as a daemon fiber on one
   shared domain — when the root process ends, remaining processes are
   cancelled: the program ends with its root. A process blocked in
   `receive` waits on its mailbox condition and rescans on every broadcast;
   messages whose guard fails stay queued. *)

(* Runs one process body under this driver's handlers and records the exit.
   A crash marks the process and dies alone — except the root, whose
   uncaught raise or failure is the program's outcome. Cancelled fibers
   (root exit shutting the system down) propagate the cancellation without
   recording anything.

   [conditions] is the system-wide pid → mailbox-condition table, shared by
   every handler instance: a sender must broadcast the very condition the
   receiver waits on. *)
let rec run_process ~sw ~conditions ~root (proc : Emo_eval.process)
    (body : unit -> unit) : unit =
  let cond_of pid =
    match Hashtbl.find_opt conditions pid with
    | Some c -> c
    | None ->
        let c = Eio.Condition.create () in
        Hashtbl.replace conditions pid c;
        c
  in
  let crashed = ref None in
  (try
     Effect.Deep.try_with body ()
       {
         effc =
           (fun (type a) (eff : a Effect.t) ->
             match eff with
             | Emo_eval.Spawn (thunk, _span) ->
                 Some
                   (fun (k : (a, _) continuation) ->
                     let child = Emo_eval.spawn_record () in
                     Eio.Fiber.fork_daemon ~sw (fun () ->
                         run_process ~sw ~conditions ~root:false child thunk;
                         `Stop_daemon);
                     Effect.Deep.continue k child.Emo_eval.pid)
             | Emo_eval.Send (pid, v, span) ->
                 Some
                   (fun (k : (a, _) continuation) ->
                     let target = Emo_eval.find_process span pid in
                     Emo_eval.deliver target v;
                     Eio.Condition.broadcast (cond_of pid);
                     Effect.Deep.continue k ())
             | Emo_eval.Self_pid ->
                 Some
                   (fun (k : (a, _) continuation) ->
                     Effect.Deep.continue k proc.Emo_eval.pid)
             | Emo_eval.Receive select ->
                 Some
                   (fun (k : (a, _) continuation) ->
                     let picked =
                       Eio.Condition.loop_no_mutex (cond_of proc.Emo_eval.pid)
                         (fun () -> Emo_eval.take_matching proc select)
                     in
                     Effect.Deep.continue k picked)
             | _ -> None);
       }
   with
  | Emo_eval.Halt_signal -> crashed := Some Emo_eval.Exit_normal
  | Emo_eval.Emo_raise (v, span, _trace) ->
      if root then raise (Emo_eval.Emo_raise (v, span, _trace))
      else crashed := Some (Emo_eval.Exit_raised (v, span))
  | Emo_eval.Error diagnostic ->
      if root then raise (Emo_eval.Error diagnostic)
      else crashed := Some (Emo_eval.Exit_failed diagnostic));
  let outcome =
    match !crashed with Some info -> info | None -> Emo_eval.Exit_normal
  in
  Emo_eval.mark_exit proc outcome

(* Runs [root_body] as the root process — the whole program. *)
let run (root_body : unit -> unit) : unit =
  Emo_eval.reset_conc ();
  Eio_main.run (fun _stdenv ->
      try
        Eio.Switch.run (fun sw ->
            let conditions : (int, Eio.Condition.t) Hashtbl.t =
              Hashtbl.create 8
            in
            let root = Emo_eval.spawn_record () in
            run_process ~sw ~conditions ~root:true root root_body)
      with Emo_eval.Halt_signal -> ())
