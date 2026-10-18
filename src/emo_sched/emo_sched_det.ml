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
  | CResumed of
      Emo_eval.process
      * int
      * Emo_eval.value list
      * (int * Emo_eval.value list, unit) Effect.Shallow.continuation
  | (* a parked socket operation: the step attempts progress and either
       rejoins the process or re-parks it *)
    Io of Emo_eval.process * (state -> outcome)

and io_interest = { iokind : [ `R | `W ]; iowake : unit -> unit }

and live = {
  lfd : Unix.file_descr;
  ltls : Ssl.socket option; (* a TLS connection rides the same fd *)
  rbuf : Buffer.t;
}

and state = {
  runq : runnable Queue.t;
  waiters :
    ( int,
      Emo_eval.process
      * (Emo_eval.value -> Emo_eval.selected option)
      * (Emo_eval.selected, unit) Effect.Shallow.continuation )
    Hashtbl.t;
  cwaiters :
    ( int,
      Emo_eval.process
      * (Emo_eval.value -> (int * Emo_eval.value list) option)
      * (int * Emo_eval.value list, unit) Effect.Shallow.continuation )
    Hashtbl.t;
      (* the backend's compiled receive *)
  io : (Unix.file_descr, io_interest list) Hashtbl.t;
  mutable timers : (float * (unit -> unit)) list; (* deadline, wake *)
  live : (int, live) Hashtbl.t; (* conn id → live socket *)
  listeners : (int, Unix.file_descr * Ssl.context option) Hashtbl.t;
      (* listener id → fd, and its TLS context when serving TLS *)
  udps : (int, Unix.file_descr) Hashtbl.t; (* udp id → socket *)
  mutable current : int; (* the pid performing effects right now *)
  rng : Random.State.t;
  log : event list ref;
  mutable log_enabled : bool;
      (* compiled programs skip the event log: 400k+ events would pin
         millions of live list cells and turn every minor GC into a
         major scan *)
  root : Emo_eval.process;
}

let log state event =
  if state.log_enabled then state.log := event :: !(state.log)

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
   run queue. Nothing matching leaves the waiter parked. Both the
   interpreted and the compiled receive park here. *)
let wake state pid =
  let wake_interpreted () =
    match Hashtbl.find_opt state.waiters pid with
    | None -> ()
    | Some (proc, select, k) -> (
        match Emo_eval.take_matching proc select with
        | None -> ()
        | Some picked ->
            Hashtbl.remove state.waiters pid;
            log state (Received proc.Emo_eval.pid);
            Queue.add (Resumed (proc, picked, k)) state.runq)
  in
  let wake_compiled () =
    match Hashtbl.find_opt state.cwaiters pid with
    | None -> ()
    | Some (proc, matcher, k) -> (
        let rec take = function
          | [] -> None
          | msg :: rest -> (
              match matcher msg with
              | Some (i, bindings) ->
                  proc.inbox <-
                    List.rev_append (List.rev (taken_before msg proc)) rest;
                  Some (i, bindings)
              | None -> take rest)
        and taken_before msg _proc =
          let rec collect acc = function
            | m :: rest ->
                if m == msg then List.rev acc else collect (m :: acc) rest
            | [] -> List.rev acc
          in
          collect [] proc.Emo_eval.inbox
        in
        match take proc.Emo_eval.inbox with
        | None -> ()
        | Some (i, bindings) ->
            Hashtbl.remove state.cwaiters pid;
            log state (Received proc.Emo_eval.pid);
            Queue.add (CResumed (proc, i, bindings, k)) state.runq)
  in
  wake_interpreted ();
  wake_compiled ()

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

(* Wraps a socket fd as a connection. The caller must have put [fd] in
   nonblocking mode: Linux does not inherit O_NONBLOCK across accept, so a
   blocking accepted socket would stall the whole scheduler. *)
let make_conn state fd desc =
  let c =
    {
      Emo_eval.cid = Emo_eval.fresh_resource_id ();
      cdesc = desc;
      ctimeout = 0.0;
      cclosed = false;
    }
  in
  Hashtbl.replace state.live c.Emo_eval.cid
    { lfd = fd; ltls = None; rbuf = Buffer.create 0 };
  c

(* A TLS connection: the same handle, with the SSL socket riding its fd.
   OpenSSL runs on the nonblocking fd; want_read / want_write park the
   continuation exactly like the plain paths. *)
let make_tls_conn state fd ssl desc =
  let c =
    {
      Emo_eval.cid = Emo_eval.fresh_resource_id ();
      cdesc = desc;
      ctimeout = 0.0;
      cclosed = false;
    }
  in
  Hashtbl.replace state.live c.Emo_eval.cid
    { lfd = fd; ltls = Some ssl; rbuf = Buffer.create 0 };
  c

let describe_sockaddr = function
  | Unix.ADDR_UNIX path -> Printf.sprintf "unix socket %s" path
  | Unix.ADDR_INET (addr, port) ->
      Printf.sprintf "%s:%d" (Unix.string_of_inet_addr addr) port

(* A connect candidate: the socket family and address, as resolved. *)
type candidate = { cfam : Unix.socket_domain; caddr : Unix.sockaddr }

(* Maps a Unix error onto the precise failure reason for [what]. *)
let io_reason what desc (err : Unix.error) =
  Printf.sprintf "cannot %s on %s: %s" what desc (Unix.error_message err)

(* OCaml's Sys_error message prefixes the path ("p: No such file or
   directory"); the reason states the failure once, after the path the
   call already names — the text the c runtime prints for the same
   miss. *)
let file_reason verb path message =
  let prefix = path ^ ": " in
  let n = String.length prefix in
  let why =
    if n <= String.length message && String.sub message 0 n = prefix then
      String.sub message n (String.length message - n)
    else message
  in
  Printf.sprintf "file: cannot %s %s: %s" verb path why

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
   returned description. Every candidate address is tried; failure is
   the reason string. *)
let listen_on host port : (Unix.file_descr * int, string) result =
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
        Ok (fd, bound)
    | exception e ->
        Unix.close fd;
        raise e
  in
  match
    Unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  with
  | [] -> Error (Printf.sprintf "cannot resolve host `%s`" host)
  | entries ->
      let rec try_all = function
        | [] -> Error (Printf.sprintf "cannot listen on %s:%d" host port)
        | ai :: rest -> (
            try bind_addr ai
            with Unix.Unix_error (err, _, _) ->
              if rest = [] then
                Error
                  (Printf.sprintf "cannot listen on %s:%d: %s" host port
                     (Unix.error_message err))
              else try_all rest)
      in
      try_all entries

(* ---- Operation pumps ----
   Each pump attempts progress; when the socket cannot proceed it parks
   the continuation on fd interest plus its deadline, and the wake re-runs
   the pump. All completions funnel through [guard] so exactly one of a
   readiness wake and a deadline wake finishes the operation. *)

(* One read against the live socket — plain or TLS. TLS runs OpenSSL on
   the nonblocking fd and reports the readiness it wants; plain sockets
   report EAGAIN the same way. [RFailed] means the error queue holds the
   detail. *)
type read_result =
  | RData of int
  | RWant of [ `R | `W ]
  | REof
  | RFailed of string (* the reason, ready for the diagnostic *)

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
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error
                         (Printf.sprintf "cannot resolve host `%s`" host))
                      (handler state proc ())
                | addresses ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok
                         (Emo_eval.Array
                            (Array.of_list
                               (List.map (fun a -> Emo_eval.String a) addresses))))
                      (handler state proc ()))
        | Emo_eval.Net_connect (host, port, timeout, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match resolve_addrs span host with
                | [] ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error
                         (Printf.sprintf "cannot resolve host `%s`" host))
                      (handler state proc ())
                | addrs ->
                    connect_entry state proc k ~host ~port ~timeout span addrs)
        | Emo_eval.Net_listen (host, port, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match listen_on host port with
                | Error reason ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error reason)
                      (handler state proc ())
                | Ok (fd, bound) ->
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
                    Hashtbl.replace state.listeners l.Emo_eval.lid (fd, None);
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok (Emo_eval.TcpListener l))
                      (handler state proc ()))
        | Emo_eval.Net_tls_listen (host, port, cert_path, key_path, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match tls_listener ~host ~port ~cert_path ~key_path with
                | Error reason ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error reason)
                      (handler state proc ())
                | Ok (fd, bound, ctx) ->
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
                    Hashtbl.replace state.listeners l.Emo_eval.lid (fd, Some ctx);
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok (Emo_eval.TcpListener l))
                      (handler state proc ()))
        | Emo_eval.Net_tls_connect (host, port, timeout, insecure, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match resolve_addrs span host with
                | [] ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error
                         (Printf.sprintf "cannot resolve host `%s`" host))
                      (handler state proc ())
                | addrs ->
                    connect_tls_entry state proc k ~host ~port ~timeout
                      ~insecure span addrs)
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
        | Emo_eval.File_read (path, _) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                (* The data-driven file failures are values: the call
                   answers (R.ok, text) or (R.error, reason) — the same
                   tuple shape on every native target. *)
                let ok text =
                  Effect.Shallow.continue_with k
                    (Emo_eval.Tuple
                       [ Emo_eval.EnumMember ("R", "ok"); Emo_eval.String text ])
                    (handler state proc ())
                in
                let fail message =
                  Effect.Shallow.continue_with k
                    (Emo_eval.Tuple
                       [
                         Emo_eval.EnumMember ("R", "error");
                         Emo_eval.String message;
                       ])
                    (handler state proc ())
                in
                try
                  let ic = open_in_bin path in
                  let text = really_input_string ic (in_channel_length ic) in
                  close_in_noerr ic;
                  ok text
                with Sys_error message ->
                  fail (file_reason "read" path message))
        | Emo_eval.File_write (path, contents, _) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                (* Close before resuming: the resumption runs the rest
                   of the process, and a read-your-own-write race beats
                   descriptor hygiene. *)
                let ok n =
                  Effect.Shallow.continue_with k
                    (Emo_eval.Tuple
                       [ Emo_eval.EnumMember ("R", "ok"); Emo_eval.Int64 n ])
                    (handler state proc ())
                in
                let fail message =
                  Effect.Shallow.continue_with k
                    (Emo_eval.Tuple
                       [
                         Emo_eval.EnumMember ("R", "error");
                         Emo_eval.String message;
                       ])
                    (handler state proc ())
                in
                try
                  let oc = open_out_bin path in
                  output_string oc contents;
                  let n = String.length contents in
                  close_out_noerr oc;
                  ok (Int64.of_int n)
                with Sys_error message ->
                  fail (file_reason "write" path message))
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
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok (Emo_eval.TcpConn c))
                      (handler state proc ())))
        | Emo_eval.Net_connect_unix (path, timeout, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                connect_unix_entry state proc k ~path ~timeout span)
        | Emo_eval.Net_listen_unix (path, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match bind_unix_listener path with
                | Error reason ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error reason)
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
                    Hashtbl.replace state.listeners l.Emo_eval.lid (fd, None);
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok (Emo_eval.TcpListener l))
                      (handler state proc ()))
        | Emo_eval.Net_udp_bind (host, port, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match bind_udp_socket host port with
                | Error reason ->
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_error reason)
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
                    Effect.Shallow.continue_with k
                      (Emo_eval.net_ok (Emo_eval.UdpSocket u))
                      (handler state proc ()))
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
                  Effect.Shallow.continue_with k
                    (Emo_eval.net_error
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
                  Effect.Shallow.continue_with k
                    (Emo_eval.net_ok (Emo_eval.UdpSocket u))
                    (handler state proc ())))
        | Emo_eval.Compiled_receive matcher ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                match Emo_eval.take_compiled proc matcher with
                | Some (i, bindings) ->
                    log state (Received proc.Emo_eval.pid);
                    Effect.Shallow.continue_with k (i, bindings)
                      (handler state proc ())
                | None ->
                    Hashtbl.replace state.cwaiters proc.Emo_eval.pid
                      (proc, matcher, k);
                    None)
        | Emo_eval.Net_close_listener (l, span) ->
            Some
              (fun (k : (a, unit) Effect.Shallow.continuation) ->
                if l.Emo_eval.lclosed then
                  Effect.Shallow.continue_with k
                    (Emo_eval.net_error
                       (Printf.sprintf "the listener on %s is already closed"
                          l.Emo_eval.ldesc))
                    (handler state proc ())
                else (
                  l.Emo_eval.lclosed <- true;
                  (match Hashtbl.find_opt state.listeners l.Emo_eval.lid with
                  | Some (fd, _ctx) -> (
                      try Unix.close fd with Unix.Unix_error _ -> ())
                  | None -> ());
                  Hashtbl.remove state.listeners l.Emo_eval.lid;
                  Effect.Shallow.continue_with k
                    (Emo_eval.net_ok (Emo_eval.TcpListener l))
                    (handler state proc ())))
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
    state ->
    Emo_eval.process ->
    (Emo_eval.value, unit) Effect.Shallow.continuation ->
    Emo_eval.conn ->
    Emo_support.Span.t ->
    (live -> outcome) ->
    outcome =
 fun state proc k c span body ->
  if c.Emo_eval.cclosed then
    Effect.Shallow.continue_with k
      (Emo_eval.net_error
         (Printf.sprintf "the connection to %s is closed" c.Emo_eval.cdesc))
      (handler state proc ())
  else
    match Hashtbl.find_opt state.live c.Emo_eval.cid with
    | Some live -> body live
    | None ->
        Effect.Shallow.continue_with k
          (Emo_eval.net_error
             (Printf.sprintf "the connection to %s is closed" c.Emo_eval.cdesc))
          (handler state proc ())

(* Parks on fd interest plus the deadline; the timeout message states the
   configured budget, which is what the operation was given. *)
and park_fd :
    state ->
    Emo_eval.process ->
    (Emo_eval.value, unit) Effect.Shallow.continuation ->
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
     operation yet; the completion itself goes through finish_w,
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
                     finish_w finished st proc k
                       (Emo_eval.net_error timeout_message) ))
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

(* Guarded completions: the first of a readiness wake and a deadline
   wake wins; later ones observe the flag and do nothing. *)
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

and connect_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation) ~(host : string)
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
  connect_next state proc k ~target ~deadline ~message ~tls:None
    ~last_error:None span addrs

(* A TLS connect runs the same connect machinery; on a connected socket
   the TLS handshake takes over, parking through the scheduler. *)
and connect_tls_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation) ~(host : string)
    ~(port : int) ~(timeout : float) ~(insecure : bool)
    (span : Emo_support.Span.t) (addresses : string list) : outcome =
  let ctx = client_tls_ctx ~insecure in
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
  connect_next state proc k ~target ~deadline ~message ~tls:(Some ctx)
    ~last_error:None span addrs

(* A unix-domain connect has one candidate address: the path itself. *)
and connect_unix_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation) ~(path : string)
    ~(timeout : float) (span : Emo_support.Span.t) : outcome =
  let target = Printf.sprintf "unix socket %s" path in
  let deadline =
    if timeout > 0.0 then Some (Unix.gettimeofday () +. timeout) else None
  in
  let message =
    Printf.sprintf "timed out after %gs connecting to %s" timeout target
  in
  connect_next state proc k ~target ~deadline ~message ~tls:None
    ~last_error:None span
    [ { cfam = Unix.PF_UNIX; caddr = Unix.ADDR_UNIX path } ]

and connect_next state proc k ~target ~deadline ~message
    ~(tls : Ssl.context option) ~(last_error : Unix.error option) span addrs =
  match addrs with
  | [] ->
      (* Every candidate failed; the last OS error is the precise reason. *)
      let reason =
        match last_error with
        | Some Unix.ECONNREFUSED ->
            Printf.sprintf "connection refused to %s" target
        | Some err ->
            Printf.sprintf "cannot connect to %s: %s" target
              (Unix.error_message err)
        | None -> Printf.sprintf "cannot connect to %s" target
      in
      Effect.Shallow.continue_with k
        (Emo_eval.net_error reason)
        (handler state proc ())
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
        | Unix.ECONNREFUSED -> Printf.sprintf "connection refused to %s" target
        | _ ->
            Printf.sprintf "cannot connect to %s: %s" target
              (Unix.error_message err)
      in
      let step st =
        match Unix.getsockopt_error fd with
        | Some err ->
            cleanup st;
            (* This address failed; the refusal is only final when the
               last candidate said it. *)
            connect_next st proc k ~target ~deadline ~message ~tls
              ~last_error:(Some err) span rest
        | None -> connect_tls_upgrade st proc k finished fd target tls span
      in
      let timeout_step st =
        cleanup st;
        finish_w finished st proc k (Emo_eval.net_error message)
      in
      match Unix.connect fd addr.caddr with
      | () -> connect_tls_upgrade state proc k finished fd target tls span
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
          if rest = [] then
            finish_w finished state proc k (Emo_eval.net_error (refusal err))
          else
            connect_next state proc k ~target ~deadline ~message ~tls
              ~last_error:(Some err) span rest)

(* One negotiate-all profile for both ends of a TLS connection: TLS 1.2 up to
   1.3. The two SSL-2.0/3.0-era constants of this binding are the only ones
   OpenSSL 4 refuses (`Failed to set protocol to SSLv3`), and 1.2 is the floor
   OpenSSL 3 negotiates anyway. *)
and tls_context (kind : Ssl.context_type) : Ssl.context =
  let ctx = Ssl.create_context Ssl.TLSv1_2 kind in
  Ssl.set_max_protocol_version ctx Ssl.TLSv1_3;
  ctx

(* A verifying client context, or one that explicitly skips verification
   (`net_tls_connect_insecure` — visibly dangerous, never a default). *)
and client_tls_ctx ~(insecure : bool) : Ssl.context =
  let ctx = tls_context Ssl.Client_context in
  if insecure then Ssl.set_verify ctx [] None
  else (
    ignore (Ssl.set_default_verify_paths ctx);
    Ssl.set_verify ctx
      [ Ssl.Verify_peer; Ssl.Verify_fail_if_no_peer_cert ]
      (Some Ssl.client_verify_callback));
  ctx

(* Upgrades a just-connected socket: plain connects finish immediately;
   TLS hands the socket to OpenSSL and shakes hands asynchronously. *)
and connect_tls_upgrade state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (fd : Unix.file_descr) (target : string)
    (tls : Ssl.context option) (span : Emo_support.Span.t) : outcome =
  match tls with
  | None ->
      finish_w finished state proc k
        (Emo_eval.net_ok (Emo_eval.TcpConn (make_conn state fd target)))
  | Some ctx ->
      let ssl = Ssl.embed_socket fd ctx in
      handshake state proc k finished fd ssl target span Ssl.connect

(* Drives a nonblocking TLS handshake to completion: want_read /
   want_write park the continuation on the fd, so both ends of a
   loopback handshake progress through the scheduler. *)
and handshake state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (fd : Unix.file_descr) (ssl : Ssl.socket)
    (desc : string) (span : Emo_support.Span.t) (once : Ssl.socket -> unit) :
    outcome =
  match once ssl with
  | () ->
      finish_w finished state proc k
        (Emo_eval.net_ok (Emo_eval.TcpConn (make_tls_conn state fd ssl desc)))
  | exception
      ( Ssl.Connection_error (Ssl.Error_want_read as want)
      | Ssl.Accept_error (Ssl.Error_want_read as want) )
    when want = Ssl.Error_want_read ->
      park_and_handshake state proc k finished fd ssl desc span `R once
  | exception
      ( Ssl.Connection_error (Ssl.Error_want_write as want)
      | Ssl.Accept_error (Ssl.Error_want_write as want) )
    when want = Ssl.Error_want_write ->
      park_and_handshake state proc k finished fd ssl desc span `W once
  | exception (Ssl.Connection_error _ | Ssl.Accept_error _ | Ssl.Verify_error _)
    ->
      finish_w finished state proc k
        (Emo_eval.net_error
           (Printf.sprintf "the TLS handshake with %s failed: %s" desc
              ((Ssl.get_error_string [@alert "-deprecated"]) ())))

and park_and_handshake state proc k finished fd ssl desc span kind once =
  park_fd state proc k finished fd kind ~deadline:None
    ~timeout_message:(Printf.sprintf "timed out handshaking with %s" desc) span
    (fun st -> handshake st proc k finished fd ssl desc span once)

(* The setup half of a TLS listener: TCP listen plus a server context
   holding the certificate. *)
and tls_listener ~(host : string) ~(port : int) ~(cert_path : string)
    ~(key_path : string) : (Unix.file_descr * int * Ssl.context, string) result
    =
  let ctx = tls_context Ssl.Server_context in
  match Ssl.use_certificate ctx cert_path key_path with
  | () -> (
      match listen_on host port with
      | Ok (fd, bound) -> Ok (fd, bound, ctx)
      | Error reason -> Error reason)
  | exception (Ssl.Certificate_error message | Ssl.Private_key_error message) ->
      Error
        (Printf.sprintf "cannot load the TLS certificate for %s:%d: %s" host
           port message)

and accept_loop state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (l : Emo_eval.listener) (span : Emo_support.Span.t)
    (deadline : float option) : outcome =
  if l.Emo_eval.lclosed then
    Effect.Shallow.continue_with k
      (Emo_eval.net_error
         (Printf.sprintf "the listener on %s is closed" l.Emo_eval.ldesc))
      (handler state proc ())
  else
    let fd, tls_ctx = Hashtbl.find state.listeners l.Emo_eval.lid in
    match Unix.accept fd with
    | client, sockaddr -> (
        (* Linux does not inherit O_NONBLOCK across accept (BSD does), so
           without this the accepted socket is blocking and its first read
           or write would block the whole single-threaded scheduler. *)
        Unix.set_nonblock client;
        let desc = describe_sockaddr sockaddr in
        match tls_ctx with
        | None ->
            finish_w finished state proc k
              (Emo_eval.net_ok (Emo_eval.TcpConn (make_conn state client desc)))
        | Some ctx ->
            let ssl = Ssl.embed_socket client ctx in
            handshake state proc k finished client ssl desc span Ssl.accept)
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
        park_fd state proc k finished fd `R ~deadline
          ~timeout_message:
            (Printf.sprintf "timed out waiting to accept on %s" l.Emo_eval.ldesc)
          span (fun st -> accept_loop st proc k finished l span deadline)
    | exception Unix.Unix_error (err, _, _) ->
        finish_w finished state proc k
          (Emo_eval.net_error (io_reason "accept" l.Emo_eval.ldesc err))

(* The setup half of a unix-domain listener: bind and listen, reporting
   failure as the reason string. *)
and bind_unix_listener path : (Unix.file_descr, string) result =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  match Unix.bind fd (Unix.ADDR_UNIX path) with
  | () ->
      Unix.listen fd 128;
      Ok fd
  | exception Unix.Unix_error (err, _, _) ->
      (try Unix.close fd with Unix.Unix_error _ -> ());
      Error
        (Printf.sprintf "cannot listen on unix socket %s: %s" path
           (Unix.error_message err))

(* The setup half of a UDP socket: resolve, socket, bind; returns the fd
   and the bound port. *)
and bind_udp_socket host port : (Unix.file_descr * int, string) result =
  match
    match Unix.getaddrinfo host "0" [ Unix.AI_SOCKTYPE Unix.SOCK_DGRAM ] with
    | entry :: _ -> Ok (entry.Unix.ai_family, entry.Unix.ai_addr)
    | [] -> Error (Printf.sprintf "cannot resolve host `%s`" host)
    | exception Unix.Unix_error _ ->
        Error (Printf.sprintf "cannot resolve host `%s`" host)
  with
  | Error reason -> Error reason
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
            (Printf.sprintf "cannot bind udp on %s:%d: %s" host port
               (Unix.error_message err)))

(* Sends one datagram; a full buffer parks the send on write interest.
   The peer address arrives resolved. *)
and udp_send_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation) (addr : string)
    (port : int) (data : string) (span : Emo_support.Span.t) (u : Emo_eval.udp)
    : outcome =
  if u.Emo_eval.uclosed then
    Effect.Shallow.continue_with k
      (Emo_eval.net_error
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
    (* The peer name rides in unresolved; the same lookup the bind used
       picks its address. *)
    match resolve_addrs span addr with
    | [] ->
        Effect.Shallow.continue_with k
          (Emo_eval.net_error (Printf.sprintf "cannot resolve host `%s`" addr))
          (handler state proc ())
    | resolved :: _ ->
        let target = Unix.ADDR_INET (Unix.inet_addr_of_string resolved, port) in
        let rec send_step st =
          match Unix.sendto fd bytes 0 (Bytes.length bytes) [] target with
          | _n ->
              finish_w finished st proc k
                (Emo_eval.net_ok (Emo_eval.UdpSocket u))
          | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
              park_fd state proc k finished fd `W ~deadline
                ~timeout_message:
                  (Printf.sprintf "timed out sending on %s" u.Emo_eval.udesc)
                span send_step
          | exception Unix.Unix_error (err, _, _) ->
              finish_w finished st proc k
                (Emo_eval.net_error (io_reason "send" u.Emo_eval.udesc err))
        in
        send_step state

(* Waits for one datagram and returns it as (data, host, port). *)
and udp_recv_entry state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (span : Emo_support.Span.t) (u : Emo_eval.udp) : outcome =
  if u.Emo_eval.uclosed then
    Effect.Shallow.continue_with k
      (Emo_eval.net_error
         (Printf.sprintf "the udp socket on %s is closed" u.Emo_eval.udesc))
      (handler state proc ())
  else
    let fd = Hashtbl.find state.udps u.Emo_eval.uid in
    let buf = Bytes.create 65536 in
    match Unix.recvfrom fd buf 0 65536 [] with
    | n, sockaddr ->
        let data = Bytes.sub_string buf 0 n in
        let received =
          match sockaddr with
          | Unix.ADDR_INET (addr, port) ->
              Emo_eval.Tuple
                [
                  Emo_eval.String data;
                  Emo_eval.String (Unix.string_of_inet_addr addr);
                  Emo_eval.Int64 (Int64.of_int port);
                ]
          | Unix.ADDR_UNIX _ ->
              Emo_eval.Tuple
                [ Emo_eval.String data; Emo_eval.String ""; Emo_eval.Int64 0L ]
        in
        Effect.Shallow.continue_with k (Emo_eval.net_ok received)
          (handler state proc ())
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
        Effect.Shallow.continue_with k
          (Emo_eval.net_error (io_reason "receive" u.Emo_eval.udesc err))
          (handler state proc ())

and read_chunk live buf : read_result =
  match live.ltls with
  | None -> (
      match Unix.recv live.lfd buf 0 (Bytes.length buf) [] with
      | 0 -> REof
      | n -> RData n
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> RWant `R
      | exception Unix.Unix_error (err, _, _) ->
          RFailed (Unix.error_message err))
  | Some ssl -> (
      match Ssl.read ssl buf 0 (Bytes.length buf) with
      | 0 -> REof
      | n -> RData n
      | exception Ssl.Read_error Ssl.Error_want_read -> RWant `R
      | exception Ssl.Read_error Ssl.Error_want_write -> RWant `W
      | exception (Ssl.Read_error _ | Ssl.Connection_error _) ->
          RFailed ((Ssl.get_error_string [@alert "-deprecated"]) ())
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> RWant `R)

and read_line_loop state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) : outcome =
  match line_in_buffer live with
  | Some line ->
      finish_w finished state proc k (Emo_eval.net_ok (Emo_eval.String line))
  | None ->
      read_more state proc k finished c span live deadline
        ~timeout_what:"reading a line from"
        ~at_eof:(fun st rest ->
          (* A clean close completes with an empty line; a close mid-line
             is a failure, never a silent partial line. *)
          if rest = "" then
            finish_w finished st proc k (Emo_eval.net_ok (Emo_eval.String ""))
          else
            finish_w finished st proc k
              (Emo_eval.net_error
                 (Printf.sprintf "the connection to %s closed mid-line"
                    c.Emo_eval.cdesc)))
        ~again:(fun st ->
          read_line_loop st proc k finished c span live deadline)

and read_exactly_loop state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) (n : int) : outcome =
  if Buffer.length live.rbuf >= n then
    finish_w finished state proc k
      (Emo_eval.net_ok (Emo_eval.String (buffer_take live n)))
  else
    read_more state proc k finished c span live deadline
      ~timeout_what:"reading from"
      ~at_eof:(fun st rest ->
        finish_w finished st proc k
          (Emo_eval.net_error
             (Printf.sprintf "the connection to %s closed after %d of %d bytes"
                c.Emo_eval.cdesc (String.length rest) n)))
      ~again:(fun st ->
        read_exactly_loop st proc k finished c span live deadline n)

and read_all_loop state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) : outcome =
  read_more state proc k finished c span live deadline
    ~timeout_what:"reading from"
    ~at_eof:(fun st rest ->
      (* read_all delivers everything that arrived, empty included. *)
      finish_w finished st proc k (Emo_eval.net_ok (Emo_eval.String rest)))
    ~again:(fun st -> read_all_loop st proc k finished c span live deadline)

(* Pulls one chunk into the live buffer and re-runs [again]; the three
   read operations differ only in when their buffer satisfies them, so
   EOF and readiness handling is shared here. *)
and read_more state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) ~(timeout_what : string)
    ~(at_eof : state -> string -> outcome) ~(again : state -> outcome) : outcome
    =
  let buf = Bytes.create 16384 in
  match read_chunk live buf with
  | RData n ->
      Buffer.add_subbytes live.rbuf buf 0 n;
      again state
  | REof ->
      let rest = Buffer.contents live.rbuf in
      Buffer.reset live.rbuf;
      at_eof state rest
  | RWant kind ->
      park_fd state proc k finished live.lfd kind ~deadline
        ~timeout_message:
          (Printf.sprintf "timed out %s %s" timeout_what c.Emo_eval.cdesc)
        span again
  | RFailed detail ->
      finish_w finished state proc k
        (Emo_eval.net_error
           (Printf.sprintf "cannot read on %s: %s" c.Emo_eval.cdesc detail))

and write_loop state proc
    (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
    (finished : bool ref) (c : Emo_eval.conn) (span : Emo_support.Span.t)
    (live : live) (deadline : float option) (bytes : Bytes.t) (off : int) :
    outcome =
  let len = Bytes.length bytes in
  let sent, want =
    match live.ltls with
    | None -> (
        match Unix.send live.lfd bytes off (len - off) [] with
        | n -> (n, None)
        | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> (0, Some `W)
        | exception Unix.Unix_error (err, _, _) ->
            (0, Some (`Failed (io_reason "write" c.Emo_eval.cdesc err))))
    | Some ssl -> (
        match Ssl.write ssl bytes off (len - off) with
        | n -> (n, None)
        | exception Ssl.Write_error Ssl.Error_want_read -> (0, Some `R)
        | exception Ssl.Write_error Ssl.Error_want_write -> (0, Some `W)
        | exception (Ssl.Write_error _ | Ssl.Connection_error _) ->
            ( 0,
              Some
                (`Failed
                   (Printf.sprintf "cannot write on %s: %s" c.Emo_eval.cdesc
                      ((Ssl.get_error_string [@alert "-deprecated"]) ()))) ))
  in
  let off = off + sent in
  let park kind =
    park_fd state proc k finished live.lfd kind ~deadline
      ~timeout_message:
        (Printf.sprintf "timed out writing to %s" c.Emo_eval.cdesc) span
      (fun st -> write_loop st proc k finished c span live deadline bytes off)
  in
  match want with
  | Some (`Failed reason) ->
      finish_w finished state proc k (Emo_eval.net_error reason)
  | Some `R -> park `R
  | Some `W -> park `W
  | None when off >= len ->
      finish_w finished state proc k (Emo_eval.net_ok (Emo_eval.TcpConn c))
  | None -> park `W

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
    let readable, writable, _ =
      (* A fd closed out from under its wait — an error path elsewhere
         closing it — must not poison the whole select with EBADF: drop
         the stale registration and wake its waiters, whose next read
         or write observes the closure for itself. *)
      let alive fd =
        match Unix.fstat fd with
        | _ -> true
        | exception Unix.Unix_error (Unix.EBADF, _, _) -> false
      in
      let wake_dead fds =
        List.iter
          (fun fd ->
            if not (alive fd) then
              match Hashtbl.find_opt state.io fd with
              | Some l ->
                  Hashtbl.remove state.io fd;
                  List.iter (fun w -> w.iowake ()) l
              | None -> ())
          fds
      in
      wake_dead read_fds;
      wake_dead write_fds;
      let read_fds = List.filter alive read_fds in
      let write_fds = List.filter alive write_fds in
      Unix.select read_fds write_fds [] timeout
    in
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
  (* The root process is the program: once it has ended the program ends
     with it, and every process still runnable or parked is dropped —
     exactly the phase A semantics. Only a receiver parked while the root
     still lives can never be woken, which is the deadlock below. *)
  match state.root.Emo_eval.status with
  | `Done _ -> ()
  | `Running ->
      if Queue.is_empty state.runq then
        if Hashtbl.length state.io > 0 || state.timers <> [] then (
          (* A server parked in accept or a client parked in a socket call
             keeps the program alive — but only while its root lives. *)
          pump_io state;
          loop state)
        else if
          Hashtbl.length state.waiters > 0 || Hashtbl.length state.cwaiters > 0
        then
          (* Every live process is parked in receive with nothing left to
             wake it: the program can never move again. *)
          let span =
            Emo_support.Span.make ~file:"<runtime>" ~line:1 ~col:1 ~start:0
              ~stop:0
          in
          Emo_eval.error span "E3012"
            (Printf.sprintf
               "all %d waiting processes are blocked; no message will ever \
                arrive"
               (Hashtbl.length state.waiters + Hashtbl.length state.cwaiters))
        else ()
      else
        let item = pick_and_take state in
        let proc =
          match item with
          | Fresh (p, _) -> p
          | Continue (p, _) -> p
          | Resumed (p, _, _) -> p
          | CResumed (p, _, _, _) -> p
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
          | CResumed (_, i, bindings, k) ->
              Effect.Shallow.continue_with k (i, bindings) h
          | Io (_, step) -> step state
        in
        (match outcome with
        | None -> ()
        | Some info ->
            log state (Exited (proc.Emo_eval.pid, exit_name info));
            Emo_eval.mark_exit proc info);
        loop state

(* Runs [root_body] as the root process under the seeded schedule and
   returns the event log, oldest first. *)
let run ?(seed = 0) ?(log_events = true) (root_body : unit -> unit) : event list
    =
  Emo_eval.reset_conc ();
  let state =
    {
      runq = Queue.create ();
      waiters = Hashtbl.create 8;
      cwaiters = Hashtbl.create 8;
      io = Hashtbl.create 8;
      timers = [];
      live = Hashtbl.create 8;
      listeners = Hashtbl.create 8;
      udps = Hashtbl.create 8;
      current = 0;
      rng = Random.State.make [| seed |];
      log = ref [];
      log_enabled = log_events;
      root = Emo_eval.spawn_record ();
    }
  in
  Queue.add (Fresh (state.root, root_body)) state.runq;
  (try loop state with Emo_eval.Halt_signal -> ());
  List.rev !(state.log)
