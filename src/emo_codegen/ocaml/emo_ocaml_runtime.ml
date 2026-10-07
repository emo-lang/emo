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
   their step lands (T26.3 the value and scalar core, T26.4 the scheduler
   and IO). *)

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

  (* ---- Signals ----

     Explicit returns unwind through [Return_signal]; `raise <value>`
     unwinds as [Emo_raise] (value only — the raise site and call chain
     are compiler-side bookkeeping); `halt()` ends the current process. *)

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
      string * int * float * bool * string list (* host, port, timeout,
      insecure, resolved addresses *)
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

  (* ---- Values and the builtin bridge ---- *)

  let type_name _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let to_string _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let equal_value _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let runtime_is _ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let new_obj _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let obj_set_field _ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* Bridges compiled code into the builtin surface (println, the net_*
     family, halt, ...): the same argument shapes and runtime errors as
     interpreted calls. *)
  let call_builtin _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"
end

module Emo_runtime = struct
  open Emo_eval

  exception Arity_error of string

  let arity_error _ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Unboxing and boxing ---- *)

  let unbox_bool _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let unbox_int64 _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let unbox_float64 _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let unbox_string _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let unbox_pid _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let unbox_conn _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let box_int64 _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let box_float64 _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let box_string _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let bytes_new _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Operators (tag-checked) ---- *)

  let add _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let sub _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let mul _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let div _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let modulo _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let bit_and _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let bit_or _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let bit_xor _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let shl _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let shr _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let bit_not _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* Native-int and 64-bit shifts for the specialized path. *)
  let shl_int _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let shl_i64 _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let shr_i64 _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let shr_int _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Comparison ---- *)

  let lt _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let le _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let gt _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let ge _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let eq _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let ne _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let and_ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let or_ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let not_ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let no_return () = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let case_error _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let neg _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let negf _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Objects and values ---- *)

  let new_obj _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let obj_set_field _ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let field _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let exception_new _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let box_new _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let index _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  let interpolate _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Method dispatch ---- *)

  let method_call _ _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* First-class functions (compiled blocks and defs passed around). *)
  let apply_value _ _ = failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* ---- Process operations ---- *)

  let self_pid () = failwith "emo_ocaml_runtime: port pending (T26.4)"

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
  let register_interface _ _ =
    failwith "emo_ocaml_runtime: port pending (T26.3)"

  (* Runs the program's root process on the own scheduler; output streams
     to stdout. Returns the process exit code. *)
  let run _ = failwith "emo_ocaml_runtime: port pending (T26.4)"
end
