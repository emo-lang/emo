(* emo_ocaml_runtime.ml — the ocaml target's standalone runtime (step 26).

   Everything a compiled Emo program links against, in one file with zero
   emo_* dependencies: `ocamlopt emo_ocaml_runtime.ml main.ml -o prog`.
   The host compiler contributes only the emitter; this runtime rides the
   compiler as generated data (src/emo_codegen/ocaml, the C runtime's
   mechanism) and is compiled by the target's own toolchain on the user's
   machine — never looked up in the host build tree.

   The contract is the emitted-code inventory in
   plan/step-26-target-independence.md (T26.2): the two module names below
   are load-bearing — the emitter's qualified paths resolve through them —
   and every symbol the inventory lists must exist with the same arity and
   behavior as the host libraries it replaces (emo_eval, emo_runtime,
   emo_sched's deterministic driver).

   Dependency policy: the core (values, strings) stands on the OCaml
   standard library; the scheduler and IO use `unix`, which ships with
   the compiler, and TLS keeps `ssl` as the one opam-package
   dependency — the build invocation declares both (ocamlfind
   -package unix,ssl) and refuses with a clear message when absent.
   There is no eio: the scheduler is the hand-rolled poll loop below.

   Layout mirrors the host libraries: [Emo_eval] carries the value ADT,
   the process/IO effects, and the builtin bridge; [Emo_runtime] carries
   the operator and dispatch surface, the process operations, and the
   scheduler. Spans and diagnostics stay with the compiler — standalone
   errors are plain messages. *)

module Emo_eval = struct

  (* ---- The value ADT ----

     The tagged dynamic representation, reshaped standalone: the
     interpreter-only, AST-carrying variants (ArrowBlock, BuiltinFn,
     Module) and closure-backed class definitions drop out — compiled
     functions are always [CompiledFn], and the shipped exception class
     carries no methods. *)

  type value =
    | Int64 of int64
    | Byte of int
    | Float of float
    | Bool of bool
    | Void
    | Char of char
    | String of string
    | Bytes of Bytes.t
    | Tuple of value list
    | Array of value array
    | List of emo_list
    | Box of value ref
    | Pid of int (* a process identity, from `do` or `self_pid()` *)
    | TcpConn of conn
    | TcpListener of listener
    | UdpSocket of udp
    | Obj of obj_handle
    | CompiledFn of compiled_fn
    | ClassDef of class_def_value
    | Instance of instance_value
    | EnumType of enum_type_value
    | EnumMember of string * string (* type name, member name *)
    | TypeValue of string
    | EmoGroup of (string * value) list (* a function group's members *)

  and compiled_fn = {
    fdesc : string; (* names it for diagnostics *)
    farity : int;
    fapply : value list -> value;
  }

  and class_def_value = {
    cname : string;
    cmethods : (string * compiled_fn) list;
    builtin_exception : bool; (* the shipped `Exception` class *)
  }

  and instance_value = {
    iclass : class_def_value;
    mutable ifields : (string * value) list;
  }

  and enum_type_value = { ename : string; emembers : (string * value) list }

  (* The networking handles: small records describing the endpoint, with
     the live socket state owned by the scheduler driver behind the id.
     The timeout is the endpoint's blocking deadline in seconds (0.0 waits
     indefinitely), set only through `set_timeout`. *)
  and conn = {
    cid : int;
    cdesc : string; (* the peer, for diagnostics *)
    mutable ctimeout : float;
    mutable cclosed : bool;
  }

  and listener = {
    lid : int;
    ldesc : string;
    lport : int; (* the requested port; port 0 resolves to the assigned one *)
    lunix : bool; (* a unix-domain listener: `port` is meaningless *)
    mutable ltimeout : float;
    mutable lclosed : bool;
  }

  and udp = {
    uid : int;
    udesc : string;
    uport : int; (* the bound port; port 0 resolves to the assigned one *)
    mutable utimeout : float;
    mutable uclosed : bool;
  }

  (* A compiled class instance: the method table is the compiled
     functions ([arity] and [value list -> value]), the fields live in
     the init window like the interpreter's. *)
  and obj_handle = {
    ocname : string; (* the source class name *)
    mutable ofields : (string * value) list;
    omethods : (string, int * (value list -> value)) Hashtbl.t;
  }

  (* The List deque: a doubly-linked chain with O(1) push and pop at
     both ends. The identity is the record, so mutation is visible
     through every alias — the same shape a Box takes. *)
  and emo_list = {
    mutable lhead : emo_list_node option;
    mutable ltail : emo_list_node option;
    mutable lsize : int;
  }

  and emo_list_node = {
    lval : value;
    mutable lprev : emo_list_node option;
    mutable lnext : emo_list_node option;
  }

  (* ---- Errors and signals ----

     Runtime errors carry the E-code and the message the compiled
     program prints (`error[E3007]: ...`); [Failure] from a mismatched
     tag stays the raw OCaml exception, as on the host. Explicit returns
     unwind through [Return_signal]; `raise <value>` unwinds as
     [Emo_raise] (value only — the raise site and call chain are
     compiler-side bookkeeping); `halt()` ends the current process. *)

  exception Error of string * string

  let error code message = raise (Error (code, message))

  exception Return_signal of value
  exception Emo_raise of value
  exception Halt_signal

  (* ---- The process and IO operations ----

     Compiled code performs these as OCaml 5 effects; the scheduler
     driver handles them at the process boundary, and every blocking
     call is a suspension point. (The compiler-side spans drop out of
     the standalone shapes.) *)

  type _ Effect.t +=
    | Spawn : (unit -> unit) -> int Effect.t
    | Send : int * value -> unit Effect.t
    | Self_pid : int Effect.t
    | Compiled_receive :
        (value -> (int * value list) option)
        -> (int * value list) Effect.t
  (* the backend's selective receive: the matcher tries each compiled
     branch (pattern + guard) and returns the branch index with the
     payload's items *)

  | Net_resolve : string -> string list Effect.t
  | Net_connect : string * int * float * string list -> conn Effect.t
  | Net_connect_unix : string * float -> conn Effect.t
  | Net_listen : string * int -> listener Effect.t
  | Net_listen_unix : string -> listener Effect.t
  | Net_accept : listener -> conn Effect.t
  | Net_read_line : conn -> string Effect.t
  | Net_read_exactly : conn * int -> string Effect.t
  | Net_read_all : conn -> string Effect.t
  | Net_write : conn * string -> unit Effect.t
  | Net_close_conn : conn -> conn Effect.t
  | Net_close_listener : listener -> listener Effect.t
  | Net_udp_bind : string * int -> udp Effect.t
  | Net_udp_send_to : udp * string * int * string -> unit Effect.t
  | Net_udp_recv_from : udp -> value Effect.t
  | Net_udp_close : udp -> udp Effect.t
  | Net_tls_connect :
      string * int * float * bool * string list
      (* host, port, timeout, insecure, resolved addresses *)
      -> conn Effect.t
  | Net_tls_listen : string * int * string * string -> listener Effect.t
  | File_read : string -> string Effect.t
  | File_write : string * string -> int Effect.t

  (* The synchronous net operations compiled method dispatch performs;
     they only run under the scheduler, exactly like the interpreted
     paths. *)
  let read_line_sync (c : conn) : string = Effect.perform (Net_read_line c)

  let read_exactly_sync (c : conn) (n : int) : string =
    Effect.perform (Net_read_exactly (c, n))

  let read_all_sync (c : conn) : string = Effect.perform (Net_read_all c)

  let write_sync (c : conn) (data : string) : unit =
    Effect.perform (Net_write (c, data))

  let close_sync (c : conn) : conn = Effect.perform (Net_close_conn c)

  let accept_sync (l : listener) : conn = Effect.perform (Net_accept l)

  let close_listener_sync (l : listener) : listener =
    Effect.perform (Net_close_listener l)

  let udp_send_sync (u : udp) (host : string) (port : int) (data : string) :
      unit =
    Effect.perform (Net_udp_send_to (u, host, port, data))

  let udp_recv_sync (u : udp) : value = Effect.perform (Net_udp_recv_from u)

  let udp_close_sync (u : udp) : udp = Effect.perform (Net_udp_close u)

  let net_resolve_sync (host : string) : string list =
    Effect.perform (Net_resolve host)

  let net_connect_sync (host : string) (port : int) (timeout : float) : conn =
    Effect.perform (Net_connect (host, port, timeout, net_resolve_sync host))

  let net_listen_sync (host : string) (port : int) : listener =
    Effect.perform (Net_listen (host, port))

  (* ---- Concurrency core ----

     Processes own mailboxes; compiled code performs the process
     operations as effects, and the scheduler in [Emo_runtime] handles
     them at the process boundary. *)

  type exit_info =
    | Exit_normal
    | Exit_raised of value
    (* the raised value *)
    | Exit_failed of string
  (* the runtime error's message *)

  type process = {
    pid : int;
    mutable inbox : value list; (* oldest message first *)
    mutable status : [ `Running | `Done of exit_info ];
    mutable exit_hooks : (exit_info -> unit) list;
        (* the process-exit signal a supervisor subscribes to *)
  }

  let processes : (int, process) Hashtbl.t = Hashtbl.create 8
  let next_pid : int ref = ref 0

  (* One id space for the networking handles the driver tracks. *)
  let next_resource_id : int ref = ref 0

  let fresh_resource_id () =
    incr next_resource_id;
    !next_resource_id

  (* (Re)initializes the concurrency state for one program run. *)
  let reset_conc () =
    Hashtbl.reset processes;
    next_pid := 0;
    next_resource_id := 0

  let spawn_record () =
    let p = { pid = !next_pid; inbox = []; status = `Running; exit_hooks = [] } in
    Hashtbl.replace processes p.pid p;
    next_pid := !next_pid + 1;
    p

  let find_process pid =
    match Hashtbl.find_opt processes pid with
    | Some p -> p
    | None -> error "E3011" (Printf.sprintf "no process has pid %d" pid)

  (* The List deque's operations: O(1) push and pop at both ends, and the
     elements front to back. Popping an empty List is a domain error, like
     an out-of-bounds index. *)
  let fresh_list () : emo_list = { lhead = None; ltail = None; lsize = 0 }

  let list_values (l : emo_list) : value list =
    let rec go node acc =
      match node with
      | None -> List.rev acc
      | Some n -> go n.lnext (n.lval :: acc)
    in
    go l.lhead []

  let list_push_front (l : emo_list) (v : value) : unit =
    let node = { lval = v; lprev = None; lnext = l.lhead } in
    (match l.lhead with Some h -> h.lprev <- Some node | None -> l.ltail <- Some node);
    l.lhead <- Some node;
    l.lsize <- l.lsize + 1

  let list_push_back (l : emo_list) (v : value) : unit =
    let node = { lval = v; lprev = l.ltail; lnext = None } in
    (match l.ltail with Some t -> t.lnext <- Some node | None -> l.lhead <- Some node);
    l.ltail <- Some node;
    l.lsize <- l.lsize + 1

  let list_pop_front (l : emo_list) : value =
    match l.lhead with
    | None -> error "E3004" "`pop_front` on an empty List"
    | Some node ->
        l.lhead <- node.lnext;
        (match node.lnext with Some n -> n.lprev <- None | None -> l.ltail <- None);
        l.lsize <- l.lsize - 1;
        node.lval

  let list_pop_back (l : emo_list) : value =
    match l.ltail with
    | None -> error "E3004" "`pop_back` on an empty List"
    | Some node ->
        l.ltail <- node.lprev;
        (match node.lprev with Some p -> p.lnext <- None | None -> l.lhead <- None);
        l.lsize <- l.lsize - 1;
        node.lval

  (* Snapshots a message at the process boundary: every Box in the message
     (directly or inside a tuple, array, or instance) arrives as a fresh
     copy, so mutability never crosses a process boundary — mutations on
     either side stay unobservable to the other. Everything else is
     immutable data or identity and passes as-is. *)
  let rec snapshot (v : value) : value =
    match v with
    | Box r -> Box (ref (snapshot !r))
    | Bytes b -> Bytes (Bytes.copy b)
    | Tuple vs -> Tuple (List.map snapshot vs)
    | Array xs -> Array (Array.map snapshot xs)
    | List l ->
        let copy = fresh_list () in
        List.iter (fun v -> list_push_back copy (snapshot v)) (list_values l);
        List copy
    | Instance i ->
        Instance
          {
            iclass = i.iclass;
            ifields = List.map (fun (n, f) -> (n, snapshot f)) i.ifields;
          }
    | Obj o ->
        Obj
          {
            ocname = o.ocname;
            ofields = List.map (fun (n, f) -> (n, snapshot f)) o.ofields;
            omethods = o.omethods;
          }
    | v -> v

  (* Delivers a message to a mailbox. Sends to a process that has already
     exited are dropped, like any actor system's send to a dead pid. *)
  let deliver proc value =
    match proc.status with
    | `Running -> proc.inbox <- proc.inbox @ [ snapshot value ]
    | `Done _ -> ()

  (* Dequeues the first message the compiled matcher accepts, mirroring
     the interpreter's take_matching for the backend's receive. *)
  let take_compiled proc matcher =
    let rec go before = function
      | [] -> None
      | msg :: rest -> (
          match matcher msg with
          | Some (i, bindings) ->
              proc.inbox <- List.rev_append before rest;
              Some (i, bindings)
          | None -> go (msg :: before) rest)
    in
    go [] proc.inbox

  let mark_exit p info =
    p.status <- `Done info;
    List.iter (fun hook -> hook info) p.exit_hooks;
    p.exit_hooks <- []

  (* Builds the Emo exception a network failure unwinds with. The driver
     discontinues the parked continuation with it. *)
  let net_raise message =
    Emo_raise
      (Instance
         {
           iclass =
             { cname = "Exception"; cmethods = []; builtin_exception = true };
           ifields = [ ("message", String message) ];
         })

  (* ---- Values ---- *)

  let type_name = function
    | Int64 _ -> "Int64"
    | Byte _ -> "Byte"
    | Float _ -> "Float64"
    | Bool _ -> "Bool"
    | Void -> "Void"
    | Char _ -> "Char"
    | String _ -> "String"
    | Bytes _ -> "Bytes"
    | Tuple _ -> "Tuple"
    | Array _ -> "Array"
    | List _ -> "List"
    | Box _ -> "Box"
    | Pid _ -> "Pid"
    | TcpConn _ -> "TcpConn"
    | TcpListener _ -> "TcpListener"
    | UdpSocket _ -> "UdpSocket"
    | Obj o -> o.ocname
    | CompiledFn _ -> "an arrow block"
    | ClassDef _ -> "a class"
    | Instance _ -> "an instance"
    | EnumType _ -> "an enum"
    | EnumMember _ -> "an enum member"
    | TypeValue _ -> "a type"
    | EmoGroup _ -> "a function group"

  let rec equal_value a b =
    match (a, b) with
    | Int64 x, Int64 y -> Int64.equal x y
    | Byte x, Byte y -> Int.equal x y
    | Float x, Float y -> Float.equal x y
    | Bool x, Bool y -> Bool.equal x y
    | Void, Void -> true
    | Char x, Char y -> Char.equal x y
    | String x, String y -> String.equal x y
    | Bytes x, Bytes y -> Bytes.equal x y
    | Tuple xs, Tuple ys ->
        List.length xs = List.length ys && List.for_all2 equal_value xs ys
    | Array xs, Array ys ->
        Array.length xs = Array.length ys
        &&
        let ok = ref true in
        Array.iteri (fun i x -> if not (equal_value x ys.(i)) then ok := false) xs;
        !ok
    | List x, List y ->
        let rec go a b =
          match (a, b) with
          | None, None -> true
          | Some na, Some nb ->
              equal_value na.lval nb.lval && go na.lnext nb.lnext
          | _ -> false
        in
        go x.lhead y.lhead
    | Box x, Box y -> equal_value !x !y
    | Pid x, Pid y -> Int.equal x y
    | TcpConn x, TcpConn y -> Int.equal x.cid y.cid
    | TcpListener x, TcpListener y -> Int.equal x.lid y.lid
    | UdpSocket x, UdpSocket y -> Int.equal x.uid y.uid
    | Obj x, Obj y ->
        String.equal x.ocname y.ocname
        && List.length x.ofields = List.length y.ofields
        && List.for_all2
             (fun (nx, vx) (ny, vy) -> String.equal nx ny && equal_value vx vy)
             x.ofields y.ofields
    | CompiledFn x, CompiledFn y -> String.equal x.fdesc y.fdesc
    | EnumMember (t, m), EnumMember (t', m') ->
        String.equal t t' && String.equal m m'
    | EnumType x, EnumType y -> String.equal x.ename y.ename
    | ClassDef x, ClassDef y -> x == y (* a declaration is an identity *)
    | TypeValue x, TypeValue y -> String.equal x y
    | Instance x, Instance y ->
        String.equal x.iclass.cname y.iclass.cname
        && List.length x.ifields = List.length y.ifields
        && List.for_all2
             (fun (nx, vx) (ny, vy) -> String.equal nx ny && equal_value vx vy)
             x.ifields y.ifields
    | _ -> false

  (* Program output goes to stdout; the driver redirects through
     [set_output]. *)
  let output : (string -> unit) ref =
    ref (fun s ->
        print_string s;
        flush stdout)

  let set_output f = output := f

  (* The one stringification rule: interpolation and `.to_string()` share
     it. *)
  let rec to_string v =
    match v with
    | Int64 n -> Int64.to_string n
    | Byte n -> string_of_int n
    | Float f ->
        if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.1f" f
        else Printf.sprintf "%g" f
    | Bool b -> string_of_bool b
    | Void -> "void"
    | Char c -> String.make 1 c
    | String s -> s
    | Tuple vs -> "(" ^ String.concat ", " (List.map to_string vs) ^ ")"
    | Array vs ->
        "[" ^ String.concat ", " (List.map to_string (Array.to_list vs)) ^ "]"
    | List l ->
        "List["
        ^ String.concat ", " (List.map to_string (list_values l))
        ^ "]"
    | Box _ -> "<box>"
    | Bytes b -> Printf.sprintf "Bytes[%d]" (Bytes.length b)
    | Pid n -> Printf.sprintf "<pid %d>" n
    | TcpConn c -> Printf.sprintf "<conn %s>" c.cdesc
    | TcpListener l -> Printf.sprintf "<listener %s>" l.ldesc
    | UdpSocket u -> Printf.sprintf "<udp %s>" u.udesc
    | Obj o ->
        let fields =
          String.concat ", "
            (List.map (fun (n, fv) -> n ^ ": " ^ debug_value fv) o.ofields)
        in
        "#" ^ o.ocname ^ "(" ^ fields ^ ")"
    | CompiledFn f -> Printf.sprintf "<block %s>" f.fdesc
    | ClassDef c -> c.cname
    | Instance i ->
        if
          (* Provisional default format, per the step-06 spec. *)
          i.iclass.builtin_exception
        then
          match List.assoc_opt "message" i.ifields with
          | Some message -> to_string message
          | None -> "#Exception()"
        else
          let fields =
            String.concat ", "
              (List.map (fun (n, fv) -> n ^ ": " ^ debug_value fv) i.ifields)
          in
          "#" ^ i.iclass.cname ^ "(" ^ fields ^ ")"
    | EnumType e -> e.ename
    | EnumMember (_, m) -> m
    | TypeValue t -> t
    | EmoGroup _ -> "<group>"

  (* Inside an instance's default rendering, strings show quoted. *)
  and debug_value v =
    match v with
    | String s -> Printf.sprintf "%S" s
    | Tuple vs -> "(" ^ String.concat ", " (List.map debug_value vs) ^ ")"
    | Array vs ->
        "[" ^ String.concat ", " (List.map debug_value (Array.to_list vs)) ^ "]"
    | List l ->
        "List[" ^ String.concat ", " (List.map debug_value (list_values l)) ^ "]"
    | v -> to_string v

  (* Interfaces have no runtime artifact beyond this registry: `x.is(T)`
     checks the receiver's class against the declared method shapes. *)
  let interface_registry : (string, (string * int) list) Hashtbl.t =
    Hashtbl.create 8

  (* `x.is(T)` — the runtime half of narrowing: exact class for classes, the
     declaring enum for members, and a structural method-shape check for
     interfaces. *)
  let runtime_is v t =
    match (v, t) with
    | Obj o, ClassDef c -> String.equal o.ocname c.cname
    | Obj o, TypeValue tname -> (
        (* The compiled backend names classes with TypeValue too: an
           interface check when one is registered, a class-name compare
           otherwise. *)
        match Hashtbl.find_opt interface_registry tname with
        | Some sigs ->
            List.for_all
              (fun (m, arity) ->
                match Hashtbl.find_opt o.omethods m with
                | Some (a, _) -> a = arity
                | None -> false)
              sigs
        | None -> String.equal o.ocname tname)
    | Instance i, ClassDef c -> String.equal i.iclass.cname c.cname
    | EnumMember (et, _), EnumType e -> String.equal et e.ename
    | Instance i, TypeValue tname -> (
        match Hashtbl.find_opt interface_registry tname with
        | Some sigs ->
            List.for_all
              (fun (m, arity) ->
                match List.assoc_opt m i.iclass.cmethods with
                | Some f -> f.farity = arity
                | None -> false)
              sigs
        | None -> String.equal i.iclass.cname tname)
    | EnumMember _, TypeValue _ -> false
    | _ ->
        error "E3007"
          (Printf.sprintf "`is` checks instances and enum members, not %s"
             (type_name v))

  let new_obj (name : string)
      (methods : (string, int * (value list -> value)) Hashtbl.t) : obj_handle
      =
    { ocname = name; ofields = []; omethods = methods }

  (* Sets a field on a compiled object inside the init window: replaces in
     place, or appends in first-assignment order. *)
  let obj_set_field (o : obj_handle) (name : string) (v : value) : unit =
    if List.mem_assoc name o.ofields then
      o.ofields <-
        List.map
          (fun (n, old) -> if String.equal n name then (n, v) else (n, old))
          o.ofields
    else o.ofields <- o.ofields @ [ (name, v) ]

  (* ---- The builtin bridge ----

     Bridges compiled code into the builtin surface (println, the net_*
     family, halt, ...): the same argument shapes and runtime errors as
     interpreted calls. The net/file arms perform their effects; the
     scheduler driver handles them (T26.4). *)

  let apply_builtin name args =
    match (name, args) with
    | "println", [ v ] ->
        !output (to_string v ^ "\n");
        v
    | "println", vs ->
        error "E3007"
          (Printf.sprintf "`println` expects 1 argument, got %d"
             (List.length vs))
    | "self_pid", [] -> Pid (Effect.perform Self_pid)
    | "self_pid", vs ->
        error "E3007"
          (Printf.sprintf "`self_pid` expects no arguments, got %d"
             (List.length vs))
    | "halt", [] ->
        (* Unwinds the calling process; the scheduler driver records the
           exit. *)
        raise Halt_signal
    | "halt", vs ->
        error "E3007"
          (Printf.sprintf "`halt` expects no arguments, got %d"
             (List.length vs))
    | "net_connect", args when List.length args <> 3 ->
        error "E3007"
          (Printf.sprintf
             "`net_connect` expects (host String, port Int64, timeout Float), \
              got %d arguments"
             (List.length args))
    | "net_connect", [ String host; Int64 port; Float timeout ] ->
        let addrs = Effect.perform (Net_resolve host) in
        TcpConn (Effect.perform (Net_connect (host, Int64.to_int port, timeout, addrs)))
    | "net_resolve", [ String host ] ->
        Array
          (Array.of_list
             (List.map (fun a -> String a) (Effect.perform (Net_resolve host))))
    | "net_resolve", vs ->
        error "E3007"
          (Printf.sprintf "`net_resolve` expects 1 argument, got %d"
             (List.length vs))
    | "net_connect", _ ->
        error "E3001" "`net_connect` expects (host String, port Int64, timeout Float)"
    | "net_listen", args when List.length args <> 2 ->
        error "E3007"
          (Printf.sprintf
             "`net_listen` expects (host String, port Int64), got %d arguments"
             (List.length args))
    | "net_listen", [ String host; Int64 port ] ->
        TcpListener (Effect.perform (Net_listen (host, Int64.to_int port)))
    | "net_listen", _ ->
        error "E3001" "`net_listen` expects (host String, port Int64)"
    | "net_udp_bind", args when List.length args <> 2 ->
        error "E3007"
          (Printf.sprintf
             "`net_udp_bind` expects (host String, port Int64), got %d arguments"
             (List.length args))
    | "net_udp_bind", [ String host; Int64 port ] ->
        UdpSocket (Effect.perform (Net_udp_bind (host, Int64.to_int port)))
    | "net_udp_bind", _ ->
        error "E3001" "`net_udp_bind` expects (host String, port Int64)"
    | "file_read", args when List.length args <> 1 ->
        error "E3007"
          (Printf.sprintf "`file_read` expects (path String), got %d arguments"
             (List.length args))
    | "file_read", [ String path ] -> String (Effect.perform (File_read path))
    | "file_read", [ v ] ->
        error "E3001"
          (Printf.sprintf "`file_read` expects a String path, got %s"
             (type_name v))
    | "file_write", args when List.length args <> 2 ->
        error "E3007"
          (Printf.sprintf
             "`file_write` expects (path String, contents String), got %d \
              arguments"
             (List.length args))
    | "file_write", [ String path; String contents ] ->
        Int64 (Int64.of_int (Effect.perform (File_write (path, contents))))
    | "file_write", [ String _; v ] ->
        error "E3001"
          (Printf.sprintf "`file_write` expects String contents, got %s"
             (type_name v))
    | "file_write", [ v; _ ] ->
        error "E3001"
          (Printf.sprintf "`file_write` expects a String path, got %s"
             (type_name v))
    | "net_connect_unix", args when List.length args <> 2 ->
        error "E3007"
          (Printf.sprintf
             "`net_connect_unix` expects (path String, timeout Float64), got \
              %d arguments"
             (List.length args))
    | "net_connect_unix", [ String path; Float timeout ] ->
        TcpConn (Effect.perform (Net_connect_unix (path, timeout)))
    | "net_connect_unix", _ ->
        error "E3001" "`net_connect_unix` expects (path String, timeout Float64)"
    | "net_listen_unix", args when List.length args <> 1 ->
        error "E3007"
          (Printf.sprintf
             "`net_listen_unix` expects (path String), got %d arguments"
             (List.length args))
    | "net_listen_unix", [ String path ] ->
        TcpListener (Effect.perform (Net_listen_unix path))
    | "net_listen_unix", _ ->
        error "E3001" "`net_listen_unix` expects (path String)"
    | "net_tls_connect", args when List.length args <> 3 ->
        error "E3007"
          (Printf.sprintf
             "`net_tls_connect` expects (host String, port Int64, timeout \
              Float64), got %d arguments"
             (List.length args))
    | "net_tls_connect", [ String host; Int64 port; Float timeout ] ->
        let addrs = Effect.perform (Net_resolve host) in
        TcpConn
          (Effect.perform (Net_tls_connect (host, Int64.to_int port, timeout, false, addrs)))
    | "net_tls_connect", _ ->
        error "E3001"
          "`net_tls_connect` expects (host String, port Int64, timeout Float64)"
    | "net_tls_connect_insecure", args when List.length args <> 3 ->
        error "E3007"
          (Printf.sprintf
             "`net_tls_connect_insecure` expects (host String, port Int64, \
              timeout Float64), got %d arguments"
             (List.length args))
    | "net_tls_connect_insecure", [ String host; Int64 port; Float timeout ] ->
        let addrs = Effect.perform (Net_resolve host) in
        TcpConn
          (Effect.perform
             (Net_tls_connect (host, Int64.to_int port, timeout, true, addrs)))
    | "net_tls_connect_insecure", _ ->
        error "E3001"
          "`net_tls_connect_insecure` expects (host String, port Int64, timeout Float64)"
    | "net_listen_tls", args when List.length args <> 4 ->
        error "E3007"
          (Printf.sprintf
             "`net_listen_tls` expects (host String, port Int64, cert_path \
              String, key_path String), got %d arguments"
             (List.length args))
    | "net_listen_tls", [ String host; Int64 port; String cert; String key ] ->
        TcpListener
          (Effect.perform (Net_tls_listen (host, Int64.to_int port, cert, key)))
    | "net_listen_tls", _ ->
        error "E3001"
          "`net_listen_tls` expects (host String, port Int64, cert_path String, key_path String)"
    | _ -> error "E3007" (Printf.sprintf "unknown builtin `%s`" name)

  let call_builtin (name : string) (args : value list) : value =
    apply_builtin name args
end

module Emo_runtime = struct

  exception Return_signal of Emo_eval.value
  (* a non-tail [return] unwinds its function through this *)

  exception Arity_error of string

  let arity_error name expected got =
    raise
      (Arity_error
         (Printf.sprintf "`%s` expects %d argument%s, got %d" name expected
            (if expected = 1 then "" else "s")
            got))

  (* ---- Unboxing ---- *)

  let type_error v expected =
    Printf.sprintf "expected %s, got %s" expected (Emo_eval.type_name v)

  let unbox_bool v =
    match v with
    | Emo_eval.Bool b -> b
    | other -> failwith (type_error other "Bool")

  let unbox_int64 v =
    match v with
    | Emo_eval.Int64 n -> n
    | other -> failwith (type_error other "Int64")

  let unbox_float64 v =
    match v with
    | Emo_eval.Float f -> f
    | other -> failwith (type_error other "Float64")

  let unbox_string v =
    match v with
    | Emo_eval.String s -> s
    | other -> failwith (type_error other "String")

  let unbox_pid v =
    match v with
    | Emo_eval.Pid p -> p
    | other -> failwith (type_error other "Pid")

  let unbox_conn v =
    match v with
    | Emo_eval.TcpConn c -> c
    | other -> failwith (type_error other "TcpConn")

  let box_int64 n = Emo_eval.Int64 n
  let box_float64 f = Emo_eval.Float f
  let box_bool b = Emo_eval.Bool b
  let box_string s = Emo_eval.String s
  let box_char c = Emo_eval.Char c

  let bytes_new (v : Emo_eval.value) : Emo_eval.value =
    match v with
    | Emo_eval.Int64 n when n >= 0L ->
        Emo_eval.Bytes (Bytes.make (Int64.to_int n) '\000')
    | Emo_eval.Int64 n ->
        failwith
          (Printf.sprintf "`Bytes.new` needs a non-negative length, got %Ld" n)
    | v -> failwith (type_error v "Int64")

  (* ---- Operators (tag-checked, mirroring the evaluator) ---- *)

  (* Fixed-width arithmetic wraps in two's complement; Byte, being
     unsigned, wraps modulo 256 — the evaluator's rule, mirrored here. *)
  let add a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.add x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte ((x + y) land 255)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x +. y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x +. y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x +. Int64.to_float y)
    | Emo_eval.String x, Emo_eval.String y -> Emo_eval.String (x ^ y)
    | _ -> failwith "operator `+` expects two numbers or two strings"

  let sub a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.sub x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte ((x - y) land 255)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x -. y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x -. y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x -. Int64.to_float y)
    | _ -> failwith "operator `-` expects two numbers"

  let mul a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.mul x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x * y land 255)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x *. y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x *. y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x *. Int64.to_float y)
    | _ -> failwith "operator `*` expects two numbers"

  let div a b =
    match (a, b) with
    | Emo_eval.Int64 _, Emo_eval.Int64 0L -> failwith "division by zero"
    | Emo_eval.Byte _, Emo_eval.Byte 0 -> failwith "division by zero"
    | Emo_eval.Float _, Emo_eval.Float 0.0 -> failwith "division by zero"
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.div x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x / y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x /. y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x /. y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x /. Int64.to_float y)
    | _ -> failwith "operator `/` expects two numbers"

  let modulo a b =
    match (a, b) with
    | Emo_eval.Int64 _, Emo_eval.Int64 0L -> failwith "division by zero"
    | Emo_eval.Byte _, Emo_eval.Byte 0 -> failwith "division by zero"
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.rem x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x mod y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (Float.rem x y)
    | _ -> failwith "operator `%` expects two numbers"

  (* Bitwise work is integer work: no float coercion, and out-of-range
     shift counts are an error, never a silent platform wrap. *)
  let shift_count = function
    | Emo_eval.Int64 y when y >= 0L -> Int64.to_int y
    | v -> failwith (type_error v "non-negative shift count")

  let bit_and a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logand x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x land y)
    | _ -> failwith (type_error a "two Int64s or two Bytes")

  let bit_or a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logor x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x lor y)
    | _ -> failwith (type_error a "two Int64s or two Bytes")

  let bit_xor a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logxor x y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x lxor y)
    | _ -> failwith (type_error a "two Int64s or two Bytes")

  (* Fixed-width shift counts are their own width; the count saturates at
     the width, matching the evaluator. *)
  let shl a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 c ->
        if c < 0L then failwith "shift count must be non-negative"
        else if c >= 64L then Emo_eval.Int64 0L
        else Emo_eval.Int64 (Int64.shift_left x (Int64.to_int c))
    | Emo_eval.Byte x, Emo_eval.Byte c ->
        if c >= 8 then Emo_eval.Byte 0 else Emo_eval.Byte ((x lsl c) land 255)
    | _ -> failwith (type_error a "two Int64s or two Bytes")

  let shr a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 c ->
        if c < 0L then failwith "shift count must be non-negative"
        else if c >= 64L then Emo_eval.Int64 (if x < 0L then -1L else 0L)
        else Emo_eval.Int64 (Int64.shift_right x (Int64.to_int c))
    | Emo_eval.Byte x, Emo_eval.Byte c ->
        if c >= 8 then Emo_eval.Byte 0 else Emo_eval.Byte (x lsr c)
    | _ -> failwith (type_error a "two Int64s or two Bytes")

  let bit_not = function
    | Emo_eval.Int64 x -> Emo_eval.Int64 (Int64.lognot x)
    | Emo_eval.Byte x -> Emo_eval.Byte (lnot x land 255)
    | v -> failwith (type_error v "Int64")

  (* Native-int shifts for the specialized path: the operands are already
     unboxed, so the guard must live here rather than in emitted code. *)
  let shl_int (x : int) (count : int) : int =
    if count < 0 then failwith "shift count must be non-negative"
    else if count >= 63 then 0
    else x lsl count

  (* 64-bit shifts for the specialized path's boxed Int64.t. *)
  let shl_i64 (x : int64) (count : int64) : int64 =
    let c = Int64.to_int count in
    if c < 0 then failwith "shift count must be non-negative"
    else if c >= 64 then 0L
    else Int64.shift_left x c

  let shr_i64 (x : int64) (count : int64) : int64 =
    let c = Int64.to_int count in
    if c < 0 then failwith "shift count must be non-negative"
    else if c >= 64 then if x < 0L then -1L else 0L
    else Int64.shift_right x c

  let shr_int (x : int) (count : int) : int =
    if count < 0 then failwith "shift count must be non-negative"
    else if count >= 63 then if x < 0 then -1 else 0
    else x asr count

  let lt a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x < y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x < y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x < y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x < y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x < Int64.to_float y)
    | _ -> failwith "operator `<` expects two numbers"

  let le a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x <= y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x <= y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x <= y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x <= y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x <= Int64.to_float y)
    | _ -> failwith "operator `<=` expects two numbers"

  let gt a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x > y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x > y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x > y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x > y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x > Int64.to_float y)
    | _ -> failwith "operator `>` expects two numbers"

  let ge a b =
    match (a, b) with
    | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x >= y)
    | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x >= y)
    | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x >= y)
    | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x >= y)
    | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x >= Int64.to_float y)
    | _ -> failwith "operator `>=` expects two numbers"

  let eq a b = Emo_eval.Bool (Emo_eval.equal_value a b)
  let ne a b = Emo_eval.Bool (not (Emo_eval.equal_value a b))
  let and_ a b = Emo_eval.Bool (if unbox_bool a then unbox_bool b else false)
  let or_ a b = Emo_eval.Bool (if unbox_bool a then true else unbox_bool b)
  let not_ v = Emo_eval.Bool (not (unbox_bool v))
  let no_return () = failwith "reached the end of a function without `return`"

  let case_error v =
    failwith
      (Printf.sprintf "no `case` branch matched this %s value"
         (Emo_eval.type_name v))

  let neg v = Emo_eval.Int64 (Int64.neg (unbox_int64 v))

  let negf v =
    match v with
    | Emo_eval.Float f -> Emo_eval.Float (-.f)
    | Emo_eval.Int64 n -> Emo_eval.Int64 (Int64.neg n)
    | other -> failwith (type_error other "number")

  (* ---- Objects and values ---- *)

  let new_obj name methods =
    (* Returns the [obj_handle] so the constructor can wrap it once; call
       [Emo_eval.Obj] on the result. *)
    Emo_eval.new_obj name methods

  let obj_set_field self name v =
    match self with
    | Emo_eval.Obj o -> Emo_eval.obj_set_field o name v
    | other -> failwith (type_error other "an object under construction")

  let field obj name =
    match obj with
    | Emo_eval.Obj o -> (
        match List.assoc_opt name o.Emo_eval.ofields with
        | Some v -> v
        | None -> failwith (Printf.sprintf "`%s` has no field `%s`" o.ocname name)
        )
    | Emo_eval.Instance i -> (
        match List.assoc_opt name i.Emo_eval.ifields with
        | Some v -> v
        | None ->
            failwith
              (Printf.sprintf "`%s` has no field `%s`" i.Emo_eval.iclass.cname
                 name))
    | other -> failwith (type_error other "an instance")

  let exception_new (message : Emo_eval.value) : Emo_eval.value =
    let exception_class =
      {
        Emo_eval.cname = "Exception";
        cmethods = [];
        builtin_exception = true;
      }
    in
    Emo_eval.Instance
      { iclass = exception_class; ifields = [ ("message", message) ] }

  let box_new v = Emo_eval.Box (ref v)

  (* List.new(array): copies the elements into a fresh deque, front to
     back. The argument must be an Array — anything else is the E3001
     type error. *)
  let list_new (v : Emo_eval.value) : Emo_eval.value =
    match v with
    | Emo_eval.Array xs ->
        let l = Emo_eval.fresh_list () in
        Array.iter (Emo_eval.list_push_back l) xs;
        Emo_eval.List l
    | other ->
        Emo_eval.error "E3001"
          (Printf.sprintf "`List.new` expects an Array, got %s"
             (Emo_eval.type_name other))

  let index collection i =
    match (collection, i) with
    | Emo_eval.Array xs, Emo_eval.Int64 n ->
        if n >= 0L && n < Int64.of_int (Array.length xs) then xs.(Int64.to_int n)
        else failwith (Printf.sprintf "index %Ld is out of bounds" n)
    | Emo_eval.Tuple xs, Emo_eval.Int64 n ->
        if n >= 0L && n < Int64.of_int (List.length xs) then
          List.nth xs (Int64.to_int n)
        else failwith (Printf.sprintf "index %Ld is out of bounds" n)
    | _ -> failwith "indexing expects an Array or Tuple and an Int64"

  let interpolate parts =
    Emo_eval.String
      (String.concat "" (List.map (fun p -> Emo_eval.to_string p) parts))

  (* ---- Method dispatch: the shared native methods over values ---- *)

  let method_call self name args =
    let argc = List.length args in
    let none_expected () =
      if argc <> 0 then
        failwith (Printf.sprintf "`%s` expects no arguments, got %d" name argc)
    in
    let one_expected () =
      if argc <> 1 then
        failwith (Printf.sprintf "`%s` expects 1 argument, got %d" name argc)
    in
    match (self, name) with
    | Emo_eval.Bytes b, "to_string" ->
        none_expected ();
        Emo_eval.String (Bytes.to_string b)
    | Emo_eval.Bytes b, "length" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int (Bytes.length b))
    | Emo_eval.Bytes b, "get" -> (
        one_expected ();
        match args with
        | [ Emo_eval.Int64 i ] when i >= 0L && i < Int64.of_int (Bytes.length b)
          ->
            Emo_eval.Int64
              (Int64.of_int (Char.code (Bytes.get b (Int64.to_int i))))
        | [ Emo_eval.Int64 i ] ->
            failwith
              (Printf.sprintf "index %Ld is out of bounds for a length-%d Bytes" i
                 (Bytes.length b))
        | [ v ] -> failwith (type_error v "Int64")
        | _ -> failwith "`get` expects 1 argument")
    | Emo_eval.Bytes b, "set" -> (
        if argc <> 2 then failwith "`set` expects 2 arguments";
        match args with
        | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
          when i >= 0L && i < Int64.of_int (Bytes.length b) ->
            if v < 0L || v > 255L then
              failwith
                (Printf.sprintf
                   "byte value %Ld is out of range for a byte (0-255)" v);
            Bytes.set b (Int64.to_int i) (Char.chr (Int64.to_int v));
            Emo_eval.Int64 v
        | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
            failwith
              (Printf.sprintf "index %Ld is out of bounds for a length-%d Bytes" i
                 (Bytes.length b))
        | _ -> failwith "`set` expects (i Int64, v Int64)")
    | Emo_eval.Bytes b, (("get_u16_le" | "get_u32_le") as mname) -> (
        one_expected ();
        let width = if mname = "get_u16_le" then 2 else 4 in
        match args with
        | [ Emo_eval.Int64 i ]
          when i >= 0L
               && Int64.add i (Int64.of_int width)
                  <= Int64.of_int (Bytes.length b) ->
            let i = Int64.to_int i in
            let acc = ref 0 in
            for k = width - 1 downto 0 do
              acc := (!acc lsl 8) lor Char.code (Bytes.get b (i + k))
            done;
            Emo_eval.Int64 (Int64.of_int !acc)
        | [ Emo_eval.Int64 i ] ->
            failwith
              (Printf.sprintf
                 "index %Ld is out of bounds for a %s read on a length-%d Bytes" i
                 mname (Bytes.length b))
        | [ v ] -> failwith (type_error v "Int64")
        | _ -> failwith "`get_u16_le`/`get_u32_le` expects 1 argument")
    | Emo_eval.Bytes b, (("set_u16_le" | "set_u32_le") as mname) -> (
        if argc <> 2 then failwith "`set_u16_le`/`set_u32_le` expects 2 arguments";
        let width = if mname = "set_u16_le" then 2 else 4 in
        let max = if width = 2 then 0xFFFF else 0xFFFFFFFF in
        match args with
        | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
          when i >= 0L
               && Int64.add i (Int64.of_int width)
                  <= Int64.of_int (Bytes.length b) ->
            let i = Int64.to_int i in
            let v = Int64.to_int v land max in
            for k = 0 to width - 1 do
              Bytes.set b (i + k) (Char.chr ((v lsr (8 * k)) land 0xFF))
            done;
            Emo_eval.Int64 (Int64.of_int v)
        | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
            failwith
              (Printf.sprintf
                 "index %Ld is out of bounds for a %s write on a length-%d Bytes"
                 i mname (Bytes.length b))
        | _ -> failwith "`set_u16_le`/`set_u32_le` expects (i Int64, v Int64)")
    | Emo_eval.Bytes b, "get_u64_le" -> (
        one_expected ();
        match args with
        | [ Emo_eval.Int64 i ]
          when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
            let i = Int64.to_int i in
            let acc = ref 0L in
            for k = 7 downto 0 do
              acc :=
                Int64.logor (Int64.shift_left !acc 8)
                  (Int64.of_int (Char.code (Bytes.get b (i + k))))
            done;
            Emo_eval.Int64 !acc
        | [ Emo_eval.Int64 i ] ->
            failwith
              (Printf.sprintf
                 "index %Ld is out of bounds for a get_u64_le read on a \
                  length-%d Bytes"
                 i (Bytes.length b))
        | [ v ] -> failwith (type_error v "Int64")
        | _ -> failwith "`get_u64_le` expects 1 argument")
    | Emo_eval.Bytes b, "set_u64_le" -> (
        if argc <> 2 then failwith "`set_u64_le` expects 2 arguments";
        match args with
        | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
          when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
            let i = Int64.to_int i in
            for k = 0 to 7 do
              Bytes.set b (i + k)
                (Char.chr
                   (Int64.to_int
                      (Int64.logand (Int64.shift_right_logical v (8 * k)) 0xFFL)))
            done;
            Emo_eval.Int64 v
        | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
            failwith
              (Printf.sprintf
                 "index %Ld is out of bounds for a set_u64_le write on a \
                  length-%d Bytes"
                 i (Bytes.length b))
        | [ _; v ] -> failwith (type_error v "Int64")
        | _ -> failwith "`set_u64_le` expects (i Int64, v Int64)")
    | Emo_eval.String s, "to_bytes" ->
        none_expected ();
        Emo_eval.Bytes (Bytes.of_string s)
    | Emo_eval.TypeValue "Byte", "from_int64" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.Int64 n when n >= 0L && n <= 255L ->
            Emo_eval.Byte (Int64.to_int n)
        | Emo_eval.Int64 n ->
            failwith
              (Printf.sprintf "`Byte.from_int64` needs a value in 0-255, got %Ld"
                 n)
        | v -> failwith (type_error v "Int64"))
    | Emo_eval.TypeValue "Float64", "from_bits" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.Int64 b -> Emo_eval.Float (Int64.float_of_bits b)
        | v -> failwith (type_error v "Int64"))
    | Emo_eval.Int64 x, "to_byte" ->
        none_expected ();
        Emo_eval.Byte (Int64.to_int (Int64.logand x 255L))
    | Emo_eval.Byte n, "to_int64" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int n)
    | Emo_eval.Float f, "to_bits" ->
        none_expected ();
        Emo_eval.Int64 (Int64.bits_of_float f)
    | Emo_eval.Float f, "sqrt" ->
        none_expected ();
        Emo_eval.Float (Float.sqrt f)
    | Emo_eval.Float f, "floor" ->
        none_expected ();
        Emo_eval.Float (Float.floor f)
    | Emo_eval.Float f, "ceil" ->
        none_expected ();
        Emo_eval.Float (Float.ceil f)
    | Emo_eval.Float f, "trunc" ->
        none_expected ();
        Emo_eval.Float (Float.trunc f)
    | Emo_eval.Float f, "to_int64" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_float f)
    | Emo_eval.Int64 n, "to_float64" ->
        none_expected ();
        Emo_eval.Float (Int64.to_float n)
    | _, "to_string" ->
        none_expected ();
        Emo_eval.String (Emo_eval.to_string self)
    | _, "is" ->
        one_expected ();
        let target = List.hd args in
        Emo_eval.Bool
          (try Emo_eval.runtime_is self target
           with Emo_eval.Error _ ->
             failwith "`is` checks instances and enum members, not this value")
    | Emo_eval.Array xs, "length" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int (Array.length xs))
    | Emo_eval.Tuple xs, "length" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int (List.length xs))
    | Emo_eval.String s, "length" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int (String.length s))
    | Emo_eval.String s, "substring" -> (
        match args with
        | [ Emo_eval.Int64 start; Emo_eval.Int64 len ]
          when start >= 0L && len >= 0L
               && Int64.add start len <= Int64.of_int (String.length s) ->
            Emo_eval.String (String.sub s (Int64.to_int start) (Int64.to_int len))
        | _ -> failwith "`substring` expects (start Int64, length Int64) in bounds")
    | Emo_eval.String s, "split" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.String sep when sep <> "" ->
            let rec split_at from acc =
              match
                let rec find j =
                  if j + String.length sep > String.length s then None
                  else if String.sub s j (String.length sep) = sep then Some j
                  else find (j + 1)
                in
                find from
              with
              | Some j ->
                  split_at
                    (j + String.length sep)
                    (Emo_eval.String (String.sub s from (j - from)) :: acc)
              | None ->
                  List.rev
                    (Emo_eval.String
                       (String.sub s from (String.length s - from))
                    :: acc)
            in
            Emo_eval.Array (Array.of_list (split_at 0 []))
        | _ -> failwith "`split` expects a non-empty String separator")
    | Emo_eval.String s, "trim" ->
        none_expected ();
        Emo_eval.String (String.trim s)
    | Emo_eval.String s, "lower" ->
        none_expected ();
        Emo_eval.String (String.lowercase_ascii s)
    | Emo_eval.String s, "index_of" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.String needle ->
            let rec find i =
              if i + String.length needle > String.length s then None
              else if String.sub s i (String.length needle) = needle then Some i
              else find (i + 1)
            in
            Emo_eval.Int64
              (Int64.of_int (match find 0 with Some i -> i | None -> -1))
        | _ -> failwith "`index_of` expects a String")
    | Emo_eval.String s, "starts_with" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.String prefix -> Emo_eval.Bool (String.starts_with ~prefix s)
        | _ -> failwith "`starts_with` expects a String")
    | Emo_eval.String s, "to_int64" -> (
        none_expected ();
        let body =
          if String.length s > 0 && s.[0] = '-' then
            String.sub s 1 (String.length s - 1)
          else s
        in
        if body = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') body)
        then failwith (Printf.sprintf "cannot parse `%s` as an Int64" s)
        else
          match Int64.of_string_opt s with
          | Some n -> Emo_eval.Int64 n
          | None -> failwith (Printf.sprintf "cannot parse `%s` as an Int64" s))
    | Emo_eval.Array xs, "append" ->
        one_expected ();
        Emo_eval.Array (Array.append xs [| List.hd args |])
    | Emo_eval.Box r, "read" ->
        none_expected ();
        !r
    | Emo_eval.Box r, "replace" ->
        one_expected ();
        let v = List.hd args in
        r := v;
        v
    | Emo_eval.List l, "push_front" ->
        one_expected ();
        Emo_eval.list_push_front l (List.hd args);
        Emo_eval.List l
    | Emo_eval.List l, "push_back" ->
        one_expected ();
        Emo_eval.list_push_back l (List.hd args);
        Emo_eval.List l
    | Emo_eval.List l, "pop_front" ->
        none_expected ();
        Emo_eval.list_pop_front l
    | Emo_eval.List l, "pop_back" ->
        none_expected ();
        Emo_eval.list_pop_back l
    | Emo_eval.List l, "length" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int l.Emo_eval.lsize)
    | Emo_eval.TcpConn c, "read_line" ->
        none_expected ();
        Emo_eval.String (Emo_eval.read_line_sync c)
    | Emo_eval.TcpConn c, "read_exactly" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.Int64 n ->
            Emo_eval.String (Emo_eval.read_exactly_sync c (Int64.to_int n))
        | _ -> failwith "`read_exactly` expects an Int64")
    | Emo_eval.TcpConn c, "read_all" ->
        none_expected ();
        Emo_eval.String (Emo_eval.read_all_sync c)
    | Emo_eval.TcpConn c, "write" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.String data ->
            Emo_eval.write_sync c data;
            self
        | _ -> failwith "`write` expects a String")
    | Emo_eval.TcpConn c, "close" ->
        none_expected ();
        Emo_eval.TcpConn (Emo_eval.close_sync c)
    | Emo_eval.TcpConn c, "set_timeout" -> (
        one_expected ();
        match List.hd args with
        | Emo_eval.Float f ->
            c.Emo_eval.ctimeout <- f;
            self
        | _ -> failwith "`set_timeout` expects a Float64")
    | Emo_eval.TcpListener l, "accept" ->
        none_expected ();
        Emo_eval.TcpConn (Emo_eval.accept_sync l)
    | Emo_eval.TcpListener l, "port" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int l.Emo_eval.lport)
    | Emo_eval.TcpListener l, "close" ->
        none_expected ();
        Emo_eval.TcpListener (Emo_eval.close_listener_sync l)
    | Emo_eval.UdpSocket u, "send_to" -> (
        match args with
        | [ Emo_eval.String host; Emo_eval.Int64 port; Emo_eval.String data ] ->
            Emo_eval.udp_send_sync u host (Int64.to_int port) data;
            self
        | _ -> failwith "`send_to` expects (host, port, data)")
    | Emo_eval.UdpSocket u, "recv_from" ->
        none_expected ();
        Emo_eval.udp_recv_sync u
    | Emo_eval.UdpSocket u, "port" ->
        none_expected ();
        Emo_eval.Int64 (Int64.of_int u.Emo_eval.uport)
    | Emo_eval.UdpSocket u, "close" ->
        none_expected ();
        Emo_eval.UdpSocket (Emo_eval.udp_close_sync u)
    | _ -> (
        (* Compiled objects dispatch through their table; everything else
           is NoMethodError. *)
        match self with
        | Emo_eval.Obj o -> (
            match Hashtbl.find_opt o.Emo_eval.omethods name with
            (* Compiled class methods take [self] first; the table's arity
               counts the declared parameters only. *)
            | Some (_arity, f) -> f (self :: args)
            | None ->
                failwith
                  (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
                     o.ocname name))
        | _ ->
            failwith
              (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
                 (Emo_eval.type_name self) name))

  (* First-class functions (compiled blocks and defs passed around). *)
  let apply_value f args =
    match f with
    | Emo_eval.CompiledFn c -> c.Emo_eval.fapply args
    | _ -> failwith "calling a non-function"

  (* ---- Process operations ---- *)

  let self_pid () =
    Emo_eval.Int64 (Int64.of_int (Effect.perform Emo_eval.Self_pid))

  (* Spawns a process whose arguments were evaluated eagerly in the
     spawning process — `do f(x)` reads x where the spawn appears, like
     the interpreter. *)
  let spawn_args (vals : Emo_eval.value list) (f : Emo_eval.value list -> unit) :
      Emo_eval.value =
    let thunk () = ignore (f vals) in
    Emo_eval.Pid (Effect.perform (Emo_eval.Spawn thunk))

  let spawn (thunk : unit -> unit) : Emo_eval.value =
    Emo_eval.Pid (Effect.perform (Emo_eval.Spawn thunk))

  let send (pid_value : Emo_eval.value) (message : Emo_eval.value) : unit =
    Effect.perform (Emo_eval.Send (unbox_pid pid_value, message))

  let receive
      (matchers : (Emo_eval.value -> (int * Emo_eval.value list) option) list) :
      int * Emo_eval.value list =
    (* Each branch matcher already tags its own index; the first branch
       that accepts the message decides. *)
    let matcher v =
      let rec try_branch = function
        | [] -> None
        | m :: rest -> (
            match m v with Some picked -> Some picked | None -> try_branch rest)
      in
      try_branch matchers
    in
    Effect.perform (Emo_eval.Compiled_receive matcher)

  (* The items a receive branch's pattern binds against: tuple elements,
     array elements, or the value itself. *)
  let payload_items (v : Emo_eval.value) : Emo_eval.value list =
    match v with
    | Emo_eval.Tuple xs -> xs
    | Emo_eval.Array xs -> Array.to_list xs
    | other -> [ other ]

  (* Binds a receive payload's items: [f] receives the items as a list
     the emitter destructures with an exhaustive pattern. *)
  let bind_items (v : Emo_eval.value) (f : Emo_eval.value list -> 'a) : 'a =
    f (payload_items v)

  let raise_ v = raise (Emo_eval.Emo_raise v)

  let halt () = raise Emo_eval.Halt_signal

  (* ---- The scheduler ----

     The deterministic driver the compiled program runs on: one shallow
     handler per process step, an explicit run queue, and a seeded pick —
     the same seed replays the same interleaving. Only non-suspending
     effects continue a process inline, so a slice parked in `receive` or
     in a socket call returns to the loop and the stack stays flat across
     millions of message cycles.

     Networking rides the same loop: a socket operation that cannot
     finish immediately parks its continuation on the fd (read or write
     interest) and, where a deadline applies, on a timer. When the run
     queue empties, the loop polls readiness and fires due timers, so
     concurrent server and client processes interleave through real IO.
     When the root process has ended, the program ends with it —
     remaining processes are cancelled. *)

  (* A scheduled process is either a fresh body or a continuation parked
     in receive or in a socket operation. Interest in one fd's
     readability or writability re-queues the parked operation. The live
     socket behind a connection handle is its fd plus the bytes received
     but not yet consumed by a read operation. *)
  type runnable =
    | Fresh of Emo_eval.process * (unit -> unit)
    | (* a sender parked by its own send: resume past the send, no payload *)
      Continue of Emo_eval.process * (unit, unit) Effect.Shallow.continuation
    | CResumed of
        Emo_eval.process
        * int
        * Emo_eval.value list
        * (int * Emo_eval.value list, unit) Effect.Shallow.continuation
    | (* a parked socket operation: the step attempts progress and either
         rejoins the process or re-parks it *)
      Io of Emo_eval.process * (state -> Emo_eval.exit_info option)

  and io_interest = { iokind : [ `R | `W ]; iowake : unit -> unit }

  and live = {
    lfd : Unix.file_descr;
    ltls : Ssl.socket option; (* a TLS connection rides the same fd *)
    rbuf : Buffer.t;
  }

  and state = {
    runq : runnable Queue.t;
    cwaiters :
      ( int,
        Emo_eval.process
        * (Emo_eval.value -> (int * Emo_eval.value list) option)
        * (int * Emo_eval.value list, unit) Effect.Shallow.continuation )
      Hashtbl.t;
    io : (Unix.file_descr, io_interest list) Hashtbl.t;
    mutable timers : (float * (unit -> unit)) list; (* deadline, wake *)
    live : (int, live) Hashtbl.t; (* conn id → live socket *)
    listeners : (int, Unix.file_descr * Ssl.context option) Hashtbl.t;
        (* listener id → fd, and its TLS context when serving TLS *)
    udps : (int, Unix.file_descr) Hashtbl.t; (* udp id → socket *)
    mutable current : int; (* the pid performing effects right now *)
    rng : Random.State.t;
    root : Emo_eval.process;
  }

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

  (* Wakes a parked receiver: rescanning its mailbox with its matcher,
     the first matching message is dequeued and the continuation rejoins
     the run queue. Nothing matching leaves the waiter parked. *)
  let wake state pid =
    match Hashtbl.find_opt state.cwaiters pid with
    | None -> ()
    | Some (proc, matcher, k) -> (
        match Emo_eval.take_compiled proc matcher with
        | None -> ()
        | Some (i, bindings) ->
            Hashtbl.remove state.cwaiters pid;
            Queue.add (CResumed (proc, i, bindings, k)) state.runq)

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
     nonblocking mode: Linux does not inherit O_NONBLOCK across accept, so
     a blocking accepted socket would stall the whole scheduler. *)
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

  (* Maps a Unix error onto the precise Emo exception message for [what]. *)
  let io_error what desc (err : Unix.error) =
    Emo_eval.net_raise
      (Printf.sprintf "cannot %s on %s: %s" what desc (Unix.error_message err))

  (* Consumes [n] bytes from the front of the live buffer. *)
  let buffer_take live n =
    let s = Buffer.contents live.rbuf in
    Buffer.reset live.rbuf;
    Buffer.add_string live.rbuf (String.sub s n (String.length s - n));
    String.sub s 0 n

  (* The next newline-terminated line in the buffer, without its
     terminator; the bytes are consumed. *)
  let line_in_buffer live =
    let s = Buffer.contents live.rbuf in
    match String.index_opt s '\n' with
    | None -> None
    | Some i ->
        let line = String.sub s 0 i in
        let n = String.length line in
        let line =
          if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1)
          else line
        in
        ignore (buffer_take live (i + 1));
        Some line

  (* Resolves a host to candidate address strings — DNS resolves inline
     in the handler. *)
  let resolve_addrs host : string list =
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
  let listen_on host port : Unix.file_descr * int =
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
        raise (Emo_eval.net_raise (Printf.sprintf "cannot resolve host `%s`" host))
    | entries ->
        let rec try_all = function
          | [] ->
              raise
                (Emo_eval.net_raise
                   (Printf.sprintf "cannot listen on %s:%d" host port))
          | ai :: rest -> (
              try bind_addr ai with
              | Emo_eval.Emo_raise _ as exn ->
                  if rest = [] then raise exn else try_all rest
              | Unix.Unix_error (err, _, _) ->
                  if rest = [] then
                    raise
                      (Emo_eval.net_raise
                         (Printf.sprintf "cannot listen on %s:%d: %s" host port
                            (Unix.error_message err)))
                  else try_all rest)
        in
        try_all entries

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
      (unit, Emo_eval.exit_info option) Effect.Shallow.handler =
    {
      Effect.Shallow.retc = (fun () -> Some Emo_eval.Exit_normal);
      exnc =
        (fun exn ->
          match exn with
          | Emo_eval.Halt_signal -> Some Emo_eval.Exit_normal
          | Emo_eval.Emo_raise v ->
              if proc == state.root then raise (Emo_eval.Emo_raise v)
              else Some (Emo_eval.Exit_raised v)
          | Emo_eval.Error (code, message) ->
              if proc == state.root then raise (Emo_eval.Error (code, message))
              else Some (Emo_eval.Exit_failed message)
          | e -> raise e);
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Emo_eval.Spawn thunk ->
              Some
                (fun (k : (a, _) Effect.Shallow.continuation) ->
                  let child = Emo_eval.spawn_record () in
                  Queue.add (Fresh (child, thunk)) state.runq;
                  Effect.Shallow.continue_with k child.Emo_eval.pid
                    (handler state proc ()))
          | Emo_eval.Send (pid, v) ->
              Some
                (fun (k : (a, _) Effect.Shallow.continuation) ->
                  let target = Emo_eval.find_process pid in
                  Emo_eval.deliver target v;
                  wake state pid;
                  (* Sending yields the sender's slice: the continuation
                     re-joins the run queue instead of nesting one frame
                     per message, so a process firing a million sends
                     never grows the stack. *)
                  Queue.add (Continue (proc, k)) state.runq;
                  None)
          | Emo_eval.Self_pid ->
              Some
                (fun (k : (a, _) Effect.Shallow.continuation) ->
                  Effect.Shallow.continue_with k state.current
                    (handler state proc ()))
          | Emo_eval.Net_resolve host ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match resolve_addrs host with
                  | [] ->
                      Effect.Shallow.discontinue_with k
                        (Emo_eval.net_raise
                           (Printf.sprintf "cannot resolve host `%s`" host))
                        (handler state proc ())
                  | addresses ->
                      Effect.Shallow.continue_with k addresses
                        (handler state proc ()))
          | Emo_eval.Net_connect (host, port, timeout, addrs) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  connect_entry state proc k ~host ~port ~timeout addrs)
          | Emo_eval.Net_listen (host, port) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match listen_on host port with
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
                      Hashtbl.replace state.listeners l.Emo_eval.lid (fd, None);
                      Effect.Shallow.continue_with k l (handler state proc ()))
          | Emo_eval.Net_tls_listen (host, port, cert_path, key_path) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match tls_listener ~host ~port ~cert_path ~key_path with
                  | Error exn ->
                      Effect.Shallow.discontinue_with k exn
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
                      Hashtbl.replace state.listeners l.Emo_eval.lid
                        (fd, Some ctx);
                      Effect.Shallow.continue_with k l (handler state proc ()))
          | Emo_eval.Net_tls_connect (host, port, timeout, insecure, addrs) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  connect_tls_entry state proc k ~host ~port ~timeout ~insecure
                    addrs)
          | Emo_eval.Net_accept l ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  let finished = ref false in
                  let deadline =
                    if l.Emo_eval.ltimeout > 0.0 then
                      Some (Unix.gettimeofday () +. l.Emo_eval.ltimeout)
                    else None
                  in
                  accept_loop state proc k finished l deadline)
          | Emo_eval.Net_read_line c ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  conn_entry state proc k c (fun live ->
                      let finished = ref false in
                      let deadline = conn_deadline c in
                      read_line_loop state proc k finished c live deadline))
          | Emo_eval.Net_read_exactly (c, n) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  conn_entry state proc k c (fun live ->
                      let finished = ref false in
                      let deadline = conn_deadline c in
                      read_exactly_loop state proc k finished c live deadline n))
          | Emo_eval.Net_read_all c ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  conn_entry state proc k c (fun live ->
                      let finished = ref false in
                      let deadline = conn_deadline c in
                      read_all_loop state proc k finished c live deadline))
          | Emo_eval.Net_write (c, data) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  conn_entry state proc k c (fun live ->
                      let finished = ref false in
                      let deadline = conn_deadline c in
                      write_loop state proc k finished c live deadline
                        (Bytes.of_string data) 0))
          | Emo_eval.File_read path ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  try
                    let ic = open_in_bin path in
                    let text = really_input_string ic (in_channel_length ic) in
                    close_in_noerr ic;
                    Effect.Shallow.continue_with k text (handler state proc ())
                  with Sys_error message ->
                    raise
                      (Emo_eval.net_raise
                         (Printf.sprintf "cannot read %s: %s" path message)))
          | Emo_eval.File_write (path, contents) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  (* Close before resuming: the resumption runs the rest
                     of the process, and a read-your-own-write race beats
                     descriptor hygiene. *)
                  try
                    let oc = open_out_bin path in
                    output_string oc contents;
                    let n = String.length contents in
                    close_out_noerr oc;
                    Effect.Shallow.continue_with k n (handler state proc ())
                  with Sys_error message ->
                    raise
                      (Emo_eval.net_raise
                         (Printf.sprintf "cannot write %s: %s" path message)))
          | Emo_eval.Net_close_conn c ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  conn_entry state proc k c (fun live ->
                      (* Graceful: writes have already been delivered in
                         full; shut down our sending side, then close. *)
                      (try Unix.shutdown live.lfd Unix.SHUTDOWN_SEND
                       with Unix.Unix_error _ -> ());
                      (try Unix.close live.lfd with Unix.Unix_error _ -> ());
                      Hashtbl.remove state.live c.Emo_eval.cid;
                      Effect.Shallow.continue_with k c (handler state proc ())))
          | Emo_eval.Net_connect_unix (path, timeout) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  connect_unix_entry state proc k ~path ~timeout)
          | Emo_eval.Net_listen_unix path ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match bind_unix_listener path with
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
                      Hashtbl.replace state.listeners l.Emo_eval.lid (fd, None);
                      Effect.Shallow.continue_with k l (handler state proc ()))
          | Emo_eval.Net_udp_bind (host, port) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match bind_udp_socket host port with
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
          | Emo_eval.Net_udp_send_to (u, addr, port, data) ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  udp_send_entry state proc k addr port data u)
          | Emo_eval.Net_udp_recv_from u ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  udp_recv_entry state proc k u)
          | Emo_eval.Net_udp_close u ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  if u.Emo_eval.uclosed then
                    Effect.Shallow.discontinue_with k
                      (Emo_eval.net_raise
                         (Printf.sprintf
                            "the udp socket on %s is already closed"
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
          | Emo_eval.Compiled_receive matcher ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  match Emo_eval.take_compiled proc matcher with
                  | Some (i, bindings) ->
                      Effect.Shallow.continue_with k (i, bindings)
                        (handler state proc ())
                  | None ->
                      Hashtbl.replace state.cwaiters proc.Emo_eval.pid
                        (proc, matcher, k);
                      None)
          | Emo_eval.Net_close_listener l ->
              Some
                (fun (k : (a, unit) Effect.Shallow.continuation) ->
                  if l.Emo_eval.lclosed then
                    Effect.Shallow.discontinue_with k
                      (Emo_eval.net_raise
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
                    Effect.Shallow.continue_with k l (handler state proc ())))
          | _ -> None);
    }

  (* The connection's whole-operation deadline, computed when the
     operation starts so multi-park reads honor one budget. *)
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
      (live -> Emo_eval.exit_info option) ->
      Emo_eval.exit_info option =
   fun state proc k c body ->
    let closed =
      Emo_eval.net_raise
        (Printf.sprintf "the connection to %s is closed" c.Emo_eval.cdesc)
    in
    if c.Emo_eval.cclosed then
      Effect.Shallow.discontinue_with k closed (handler state proc ())
    else
      match Hashtbl.find_opt state.live c.Emo_eval.cid with
      | Some live -> body live
      | None -> Effect.Shallow.discontinue_with k closed (handler state proc ())

  (* Parks on fd interest plus the deadline; the timeout message states
     the configured budget, which is what the operation was given. *)
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
      (state -> Emo_eval.exit_info option) ->
      Emo_eval.exit_info option =
   fun state proc k finished fd kind ~deadline ~timeout_message step ->
    (* A wake only re-runs the step when nothing has completed the
       operation yet; the completion itself goes through finish_w/abort_w,
       which set the flag — so a racing timer and readiness wake resume
       the parked continuation exactly once. *)
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
                         (Emo_eval.net_raise timeout_message) ))
            state.runq)
    | None -> ());
    None

  and finish :
      'x.
      state ->
      Emo_eval.process ->
      ('x, unit) Effect.Shallow.continuation ->
      'x ->
      Emo_eval.exit_info option =
   fun state proc k v -> Effect.Shallow.continue_with k v (handler state proc ())

  and abort :
      'x.
      state ->
      Emo_eval.process ->
      ('x, unit) Effect.Shallow.continuation ->
      exn ->
      Emo_eval.exit_info option =
   fun state proc k exn ->
    Effect.Shallow.discontinue_with k exn (handler state proc ())

  (* Guarded completions: the first of a readiness wake and a deadline
     wake wins; later ones observe the flag and do nothing. *)
  and finish_w :
      'x.
      bool ref ->
      state ->
      Emo_eval.process ->
      ('x, unit) Effect.Shallow.continuation ->
      'x ->
      Emo_eval.exit_info option =
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
      Emo_eval.exit_info option =
   fun finished st proc k exn ->
    if !finished then None
    else (
      finished := true;
      abort st proc k exn)

  and connect_entry state proc
      (k : (Emo_eval.conn, unit) Effect.Shallow.continuation) ~(host : string)
      ~(port : int) ~(timeout : float) (addresses : string list) :
      Emo_eval.exit_info option =
    let target = Printf.sprintf "%s:%d" host port in
    let addrs =
      List.map
        (fun a ->
          {
            cfam =
              (if String.contains a ':' then Unix.PF_INET6 else Unix.PF_INET);
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
      ~last_error:None addrs

  (* A TLS connect runs the same connect machinery; on a connected socket
     the TLS handshake takes over, parking through the scheduler. *)
  and connect_tls_entry state proc
      (k : (Emo_eval.conn, unit) Effect.Shallow.continuation) ~(host : string)
      ~(port : int) ~(timeout : float) ~(insecure : bool)
      (addresses : string list) : Emo_eval.exit_info option =
    let ctx = client_tls_ctx ~insecure in
    let target = Printf.sprintf "%s:%d" host port in
    let addrs =
      List.map
        (fun a ->
          {
            cfam =
              (if String.contains a ':' then Unix.PF_INET6 else Unix.PF_INET);
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
      ~last_error:None addrs

  (* A unix-domain connect has one candidate address: the path itself. *)
  and connect_unix_entry state proc
      (k : (Emo_eval.conn, unit) Effect.Shallow.continuation) ~(path : string)
      ~(timeout : float) : Emo_eval.exit_info option =
    let target = Printf.sprintf "unix socket %s" path in
    let deadline =
      if timeout > 0.0 then Some (Unix.gettimeofday () +. timeout) else None
    in
    let message =
      Printf.sprintf "timed out after %gs connecting to %s" timeout target
    in
    connect_next state proc k ~target ~deadline ~message ~tls:None
      ~last_error:None
      [ { cfam = Unix.PF_UNIX; caddr = Unix.ADDR_UNIX path } ]

  and connect_next state proc k ~target ~deadline ~message
      ~(tls : Ssl.context option) ~(last_error : Unix.error option) addrs =
    match addrs with
    | [] ->
        (* Every candidate failed; the last OS error is the precise
           reason. *)
        abort state proc k
          (match last_error with
          | Some Unix.ECONNREFUSED ->
              Emo_eval.net_raise (Printf.sprintf "connection refused to %s" target)
          | Some err ->
              Emo_eval.net_raise
                (Printf.sprintf "cannot connect to %s: %s" target
                   (Unix.error_message err))
          | None -> Emo_eval.net_raise (Printf.sprintf "cannot connect to %s" target))
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
              Emo_eval.net_raise (Printf.sprintf "connection refused to %s" target)
          | _ ->
              Emo_eval.net_raise
                (Printf.sprintf "cannot connect to %s: %s" target
                   (Unix.error_message err))
        in
        let step st =
          match Unix.getsockopt_error fd with
          | Some err ->
              cleanup st;
              (* This address failed; the refusal is only final when the
                 last candidate said it. *)
              connect_next st proc k ~target ~deadline ~message ~tls
                ~last_error:(Some err) rest
          | None -> connect_tls_upgrade st proc k finished fd target tls
        in
        let timeout_step st =
          cleanup st;
          abort_w finished st proc k (Emo_eval.net_raise message)
        in
        match Unix.connect fd addr.caddr with
        | () -> connect_tls_upgrade state proc k finished fd target tls
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
              connect_next state proc k ~target ~deadline ~message ~tls
                ~last_error:(Some err) rest)

  (* A verifying client context, or one that explicitly skips
     verification (`net_tls_connect_insecure` — visibly dangerous, never
     a default). *)
  and client_tls_ctx ~(insecure : bool) : Ssl.context =
    (* SSLv23 is the negotiate-all profile; the deprecation alert refers
       to the SSL 2.0 days, not to what OpenSSL does with it today. *)
    let[@alert "-deprecated"] ctx =
      Ssl.create_context Ssl.SSLv23 Ssl.Client_context
    in
    if insecure then Ssl.set_verify ctx [] None
    else (
      ignore (Ssl.set_default_verify_paths ctx);
      Ssl.set_verify ctx
        [ Ssl.Verify_peer; Ssl.Verify_fail_if_no_peer_cert ]
        (Some Ssl.client_verify_callback));
    ctx

  (* Upgrades a just-connected socket: plain connects finish
     immediately; TLS hands the socket to OpenSSL and shakes hands
     asynchronously. *)
  and connect_tls_upgrade state proc
      (k : (Emo_eval.conn, unit) Effect.Shallow.continuation)
      (finished : bool ref) (fd : Unix.file_descr) (target : string)
      (tls : Ssl.context option) : Emo_eval.exit_info option =
    match tls with
    | None -> finish_w finished state proc k (make_conn state fd target)
    | Some ctx ->
        let ssl = Ssl.embed_socket fd ctx in
        handshake state proc k finished fd ssl target Ssl.connect

  (* Drives a nonblocking TLS handshake to completion: want_read /
     want_write park the continuation on the fd, so both ends of a
     loopback handshake progress through the scheduler. *)
  and handshake state proc (k : (Emo_eval.conn, unit) Effect.Shallow.continuation)
      (finished : bool ref) (fd : Unix.file_descr) (ssl : Ssl.socket)
      (desc : string) (once : Ssl.socket -> unit) : Emo_eval.exit_info option =
    match once ssl with
    | () -> finish_w finished state proc k (make_tls_conn state fd ssl desc)
    | exception
        ( Ssl.Connection_error (Ssl.Error_want_read as want)
        | Ssl.Accept_error (Ssl.Error_want_read as want) )
      when want = Ssl.Error_want_read ->
        park_and_handshake state proc k finished fd ssl desc `R once
    | exception
        ( Ssl.Connection_error (Ssl.Error_want_write as want)
        | Ssl.Accept_error (Ssl.Error_want_write as want) )
      when want = Ssl.Error_want_write ->
        park_and_handshake state proc k finished fd ssl desc `W once
    | exception (Ssl.Connection_error _ | Ssl.Accept_error _ | Ssl.Verify_error _)
      ->
        abort_w finished state proc k
          (Emo_eval.net_raise
             (Printf.sprintf "the TLS handshake with %s failed: %s" desc
                ((Ssl.get_error_string [@alert "-deprecated"]) ())))

  and park_and_handshake state proc k finished fd ssl desc kind once =
    park_fd state proc k finished fd kind ~deadline:None
      ~timeout_message:(Printf.sprintf "timed out handshaking with %s" desc)
      (fun st -> handshake st proc k finished fd ssl desc once)

  (* The setup half of a TLS listener: TCP listen plus a server context
     holding the certificate. *)
  and tls_listener ~(host : string) ~(port : int) ~(cert_path : string)
      ~(key_path : string) :
      (Unix.file_descr * int * Ssl.context, exn) result =
    let[@alert "-deprecated"] ctx =
      Ssl.create_context Ssl.SSLv23 Ssl.Server_context
    in
    match Ssl.use_certificate ctx cert_path key_path with
    | () -> (
        try
          let fd, bound = listen_on host port in
          Ok (fd, bound, ctx)
        with Emo_eval.Emo_raise _ as exn -> Error exn)
    | exception (Ssl.Certificate_error message | Ssl.Private_key_error message) ->
        Error
          (Emo_eval.net_raise
             (Printf.sprintf "cannot load the TLS certificate for %s:%d: %s" host
                port message))

  and accept_loop state proc
      (k : (Emo_eval.conn, unit) Effect.Shallow.continuation)
      (finished : bool ref) (l : Emo_eval.listener) (deadline : float option) :
      Emo_eval.exit_info option =
    if l.Emo_eval.lclosed then
      Effect.Shallow.discontinue_with k
        (Emo_eval.net_raise
           (Printf.sprintf "the listener on %s is closed" l.Emo_eval.ldesc))
        (handler state proc ())
    else
      let fd, tls_ctx = Hashtbl.find state.listeners l.Emo_eval.lid in
      match Unix.accept fd with
      | client, sockaddr -> (
          (* Linux does not inherit O_NONBLOCK across accept (BSD does),
             so without this the accepted socket is blocking and its first
             read or write would block the whole single-threaded
             scheduler. *)
          Unix.set_nonblock client;
          let desc = describe_sockaddr sockaddr in
          match tls_ctx with
          | None -> finish_w finished state proc k (make_conn state client desc)
          | Some ctx ->
              let ssl = Ssl.embed_socket client ctx in
              handshake state proc k finished client ssl desc Ssl.accept)
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) ->
          park_fd state proc k finished fd `R ~deadline
            ~timeout_message:
              (Printf.sprintf "timed out waiting to accept on %s"
                 l.Emo_eval.ldesc)
            (fun st -> accept_loop st proc k finished l deadline)
      | exception Unix.Unix_error (err, _, _) ->
          abort_w finished state proc k (io_error "accept" l.Emo_eval.ldesc err)

  (* The setup half of a unix-domain listener: bind and listen, reporting
     failure as the Emo exception instead of raising across the entry. *)
  and bind_unix_listener path : (Unix.file_descr, exn) result =
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    match Unix.bind fd (Unix.ADDR_UNIX path) with
    | () ->
        Unix.listen fd 128;
        Ok fd
    | exception Unix.Unix_error (err, _, _) ->
        (try Unix.close fd with Unix.Unix_error _ -> ());
        Error
          (Emo_eval.net_raise
             (Printf.sprintf "cannot listen on unix socket %s: %s" path
                (Unix.error_message err)))

  (* The setup half of a UDP socket: resolve, socket, bind; returns the
     fd and the bound port. *)
  and bind_udp_socket host port : (Unix.file_descr * int, exn) result =
    match
      match Unix.getaddrinfo host "0" [ Unix.AI_SOCKTYPE Unix.SOCK_DGRAM ] with
      | entry :: _ -> Ok (entry.Unix.ai_family, entry.Unix.ai_addr)
      | [] ->
          Error
            (Emo_eval.net_raise (Printf.sprintf "cannot resolve host `%s`" host))
      | exception Unix.Unix_error _ ->
          Error
            (Emo_eval.net_raise (Printf.sprintf "cannot resolve host `%s`" host))
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
              (Emo_eval.net_raise
                 (Printf.sprintf "cannot bind udp on %s:%d: %s" host port
                    (Unix.error_message err))))

  (* Sends one datagram; a full buffer parks the send on write interest.
     The peer address arrives resolved. *)
  and udp_send_entry state proc (k : (unit, unit) Effect.Shallow.continuation)
      (addr : string) (port : int) (data : string) (u : Emo_eval.udp) :
      Emo_eval.exit_info option =
    if u.Emo_eval.uclosed then
      Effect.Shallow.discontinue_with k
        (Emo_eval.net_raise
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
              send_step
        | exception Unix.Unix_error (err, _, _) ->
            abort_w finished st proc k (io_error "send" u.Emo_eval.udesc err)
      in
      send_step state

  (* Waits for one datagram and returns it as (data, host, port). *)
  and udp_recv_entry state proc
      (k : (Emo_eval.value, unit) Effect.Shallow.continuation)
      (u : Emo_eval.udp) : Emo_eval.exit_info option =
    if u.Emo_eval.uclosed then
      Effect.Shallow.discontinue_with k
        (Emo_eval.net_raise
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
                     Emo_eval.Int64 (Int64.of_int port);
                   ])
                (handler state proc ())
          | Unix.ADDR_UNIX _ ->
              Effect.Shallow.continue_with k
                (Emo_eval.Tuple
                   [ Emo_eval.String data; Emo_eval.String ""; Emo_eval.Int64 0L ])
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
                 u.Emo_eval.udesc)
            (fun st -> udp_recv_entry st proc k u)
      | exception Unix.Unix_error (err, _, _) ->
          Effect.Shallow.discontinue_with k
            (io_error "receive" u.Emo_eval.udesc err)
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

  and read_line_loop state proc (k : (string, unit) Effect.Shallow.continuation)
      (finished : bool ref) (c : Emo_eval.conn) (live : live)
      (deadline : float option) : Emo_eval.exit_info option =
    match line_in_buffer live with
    | Some line -> finish_w finished state proc k line
    | None ->
        read_more state proc k finished c live deadline
          ~timeout_what:"reading a line from"
          ~at_eof:(fun st rest ->
            (* A clean close completes with an empty line; a close
               mid-line is a failure, never a silent partial line. *)
            if rest = "" then finish_w finished st proc k ""
            else
              abort_w finished st proc k
                (Emo_eval.net_raise
                   (Printf.sprintf "the connection to %s closed mid-line"
                      c.Emo_eval.cdesc)))
          ~again:(fun st -> read_line_loop st proc k finished c live deadline)

  and read_exactly_loop state proc
      (k : (string, unit) Effect.Shallow.continuation) (finished : bool ref)
      (c : Emo_eval.conn) (live : live) (deadline : float option) (n : int) :
      Emo_eval.exit_info option =
    if Buffer.length live.rbuf >= n then
      finish_w finished state proc k (buffer_take live n)
    else
      read_more state proc k finished c live deadline ~timeout_what:"reading from"
        ~at_eof:(fun st rest ->
          abort_w finished st proc k
            (Emo_eval.net_raise
               (Printf.sprintf "the connection to %s closed after %d of %d bytes"
                  c.Emo_eval.cdesc (String.length rest) n)))
        ~again:(fun st ->
          read_exactly_loop st proc k finished c live deadline n)

  and read_all_loop state proc (k : (string, unit) Effect.Shallow.continuation)
      (finished : bool ref) (c : Emo_eval.conn) (live : live)
      (deadline : float option) : Emo_eval.exit_info option =
    read_more state proc k finished c live deadline ~timeout_what:"reading from"
      ~at_eof:(fun st rest ->
        (* read_all delivers everything that arrived, empty included. *)
        finish_w finished st proc k rest)
      ~again:(fun st -> read_all_loop st proc k finished c live deadline)

  (* Pulls one chunk into the live buffer and re-runs [again]; the three
     read operations differ only in when their buffer satisfies them, so
     EOF and readiness handling is shared here. *)
  and read_more state proc (k : (string, unit) Effect.Shallow.continuation)
      (finished : bool ref) (c : Emo_eval.conn) (live : live)
      (deadline : float option) ~(timeout_what : string)
      ~(at_eof : state -> string -> Emo_eval.exit_info option)
      ~(again : state -> Emo_eval.exit_info option) : Emo_eval.exit_info option
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
          again
    | RFailed detail ->
        abort_w finished state proc k
          (Emo_eval.net_raise
             (Printf.sprintf "cannot read on %s: %s" c.Emo_eval.cdesc detail))

  and write_loop state proc (k : (unit, unit) Effect.Shallow.continuation)
      (finished : bool ref) (c : Emo_eval.conn) (live : live)
      (deadline : float option) (bytes : Bytes.t) (off : int) :
      Emo_eval.exit_info option =
    let len = Bytes.length bytes in
    let sent, want =
      match live.ltls with
      | None -> (
          match Unix.send live.lfd bytes off (len - off) [] with
          | n -> (n, None)
          | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> (0, Some `W)
          | exception Unix.Unix_error (err, _, _) ->
              (0, Some (`Failed (io_error "write" c.Emo_eval.cdesc err))))
      | Some ssl -> (
          match Ssl.write ssl bytes off (len - off) with
          | n -> (n, None)
          | exception Ssl.Write_error Ssl.Error_want_read -> (0, Some `R)
          | exception Ssl.Write_error Ssl.Error_want_write -> (0, Some `W)
          | exception (Ssl.Write_error _ | Ssl.Connection_error _) ->
              ( 0,
                Some
                  (`Failed
                     (Emo_eval.net_raise
                        (Printf.sprintf "cannot write on %s: %s"
                           c.Emo_eval.cdesc
                           ((Ssl.get_error_string [@alert "-deprecated"]) ()))))
              ))
    in
    let off = off + sent in
    let park kind =
      park_fd state proc k finished live.lfd kind ~deadline
        ~timeout_message:
          (Printf.sprintf "timed out writing to %s" c.Emo_eval.cdesc)
        (fun st -> write_loop st proc k finished c live deadline bytes off)
    in
    match want with
    | Some (`Failed exn) -> abort_w finished state proc k exn
    | Some `R -> park `R
    | Some `W -> park `W
    | None when off >= len -> finish_w finished state proc k ()
    | None -> park `W

  (* Fires due timers, then polls fd readiness once and wakes the parked
     operations whose fd is ready. Waiters that stay parked are
     untouched. *)
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
        if
          match state.root.Emo_eval.status with
          | `Done _ -> true
          | `Running -> false
        then ()
        else (
          pump_io state;
          loop state)
      else if Hashtbl.length state.cwaiters > 0 then
        (* Every live process is parked in receive with nothing left to
           wake it: the program can never move again. *)
        raise
          (Emo_eval.Error
             ( "E3012",
               Printf.sprintf
                 "all %d waiting processes are blocked; no message will ever \
                  arrive"
                 (Hashtbl.length state.cwaiters) ))
      else ()
    else
      let item = pick_and_take state in
      let proc =
        match item with
        | Fresh (p, _) -> p
        | Continue (p, _) -> p
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
        | CResumed (_, i, bindings, k) ->
            Effect.Shallow.continue_with k (i, bindings) h
        | Io (_, step) -> step state
      in
      (match outcome with
      | None -> ()
      | Some info -> Emo_eval.mark_exit proc info);
      loop state

  (* ---- The scheduler hookup ---- *)

  (* Registers an interface for the runtime's structural is(). *)
  let register_interface name methods =
    Hashtbl.replace Emo_eval.interface_registry name methods

  (* Runs the program's root process on the own scheduler; output streams
     to stdout. Returns the process exit code. *)
  let run (body : unit -> unit) : int =
    Emo_eval.reset_conc ();
    let state =
      {
        runq = Queue.create ();
        cwaiters = Hashtbl.create 8;
        io = Hashtbl.create 8;
        timers = [];
        live = Hashtbl.create 8;
        listeners = Hashtbl.create 8;
        udps = Hashtbl.create 8;
        current = 0;
        rng = Random.State.make [| 0 |];
        root = Emo_eval.spawn_record ();
      }
    in
    Queue.add (Fresh (state.root, body)) state.runq;
    try
      loop state;
      0
    with
    | Emo_eval.Error (code, message) ->
        Printf.eprintf "error[%s]: %s\n%!" code message;
        70
    | Emo_eval.Emo_raise v ->
        Printf.eprintf "uncaught exception: %s\n%!" (Emo_eval.to_string v);
        1
    | Emo_eval.Halt_signal -> 0
end
