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

   Dependency policy: the core (values, strings, the scheduler) stands on
   the OCaml standard library alone; networking keeps TLS (the ssl
   package) as a target-ecosystem dependency, declared with the runtime's
   build invocation and refused with a clear message when absent.

   Layout mirrors the host libraries: [Emo_eval] carries the value ADT,
   the process/IO effects, and the builtin bridge; [Emo_runtime] carries
   the operator and dispatch surface plus the scheduler hookup. Spans and
   diagnostics stay with the compiler — standalone errors are plain
   messages. Behavioral sections marked "port pending" are stubs until
   their step lands (T26.4 the scheduler and IO). *)

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

  let self_pid () = failwith "emo_ocaml_runtime: port pending (T26.4)"

  (* Spawns a process whose arguments were evaluated eagerly in the
     spawning process — `do f(x)` reads x where the spawn appears, like
     the interpreter. *)
  let spawn_args _ _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  let spawn _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  let send _ _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  let receive _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  (* The items a receive branch's pattern binds against: tuple elements,
     array elements, or the value itself. *)
  let payload_items _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  (* Binds a receive payload's items: [f] receives the items as a list
     the emitter destructures with an exhaustive pattern. *)
  let bind_items _ _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  let raise_ _ = failwith "emo_ocaml_runtime: port pending (T26.4)"

  let halt () = failwith "emo_ocaml_runtime: port pending (T26.4)"

  (* ---- The scheduler hookup ---- *)

  (* Registers an interface for the runtime's structural is(). *)
  let register_interface name methods =
    Hashtbl.replace Emo_eval.interface_registry name methods

  (* Runs the program's root process on the own scheduler; output streams
     to stdout. Returns the process exit code. *)
  let run _ = failwith "emo_ocaml_runtime: port pending (T26.4)"
end
