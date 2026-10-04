(* Tree-walking evaluator. Values are dynamically tagged; environments form a
   lexical chain that closures capture by reference. Runtime errors are
   diagnostics with spans, in the E3xxx code range. *)

module Ast = Emo_ast

exception Error of Emo_support.Diagnostic.t

let error span ?hint code message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

type value =
  | Int of int
  | Float of float
  | Bool of bool
  | Char of char
  | String of string
  | Tuple of value list
  | Array of value array
  | Box of value ref
  | Pid of int (* a process identity, from `do` or `self_pid()` *)
  | TcpConn of conn
  | TcpListener of listener
  | UdpSocket of udp
  | Obj of obj_handle
  | CompiledFn of compiled_fn
  | ArrowBlock of closure
  | BuiltinFn of string
  | ClassDef of class_def_value
  | Instance of instance_value
  | EnumType of enum_type_value
  | EnumMember of string * string (* type name, member name *)
  | TypeValue of string
  | Module of module_handle
  | EmoGroup of (string * value) list (* a function group's members *)

and class_def_value = {
  cname : string;
  cinit : closure option; (* at most one init, per the parser *)
  cmethods : (string * closure) list;
  builtin_exception : bool; (* the shipped `Exception` class *)
}

and instance_value = {
  iclass : class_def_value;
  mutable ifields : (string * value) list;
      (* appended/replaced only by `self.x = ...` inside init; frozen after *)
}

and enum_type_value = { ename : string; emembers : (string * value) list }

(* The networking handles the evaluator hands out: small records describing
   the endpoint, with the live socket state owned by the scheduler driver
   behind the id. The timeout is the endpoint's blocking deadline in
   seconds (0.0 waits indefinitely), set only through `set_timeout` — it is
   never a default. *)
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

(* A compiled class instance: the method table is the backend's compiled
   functions ([arity] and [value list -> value]), the fields live in the
   init window like the interpreter's. *)
and obj_handle = {
  ocname : string; (* the source class name *)
  mutable ofields : (string * value) list;
  omethods : (string, int * (value list -> value)) Hashtbl.t;
}

(* A compiled function as a first-class value (arrow blocks, defs passed
   around). [fdesc] names it for diagnostics. *)
and compiled_fn = { fdesc : string; farity : int; fapply : value list -> value }

and closure = {
  def_name : string; (* "`fib`" or "`<arrow block>`", for diagnostics *)
  params : Ast.param list;
  body : Ast.stmt list;
  env : env;
}

and module_handle = {
  mpath : string list; (* normalized module path, e.g. ["shop"; "order"] *)
  mchildren : (string * string list) list; (* name → child module path *)
  mutable menv : env option; (* the namespace once its items have run *)
  mutable loading : bool; (* cycle guard while items are running *)
}

and env = { frame : (string, binding) Hashtbl.t; parent : env option }
and binding = { mutable bound : value; mutable_ : bool }

(* Splits on a (possibly multi-character) separator. *)
let split_on_string sep s =
  let seplen = String.length sep in
  let last = String.length s - seplen in
  let rec find j =
    if j > last then None
    else if String.sub s j seplen = sep then Some j
    else find (j + 1)
  in
  let rec go i acc =
    match find i with
    | Some j -> go (j + seplen) (String.sub s i (j - i) :: acc)
    | None -> List.rev (String.sub s i (String.length s - i) :: acc)
  in
  go 0 []

(* Decimal only, optional minus, no separators or exponents: `1_000`,
   `0x10`, and `+5` are not integers here. *)
let parse_decimal s =
  let body =
    if String.length s > 0 && s.[0] = '-' then
      String.sub s 1 (String.length s - 1)
    else s
  in
  if body = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') body) then
    None
  else int_of_string_opt s

let type_name = function
  | Int _ -> "Int"
  | Float _ -> "Float"
  | Bool _ -> "Bool"
  | Char _ -> "Char"
  | String _ -> "String"
  | Tuple _ -> "Tuple"
  | Array _ -> "Array"
  | Box _ -> "Box"
  | Pid _ -> "Pid"
  | TcpConn _ -> "TcpConn"
  | TcpListener _ -> "TcpListener"
  | UdpSocket _ -> "UdpSocket"
  | Obj o -> o.ocname
  | CompiledFn _ -> "an arrow block"
  | ArrowBlock _ -> "an arrow block"
  | BuiltinFn _ -> "a builtin"
  | ClassDef _ -> "a class"
  | Instance _ -> "an instance"
  | EnumType _ -> "an enum"
  | EnumMember _ -> "an enum member"
  | TypeValue _ -> "a type"
  | Module _ -> "a module"
  | EmoGroup _ -> "a function group"

let rec equal_value a b =
  match (a, b) with
  | Int x, Int y -> Int.equal x y
  | Float x, Float y -> Float.equal x y
  | Bool x, Bool y -> Bool.equal x y
  | Char x, Char y -> Char.equal x y
  | String x, String y -> String.equal x y
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
  | Module x, Module y -> x == y (* a module is a namespace identity *)
  | TypeValue x, TypeValue y -> String.equal x y
  | Instance x, Instance y ->
      String.equal x.iclass.cname y.iclass.cname
      && List.length x.ifields = List.length y.ifields
      && List.for_all2
           (fun (nx, vx) (ny, vy) -> String.equal nx ny && equal_value vx vy)
           x.ifields y.ifields
  | ArrowBlock x, ArrowBlock y -> x == y (* closures are identities *)
  | BuiltinFn x, BuiltinFn y -> String.equal x y
  | _ -> false

let global_env () =
  let env = { frame = Hashtbl.create 16; parent = None } in
  Hashtbl.replace env.frame "print"
    { bound = BuiltinFn "print"; mutable_ = false };
  Hashtbl.replace env.frame "self_pid"
    { bound = BuiltinFn "self_pid"; mutable_ = false };
  Hashtbl.replace env.frame "halt"
    { bound = BuiltinFn "halt"; mutable_ = false };
  Hashtbl.replace env.frame "net_connect"
    { bound = BuiltinFn "net_connect"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen"
    { bound = BuiltinFn "net_listen"; mutable_ = false };
  Hashtbl.replace env.frame "net_resolve"
    { bound = BuiltinFn "net_resolve"; mutable_ = false };
  Hashtbl.replace env.frame "net_udp_bind"
    { bound = BuiltinFn "net_udp_bind"; mutable_ = false };
  Hashtbl.replace env.frame "net_connect_unix"
    { bound = BuiltinFn "net_connect_unix"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen_unix"
    { bound = BuiltinFn "net_listen_unix"; mutable_ = false };
  Hashtbl.replace env.frame "net_tls_connect"
    { bound = BuiltinFn "net_tls_connect"; mutable_ = false };
  Hashtbl.replace env.frame "net_tls_connect_insecure"
    { bound = BuiltinFn "net_tls_connect_insecure"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen_tls"
    { bound = BuiltinFn "net_listen_tls"; mutable_ = false };
  Hashtbl.replace env.frame "Box" { bound = TypeValue "Box"; mutable_ = false };
  (* The shipped exception class: `raise Exception.new(message: "boom")`. *)
  Hashtbl.replace env.frame "Exception"
    {
      bound =
        ClassDef
          {
            cname = "Exception";
            cinit = None;
            cmethods = [];
            builtin_exception = true;
          };
      mutable_ = false;
    };
  env

(* The restricted profile: hermetic evaluation with a step budget — the same
   machinery serves manifest evaluation and user-facing config files. The
   budget error names the limit, per the README's configuration story. *)
exception Budget_exceeded of int (* the budget that was hit *)

let step_budget : int option ref = ref None
let step_count : int ref = ref 0

let count_step () =
  match !step_budget with
  | Some budget when !step_count >= budget -> raise (Budget_exceeded budget)
  | _ -> step_count := !step_count + 1

(* The module system hooks: the project layer installs discovery (a
   normalized module path → handle, with its child module names) and loading
   (a normalized module path → the namespace from running its items). *)
let module_handle_of : (string list -> module_handle option) ref =
  ref (fun _ -> None)

let module_loader : (string list -> env) ref =
  ref (fun path ->
      failwith
        (Printf.sprintf "no module loader for `%s`" (String.concat "." path)))

(* Ensures a module's items have run exactly once. *)
let ensure_module_loaded h =
  match h.menv with
  | Some _ -> ()
  | None ->
      if h.loading then
        raise
          (Error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5003";
                 message =
                   Printf.sprintf "module cycle while loading `%s`"
                     (String.concat "." h.mpath);
                 span =
                   Emo_support.Span.make ~file:"<modules>" ~line:1 ~col:1
                     ~start:0 ~stop:0;
                 hint = None;
               });
      h.loading <- true;
      let env = !module_loader h.mpath in
      h.loading <- false;
      h.menv <- Some env

(* Program output goes to stdout; tests redirect it through [set_output]. *)
let output : (string -> unit) ref =
  ref (fun s ->
      print_string s;
      flush stdout)

let set_output f = output := f

(* The one stringification rule: interpolation and `.to_string()` share it. *)
let rec to_string v =
  match v with
  | Int n -> string_of_int n
  | Float f ->
      if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.1f" f
      else Printf.sprintf "%g" f
  | Bool b -> string_of_bool b
  | Char c -> String.make 1 c
  | String s -> s
  | Tuple vs -> "(" ^ String.concat ", " (List.map to_string vs) ^ ")"
  | Array vs ->
      "[" ^ String.concat ", " (List.map to_string (Array.to_list vs)) ^ "]"
  | Box _ -> "<box>"
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
  | ArrowBlock _ -> "<arrow block>"
  | BuiltinFn name -> Printf.sprintf "<builtin %s>" name
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
  | Module m -> "<module " ^ String.concat "." m.mpath ^ ">"
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

(* Function groups are project-global at runtime: a group defined in
   one module is callable from another module's processes. *)
let group_registry : (string, (string * value) list) Hashtbl.t ref =
  ref (Hashtbl.create 8)

(* `x.is(T)` — the runtime half of narrowing: exact class for classes, the
   declaring enum for members, and a structural method-shape check for
   interfaces. *)
let runtime_is span v t =
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
              | Some closure -> List.length closure.params = arity
              | None -> false)
            sigs
      | None -> String.equal i.iclass.cname tname)
  | EnumMember _, TypeValue _ -> false
  | _ ->
      error span "E3007"
        (Printf.sprintf "`is` checks instances and enum members, not %s"
           (type_name v))

let child parent = { frame = Hashtbl.create 8; parent = Some parent }

(* Defines a name in exactly this frame; a later definition of the same name
   replaces the earlier one within the frame. *)
let define env name ~mutable_ value =
  Hashtbl.replace env.frame name { bound = value; mutable_ }

let rec lookup env span name =
  match Hashtbl.find_opt env.frame name with
  | Some { bound; _ } -> bound
  | None -> (
      match env.parent with
      | Some parent -> lookup parent span name
      | None -> error span "E3002" (Printf.sprintf "`%s` is not defined" name))

let rec lookup_opt env name =
  match Hashtbl.find_opt env.frame name with
  | Some { bound; _ } -> Some bound
  | None -> (
      match env.parent with
      | Some parent -> lookup_opt parent name
      | None -> None)

let rec assign env span name value =
  match Hashtbl.find_opt env.frame name with
  | Some { mutable_ = true; _ } ->
      Hashtbl.replace env.frame name { bound = value; mutable_ = true }
  | Some { mutable_ = false; _ } ->
      error span "E3003"
        (Printf.sprintf "cannot assign to `%s`; it is a const" name)
        ~hint:"use `var` for bindings that change"
  | None -> (
      match env.parent with
      | Some parent -> assign parent span name value
      | None ->
          error span "E3003"
            (Printf.sprintf "cannot assign to `%s`; it is not defined" name))

(* Explicit returns unwind through an exception to the nearest function
   frame; a return whose expression is a call raises [Tail_call] instead,
   so the frame can rebind and iterate — tail calls never grow the OCaml
   stack. *)
exception Return_signal of value

exception
  Tail_call of closure * (string option * value) list * (string * value) list
(* callee, arguments, pre-bound extras (a method's `self`) *)

(* `raise <value>` unwinds as an exception; the driver turns an uncaught one
   into an E3010 diagnostic. *)
exception
  Emo_raise of value * Emo_support.Span.t * (string * Emo_support.Span.t) list
(* the raised value, the raise site, and the Emo call chain, innermost first *)

(* The Emo-level call chain, maintained as closures enter and leave frames. *)
let call_trace : (string * Emo_support.Span.t) list ref = ref []

(* Formats an uncaught raise: the value's to_string plus the call chain. *)
let uncaught_diagnostic (v, span, trace) =
  let hint =
    match trace with
    | [] -> None
    | _ ->
        Some
          (String.concat ", "
             (List.map
                (fun (name, s) ->
                  Printf.sprintf "called from `%s` (%s)" name
                    (Emo_support.Span.to_string s))
                trace))
  in
  Emo_support.Diagnostic.
    {
      severity = Error;
      code = Some "E3010";
      message = Printf.sprintf "uncaught exception: %s" (to_string v);
      span;
      hint;
    }

let literal_value = function
  | Ast.L_int n -> Int n
  | Ast.L_float f -> Float f
  | Ast.L_char c -> Char c
  | Ast.L_string s -> String s
  | Ast.L_bool b -> Bool b

(* Binds pattern variables into [frame] and reports whether the pattern
   matches. Bindings from a branch that ends up not matching do not leak:
   each branch attempts its match in a fresh child frame. *)
let rec match_pattern frame span pattern value =
  match pattern.Ast.pattern_desc with
  | Ast.Wildcard -> true
  | Ast.Pattern_binding name ->
      define frame name ~mutable_:false value;
      true
  | Ast.Pattern_literal l -> equal_value value (literal_value l)
  | Ast.Enum_member (t, m) -> (
      match value with
      | EnumMember (t', m') -> String.equal t t' && String.equal m m'
      | _ -> false)
  | Ast.Tuple_pattern ps -> (
      match value with
      | Tuple vs when List.length vs = List.length ps ->
          List.for_all2 (fun p v -> match_pattern frame span p v) ps vs
      | _ -> false)

(* ---- Concurrency core ----
   Processes own mailboxes; the evaluator performs the process operations
   as OCaml 5 effects, and a scheduler driver handles them at the process
   boundary (Emo_sched_eio today, the own effects runtime beside it).
   Contexts that never planned to spawn run under [run_without_scheduler],
   which turns the operations into diagnostics instead. *)

type exit_info =
  | Exit_normal
  | Exit_raised of value * Emo_support.Span.t
    (* the raised value and the raise site *)
  | Exit_failed of Emo_support.Diagnostic.t
(* a runtime diagnostic killed the process *)

type process = {
  pid : int;
  mutable inbox : value list; (* oldest message first *)
  mutable status : [ `Running | `Done of exit_info ];
  mutable exit_hooks : (exit_info -> unit) list;
      (* the process-exit signal a supervisor subscribes to *)
}

exception Halt_signal
(* `halt()` unwinds the current process; its driver turns it into a normal
   exit. It never crosses a process boundary. *)

(* The branch a `receive` picked: the branch index and the frame carrying
   the pattern's bindings, opaque to drivers. *)
type selected = Selected of int * env

(* The operations the evaluator performs; scheduler drivers handle them.
   (OCaml 5.5 spells effect declarations as Effect.t extensions.) *)
type _ Effect.t +=
  | Spawn : ((unit -> unit) * Emo_support.Span.t) -> int Effect.t
  | Send : (int * value * Emo_support.Span.t) -> unit Effect.t
  | Self_pid : int Effect.t
  | Receive : (value -> selected option) -> selected Effect.t

(* ---- Networking core ----
   Socket operations follow the process operations: the evaluator performs
   effects and the scheduler driver handles them at the process boundary —
   every blocking call is a suspension point. Contexts outside a scheduled
   run refuse them with E3009, like the process operations.

   Failures are ordinary Emo exceptions: an `Exception` instance whose
   message states exactly what failed — connection refused, name
   unresolvable, deadline exceeded, socket closed. No error codes, no nil
   returns (the README error model). *)

type _ Effect.t +=
  | Net_resolve : string * Emo_support.Span.t -> string list Effect.t
  | Net_connect :
      (string * int * float * string list * Emo_support.Span.t)
      -> conn Effect.t
  | Net_listen : string * int * Emo_support.Span.t -> listener Effect.t
  | Net_accept : listener * Emo_support.Span.t -> conn Effect.t
  | Net_read_line : conn * Emo_support.Span.t -> string Effect.t
  | Net_read_exactly : conn * int * Emo_support.Span.t -> string Effect.t
  | Net_read_all : conn * Emo_support.Span.t -> string Effect.t
  | Net_write : conn * string * Emo_support.Span.t -> unit Effect.t
  | Net_close_conn : conn * Emo_support.Span.t -> conn Effect.t
  | Net_close_listener : listener * Emo_support.Span.t -> listener Effect.t
  | Net_udp_bind : string * int * Emo_support.Span.t -> udp Effect.t
  | Net_udp_send_to :
      (udp * string * int * string * Emo_support.Span.t)
      -> unit Effect.t
  | Net_udp_recv_from : udp * Emo_support.Span.t -> value Effect.t
  | Net_udp_close : udp * Emo_support.Span.t -> udp Effect.t
  | Net_connect_unix : string * float * Emo_support.Span.t -> conn Effect.t
  | Net_listen_unix : string * Emo_support.Span.t -> listener Effect.t
  | Net_tls_connect :
      (string * int * float * bool * string list * Emo_support.Span.t)
      -> conn Effect.t
  | (* host, port, timeout, insecure, resolved addresses *)
      Net_tls_listen :
      (string * int * string * string * Emo_support.Span.t)
      -> listener Effect.t
  | Compiled_receive :
      (value -> (int * value list) option)
      -> (int * value list) Effect.t
(* the backend's selective receive: the matcher tries each compiled
     branch (pattern + guard) and returns the branch index with the
     pattern's bindings *)

(* Dequeues the first message the compiled matcher accepts, mirroring
   [take_matching] for the backend's receive. *)
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

let find_process span pid =
  match Hashtbl.find_opt processes pid with
  | Some p -> p
  | None -> error span "E3011" (Printf.sprintf "no process has pid %d" pid)

(* Snapshots a message at the process boundary: every Box in the message
   (directly or inside a tuple, array, or instance) arrives as a fresh
   copy, so mutability never crosses a process boundary — mutations on
   either side stay unobservable to the other. Everything else is
   immutable data or identity and passes as-is. *)
let rec snapshot (v : value) : value =
  match v with
  | Box r -> Box (ref (snapshot !r))
  | Tuple vs -> Tuple (List.map snapshot vs)
  | Array xs -> Array (Array.map snapshot xs)
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

(* Scans the mailbox in order and dequeues the first message [select]
   accepts; a non-matching message stays queued. None leaves the mailbox
   untouched. *)
let take_matching proc select =
  let rec go before = function
    | [] -> None
    | msg :: rest -> (
        match select msg with
        | Some picked ->
            proc.inbox <- List.rev_append before rest;
            Some picked
        | None -> go (msg :: before) rest)
  in
  go [] proc.inbox

(* Subscribes to a process's exit. A hook on an exited process fires
   immediately with the recorded exit. *)
let on_exit pid hook =
  match Hashtbl.find_opt processes pid with
  | None -> ()
  | Some p -> (
      match p.status with
      | `Done info -> hook info
      | `Running -> p.exit_hooks <- hook :: p.exit_hooks)

let mark_exit p info =
  p.status <- `Done info;
  List.iter (fun hook -> hook info) p.exit_hooks;
  p.exit_hooks <- []

(* Runs a body under the guard handler: every process operation reports
   E3009 — only a scheduled run can spawn, send, or receive. *)
let run_without_scheduler (body : unit -> unit) : unit =
  let nowhere =
    Emo_support.Span.make ~file:"<runtime>" ~line:1 ~col:1 ~start:0 ~stop:0
  in
  let refused span what =
    error span "E3009"
      (Printf.sprintf
         "%s runs only under a scheduler — run the program with `emo run`" what)
  in
  try
    Effect.Deep.try_with body ()
      {
        effc =
          (fun (type a) (eff : a Effect.t) ->
            match eff with
            | Spawn (_, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`do`")
            | Send (_, _, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`<-`")
            | Self_pid ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused nowhere "`self_pid()`")
            | Receive _ ->
                Some
                  (fun (_ : (a, _) continuation) -> refused nowhere "`receive`")
            | Net_resolve (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_resolve`")
            | Net_connect (_, _, _, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_connect`")
            | Net_listen (_, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`net_listen`")
            | Net_accept (_, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`accept`")
            | Net_read_line (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`read_line`")
            | Net_read_exactly (_, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`read_exactly`")
            | Net_read_all (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`read_all`")
            | Net_write (_, _, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`write`")
            | Net_close_conn (_, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`close`")
            | Net_close_listener (_, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`close`")
            | Net_udp_bind (_, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_udp_bind`")
            | Net_udp_send_to (_, _, _, _, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`send_to`")
            | Net_udp_recv_from (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`recv_from`")
            | Net_udp_close (_, span) ->
                Some (fun (_ : (a, _) continuation) -> refused span "`close`")
            | Net_connect_unix (_, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_connect_unix`")
            | Net_listen_unix (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_listen_unix`")
            | Compiled_receive _ ->
                Some
                  (fun (_ : (a, _) continuation) -> refused nowhere "`receive`")
            | Net_tls_connect (_, _, _, _, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_tls_connect`")
            | Net_tls_listen (_, _, _, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_listen_tls`")
            | _ -> None);
      }
  with Halt_signal -> ()

let not_yet span what =
  error span "E3009" (Printf.sprintf "%s is not supported yet" what)

(* Builds the Emo exception a network failure unwinds with. Drivers
   discontinue the parked continuation with it. *)
let net_raise span message =
  Emo_raise
    ( Instance
        {
          iclass =
            {
              cname = "Exception";
              cinit = None;
              cmethods = [];
              builtin_exception = true;
            };
          ifields = [ ("message", String message) ];
        },
      span,
      !call_trace )

let rec eval_unary env span op x =
  let v = eval_expr env x in
  match (op, v) with
  | Ast.Not, Bool b -> Bool (not b)
  | Ast.Not, v ->
      error span "E3001"
        (Printf.sprintf "operator `!` expects a Bool, got %s" (type_name v))
  | Ast.Neg, Int n -> Int (-n)
  | Ast.Neg, Float f -> Float (-.f)
  | Ast.Neg, v ->
      error span "E3001"
        (Printf.sprintf "operator `-` expects a number, got %s" (type_name v))

and eval_binary env span op left_expr right_expr =
  let op_name = function
    | Ast.Eq -> "=="
    | Ast.Ne -> "!="
    | Ast.Lt -> "<"
    | Ast.Le -> "<="
    | Ast.Gt -> ">"
    | Ast.Ge -> ">="
    | Ast.Add -> "+"
    | Ast.Sub -> "-"
    | Ast.Mul -> "*"
    | Ast.Div -> "/"
    | Ast.Mod -> "%"
    | Ast.And -> "&&"
    | Ast.Or -> "||"
  in
  let left = eval_expr env left_expr in
  let right = eval_expr env right_expr in
  let type_mismatch expects =
    error span "E3001"
      (Printf.sprintf "operator `%s` expects %s, got %s and %s" (op_name op)
         expects (type_name left) (type_name right))
  in
  let as_float = function
    | Int x -> float_of_int x
    | Float f -> f
    | v -> type_mismatch "two numbers"
  in
  let check_bool v =
    match v with Bool b -> b | v -> type_mismatch "two Bools"
  in
  match op with
  | Ast.And -> Bool (if check_bool left then check_bool right else false)
  | Ast.Or -> Bool (if check_bool left then true else check_bool right)
  | Ast.Eq -> Bool (equal_value left right)
  | Ast.Ne -> Bool (not (equal_value left right))
  | Ast.Lt -> Bool (as_float left < as_float right)
  | Ast.Le -> Bool (as_float left <= as_float right)
  | Ast.Gt -> Bool (as_float left > as_float right)
  | Ast.Ge -> Bool (as_float left >= as_float right)
  | Ast.Add -> (
      match (left, right) with
      | Int x, Int y -> Int (x + y)
      | Float x, Float y -> Float (x +. y)
      | Int x, Float y -> Float (float_of_int x +. y)
      | Float x, Int y -> Float (x +. float_of_int y)
      | String x, String y -> String (x ^ y)
      | _ -> type_mismatch "two numbers or two strings")
  | Ast.Sub -> (
      match (left, right) with
      | Int x, Int y -> Int (x - y)
      | Float x, Float y -> Float (x -. y)
      | Int x, Float y -> Float (float_of_int x -. y)
      | Float x, Int y -> Float (x -. float_of_int y)
      | _ -> type_mismatch "two numbers")
  | Ast.Mul -> (
      match (left, right) with
      | Int x, Int y -> Int (x * y)
      | Float x, Float y -> Float (x *. y)
      | Int x, Float y -> Float (float_of_int x *. y)
      | Float x, Int y -> Float (x *. float_of_int y)
      | _ -> type_mismatch "two numbers")
  | Ast.Div | Ast.Mod -> (
      let zero_check d =
        match d with
        | Int 0 -> error span "E3005" "division by zero"
        | Float f when f = 0.0 -> error span "E3005" "division by zero"
        | _ -> ()
      in
      match (left, right) with
      | Int x, Int y ->
          zero_check right;
          if op = Ast.Div then Int (x / y) else Int (x mod y)
      | Float x, Float y ->
          zero_check right;
          if op = Ast.Div then Float (x /. y) else Float (Float.rem x y)
      | Int x, Float y ->
          zero_check right;
          if op = Ast.Div then Float (float_of_int x /. y)
          else Float (Float.rem (float_of_int x) y)
      | Float x, Int y ->
          zero_check right;
          if op = Ast.Div then Float (x /. float_of_int y)
          else Float (Float.rem x (float_of_int y))
      | _ -> type_mismatch "two numbers")

and eval_index env span base index =
  let b = eval_expr env base in
  let i = eval_expr env index in
  let at len =
    match i with
    | Int n when n >= 0 && n < len -> n
    | Int n ->
        error span "E3004"
          (Printf.sprintf "index %d is out of bounds for a length-%d %s" n len
             (match b with Array _ -> "Array" | _ -> "Tuple"))
    | v ->
        error span "E3001"
          (Printf.sprintf "the index must be an Int, got %s" (type_name v))
  in
  match (b, i) with
  | Array xs, _ -> xs.(at (Array.length xs))
  | Tuple xs, _ ->
      let xs = Array.of_list xs in
      xs.(at (Array.length xs))
  | v, _ ->
      error span "E3001"
        (Printf.sprintf "%s does not support indexing" (type_name v))

and eval_call env span callee arg_exprs =
  match callee.Ast.desc with
  | Ast.Member (recv, mname) -> eval_method env span recv mname arg_exprs
  | _ ->
      let f = eval_expr env callee in
      let args =
        List.map
          (fun { Ast.arg_name; arg_value } ->
            (arg_name, eval_expr env arg_value))
          arg_exprs
      in
      apply f span args

(* Methods are only callable directly: `x.to_string()`, `box.read()`,
   `Box.new(v)`. A bare `x.to_string` is not a value. *)
and module_member span h name =
  match List.assoc_opt name h.mchildren with
  | Some child_path -> (
      match !module_handle_of child_path with
      | Some child -> Module child
      | None ->
          error span "E5002"
            (Printf.sprintf "module `%s` has no member `%s`"
               (String.concat "." h.mpath)
               name))
  | None -> (
      ensure_module_loaded h;
      let menv = match h.menv with Some e -> e | None -> assert false in
      match lookup_opt menv name with
      | Some v -> v
      | None ->
          error span "E5004"
            (Printf.sprintf "module `%s` has no member `%s`"
               (String.concat "." h.mpath)
               name))

and eval_method env span recv mname arg_exprs =
  let argc = List.length arg_exprs in
  let eval_args () =
    List.map
      (fun { Ast.arg_name; arg_value } ->
        match arg_name with
        | Some n ->
            error span "E3007"
              (Printf.sprintf "methods take positional arguments only (`%s`)" n)
        | None -> eval_expr env arg_value)
      arg_exprs
  in
  (* Constructors and methods keep the argument names so they can bind by
     parameter name. *)
  let eval_args_named () =
    List.map
      (fun { Ast.arg_name; arg_value } -> (arg_name, eval_expr env arg_value))
      arg_exprs
  in
  let none_expected what =
    if argc = 0 then ()
    else
      error span "E3007"
        (Printf.sprintf "`%s` expects no arguments, got %d" what argc)
  in
  match recv.Ast.desc with
  | Ast.Type_ident gname when Hashtbl.mem !group_registry gname ->
      let members = Hashtbl.find !group_registry gname in
      if not (List.mem_assoc mname members) then
        error span "E4001"
          (Printf.sprintf "the group `%s` has no member `%s`" gname mname);
      let v = List.assoc mname members in
      let arity =
        match v with ArrowBlock c -> List.length c.params | _ -> 0
      in
      if List.length arg_exprs <> arity then
        error span "E3007"
          (Printf.sprintf "`%s.%s` expects %d argument(s), got %d" gname mname
             arity (List.length arg_exprs));
      let args = eval_args_named () in
      apply v span args
  | _ -> (
      let base = eval_expr env recv in
      match (base, mname) with
      | EmoGroup members, _ -> (
          (* a group member: defs apply, consts produce their value. A bare
         def reference (`Foo.hello` without a call) is the block itself. *)
          if not (List.mem_assoc mname members) then
            error span "E4001"
              (Printf.sprintf "this group has no member `%s`" mname);
          let v = List.assoc mname members in
          match v with
          | ArrowBlock closure ->
              let args = eval_args_named () in
              let frame = bind_params closure span args in
              eval_frame closure frame span
          | const_value ->
              if argc > 0 then
                error span "E3007"
                  (Printf.sprintf "`%s` is a constant and takes no arguments"
                     mname);
              const_value)
      | Module h, _ ->
          let v = module_member span h mname in
          let args = eval_args_named () in
          apply v span args
      | Instance i, mname when List.mem_assoc mname i.iclass.cmethods ->
          let closure = List.assoc mname i.iclass.cmethods in
          let args = eval_args_named () in
          let frame = bind_params closure span args in
          define frame "self" ~mutable_:false (Instance i);
          eval_frame closure frame span
      | ClassDef c, "new" -> (
          let args = eval_args_named () in
          match c.cinit with
          | Some init ->
              let instance = Instance { iclass = c; ifields = [] } in
              let frame = bind_params init span args in
              define frame "self" ~mutable_:false instance;
              (* init constructs; it does not return a value. An early `return`
             simply ends the window, and no implicit value exists. *)
              (try List.iter (eval_stmt frame) init.body with
              | Return_signal _ -> ()
              | Tail_call _ -> ());
              instance
          | None when c.builtin_exception -> (
              match args with
              | [ (Some "message", v) ] | [ (None, v) ] ->
                  Instance { iclass = c; ifields = [ ("message", v) ] }
              | _ -> error span "E3007" "`Exception.new` expects `message`")
          | None ->
              if List.length args > 0 then
                error span "E3007"
                  (Printf.sprintf
                     "class `%s` declares no `init`; `new` takes no arguments"
                     c.cname);
              Instance { iclass = c; ifields = [] })
      | ClassDef c, m ->
          error span "E3007"
            (Printf.sprintf "class `%s` has no member `%s`" c.cname m)
      | TypeValue "Box", "new" -> (
          let args = eval_args () in
          match args with
          | [ v ] -> Box (ref v)
          | _ ->
              error span "E3007"
                (Printf.sprintf "`Box.new` expects 1 argument, got %d" argc))
      | TypeValue t, m ->
          error span "E3009"
            (Printf.sprintf "type `%s` has no member `%s` yet" t m)
      | v, "to_string" ->
          none_expected "to_string";
          String (to_string v)
      | Array xs, "length" ->
          none_expected "length";
          Int (Array.length xs)
      | Tuple xs, "length" ->
          none_expected "length";
          Int (List.length xs)
      | Box r, "read" ->
          none_expected "read";
          !r
      | Box r, "replace" -> (
          let args = eval_args () in
          match args with
          | [ v ] ->
              r := v;
              v
          | _ ->
              error span "E3007"
                (Printf.sprintf "`replace` expects 1 argument, got %d" argc))
      | TcpConn c, "read_line" ->
          none_expected "read_line";
          String (Effect.perform (Net_read_line (c, span)))
      | TcpConn c, "read_exactly" -> (
          match eval_args () with
          | [ Int n ] -> String (Effect.perform (Net_read_exactly (c, n, span)))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`read_exactly` expects an Int, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`read_exactly` expects 1 argument, got %d" argc)
          )
      | TcpConn c, "read_all" ->
          none_expected "read_all";
          String (Effect.perform (Net_read_all (c, span)))
      | TcpConn c, "write" -> (
          match eval_args () with
          | [ String s ] ->
              Effect.perform (Net_write (c, s, span));
              TcpConn c
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`write` expects a String, got %s" (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`write` expects 1 argument, got %d" argc))
      | TcpConn c, "close" ->
          none_expected "close";
          TcpConn (Effect.perform (Net_close_conn (c, span)))
      | TcpConn c, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              c.ctimeout <- f;
              TcpConn c
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | TcpListener l, "accept" ->
          none_expected "accept";
          TcpConn (Effect.perform (Net_accept (l, span)))
      | TcpListener { lunix = true; ldesc; _ }, "port" ->
          error span "E3007"
            (Printf.sprintf "a unix-domain listener (%s) has no port" ldesc)
      | TcpListener l, "port" ->
          none_expected "port";
          Int l.lport
      | TcpListener l, "close" ->
          none_expected "close";
          TcpListener (Effect.perform (Net_close_listener (l, span)))
      | TcpListener l, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              l.ltimeout <- f;
              TcpListener l
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | UdpSocket u, "send_to" -> (
          match eval_args () with
          | [ String host; Int port; String data ] -> (
              let addrs = Effect.perform (Net_resolve (host, span)) in
              match addrs with
              | addr :: _ ->
                  Effect.perform (Net_udp_send_to (u, addr, port, data, span));
                  UdpSocket u
              | [] ->
                  raise
                    (net_raise span
                       (Printf.sprintf "cannot resolve host `%s`" host)))
          | _ ->
              error span "E3007"
                "`send_to` expects (host String, port Int, data String)")
      | UdpSocket u, "recv_from" ->
          none_expected "recv_from";
          let received = Effect.perform (Net_udp_recv_from (u, span)) in
          received
      | UdpSocket u, "port" ->
          none_expected "port";
          Int u.uport
      | UdpSocket u, "close" ->
          none_expected "close";
          UdpSocket (Effect.perform (Net_udp_close (u, span)))
      | UdpSocket u, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              u.utimeout <- f;
              UdpSocket u
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | String s, "length" ->
          none_expected "length";
          Int (String.length s)
      | String s, "substring" -> (
          match eval_args () with
          | [ Int start; Int len ]
            when start >= 0 && len >= 0 && start + len <= String.length s ->
              String (String.sub s start len)
          | [ Int start; Int len ] ->
              error span "E3004"
                (Printf.sprintf
                   "substring (%d, %d) is out of bounds for a length-%d String"
                   start len (String.length s))
          | _ ->
              error span "E3007" "`substring` expects (start Int, length Int)")
      | String s, "split" -> (
          match eval_args () with
          | [ String sep ] when sep <> "" ->
              Array
                (Array.of_list
                   (List.map (fun part -> String part) (split_on_string sep s)))
          | [ String _ ] -> error span "E3007" "the separator must not be empty"
          | _ -> error span "E3007" "`split` expects a String separator")
      | String s, "trim" ->
          none_expected "trim";
          String (String.trim s)
      | String s, "lower" ->
          none_expected "lower";
          String (String.lowercase_ascii s)
      | String s, "index_of" -> (
          match eval_args () with
          | [ String needle ] ->
              let rec find i =
                if i + String.length needle > String.length s then None
                else if String.sub s i (String.length needle) = needle then
                  Some i
                else find (i + 1)
              in
              Int (match find 0 with Some i -> i | None -> -1)
          | _ -> error span "E3007" "`index_of` expects a String needle")
      | String s, "starts_with" -> (
          match eval_args () with
          | [ String prefix ] -> Bool (String.starts_with ~prefix s)
          | _ -> error span "E3007" "`starts_with` expects a String prefix")
      | String s, "to_int" -> (
          match parse_decimal s with
          | Some n -> Int n
          | None ->
              error span "E3007"
                (Printf.sprintf "cannot parse `%s` as an Int" s))
      | Array xs, "append" -> (
          match eval_args () with
          | [ v ] -> Array (Array.append xs [| v |])
          | _ ->
              error span "E3007"
                (Printf.sprintf "`append` expects 1 argument, got %d" argc))
      | Instance i, "is" -> (
          let args = eval_args () in
          match args with
          | [ t ] -> Bool (runtime_is span (Instance i) t)
          | _ ->
              error span "E3007"
                (Printf.sprintf "`is` expects 1 argument, got %d" argc))
      | (EnumMember _ as v), "is" -> (
          let args = eval_args () in
          match args with
          | [ t ] -> Bool (runtime_is span v t)
          | _ ->
              error span "E3007"
                (Printf.sprintf "`is` expects 1 argument, got %d" argc))
      | Instance i, mname ->
          error span "E3007"
            (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
               i.iclass.cname mname)
      | Obj o, "is" -> (
          let args = eval_args () in
          match args with
          | [ t ] -> Bool (runtime_is span (Obj o) t)
          | _ ->
              error span "E3007"
                (Printf.sprintf "`is` expects 1 argument, got %d" argc))
      | Obj o, mname -> (
          match Hashtbl.find_opt o.omethods mname with
          | Some (_arity, f) ->
              let args = eval_args () in
              f args
          | None ->
              error span "E3007"
                (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
                   o.ocname mname))
      | v, m ->
          error span "E3007"
            (Printf.sprintf "%s has no method `%s`" (type_name v) m))

and apply f span args =
  match f with
  | ArrowBlock closure -> apply_closure closure span args
  | BuiltinFn name ->
      List.iter
        (fun (name_, _) ->
          match name_ with
          | Some n ->
              error span "E3007"
                (Printf.sprintf "builtin `%s` takes positional arguments only"
                   name)
          | None -> ())
        args;
      apply_builtin span name (List.map snd args)
  | v ->
      error span "E3007"
        (Printf.sprintf "%s is not callable"
           (String.capitalize_ascii (type_name v)))

(* Binds the arguments to the parameters: positionals fill the first free
   slot left to right, named arguments address their parameter directly. *)
and bind_params closure span args =
  let params = Array.of_list closure.params in
  let positional = Queue.create () in
  let named = Hashtbl.create 4 in
  List.iter
    (fun (name, value) ->
      match name with
      | None -> Queue.push value positional
      | Some name ->
          if Hashtbl.mem named name then
            error span "E3007"
              (Printf.sprintf "the argument `%s` is passed twice" name);
          Hashtbl.replace named name value)
    args;
  let positional_count = Queue.length positional in
  let named_count = Hashtbl.length named in
  if positional_count + named_count <> Array.length params then
    error span "E3007"
      (Printf.sprintf "`%s` expects %d argument%s, got %d" closure.def_name
         (Array.length params)
         (if Array.length params = 1 then "" else "s")
         (positional_count + named_count));
  let frame = child closure.env in
  Array.iter
    (fun { Ast.param_name; _ } ->
      let value =
        match Hashtbl.find_opt named param_name with
        | Some v ->
            Hashtbl.remove named param_name;
            v
        | None ->
            if Queue.is_empty positional then
              error span "E3007"
                (Printf.sprintf "`%s` is missing an argument for `%s`"
                   closure.def_name param_name)
            else Queue.pop positional
      in
      define frame param_name ~mutable_:false value)
    params;
  let leftover =
    Hashtbl.fold (fun k _ acc -> if acc = None then Some k else acc) named None
  in
  match leftover with
  | Some name ->
      error span "E3007"
        (Printf.sprintf "`%s` has no parameter named `%s`" closure.def_name name)
  | None -> frame

and apply_closure closure span args = eval_body closure span args

and apply_builtin span name args =
  match (name, args) with
  | "print", [ v ] ->
      !output (to_string v ^ "\n");
      v
  | "print", vs ->
      error span "E3007"
        (Printf.sprintf "`print` expects 1 argument, got %d" (List.length vs))
  | "self_pid", [] -> Pid (Effect.perform Self_pid)
  | "self_pid", vs ->
      error span "E3007"
        (Printf.sprintf "`self_pid` expects no arguments, got %d"
           (List.length vs))
  | "halt", [] ->
      (* Unwinds the calling process; the scheduler driver records the exit. *)
      raise Halt_signal
  | "halt", vs ->
      error span "E3007"
        (Printf.sprintf "`halt` expects no arguments, got %d" (List.length vs))
  | "net_connect", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_connect` expects (host String, port Int, timeout Float), got \
            %d arguments"
           (List.length args))
  | "net_connect", [ String host; Int port; Float timeout ] ->
      let addrs = Effect.perform (Net_resolve (host, span)) in
      TcpConn (Effect.perform (Net_connect (host, port, timeout, addrs, span)))
  | "net_resolve", [ String host ] ->
      Array
        (Array.of_list
           (List.map
              (fun a -> String a)
              (Effect.perform (Net_resolve (host, span)))))
  | "net_resolve", vs ->
      error span "E3007"
        (Printf.sprintf "`net_resolve` expects 1 argument, got %d"
           (List.length vs))
  | "net_connect", _ ->
      error span "E3001"
        "`net_connect` expects (host String, port Int, timeout Float)"
  | "net_listen", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen` expects (host String, port Int), got %d arguments"
           (List.length args))
  | "net_listen", [ String host; Int port ] ->
      TcpListener (Effect.perform (Net_listen (host, port, span)))
  | "net_listen", _ ->
      error span "E3001" "`net_listen` expects (host String, port Int)"
  | "net_udp_bind", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_udp_bind` expects (host String, port Int), got %d arguments"
           (List.length args))
  | "net_udp_bind", [ String host; Int port ] ->
      UdpSocket (Effect.perform (Net_udp_bind (host, port, span)))
  | "net_udp_bind", _ ->
      error span "E3001" "`net_udp_bind` expects (host String, port Int)"
  | "net_connect_unix", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_connect_unix` expects (path String, timeout Float), got \
            %d             arguments"
           (List.length args))
  | "net_connect_unix", [ String path; Float timeout ] ->
      TcpConn (Effect.perform (Net_connect_unix (path, timeout, span)))
  | "net_connect_unix", _ ->
      error span "E3001"
        "`net_connect_unix` expects (path String, timeout Float)"
  | "net_listen_unix", args when List.length args <> 1 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen_unix` expects (path String), got %d arguments"
           (List.length args))
  | "net_listen_unix", [ String path ] ->
      TcpListener (Effect.perform (Net_listen_unix (path, span)))
  | "net_listen_unix", _ ->
      error span "E3001" "`net_listen_unix` expects (path String)"
  | "net_tls_connect", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_tls_connect` expects (host String, port Int, timeout \
            Float),             got %d arguments"
           (List.length args))
  | "net_tls_connect", [ String host; Int port; Float timeout ] ->
      let addrs = Effect.perform (Net_resolve (host, span)) in
      TcpConn
        (Effect.perform
           (Net_tls_connect (host, port, timeout, false, addrs, span)))
  | "net_tls_connect", _ ->
      error span "E3001"
        "`net_tls_connect` expects (host String, port Int, timeout Float)"
  | "net_tls_connect_insecure", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_tls_connect_insecure` expects (host String, port Int, \
            timeout             Float), got %d arguments"
           (List.length args))
  | "net_tls_connect_insecure", [ String host; Int port; Float timeout ] ->
      let addrs = Effect.perform (Net_resolve (host, span)) in
      TcpConn
        (Effect.perform
           (Net_tls_connect (host, port, timeout, true, addrs, span)))
  | "net_tls_connect_insecure", _ ->
      error span "E3001"
        "`net_tls_connect_insecure` expects (host String, port Int, \
         timeout          Float)"
  | "net_listen_tls", args when List.length args <> 4 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen_tls` expects (host String, port Int, cert_path \
            String,             key_path String), got %d arguments"
           (List.length args))
  | "net_listen_tls", [ String host; Int port; String cert; String key ] ->
      TcpListener
        (Effect.perform (Net_tls_listen (host, port, cert, key, span)))
  | "net_listen_tls", _ ->
      error span "E3001"
        "`net_listen_tls` expects (host String, port Int, cert_path \
         String,          key_path String)"
  | _ -> error span "E3007" (Printf.sprintf "unknown builtin `%s`" name)

(* The function frame. A [Tail_call] rebinds callee and arguments and
   iterates in place; the OCaml stack stays flat however long the Emo-level
   recursion runs. *)
and eval_body closure span args =
  eval_frame closure (bind_params closure span args) span

(* Runs a prepared frame. A [Tail_call] rebinds callee, arguments, and any
   extras (a method's `self`), and iterates in place — the OCaml stack stays
   flat however long the Emo-level recursion runs. *)
and eval_frame closure frame span =
  let rec loop closure frame =
    call_trace := (closure.def_name, span) :: !call_trace;
    Fun.protect
      (fun () ->
        try
          let rec run = function
            | [] ->
                error span "E3008"
                  (Printf.sprintf "reached the end of %s without `return`"
                     closure.def_name)
            | stmt :: rest ->
                let () = eval_stmt frame stmt in
                run rest
          in
          run closure.body
        with
        | Return_signal v -> v
        | Tail_call (c, args, extras) ->
            let frame = bind_params c span args in
            List.iter (fun (k, v) -> define frame k ~mutable_:false v) extras;
            loop c frame)
      ~finally:(fun () -> call_trace := List.tl !call_trace)
  in
  loop closure frame

and eval_stmt env s =
  count_step ();
  let span = s.Ast.stmt_span in
  match s.Ast.stmt_desc with
  | Ast.Expr_stmt e -> ignore (eval_expr env e)
  | Ast.Binding { mutable_; name; init } ->
      define env name ~mutable_ (eval_expr env init)
  | Ast.Assign { target; value } -> (
      let v = eval_expr env value in
      match target.Ast.desc with
      | Ast.Ident name -> assign env span name v
      | Ast.Member ({ Ast.desc = Ast.Self; _ }, name) -> (
          (* Only init bodies contain `self.x = ...` — the parser enforces
             the window; here `self` must be the instance under
             construction. *)
          match lookup env span "self" with
          | Instance i ->
              (* Replace in place, or append the field in first-assignment
                 order — the list freezes in that order after init. *)
              if List.mem_assoc name i.ifields then
                i.ifields <-
                  List.map
                    (fun (n, old) ->
                      if String.equal n name then (n, v) else (n, old))
                    i.ifields
              else i.ifields <- i.ifields @ [ (name, v) ]
          | v ->
              error span "E3003"
                (Printf.sprintf
                   "`self.x = ...` needs an instance under construction, got %s"
                   (type_name v)))
      | _ -> error span "E3003" "invalid assignment target")
  | Ast.Return None -> not_yet span "a valueless `return`"
  | Ast.Return (Some e) -> (
      match e.Ast.desc with
      | Ast.Call ({ Ast.desc = Ast.Member (recv, mname); _ }, arg_exprs) -> (
          (* A method call in return position tail-calls with `self`. *)
          let base = eval_expr env recv in
          match base with
          | Instance i when List.mem_assoc mname i.iclass.cmethods ->
              let closure = List.assoc mname i.iclass.cmethods in
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    (arg_name, eval_expr env arg_value))
                  arg_exprs
              in
              raise (Tail_call (closure, args, [ ("self", Instance i) ]))
          | _ -> raise (Return_signal (eval_expr env e)))
      | Ast.Call (callee, arg_exprs) -> (
          let f = eval_expr env callee in
          match f with
          | ArrowBlock closure ->
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    (arg_name, eval_expr env arg_value))
                  arg_exprs
              in
              raise (Tail_call (closure, args, []))
          | not_a_closure ->
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    match arg_name with
                    | Some n ->
                        error span "E3007"
                          (Printf.sprintf
                             "builtins take positional arguments only (`%s`)" n)
                    | None -> eval_expr env arg_value)
                  arg_exprs
              in
              raise
                (Return_signal
                   (apply not_a_closure span
                      (List.map (fun v -> (None, v)) args))))
      | _ -> raise (Return_signal (eval_expr env e)))
  | Ast.If { cond; then_body; else_body } -> (
      let c = eval_expr env cond in
      match c with
      | Bool true -> List.iter (eval_stmt env) then_body
      | Bool false -> (
          match else_body with
          | Some body -> List.iter (eval_stmt env) body
          | None -> ())
      | v ->
          error cond.Ast.span "E3001"
            (Printf.sprintf "the `if` condition must be a Bool, got %s"
               (type_name v)))
  | Ast.Case { scrutinee; branches } ->
      let v = eval_expr env scrutinee in
      let rec try_branches = function
        | [] ->
            error span "E3006"
              (Printf.sprintf "no `case` branch matched this %s value"
                 (type_name v))
        | branch :: rest ->
            let frame = child env in
            if not (match_pattern frame span branch.Ast.pattern v) then
              try_branches rest
            else
              let guard_holds =
                match branch.Ast.guard with
                | Some g -> (
                    match eval_expr frame g with
                    | Bool b -> b
                    | gv ->
                        error span "E3001"
                          (Printf.sprintf
                             "a `when` guard must be a Bool, got %s"
                             (type_name gv)))
                | None -> true
              in
              if guard_holds then List.iter (eval_stmt frame) branch.Ast.body
              else try_branches rest
      in
      try_branches branches
  | Ast.Receive branches ->
      (* Selective receive: the mailbox is scanned in order for the first
         message matching any branch — patterns are ordinary `case`
         patterns, and a message whose guard fails stays queued. Blocking
         while nothing matches is the scheduler driver's part. *)
      let select (msg : value) : selected option =
        let rec try_branch i = function
          | [] -> None
          | branch :: rest ->
              let frame = child env in
              if not (match_pattern frame span branch.Ast.pattern msg) then
                try_branch (i + 1) rest
              else
                let guard_holds =
                  match branch.Ast.guard with
                  | Some g -> (
                      match eval_expr frame g with
                      | Bool b -> b
                      | gv ->
                          error span "E3001"
                            (Printf.sprintf
                               "a `when` guard must be a Bool, got %s"
                               (type_name gv)))
                  | None -> true
                in
                if guard_holds then Some (Selected (i, frame))
                else try_branch (i + 1) rest
        in
        try_branch 0 branches
      in
      let (Selected (i, frame)) = Effect.perform (Receive select) in
      List.iter (eval_stmt frame) (List.nth branches i).Ast.body
  | Ast.Send { target; message } ->
      let pid =
        match eval_expr env target with
        | Pid pid -> pid
        | other ->
            error span "E3001"
              (Printf.sprintf "`<-` delivers to a pid, got %s" (type_name other))
      in
      let v = eval_expr env message in
      Effect.perform (Send (pid, v, span))
  | Ast.Raise e ->
      let v = eval_expr env e in
      raise (Emo_raise (v, span, !call_trace))

and eval_expr env e =
  count_step ();
  let span = e.Ast.span in
  match e.Ast.desc with
  | Ast.Int n -> Int n
  | Ast.Float f -> Float f
  | Ast.Bool b -> Bool b
  | Ast.Char c -> Char c
  | Ast.String s -> String s
  | Ast.Ident name -> (
      match lookup_opt env name with
      | Some v -> v
      | None -> (
          (* An unbound name may address a module: the directory tree is the
             module tree. *)
          match !module_handle_of [ name ] with
          | Some h -> Module h
          | None -> lookup env span name))
  | Ast.Type_ident t -> (
      (* A declared class, enum, or interface resolves to its value; an
         unknown upper name stays a bare type value. *)
      match lookup_opt env t with
      | Some v -> v
      | None -> TypeValue t)
  | Ast.Interpolated parts ->
      String
        (String.concat ""
           (List.map
              (function
                | Ast.Literal_text s -> s
                | Ast.Part_expr e -> to_string (eval_expr env e))
              parts))
  | Ast.Self -> lookup env span "self"
  | Ast.Member (inner, name) -> (
      let base = eval_expr env inner in
      match base with
      | Instance i -> (
          match List.assoc_opt name i.ifields with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "`%s` has no field `%s`" i.iclass.cname name))
      | Obj o -> (
          match List.assoc_opt name o.ofields with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "`%s` has no field `%s`" o.ocname name))
      | EnumType e -> (
          match List.assoc_opt name e.emembers with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "enum `%s` has no member `%s`" e.ename name))
      | Module h -> module_member span h name
      | EmoGroup members -> (
          match List.assoc_opt name members with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "this group has no member `%s`" name))
      | _ ->
          error span "E3007" "a member access must be a call, like `x.read()`")
  | Ast.Index (base, index) -> eval_index env span base index
  | Ast.Tuple es -> Tuple (List.map (eval_expr env) es)
  | Ast.Array_literal es -> Array (Array.of_list (List.map (eval_expr env) es))
  | Ast.Arrow_block (params, body) ->
      ArrowBlock { def_name = "<arrow block>"; params; body; env }
  | Ast.Unary (op, x) -> eval_unary env span op x
  | Ast.Binary (op, l, r) -> eval_binary env span op l r
  | Ast.Call (callee, args) -> eval_call env span callee args
  | Ast.Do operand -> (
      (* `do work(args)` runs the call in a new process: the caller gets the
         child's pid immediately, and the call's own result is discarded. *)
      match operand.Ast.desc with
      | Ast.Call (callee, arg_exprs) ->
          let f = eval_expr env callee in
          let args =
            List.map
              (fun { Ast.arg_name; arg_value } ->
                (arg_name, eval_expr env arg_value))
              arg_exprs
          in
          let pid =
            Effect.perform
              (Spawn ((fun () -> ignore (apply f span args)), span))
          in
          Pid pid
      | _ ->
          error span "E3007"
            "`do` starts a process from a call, like `do work()`")

(* Top-level items: defs register closures in the environment, statements
   run in order. Closures capture [env] by reference, so a def resolves
   names against the frame as it stands when the call happens — recursion
   and forward references among defs both work. *)
let method_closure class_name env d =
  {
    def_name = Printf.sprintf "%s.%s" class_name d.Ast.def_name;
    params = d.Ast.def_params;
    body = d.Ast.def_body;
    env;
  }

let eval_item env item =
  match item.Ast.item_desc with
  | Ast.Item_stmt s -> eval_stmt env s
  | Ast.Item_require _ ->
      (* Scope comes from the module table once the package layer registers
         the package; the statement itself needs no evaluation. *)
      ()
  | Ast.Item_def d ->
      define env d.Ast.def_name ~mutable_:false
        (ArrowBlock
           {
             def_name = d.Ast.def_name;
             params = d.Ast.def_params;
             body = d.Ast.def_body;
             env;
           })
  | Ast.Item_class c ->
      define env c.Ast.class_name ~mutable_:false
        (ClassDef
           {
             cname = c.Ast.class_name;
             cinit =
               Option.map
                 (fun d -> method_closure c.Ast.class_name env d)
                 c.Ast.class_init;
             cmethods =
               List.map
                 (fun d ->
                   (d.Ast.def_name, method_closure c.Ast.class_name env d))
                 c.Ast.class_methods;
             builtin_exception = false;
           })
  | Ast.Item_interface i ->
      let sigs =
        List.map
          (fun s -> (s.Ast.sig_name, List.length s.Ast.sig_params))
          i.Ast.interface_methods
      in
      Hashtbl.replace interface_registry i.Ast.interface_name sigs;
      define env i.Ast.interface_name ~mutable_:false
        (TypeValue i.Ast.interface_name)
  | Ast.Item_enum e ->
      let members =
        List.map
          (fun m ->
            (m.Ast.member_name, EnumMember (e.Ast.enum_name, m.Ast.member_name)))
          e.Ast.enum_members
      in
      define env e.Ast.enum_name ~mutable_:false
        (EnumType { ename = e.Ast.enum_name; emembers = members })
  | Ast.Item_emo_group g ->
      (* members are defined into the frame first so bodies read them
         bare, then collected into the group value *)
      List.iter
        (fun (d : Ast.fun_def) ->
          define env d.Ast.def_name ~mutable_:false
            (ArrowBlock
               {
                 def_name = g.Ast.group_name ^ "__" ^ d.Ast.def_name;
                 params = d.Ast.def_params;
                 body = d.Ast.def_body;
                 env;
               }))
        g.Ast.group_defs;
      List.iter
        (fun (_, cname, cexpr) ->
          define env cname ~mutable_:false (eval_expr env cexpr))
        g.Ast.group_consts;
      let member_values =
        List.map
          (fun (d : Ast.fun_def) ->
            ( d.Ast.def_name,
              match lookup_opt env d.Ast.def_name with
              | Some v -> v
              | None -> assert false ))
          g.Ast.group_defs
        @ List.map
            (fun (_, cname, _) ->
              ( cname,
                match lookup_opt env cname with
                | Some v -> v
                | None -> assert false ))
            g.Ast.group_consts
      in
      define env g.Ast.group_name ~mutable_:false (EmoGroup member_values);
      Hashtbl.replace !group_registry g.Ast.group_name member_values
  | Ast.Item_foreign f ->
      (* The compiled backend emits the external declaration; the
         interpreter has no C linkage. *)
      error f.Ast.foreign_span "E3009"
        "foreign definitions run only in compiled programs (use emo build)"

(* Restricted-profile schema errors: the manifest reader maps them onto the
   E51xx codes. A field defined twice, and a value that is not literal data
   (the manifest is data, not program logic). *)
exception Duplicate_field of string
exception Impure_field of string

(* Evaluates pre-parsed items hermetically: an empty environment (no I/O
   builtins in scope), a step budget, and `package`/`deps` blocks whose
   bindings are collected into a dependency table instead of the scope.
   Returns the resulting environment and the collected (dep, value) pairs. *)
let run_restricted ~(budget : int) ~(file : string) (items : Ast.item list) :
    env * (string * string) list =
  step_budget := Some budget;
  step_count := 0;
  let env = { frame = Hashtbl.create 8; parent = None } in
  let deps : (string * string) list ref = ref [] in
  let is_literal (e : Ast.expr) =
    let rec go (e : Ast.expr) =
      match e.Ast.desc with
      | Ast.String _ | Ast.Int _ | Ast.Float _ | Ast.Bool _ | Ast.Char _ -> true
      | Ast.Array_literal es -> List.for_all go es
      | _ -> false
    in
    go e
  in
  let field_target (s : Ast.stmt) =
    match s.Ast.stmt_desc with
    | Ast.Binding { name; init; _ } -> Some (name, init)
    | Ast.Assign { target = { Ast.desc = Ast.Ident name; _ }; value } ->
        Some (name, value)
    | _ -> None
  in
  let define_field target name (init : Ast.expr) =
    if Hashtbl.mem target.frame name then raise (Duplicate_field name);
    if not (is_literal init) then raise (Impure_field name);
    count_step ();
    define target name ~mutable_:false (eval_expr env init)
  in
  let add_dep name (init : Ast.expr) =
    if List.mem_assoc name !deps then raise (Duplicate_field name);
    match init.Ast.desc with
    | Ast.String s -> deps := !deps @ [ (name, s) ]
    | _ -> raise (Impure_field name)
  in
  let handle_stmt (s : Ast.stmt) =
    match field_target s with
    | Some (name, init) -> define_field env name init
    | None -> ()
  in
  let rec handle_block name body =
    if name = "deps" then
      List.iter
        (fun s ->
          match field_target s with
          | Some (name, init) -> add_dep name init
          | None -> ())
        body
    else
      (* A package block defines its fields; a nested `deps { ... }` block is
         collected in source order. *)
      List.iter
        (fun s ->
          match s.Ast.stmt_desc with
          | Ast.Expr_stmt
              {
                desc = Ast.Call ({ Ast.desc = Ast.Ident "deps"; _ }, block_args);
                _;
              } -> (
              match block_args with
              | [
               {
                 Ast.arg_value = { Ast.desc = Ast.Arrow_block (_, inner); _ };
                 _;
               };
              ] ->
                  handle_block "deps" inner
              | _ -> handle_stmt s)
          | _ -> handle_stmt s)
        body
  in
  let flatten item =
    let eval_plain () = ignore (eval_item env item) in
    match item.Ast.item_desc with
    | Ast.Item_stmt
        {
          stmt_desc = Ast.Expr_stmt { desc = Ast.Call (callee, block_args); _ };
          _;
        } -> (
        match (callee.Ast.desc, block_args) with
        | ( Ast.Ident (("package" | "deps") as name),
            [
              { Ast.arg_value = { Ast.desc = Ast.Arrow_block (_, body); _ }; _ };
            ] ) ->
            handle_block name body
        | _ -> eval_plain ())
    | _ -> eval_plain ()
  in
  (try List.iter flatten items
   with e ->
     step_budget := None;
     raise e);
  step_budget := None;
  (env, !deps)

let run_items items =
  Hashtbl.reset interface_registry;
  Hashtbl.reset !group_registry;
  call_trace := [];
  let env = global_env () in
  (* Unscheduled runs refuse the process operations with E3009. *)
  try run_without_scheduler (fun () -> List.iter (eval_item env) items)
  with Emo_raise (v, span, trace) ->
    raise (Error (uncaught_diagnostic (v, span, trace)))

(* Bridges compiled code into the builtin surface (print, the net_*
   family, halt, ...): the same argument shapes and runtime errors as
   interpreted calls. *)
let call_builtin (name : string) (args : value list) : value =
  let nowhere =
    Emo_support.Span.make ~file:"<native>" ~line:1 ~col:1 ~start:0 ~stop:0
  in
  apply_builtin nowhere name args

(* Sets a field on a compiled object inside the init window: replaces in
   place, or appends in first-assignment order. *)
let obj_set_field (o : obj_handle) (name : string) (v : value) : unit =
  if List.mem_assoc name o.ofields then
    o.ofields <-
      List.map
        (fun (n, old) -> if String.equal n name then (n, v) else (n, old))
        o.ofields
  else o.ofields <- o.ofields @ [ (name, v) ]

let new_obj (name : string)
    (methods : (string, int * (value list -> value)) Hashtbl.t) : obj_handle =
  { ocname = name; ofields = []; omethods = methods }

(* ---- Synchronous net operations for the compiled backend ----

   Each performs its effect; they only run under the scheduler, exactly
   like the interpreted paths. *)

let read_line_sync (c : conn) : string =
  Effect.perform (Net_read_line (c, Emo_support.Span.zero))

let read_exactly_sync (c : conn) (n : int) : string =
  Effect.perform (Net_read_exactly (c, n, Emo_support.Span.zero))

let read_all_sync (c : conn) : string =
  Effect.perform (Net_read_all (c, Emo_support.Span.zero))

let write_sync (c : conn) (data : string) : unit =
  Effect.perform (Net_write (c, data, Emo_support.Span.zero))

let close_sync (c : conn) : conn =
  Effect.perform (Net_close_conn (c, Emo_support.Span.zero))

let accept_sync (l : listener) : conn =
  Effect.perform (Net_accept (l, Emo_support.Span.zero))

let close_listener_sync (l : listener) : listener =
  Effect.perform (Net_close_listener (l, Emo_support.Span.zero))

let udp_send_sync (u : udp) (host : string) (port : int) (data : string) : unit
    =
  Effect.perform (Net_udp_send_to (u, host, port, data, Emo_support.Span.zero))

let udp_recv_sync (u : udp) : value =
  Effect.perform (Net_udp_recv_from (u, Emo_support.Span.zero))

let udp_close_sync (u : udp) : udp =
  Effect.perform (Net_udp_close (u, Emo_support.Span.zero))

let net_resolve_sync (host : string) : string list =
  Effect.perform (Net_resolve (host, Emo_support.Span.zero))

let net_connect_sync (host : string) (port : int) (timeout : float) : conn =
  Effect.perform
    (Net_connect
       (host, port, timeout, net_resolve_sync host, Emo_support.Span.zero))

let net_listen_sync (host : string) (port : int) : listener =
  Effect.perform (Net_listen (host, port, Emo_support.Span.zero))

(* Runs a whole file: declarations register, statements execute in order. *)
let run_program ~file ~source =
  run_items (Emo_parser.parse_program ~file ~source)
