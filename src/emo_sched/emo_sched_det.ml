(* The deterministic scheduler: an own effects runtime built for tests,
   and the scheduler `emo run` uses.

   One shallow handler per process step, an explicit run queue, and a
   seeded pick — the same seed replays the same interleaving, and the
   event log pins what happened. Race-sensitive tests reproduce against a
   recorded schedule instead of timing luck.

   The engine is also the phase B scheduler's core: only non-suspending
   effects continue a process inline, so a slice parked in `receive` or in
   a socket call returns to the loop and the stack stays flat across
   millions of message cycles.

   Networking rides the same loop: a socket operation that cannot finish
   immediately parks its continuation on the fd (read or write interest)
   and, where a deadline applies, on a timer. When the run queue empties,
   the loop polls readiness and fires due timers, so concurrent server and
   client processes interleave through real IO. When the root process has
   ended, the program ends with it — remaining processes are cancelled,
   exactly the phase A semantics. *)

type event =
  | Spawned of int (* the new pid *)
  | Sent of int * int (* from pid, to pid *)
  | Received of int (* the pid a receive resumed *)
  | Exited of int * string (* pid, "normal" | "raised" | "failed" *)

(* How a scheduled slice ended: parked in receive or IO is None. *)
type outcome = Emo_eval.exit_info option

(* A scheduled process is either a fresh body or a continuation parked in
   `receive` or in a socket operation. Interest in one fd's readability or
   writability re-queues the parked operation. The live socket behind a
   connection handle is its fd plus the bytes received but not yet
   consumed by a read operation. *)
type runnable =
  | Fresh of Emo_eval.process * (unit -> unit)
  | (* a sender parked by its own send: resume past the send, no payload *)
    Continue of Emo_eval.process * (unit, unit) Effect.Shallow.continuation
  | Resumed of
      Emo_eval.process
      * Emo_eval.selected
      * (Emo_eval.selected, unit) Effect.Shallow.continuation
  | (* a parked socket operation: the step attempts progress and either
       rejoins the process or re-parks it *)
    Io of Emo_eval.process * (state -> outcome)

and io_interest = { iokind : [ `R | `W ]; iowake : unit -> unit }
and live = { lfd : Unix.file_descr; rbuf : Buffer.t }

and state = {
  runq : runnable Queue.t;
  waiters :
    ( int,
      Emo_eval.process
      * (Emo_eval.value -> Emo_eval.selected option)
      * (Emo_eval.selected, unit) Effect.Shallow.continuation )
    Hashtbl.t;
  io : (Unix.file_descr, io_interest list) Hashtbl.t;
  mutable timers : (float * (unit -> unit)) list; (* deadline, wake *)
  live : (int, live) Hashtbl.t; (* conn id → live socket *)
  listeners : (int, Unix.file_descr) Hashtbl.t; (* listener id → fd *)
  udps : (int, Unix.file_descr) Hashtbl.t; (* udp id → socket *)
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

(* ---- IO plumbing ---- *)

let add_io state fd kind wake =
  let l = match Hashtbl.find_opt state.io fd with Some l -> l | None -> [] in
  Hashtbl.replace state.io fd ({ iokind = kind; iowake = wake } :: l)

let drop_io state fd kind =
  match Hashtbl.find_opt state.io fd with
  | None -> ()
  | Some l ->
      let rest = List.filter (fun w -> w.iokind <> kind) l in
      if rest = [] then Hashtbl.remove state.io fd
      else Hashtbl.replace state.io fd rest

let add_timer state seconds wake =
  state.timers <- (Unix.gettimeofday () +. seconds, wake) :: state.timers

let make_conn state fd desc =
  let c =
    {
      Emo_eval.cid = Emo_eval.fresh_resource_id ();
      cdesc = desc;
      ctimeout = 0.0;
      cclosed = false;
    }
  in
  Hashtbl.replace state.live c.Emo_eval.cid { lfd = fd; rbuf = Buffer.create 0 };
  c

let describe_sockaddr = function
  | Unix.ADDR_UNIX path -> Printf.sprintf "unix socket %s" path
  | Unix.ADDR_INET (addr, port) ->
      Printf.sprintf "%s:%d" (Unix.string_of_inet_addr addr) port

(* A connect candidate: the socket family and address, as resolved. *)
type candidate = { cfam : Unix.socket_domain; caddr : Unix.sockaddr }

(* Maps a Unix error onto the precise Emo exception message for [what]. *)
let io_error span what desc (err : Unix.error) =
  Emo_eval.net_raise span
    (Printf.sprintf "cannot %s on %s: %s" what desc (Unix.error_message err))

(* Consumes [n] bytes from the front of the live buffer. *)
let buffer_take live n =
  let s = Buffer.contents live.rbuf in
  Buffer.reset live.rbuf;
  Buffer.add_string live.rbuf (String.sub s n (String.length s - n));
  String.sub s 0 n

(* The next newline-terminated line in the buffer, without its terminator;
   the bytes are consumed. *)
let line_in_buffer live =
  let s = Buffer.contents live.rbuf in
  match String.index_opt s '\n' with
  | None -> None
  | Some i ->
      let line = String.sub s 0 i in
      let n = String.length line in
      let line =
        if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
      in
      ignore (buffer_take live (i + 1));
      Some line

(* Resolves a host to candidate address strings through the
   [Net_resolve] effect — the same suspension path as every other
   network operation. DNS itself resolves inline in this handler. *)
let resolve_addrs span host : string list =
  match Unix.getaddrinfo host "0" [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | entries ->
      List.filter_map
        (fun e ->
          match e.Unix.ai_addr with
          | Unix.ADDR_INET (addr, _) -> Some (Unix.string_of_inet_addr addr)
          | Unix.ADDR_UNIX _ -> None)
        entries
  | exception Unix.Unix_error _ -> []

(* Binds and listens; port 0 resolves to the assigned port in the
   returned description. Every candidate address is tried. *)
let listen_on span host port : Unix.file_descr * int =
  let bind_addr ai =
    let fd = Unix.socket ai.Unix.ai_family Unix.SOCK_STREAM 0 in
    Unix.setsockopt fd Unix.SO_REUSEADDR true;
    match Unix.bind fd ai.Unix.ai_addr with
    | () ->
        Unix.listen fd 128;
        let bound =
          match (Unix.getsockname fd : Unix.sockaddr) with
          | Unix.ADDR_INET (_, p) -> p
          | Unix.ADDR_UNIX _ -> port
        in
        (fd, bound)
    | exception e ->
        Unix.close fd;
        raise e
  in
  match
    Unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  with
  | [] ->
      raise
        (Emo_eval.net_raise span
           (Printf.sprintf "cannot resolve host `%s`" host))
  | entries ->
      let rec try_all = function
        | [] ->
            raise
              (Emo_eval.net_raise span
                 (Printf.sprintf "cannot listen on %s:%d" host port))
        | ai :: rest -> (
            try bind_addr ai with
            | Emo_eval.Emo_raise _ as exn ->
                if rest = [] then raise exn else try_all rest
            | Unix.Unix_error (err, _, _) ->
                if rest = [] then
                  raise
                    (Emo_eval.net_raise span
                       (Printf.sprintf "cannot listen on %s:%d: %s" host port
                          (Unix.error_message err)))
                else try_all rest)
      in
      try_all entries

(* ---- Operation pumps ----
   Each pump attempts progress; when the socket cannot proceed it parks
   the continuation on fd interest plus its deadline, and the wake re-runs
   the pump. All completions funnel through [guard] so exactly one of a
   readiness wake and a deadline wake finishes the operation. *)

let exit_name = function
  | Emo_eval.Exit_normal -> "normal"
  | Emo_eval.Exit_raised _ -> "raised"
  | Emo_eval.Exit_failed _ -> "failed"

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
                (* Sending yields the sender's slice: the continuation
                   re-joins the run queue instead of nesting one frame per
                   message, so a process firing a million sends never
                   grows the stack. *)
                Queue.add (Continue (proc, k)) state.runq;
                None)
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
        | Emo_eval.Net_resolve (host, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match resolve_addrs span host with
                | [] ->
                    Effect.Shallow.discontinue_with k
                      (Emo_eval.net_raise span
                         (Printf.sprintf "cannot resolve host `%s`" host))
                      (handler state proc ())
                | addresses ->
                    Effect.Shallow.continue_with k addresses
                      (handler state proc ()))
        | Emo_eval.Net_connect (host, port, timeout, addrs, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                connect_entry state proc k ~host ~port ~timeout span addrs)
        | Emo_eval.Net_listen (host, port, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match listen_on span host port with
                | exception (Emo_eval.Emo_raise _ as exn) ->
                    Effect.Shallow.discontinue_with k exn
                      (handler state proc ())
                | fd, bound ->
                    Unix.set_nonblock fd;
                    let l =
                      {
                        Emo_eval.lid = Emo_eval.fresh_resource_id ();
                        ldesc = Printf.sprintf "%s:%d" host bound;
                        lport = bound;
                        lunix = false;
                        ltimeout = 0.0;
                        lclosed = false;
                      }
                    in
                    Hashtbl.replace state.listeners l.Emo_eval.lid fd;
                    Effect.Shallow.continue_with k l (handler state proc ()))
        | Emo_eval.Net_accept (l, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                let finished = ref false in
                let deadline =
                  if l.Emo_eval.ltimeout > 0.0 then
                    Some (Unix.gettimeofday () +. l.Emo_eval.ltimeout)
                  else None
                in
                accept_loop state proc k finished l span deadline)
        | Emo_eval.Net_read_line (c, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                conn_entry state proc k c span (fun live ->
                    let finished = ref false in
                    let deadline = conn_deadline c in
                    read_line_loop state proc k finished c span live deadline))
        | Emo_eval.Net_read_exactly (c, n, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                conn_entry state proc k c span (fun live ->
                    let finished = ref false in
                    let deadline = conn_deadline c in
                    read_exactly_loop state proc k finished c span live deadline
                      n))
        | Emo_eval.Net_read_all (c, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                conn_entry state proc k c span (fun live ->
                    let finished = ref false in
                    let deadline = conn_deadline c in
                    read_all_loop state proc k finished c span live deadline))
        | Emo_eval.Net_write (c, data, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                conn_entry state proc k c span (fun live ->
                    let finished = ref false in
                    let deadline = conn_deadline c in
                    write_loop state proc k finished c span live deadline
                      (Bytes.of_string data) 0))
        | Emo_eval.Net_close_conn (c, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                conn_entry state proc k c span (fun live ->
                    (* Graceful: writes have already been delivered in
                       full; shut down our sending side, then close. *)
                    (try Unix.shutdown live.lfd Unix.SHUTDOWN_SEND
                     with Unix.Unix_error _ -> ());
                    (try Unix.close live.lfd with Unix.Unix_error _ -> ());
                    Hashtbl.remove state.live c.Emo_eval.cid;
                    Effect.Shallow.continue_with k c (handler state proc ())))
        | Emo_eval.Net_connect_unix (path, timeout, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                connect_unix_entry state proc k ~path ~timeout span)
        | Emo_eval.Net_listen_unix (path, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match bind_unix_listener span path with
                | Error exn ->
                    Effect.Shallow.discontinue_with k exn
                      (handler state proc ())
                | Ok fd ->
                    Unix.set_nonblock fd;
                    let l =
                      {
                        Emo_eval.lid = Emo_eval.fresh_resource_id ();
                        ldesc = Printf.sprintf "unix socket %s" path;
                        lport = 0;
                        lunix = true;
                        ltimeout = 0.0;
                        lclosed = false;
                      }
                    in
                    Hashtbl.replace state.listeners l.Emo_eval.lid fd;
                    Effect.Shallow.continue_with k l (handler state proc ()))
        | Emo_eval.Net_udp_bind (host, port, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match bind_udp_socket span host port with
                | Error exn ->
                    Effect.Shallow.discontinue_with k exn
                      (handler state proc ())
                | Ok (fd, bound) ->
                    Unix.set_nonblock fd;
                    let u =
                      {
                        Emo_eval.uid = Emo_eval.fresh_resource_id ();
                        udesc = Printf.sprintf "%s:%d" host bound;
                        uport = bound;
                        utimeout = 0.0;
                        uclosed = false;
                      }
                    in
                    Hashtbl.replace state.udps u.Emo_eval.uid fd;
                    Effect.Shallow.continue_with k u (handler state proc ()))
        | Emo_eval.Net_udp_send_to (u, addr, port, data, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                udp_send_entry state proc k addr port data span u)
        | Emo_eval.Net_udp_recv_from (u, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                udp_recv_entry state proc k span u)
        | Emo_eval.Net_udp_close (u, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                if u.Emo_eval.uclosed then
                  Effect.Shallow.discontinue_with k
                    (Emo_eval.net_raise span
                       (Printf.sprintf "the udp socket on %s is already closed"
                          u.Emo_eval.udesc))
                    (handler state proc ())
                else (
                  u.Emo_eval.uclosed <- true;
                  (match Hashtbl.find_opt state.udps u.Emo_eval.uid with
                  | Some fd -> (
                      try Unix.close fd with Unix.Unix_error _ -> ())
                  | None -> ());
                  Hashtbl.remove state.udps u.Emo_eval.uid;
                  Effect.Shallow.continue_with k u (handler state proc ())))
        | Emo_eval.Net_close_listener (l, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                if l.Emo_eval.lclosed then
                  Effect.Shallow.discontinue_with k
                    (Emo_eval.net_raise span
                       (Printf.sprintf "the listener on %s is already closed"
                          l.Emo_eval.ldesc))
                    (handler state proc ())
                else (
                  l.Emo_eval.lclosed <- true;
                  (match Hashtbl.find_opt state.listeners l.Emo_eval.lid with
                  | Some fd -> (
                      try Unix.close fd with Unix.Unix_error _ -> ())
                  | None -> ());
                  Hashtbl.remove state.listeners l.Emo_eval.lid;
                  Effect.Shallow.continue_with k l (handler state proc ())))
        | _ -> None);
  }

(* The connection's whole-operation deadline, computed when the operation
   starts so multi-park reads honor one budget. *)
and conn_deadline c =
  if c.Emo_eval.ctimeout > 0.0 then
    Some (Unix.gettimeofday () +. c.Emo_eval.ctimeout)
  else None

(* The closed-connection check every connection operation starts with. *)
and conn_entry :
    'x.
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    Emo_eval.conn ->
    Emo_support.Span.t ->
    (live -> outcome) ->
    outcome =
 fun state proc k c span body ->
  let closed =
    Emo_eval.net_raise span
      (Printf.sprintf "the connection to %s is closed" c.Emo_eval.cdesc)
  in
  if c.Emo_eval.cclosed then
    Effect.Shallow.discontinue_with k closed (handler state proc ())
  else
    match Hashtbl.find_opt state.live c.Emo_eval.cid with
    | Some live -> body live
    | None -> Effect.Shallow.discontinue_with k closed (handler state proc ())

(* Parks on fd interest plus the deadline; the timeout message states the
   configured budget, which is what the operation was given. *)
and park_fd :
    'x.
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    bool ref ->
    Unix.file_descr ->
    [ `R | `W ] ->
    deadline:float option ->
    timeout_message:string ->
    Emo_support.Span.t ->
    (state -> outcome) ->
    outcome =
 fun state proc k finished fd kind ~deadline ~timeout_message span step ->
  (* A wake only re-runs the step when nothing has completed the
     operation yet; the completion itself goes through finish_w/abort_w,
     which set the flag — so a racing timer and readiness wake resume the
     parked continuation exactly once. *)
  let wake st = if !finished then None else step st in
  add_io state fd kind (fun () -> Queue.add (Io (proc, wake)) state.runq);
  (match deadline with
  | Some dl ->
      let remaining = max 0.001 (dl -. Unix.gettimeofday ()) in
      add_timer state remaining (fun () ->
          Queue.add
            (Io
               ( proc,
                 fun st ->
                   if !finished then None
                   else
                     abort_w finished st proc k
                       (Emo_eval.net_raise span timeout_message) ))
            state.runq)
  | None -> ());
  None

and finish :
    'x.
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    'x ->
    outcome =
 fun state proc k v -> Effect.Shallow.continue_with k v (handler state proc ())

and abort :
    'x.
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    exn ->
    outcome =
 fun state proc k exn ->
  Effect.Shallow.discontinue_with k exn (handler state proc ())

(* Guarded completions: the first of a readiness wake and a deadline wake
   wins; later ones observe the flag and do nothing. *)
and finish_w :
    'x.
    bool ref ->
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    'x ->
    outcome =
 fun finished st proc k v ->
  if !finished then None
  else (
    finished := true;
    finish st proc k v)

and abort_w :
    'x.
    bool ref ->
    state ->
    Emo_eval.process ->
    ('x, unit) Effect.Shallow.continuation ->
    exn ->
    outcome =
 fun finished st proc k exn ->
  if !finished then None
  else (
    finished := true;
    abort st proc k exn)

and connect_entry state proc
    (k : (Emo_eval.conn, unit) Effect.Shallow.continuation) ~(host : string)
    ~(port : int) ~(timeout : float) (span : Emo_support.Span.t)
    (addresses : string list) : outcome =
  let target = Printf.sprintf "%s:%d" host port in
  let addrs =
    List.map
      (fun a ->
        {
          cfam = (if String.contains a ':' then Unix.PF_INET6 else Unix.PF_INET);
          caddr = Unix.ADDR_INET (Unix.inet_addr_of_string a, port);
        })
      addresses
  in
  let deadline =
    if timeout > 0.0 then Some (Unix.gettimeofday () +. timeout) else None
  in
  let message =
    Printf.sprintf "timed out after %gs connecting to %s" timeout target
  in
  connect_next state proc k ~target ~deadline ~message ~last_error:None span
    addrs

(* A unix-domain connect has one candidate address: the path itself. *)
and connect_unix_entry state proc
    (k : (Emo_eval.conn, unit) Effect.Shallow.continuation) ~(path : string)
    ~(timeout : float) (span : Emo_support.Span.t) : outcome =
  let target = Printf.sprintf "unix socket %s" path in
  let deadline =
    if timeout > 0.0 then Some (Unix.gettimeofday () +. timeout) else None
  in
  let message =
    Printf.sprintf "timed out after %gs connecting to %s" timeout target
  in
  connect_next state proc k ~target ~deadline ~message ~last_error:None span
    [ { cfam = Unix.PF_UNIX; caddr = Unix.ADDR_UNIX path } ]

and connect_next state proc k ~target ~deadline ~message
    ~(last_error : Unix.error option) span addrs =
  match addrs with
  | [] ->
      (* Every candidate failed; the last OS error is the precise reason. *)
      abort state proc k
        (match last_error with
        | Some Unix.ECONNREFUSED ->
            Emo_eval.net_raise span
              (Printf.sprintf "connection refused to %s" target)
        | Some err ->
            Emo_eval.net_raise span
              (Printf.sprintf "cannot connect to %s: %s" target
                 (Unix.error_message err))
        | None ->
            Emo_eval.net_raise span
              (Printf.sprintf "cannot connect to %s" target))
  | addr :: rest -> (
      (* One completion flag per address attempt; moving to the next
         candidate starts a fresh attempt with its own flag. *)
      let finished = ref false in
      let fd = Unix.socket addr.cfam Unix.SOCK_STREAM 0 in
      Unix.set_nonblock fd;
      let cleanup st =
        drop_io st fd `W;
        try Unix.close fd with Unix.Unix_error _ -> ()
      in
      let refusal err =
        match err with
        | Unix.ECONNREFUSED ->
            Emo_eval.net_raise span
              (Printf.sprintf "connection refused to %s" target)
        | _ ->
            Emo_eval.net_raise span
              (Printf.sprintf "cannot connect to %s: %s" target
                 (Unix.error_message err))
      in
      let step st =
        match Unix.getsockopt_error fd with
        | Some err ->
            cleanup st;
            (* This address failed; the refusal is only final when the
               last candidate said it. *)
            connect_next st proc k ~target ~deadline ~message
              ~last_error:(Some err) span rest
        | None -> finish_w finished st proc k (make_conn st fd target)
      in
      let timeout_step st =
        cleanup st;
        abort_w finished st proc k (Emo_eval.net_raise span message)
      in
      match Unix.connect fd addr.caddr with
      | () -> finish_w finished state proc k (make_conn state fd target)
      | exception Unix.Unix_error (Unix.EINPROGRESS, _, _) ->
          add_io state fd `W (fun () -> Queue.add (Io (proc, step)) state.runq);
          (match deadline with
          | Some dl ->
              let remaining = max 0.001 (dl -. Unix.gettimeofday ()) in
              add_timer state remaining (fun () ->
                  Queue.add (Io (proc, timeout_step)) state.runq)
          | None -> ());
          None
      | exception Unix.Unix_error (err, _, _) ->
          cleanup state;
          if rest = [] then abort_w finished state proc k (refusal err)
          else
            connect_next state proc k ~target ~deadline ~message
              ~last_error:(Some err) span rest)

and accept_loop state proc
    (k : (Emo_eval.conn, unit) Effect.Shallow.continuation)
    (finished : bool ref) (l : Emo_eval.listener) (span : Emo_support.Span.t)
    (deadline : float option) : outcome =
  if l.Emo_eval.lclosed then
    Effect.Shallow.discontinue_with k
      (Emo_eval.net_raise span
         (Printf.sprintf "the listener on %s is closed" l.Emo_eval.ldesc))
      (handler state proc ())
  else
    let fd = Hashtbl.find state.listeners l.Emo_eval.lid in
    match Unix.accept fd with
    | client, sockaddr ->
        Unix.set_nonblock client;
        let conn = make_conn state client (describe_sockaddr sockaddr) in
        finish_w finished state proc k conn
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
        park_fd state proc k finished fd `R ~deadline
          ~timeout_message:
            (Printf.sprintf "timed out waiting to accept on %s" l.Emo_eval.ldesc)
          span (fun st -> accept_loop st proc k finished l span deadline)
    | exception Unix.Unix_error (err, _, _) ->
        abort_w finished state proc k
          (io_error span "accept" l.Emo_eval.ldesc err)

(* The setup half of a unix-domain listener: bind and listen, reporting
   failure as the Emo exception instead of raising across the entry. *)
and bind_unix_listener span path : (Unix.file_descr, exn) result =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  match Unix.bind fd (Unix.ADDR_UNIX path) with
  | () ->
      Unix.listen fd 128;
      Ok fd
  | exception Unix.Unix_error (err, _, _) ->
      (try Unix.close fd with Unix.Unix_error _ -> ());
      Error
        (Emo_eval.net_raise span
           (Printf.sprintf "cannot listen on unix socket %s: %s" path
              (Unix.error_message err)))

(* The setup half of a UDP socket: resolve, socket, bind; returns the fd
   and the bound port. *)
and bind_udp_socket span host port : (Unix.file_descr * int, exn) result =
  match
    match Unix.getaddrinfo host "0" [ Unix.AI_SOCKTYPE Unix.SOCK_DGRAM ] with
    | entry :: _ -> Ok (entry.Unix.ai_family, entry.Unix.ai_addr)
    | [] ->
        Error
          (Emo_eval.net_raise span
             (Printf.sprintf "cannot resolve host `%s`" host))
    | exception Unix.Unix_error _ ->
        Error
          (Emo_eval.net_raise span
             (Printf.sprintf "cannot resolve host `%s`" host))
  with
  | Error exn -> Error exn
  | Ok (family, addr) -> (
      let fd = Unix.socket family Unix.SOCK_DGRAM 0 in
      match Unix.bind fd addr with
      | () ->
          let bound =
            match (Unix.getsockname fd : Unix.sockaddr) with
            | Unix.ADDR_INET (_, p) -> p
            | _ -> port
          in
          Ok (fd, bound)
      | exception Unix.Unix_error (err, _, _) ->
          (try Unix.close fd with Unix.Unix_error _ -> ());
          Error
            (Emo_eval.net_raise span
               (Printf.sprintf "cannot bind udp on %s:%d: %s" host port
                  (Unix.error_message err))))

(* Sends one datagram; a full buffer parks the send on write interest.
   The peer address arrives resolved. *)
and udp_send_entry state proc (k : (unit, unit) Effect.Shallow.continuation)
    (addr : string) (port : int) (data : string) (span : Emo_support.Span.t)
    (u : Emo_eval.udp) : outcome =
  if u.Emo_eval.uclosed then
    Effect.Shallow.discontinue_with k
      (Emo_eval.net_raise span
         (Printf.sprintf "the udp socket on %s is closed" u.Emo_eval.udesc))
      (handler state proc ())
  else
    let fd = Hashtbl.find state.udps u.Emo_eval.uid in
    let bytes = Bytes.of_string data in
    let finished = ref false in
    let deadline =
      if u.Emo_eval.utimeout > 0.0 then
        Some (Unix.gettimeofday () +. u.Emo_eval.utimeout)
      else None
    in
    let target = Unix.ADDR_INET (Unix.inet_addr_of_string addr, port) in
    let rec send_step st =
      match Unix.sendto fd bytes 0 (Bytes.length bytes) [] target with
      | _n -> finish_w finished st proc k ()
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
          park_fd state proc k finished fd `W ~deadline
            ~timeout_message:
              (Printf.sprintf "timed out sending on %s" u.Emo_eval.udesc)
            span send_step
      | exception Unix.Unix_error (err, _, _) ->
          abort_w finished st proc k (io_error span "send" u.Emo_eval.udesc err)
    in
    send_step state

(* Waits for one datagram and returns it as (data, host, port). *)
and udp_recv_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (span : Emo_support.Span.t) (u : Emo_eval.udp) : outcome =
  if u.Emo_eval.uclosed then
    Effect.Shallow.discontinue_with k
      (Emo_eval.net_raise span
         (Printf.sprintf "the udp socket on %s is closed" u.Emo_eval.udesc))
      (handler state proc ())
  else
    let fd = Hashtbl.find state.udps u.Emo_eval.uid in
    let buf = Bytes.create 65536 in
    match Unix.recvfrom fd buf 0 65536 [] with
    | n, sockaddr -> (
        let data = Bytes.sub_string buf 0 n in
        match sockaddr with
        | Unix.ADDR_INET (addr, port) ->
            Effect.Shallow.continue_with k
              (Emo_eval.Tuple
                 [
                   Emo_eval.String data;
                   Emo_eval.String (Unix.string_of_inet_addr addr);
                   Emo_eval.Int port;
                 ])
              (handler state proc ())
        | Unix.ADDR_UNIX _ ->
            Effect.Shallow.continue_with k
              (Emo_eval.Tuple
                 [ Emo_eval.String data; Emo_eval.String ""; Emo_eval.Int 0 ])
              (handler state proc ()))
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
        let finished = ref false in
        let deadline =
          if u.Emo_eval.utimeout > 0.0 then
            Some (Unix.gettimeofday () +. u.Emo_eval.utimeout)
          else None
        in
        park_fd state proc k finished fd `R ~deadline
          ~timeout_message:
            (Printf.sprintf "timed out waiting to receive on %s"
               u.Emo_eval.udesc) span (fun st ->
            udp_recv_entry st proc k span u)
    | exception Unix.Unix_error (err, _, _) ->
        Effect.Shallow.discontinue_with k
          (io_error span "receive" u.Emo_eval.udesc err)
          (handler state proc ())

and read_line_loop state proc (k : (string, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) : outcome =
  match line_in_buffer live with
  | Some line -> finish_w finished state proc k line
  | None -> (
      let buf = Bytes.create 4096 in
      match Unix.recv live.lfd buf 0 4096 [] with
      | 0 ->
          let rest = Buffer.contents live.rbuf in
          Buffer.reset live.rbuf;
          if rest = "" then finish_w finished state proc k ""
          else
            abort_w finished state proc k
              (Emo_eval.net_raise span
                 (Printf.sprintf "the connection to %s closed mid-line"
                    c.Emo_eval.cdesc))
      | n ->
          Buffer.add_subbytes live.rbuf buf 0 n;
          read_line_loop state proc k finished c span live deadline
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
          park_fd state proc k finished live.lfd `R ~deadline
            ~timeout_message:
              (Printf.sprintf "timed out reading a line from %s"
                 c.Emo_eval.cdesc) span (fun st ->
              read_line_loop st proc k finished c span live deadline)
      | exception Unix.Unix_error (err, _, _) ->
          abort_w finished state proc k
            (io_error span "read" c.Emo_eval.cdesc err))

and read_exactly_loop state proc
    (k : (string, unit) Effect.Shallow.continuation) (finished : bool ref)
    (c : Emo_eval.conn) (span : Emo_support.Span.t) (live : live)
    (deadline : float option) (n : int) : outcome =
  if Buffer.length live.rbuf >= n then
    finish_w finished state proc k (buffer_take live n)
  else
    let buf = Bytes.create 4096 in
    match Unix.recv live.lfd buf 0 4096 [] with
    | 0 ->
        let have = Buffer.length live.rbuf in
        abort_w finished state proc k
          (Emo_eval.net_raise span
             (Printf.sprintf "the connection to %s closed after %d of %d bytes"
                c.Emo_eval.cdesc have n))
    | n ->
        Buffer.add_subbytes live.rbuf buf 0 n;
        read_exactly_loop state proc k finished c span live deadline n
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
        park_fd state proc k finished live.lfd `R ~deadline
          ~timeout_message:
            (Printf.sprintf "timed out reading from %s" c.Emo_eval.cdesc) span
          (fun st ->
            read_exactly_loop st proc k finished c span live deadline n)
    | exception Unix.Unix_error (err, _, _) ->
        abort_w finished state proc k
          (io_error span "read" c.Emo_eval.cdesc err)

and read_all_loop state proc (k : (string, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) : outcome =
  let buf = Bytes.create 4096 in
  match Unix.recv live.lfd buf 0 4096 [] with
  | 0 ->
      let data = Buffer.contents live.rbuf in
      Buffer.reset live.rbuf;
      finish_w finished state proc k data
  | n ->
      Buffer.add_subbytes live.rbuf buf 0 n;
      read_all_loop state proc k finished c span live deadline
  | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
      park_fd state proc k finished live.lfd `R ~deadline
        ~timeout_message:
          (Printf.sprintf "timed out reading from %s" c.Emo_eval.cdesc) span
        (fun st -> read_all_loop st proc k finished c span live deadline)
  | exception Unix.Unix_error (err, _, _) ->
      abort_w finished state proc k (io_error span "read" c.Emo_eval.cdesc err)

and write_loop state proc (k : (unit, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) (bytes : Bytes.t) (off : int) :
    outcome =
  let len = Bytes.length bytes in
  match Unix.send live.lfd bytes off (len - off) [] with
  | n ->
      let off = off + n in
      if off >= len then finish_w finished state proc k ()
      else
        park_fd state proc k finished live.lfd `W ~deadline
          ~timeout_message:
            (Printf.sprintf "timed out writing to %s" c.Emo_eval.cdesc) span
          (fun st ->
            write_loop st proc k finished c span live deadline bytes off)
  | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
      park_fd state proc k finished live.lfd `W ~deadline
        ~timeout_message:
          (Printf.sprintf "timed out writing to %s" c.Emo_eval.cdesc) span
        (fun st -> write_loop st proc k finished c span live deadline bytes off)
  | exception Unix.Unix_error (err, _, _) ->
      abort_w finished state proc k (io_error span "write" c.Emo_eval.cdesc err)

(* Fires due timers, then polls fd readiness once and wakes the parked
   operations whose fd is ready. Waiters that stay parked are untouched. *)
let pump_io state =
  let now = Unix.gettimeofday () in
  let due, later = List.partition (fun (d, _) -> d <= now) state.timers in
  state.timers <- later;
  List.iter (fun (_, wake) -> wake ()) due;
  let read_fds =
    Hashtbl.fold
      (fun fd l acc ->
        if List.exists (fun w -> w.iokind = `R) l then fd :: acc else acc)
      state.io []
  in
  let write_fds =
    Hashtbl.fold
      (fun fd l acc ->
        if List.exists (fun w -> w.iokind = `W) l then fd :: acc else acc)
      state.io []
  in
  if read_fds <> [] || write_fds <> [] || later <> [] then begin
    let timeout =
      List.fold_left
        (fun acc (d, _) -> min acc (max 0.001 (d -. now)))
        1.0 later
    in
    let readable, writable, _ = Unix.select read_fds write_fds [] timeout in
    let take_ready fd kind =
      match Hashtbl.find_opt state.io fd with
      | None -> ()
      | Some l ->
          let ready, keep = List.partition (fun w -> w.iokind = kind) l in
          if keep = [] then Hashtbl.remove state.io fd
          else Hashtbl.replace state.io fd keep;
          List.iter (fun w -> w.iowake ()) ready
    in
    List.iter (fun fd -> take_ready fd `R) readable;
    List.iter (fun fd -> take_ready fd `W) writable
  end

let rec loop state =
  if Queue.is_empty state.runq then
    if Hashtbl.length state.io > 0 || state.timers <> [] then
      (* A server parked in accept or a client parked in a socket call
         keeps the program alive — but only while its root lives. *)
      begin if
        match state.root.Emo_eval.status with
        | `Done _ -> true
        | `Running -> false
      then ()
      else (
        pump_io state;
        loop state)
      end
    else if Hashtbl.length state.waiters > 0 then
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
    let proc =
      match item with
      | Fresh (p, _) -> p
      | Continue (p, _) -> p
      | Resumed (p, _, _) -> p
      | Io (p, _) -> p
    in
    state.current <- proc.Emo_eval.pid;
    let h = handler state proc () in
    let outcome =
      match item with
      | Fresh (_, body) ->
          Effect.Shallow.continue_with (Effect.Shallow.fiber body) () h
      | Continue (_, k) -> Effect.Shallow.continue_with k () h
      | Resumed (_, picked, k) -> Effect.Shallow.continue_with k picked h
      | Io (_, step) -> step state
    in
    (match outcome with
    | None -> ()
    | Some info ->
        let proc =
          match item with
          | Fresh (p, _) -> p
          | Continue (p, _) -> p
          | Resumed (p, _, _) -> p
          | Io (p, _) -> p
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
      io = Hashtbl.create 8;
      timers = [];
      live = Hashtbl.create 8;
      listeners = Hashtbl.create 8;
      udps = Hashtbl.create 8;
      current = 0;
      rng = Random.State.make [| seed |];
      log = ref [];
      root = Emo_eval.spawn_record ();
    }
  in
  Queue.add (Fresh (state.root, root_body)) state.runq;
  (try loop state with Emo_eval.Halt_signal -> ());
  List.rev !(state.log)
