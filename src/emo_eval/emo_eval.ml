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
  | Builder of emo_builder
  | Map of emo_map
  | Box of value ref
  | Atomic of value ref (* the synchronized cell: a handle, never copied *)
  | Pid of int (* a process identity, from `do` or `self_pid()` *)
  | TcpConn of conn
  | TcpListener of listener
  | UdpSocket of udp
  | Obj of obj_handle
  | CompiledFn of compiled_fn
  | ArrowBlock of closure
  | BuiltinFn of string
  | RuntimeImplFn of string
  | ForeignFn of string
    (* a `foreign def` binding: inert at load time, E3009 when called *)
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
  void_ok : bool;
      (* the body may end without `return` — a def with no return type
         (Void) and any arrow block; the checker rejects stray returns in
         these, so falling off the end yields Void instead of an error *)
}

and module_handle = {
  mpath : string list; (* normalized module path, e.g. ["shop"; "order"] *)
  mchildren : (string * string list) list; (* name → child module path *)
  mutable menv : env option; (* the namespace once its items have run *)
  mutable loading : bool; (* cycle guard while items are running *)
}

(* The List deque: a doubly-linked chain with O(1) push and pop at both
   ends. The identity is the record, so mutation is visible through every
   alias — the same shape a Box takes. *)
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

(* The ArrayBuilder: a flat element buffer under construction that
   doubles when it fills. The identity is the record, so mutation is
   visible through every alias — the same shape a Box and a List take. *)
and emo_builder = { mutable bitems : value array; mutable bsize : int }

and emo_map = {
  entries : (value, value) Hashtbl.t;
      (* hash table over the primitive key types; keys are validated
         before insertion, so structural hashing never meets a closure *)
  mutable order : value list; (* the keys, REVERSED insertion order *)
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
  else Int64.of_string_opt s

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
  | Builder _ -> "ArrayBuilder"
  | Map _ -> "Map"
  | Box _ -> "Box"
  | Atomic _ -> "Atomic"
  | Pid _ -> "Pid"
  | TcpConn _ -> "TcpConn"
  | TcpListener _ -> "TcpListener"
  | UdpSocket _ -> "UdpSocket"
  | Obj o -> o.ocname
  | CompiledFn _ -> "an arrow block"
  | ArrowBlock _ -> "an arrow block"
  | BuiltinFn _ -> "a builtin"
  | RuntimeImplFn _ -> "a runtime implementation"
  | ForeignFn _ -> "a foreign definition"
  | ClassDef _ -> "a class"
  | Instance _ -> "an instance"
  | EnumType _ -> "an enum"
  | EnumMember _ -> "an enum member"
  | TypeValue _ -> "a type"
  | Module _ -> "a module"
  | EmoGroup _ -> "a function group"

let rec equal_value a b =
  match (a, b) with
  | Int64 x, Int64 y -> Int64.equal x y
  | Byte x, Byte y -> Int.equal x y
  | Float x, Float y -> x = y
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
  | Builder x, Builder y ->
      x.bsize = y.bsize
      &&
      let ok = ref true in
      for i = 0 to x.bsize - 1 do
        if not (equal_value x.bitems.(i) y.bitems.(i)) then ok := false
      done;
      !ok
  | Map x, Map y ->
      Hashtbl.length x.entries = Hashtbl.length y.entries
      && List.for_all
           (fun k ->
             match Hashtbl.find_opt y.entries k with
             | Some v -> equal_value (Hashtbl.find x.entries k) v
             | None -> false)
           (map_keys x)
  | Box x, Box y -> equal_value !x !y
  | Atomic x, Atomic y -> equal_value !x !y
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
  | RuntimeImplFn x, RuntimeImplFn y -> String.equal x y
  | ForeignFn x, ForeignFn y -> String.equal x y
  | _ -> false

(* The map's key rule and its insertion order live beside equality:
   keys are the primitive types whose equality and hash every runtime
   agrees on, and both relations read the same order list. *)
and map_key_ok (k : value) : bool =
  match k with
  | String _ | Int64 _ | Byte _ | Bool _ | Char _ | Float _ -> true
  | _ -> false

and map_keys (m : emo_map) : value list = List.rev m.order

let global_env () =
  let env = { frame = Hashtbl.create 16; parent = None } in
  (* The language's own built-ins: the bare names every frame carries. *)
  Hashtbl.replace env.frame "println"
    { bound = BuiltinFn "println"; mutable_ = false };
  Hashtbl.replace env.frame "printf"
    { bound = BuiltinFn "printf"; mutable_ = false };
  Hashtbl.replace env.frame "self_pid"
    { bound = BuiltinFn "self_pid"; mutable_ = false };
  Hashtbl.replace env.frame "halt"
    { bound = BuiltinFn "halt"; mutable_ = false };
  Hashtbl.replace env.frame "fence"
    { bound = BuiltinFn "fence"; mutable_ = false };
  (* The raw-memory builtins (docs/raw-memory.md): the interpreter owns
     no address space, so every call is the named refusal — the checker
     already refuses on every hosted target (E4028); these arms are the
     defense for any unchecked path. *)
  Hashtbl.replace env.frame "peek8"
    { bound = BuiltinFn "peek8"; mutable_ = false };
  Hashtbl.replace env.frame "poke8"
    { bound = BuiltinFn "poke8"; mutable_ = false };
  Hashtbl.replace env.frame "peek64"
    { bound = BuiltinFn "peek64"; mutable_ = false };
  Hashtbl.replace env.frame "poke64"
    { bound = BuiltinFn "poke64"; mutable_ = false };
  Hashtbl.replace env.frame "device_wait"
    { bound = BuiltinFn "device_wait"; mutable_ = false };
  Hashtbl.replace env.frame "expect_equal"
    { bound = BuiltinFn "expect_equal"; mutable_ = false };
  Hashtbl.replace env.frame "expect_true"
    { bound = BuiltinFn "expect_true"; mutable_ = false };
  Hashtbl.replace env.frame "expect_false"
    { bound = BuiltinFn "expect_false"; mutable_ = false };
  Hashtbl.replace env.frame "expect_fail"
    { bound = BuiltinFn "expect_fail"; mutable_ = false };
  (* The capability types: the language's own types, import-free. *)
  Hashtbl.replace env.frame "Int64"
    { bound = TypeValue "Int64"; mutable_ = false };
  Hashtbl.replace env.frame "Byte"
    { bound = TypeValue "Byte"; mutable_ = false };
  Hashtbl.replace env.frame "Float64"
    { bound = TypeValue "Float64"; mutable_ = false };
  Hashtbl.replace env.frame "Box" { bound = TypeValue "Box"; mutable_ = false };
  Hashtbl.replace env.frame "Atomic"
    { bound = TypeValue "Atomic"; mutable_ = false };
  Hashtbl.replace env.frame "Bytes"
    { bound = TypeValue "Bytes"; mutable_ = false };
  Hashtbl.replace env.frame "List"
    { bound = TypeValue "List"; mutable_ = false };
  Hashtbl.replace env.frame "ArrayBuilder"
    { bound = TypeValue "ArrayBuilder"; mutable_ = false };
  Hashtbl.replace env.frame "Map" { bound = TypeValue "Map"; mutable_ = false };
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
  (* The built-in result enum: `(R.ok, value)` beside `(R.error, reason)`,
     matched in `case`, no import needed. *)
  Hashtbl.replace env.frame "R"
    {
      bound =
        EnumType
          {
            ename = "R";
            emembers =
              [
                ("ok", EnumMember ("R", "ok"));
                ("error", EnumMember ("R", "error"));
              ];
          };
      mutable_ = false;
    };
  (* The runtime's implementations of the standard library's packages: the
     bare names a package's own Emo source calls, never a surface. *)
  Hashtbl.replace env.frame "net_connect"
    { bound = RuntimeImplFn "net_connect"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen"
    { bound = RuntimeImplFn "net_listen"; mutable_ = false };
  Hashtbl.replace env.frame "net_resolve"
    { bound = RuntimeImplFn "net_resolve"; mutable_ = false };
  Hashtbl.replace env.frame "net_udp_bind"
    { bound = RuntimeImplFn "net_udp_bind"; mutable_ = false };
  Hashtbl.replace env.frame "net_connect_unix"
    { bound = RuntimeImplFn "net_connect_unix"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen_unix"
    { bound = RuntimeImplFn "net_listen_unix"; mutable_ = false };
  Hashtbl.replace env.frame "net_tls_connect"
    { bound = RuntimeImplFn "net_tls_connect"; mutable_ = false };
  Hashtbl.replace env.frame "net_tls_connect_insecure"
    { bound = RuntimeImplFn "net_tls_connect_insecure"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen_tls"
    { bound = RuntimeImplFn "net_listen_tls"; mutable_ = false };
  Hashtbl.replace env.frame "net_tls_connect_with"
    { bound = RuntimeImplFn "net_tls_connect_with"; mutable_ = false };
  Hashtbl.replace env.frame "net_listen_tls_with"
    { bound = RuntimeImplFn "net_listen_tls_with"; mutable_ = false };
  Hashtbl.replace env.frame "file_read"
    { bound = RuntimeImplFn "file_read"; mutable_ = false };
  Hashtbl.replace env.frame "file_write"
    { bound = RuntimeImplFn "file_write"; mutable_ = false };
  Hashtbl.replace env.frame "os_getpid"
    { bound = RuntimeImplFn "os_getpid"; mutable_ = false };
  Hashtbl.replace env.frame "os_getppid"
    { bound = RuntimeImplFn "os_getppid"; mutable_ = false };
  Hashtbl.replace env.frame "os_fork"
    { bound = RuntimeImplFn "os_fork"; mutable_ = false };
  Hashtbl.replace env.frame "os_waitpid"
    { bound = RuntimeImplFn "os_waitpid"; mutable_ = false };
  Hashtbl.replace env.frame "os_pipe"
    { bound = RuntimeImplFn "os_pipe"; mutable_ = false };
  Hashtbl.replace env.frame "os_execv"
    { bound = RuntimeImplFn "os_execv"; mutable_ = false };
  Hashtbl.replace env.frame "os__exit"
    { bound = RuntimeImplFn "os__exit"; mutable_ = false };
  Hashtbl.replace env.frame "os_open_read"
    { bound = RuntimeImplFn "os_open_read"; mutable_ = false };
  Hashtbl.replace env.frame "os_open_write"
    { bound = RuntimeImplFn "os_open_write"; mutable_ = false };
  Hashtbl.replace env.frame "os_open_append"
    { bound = RuntimeImplFn "os_open_append"; mutable_ = false };
  Hashtbl.replace env.frame "os_read"
    { bound = RuntimeImplFn "os_read"; mutable_ = false };
  Hashtbl.replace env.frame "os_write"
    { bound = RuntimeImplFn "os_write"; mutable_ = false };
  Hashtbl.replace env.frame "os_close"
    { bound = RuntimeImplFn "os_close"; mutable_ = false };
  Hashtbl.replace env.frame "os_list_dir"
    { bound = RuntimeImplFn "os_list_dir"; mutable_ = false };
  Hashtbl.replace env.frame "os_mkdir"
    { bound = RuntimeImplFn "os_mkdir"; mutable_ = false };
  Hashtbl.replace env.frame "os_rmdir"
    { bound = RuntimeImplFn "os_rmdir"; mutable_ = false };
  Hashtbl.replace env.frame "os_unlink"
    { bound = RuntimeImplFn "os_unlink"; mutable_ = false };
  Hashtbl.replace env.frame "os_rename"
    { bound = RuntimeImplFn "os_rename"; mutable_ = false };
  Hashtbl.replace env.frame "os_getcwd"
    { bound = RuntimeImplFn "os_getcwd"; mutable_ = false };
  Hashtbl.replace env.frame "os_chdir"
    { bound = RuntimeImplFn "os_chdir"; mutable_ = false };
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

(* Resolves a bare cross-module type name to its declared value (a
   ClassDef or an EnumType): the name binds only in its own module's
   environment, and a bare reference carries no module path to load
   through, so the project layer installs the program's owner index —
   the runtime mirror of the checker's program-wide pre-registration
   (CHECK.md, cross-module types). The declaring module loads on first
   need, like any module reference. *)
let type_owner_of : (string -> value option) ref = ref (fun _ -> None)

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
let default_output s =
  print_string s;
  flush stdout

let output : (string -> unit) ref = ref default_output
let set_output f = output := f
let reset_output () = output := default_output

(* The List deque's operations: O(1) push and pop at both ends, and the
   elements front to back. Popping an empty List is a domain error, like
   an out-of-bounds index. *)
let fresh_list () : emo_list = { lhead = None; ltail = None; lsize = 0 }

let list_values (l : emo_list) : value list =
  let rec go node acc =
    match node with None -> List.rev acc | Some n -> go n.lnext (n.lval :: acc)
  in
  go l.lhead []

let list_push_front (l : emo_list) (v : value) : unit =
  let node = { lval = v; lprev = None; lnext = l.lhead } in
  (match l.lhead with
  | Some h -> h.lprev <- Some node
  | None -> l.ltail <- Some node);
  l.lhead <- Some node;
  l.lsize <- l.lsize + 1

let list_push_back (l : emo_list) (v : value) : unit =
  let node = { lval = v; lprev = l.ltail; lnext = None } in
  (match l.ltail with
  | Some t -> t.lnext <- Some node
  | None -> l.lhead <- Some node);
  l.ltail <- Some node;
  l.lsize <- l.lsize + 1

let list_pop_front span (l : emo_list) : value =
  match l.lhead with
  | None -> error span "E3004" "`pop_front` on an empty List"
  | Some node ->
      l.lhead <- node.lnext;
      (match node.lnext with
      | Some n -> n.lprev <- None
      | None -> l.ltail <- None);
      l.lsize <- l.lsize - 1;
      node.lval

let list_pop_back span (l : emo_list) : value =
  match l.ltail with
  | None -> error span "E3004" "`pop_back` on an empty List"
  | Some node ->
      l.ltail <- node.lprev;
      (match node.lprev with
      | Some p -> p.lnext <- None
      | None -> l.lhead <- None);
      l.lsize <- l.lsize - 1;
      node.lval

(* The ArrayBuilder's operations: push at the end for amortized O(1) (the
   buffer doubles when it fills), and `to_array` — a copy, so the builder
   stays free to grow without touching the array it handed out. *)
let fresh_builder () : emo_builder = { bitems = [||]; bsize = 0 }

let builder_push (b : emo_builder) (v : value) : unit =
  if b.bsize = Array.length b.bitems then (
    let cap = Array.length b.bitems in
    let ncap = if cap < 8 then 8 else cap * 2 in
    let items = Array.make ncap v in
    Array.blit b.bitems 0 items 0 cap;
    b.bitems <- items);
  b.bitems.(b.bsize) <- v;
  b.bsize <- b.bsize + 1

let builder_get span (b : emo_builder) (i : value) : value =
  match i with
  | Int64 n when n >= 0L && n < Int64.of_int b.bsize ->
      b.bitems.(Int64.to_int n)
  | Int64 n ->
      error span "E3004"
        (Printf.sprintf
           "index %Ld is out of bounds for a length-%d ArrayBuilder" n b.bsize)
  | v ->
      error span "E3001"
        (Printf.sprintf "the index must be an Int64, got %s" (type_name v))

let builder_to_array (b : emo_builder) : value =
  Array (Array.sub b.bitems 0 b.bsize)

(* The call that runs a class's own `to_string` — the evaluator installs
   it below, after the values — so that rendering can answer an
   instance's method first, the `emo.to_string` protocol. *)
let call_to_string : (instance_value -> closure -> value) ref =
  ref (fun _ _ -> failwith "emo_eval: the to_string hook is not installed")

(* The one stringification rule: interpolation and `.to_string()` share it. *)
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
      "List[" ^ String.concat ", " (List.map to_string (list_values l)) ^ "]"
  | Builder b ->
      "ArrayBuilder["
      ^ String.concat ", "
          (List.map to_string (Array.to_list (Array.sub b.bitems 0 b.bsize)))
      ^ "]"
  | Map m ->
      "{"
      ^ String.concat ", "
          (List.map
             (fun k ->
               debug_value k ^ ": " ^ debug_value (Hashtbl.find m.entries k))
             (map_keys m))
      ^ "}"
  | Box _ -> "<box>"
  | Atomic _ -> "<atomic>"
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
  | ArrowBlock _ -> "<arrow block>"
  | BuiltinFn name -> Printf.sprintf "<builtin %s>" name
  | RuntimeImplFn name -> Printf.sprintf "<runtime implementation %s>" name
  | ForeignFn name -> Printf.sprintf "<foreign %s>" name
  | ClassDef c -> c.cname
  | Instance i -> (
      if
        (* Provisional default format, per the step-06 spec. *)
        i.iclass.builtin_exception
      then
        match List.assoc_opt "message" i.ifields with
        | Some message -> to_string message
        | None -> "#Exception()"
      else
        (* A class's own `to_string` answers first — the protocol entry
         `emo.to_string` — and the structure dump is the defined
         default, not a fallback the method can shadow by a different
         signature. *)
        match List.assoc_opt "to_string" i.iclass.cmethods with
        | Some closure when closure.params = [] -> (
            match !call_to_string i closure with
            | String s -> s
            | _ ->
                error Emo_support.Span.zero "E3015"
                  "`to_string` must answer a String")
        | _ ->
            let fields =
              String.concat ", "
                (List.map (fun (n, fv) -> n ^ ": " ^ debug_value fv) i.ifields)
            in
            "#" ^ i.iclass.cname ^ "(" ^ fields ^ ")")
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
  | List l ->
      "List[" ^ String.concat ", " (List.map debug_value (list_values l)) ^ "]"
  | Builder b ->
      "ArrayBuilder["
      ^ String.concat ", "
          (List.map debug_value (Array.to_list (Array.sub b.bitems 0 b.bsize)))
      ^ "]"
  | Map _ as v -> to_string v
  | v -> to_string v

(* ---- Map: the mutable, insertion-ordered hash table ----

   Keys are validated at every insertion (see [map_key_ok]), so the
   backing table's structural hashing never meets a closure or an
   instance. Setting an existing key replaces its value and keeps its
   position; the order list stores the keys reversed so insertion stays
   O(1). *)

let map_key_type_error span k =
  error span "E3001"
    (Printf.sprintf
       "a map key must be a String, Int64, Byte, Bool, Char, or Float64; got %s"
       (type_name k))

(* Inserts or replaces; a replacement keeps the key's position. *)
let map_set span (m : emo_map) k v =
  if not (map_key_ok k) then map_key_type_error span k;
  if Hashtbl.mem m.entries k then Hashtbl.replace m.entries k v
  else (
    Hashtbl.add m.entries k v;
    m.order <- k :: m.order)

let map_get span (m : emo_map) k =
  if not (map_key_ok k) then map_key_type_error span k;
  match Hashtbl.find_opt m.entries k with
  | Some v -> v
  | None ->
      error span "E3004"
        (Printf.sprintf "no key %s in this Map" (debug_value k))

let fresh_map () : emo_map = { entries = Hashtbl.create 8; order = [] }

(* Interfaces have no runtime artifact beyond this registry: `x.is(T)`
   checks the receiver's class against the declared method shapes. *)
let interface_registry : (string, (string * int) list) Hashtbl.t =
  Hashtbl.create 8

(* Function groups are project-global at runtime: a group defined in
   one module is callable from another module's processes. *)
let group_registry : (string, (string * value) list) Hashtbl.t ref =
  ref (Hashtbl.create 8)

(* A program run starts with fresh program-wide registries: the project
   layer calls this before installing its module hooks, and single-file
   runs reset inline. *)
let reset_program_registries () =
  Hashtbl.reset interface_registry;
  Hashtbl.reset !group_registry;
  type_owner_of := fun _ -> None

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

(* Resolves a type reference — a bare name in the current module, or a
   module-qualified path — to its declared value. A dotted path walks
   the module tree, loading modules on demand; the env first, so a
   module already bound (a sibling, the package tree) answers directly. *)
let rec resolve_type_value env (ref_ : string) : value option =
  match lookup_opt env ref_ with
  | Some v -> Some v
  | None -> (
      match String.split_on_char '.' ref_ with
      | head :: rest -> (
          match lookup_opt env head with
          | Some (Module h) -> walk_type h rest
          | _ -> (
              match !module_handle_of [ head ] with
              | Some h -> walk_type h rest
              | None -> None))
      | [] -> None)

and walk_type h segs : value option =
  match segs with
  | [] -> None
  | [ last ] -> (
      ensure_module_loaded h;
      match h.menv with Some e -> lookup_opt e last | None -> None)
  | seg :: rest -> (
      match !module_handle_of (h.mpath @ [ seg ]) with
      | Some child -> walk_type child rest
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

(* `break` and `continue` unwind to the nearest enclosing loop's host
   loop; crossing a function boundary is a checker-caught error, and the
   call boundary turns one into a loud error all the same. *)
exception Break_signal
exception Continue_signal

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

(* The crash report's machine-readable context: an `Exception`'s non-empty
   `data` Map renders alongside the message (CHECK.md, error handling). *)
let exception_data (v : value) : string option =
  match v with
  | Instance i when i.iclass.builtin_exception -> (
      match List.assoc_opt "data" i.ifields with
      | Some (Map m) when Hashtbl.length m.entries > 0 ->
          Some (to_string (Map m))
      | _ -> None)
  | _ -> None

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
  let message =
    match exception_data v with
    | Some data ->
        Printf.sprintf "uncaught exception: %s (data: %s)" (to_string v) data
    | None -> Printf.sprintf "uncaught exception: %s" (to_string v)
  in
  Emo_support.Diagnostic.
    { severity = Error; code = Some "E3010"; message; span; hint }

let literal_value = function
  | Ast.L_int n -> Int64 n
  | Ast.L_byte n -> Byte n
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
      (* The value's tag carries the qualified enum identity; resolve the
         pattern's written reference to the same identity. *)
      let tag =
        match resolve_type_value frame t with
        | Some (EnumType e) -> e.ename
        | _ -> t
      in
      match value with
      | EnumMember (t', m') -> String.equal tag t' && String.equal m m'
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

   The data-driven failures are values, not exceptions: an operation
   answers (R.ok, value) or (R.error, reason), the reason stating exactly
   what failed — connection refused, name unresolvable, deadline exceeded,
   socket closed (the README error model; CHECK.md, error handling). No
   error codes, no nil. The effects carry the final tuple: the driver
   finishes the parked continuation with it, and the refusals below are
   the only raising path left. *)

type tls_client_options = {
  tls_ca_file : string;
  tls_client_cert_file : string;
  tls_client_key_file : string;
  tls_server_name : string;
  tls_insecure : bool;
}

type tls_server_options = {
  tls_client_ca_file : string;
  tls_require_client_cert : bool;
}

let default_tls_client_options =
  {
    tls_ca_file = "";
    tls_client_cert_file = "";
    tls_client_key_file = "";
    tls_server_name = "";
    tls_insecure = false;
  }

let default_tls_server_options =
  { tls_client_ca_file = ""; tls_require_client_cert = false }

type _ Effect.t +=
  | Net_resolve : string * Emo_support.Span.t -> value Effect.t
  | Net_connect : (string * int * float * Emo_support.Span.t) -> value Effect.t
  | Net_listen : string * int * Emo_support.Span.t -> value Effect.t
  | Net_accept : listener * Emo_support.Span.t -> value Effect.t
  | Net_read_line : conn * Emo_support.Span.t -> value Effect.t
  | Net_read_exactly : conn * int * Emo_support.Span.t -> value Effect.t
  | Net_read_all : conn * Emo_support.Span.t -> value Effect.t
  | Net_write : conn * string * Emo_support.Span.t -> value Effect.t
  | Net_close_conn : conn * Emo_support.Span.t -> value Effect.t
  | Net_close_listener : listener * Emo_support.Span.t -> value Effect.t
  | Net_udp_bind : string * int * Emo_support.Span.t -> value Effect.t
  | Net_udp_send_to :
      (udp * string * int * string * Emo_support.Span.t)
      -> value Effect.t
  | Net_udp_recv_from : udp * Emo_support.Span.t -> value Effect.t
  | Net_udp_close : udp * Emo_support.Span.t -> value Effect.t
  | Net_connect_unix : string * float * Emo_support.Span.t -> value Effect.t
  | Net_listen_unix : string * Emo_support.Span.t -> value Effect.t
  | File_read : string * Emo_support.Span.t -> value Effect.t
  | File_write : string * string * Emo_support.Span.t -> value Effect.t
  | Net_tls_connect :
      (string * int * float * tls_client_options * Emo_support.Span.t)
      -> value Effect.t
  | (* host, port, timeout, options *)
      Net_tls_listen :
      (string * int * string * string * tls_server_options * Emo_support.Span.t)
      -> value Effect.t
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

(* Snapshots a message at the process boundary: every Box, List, and
   ArrayBuilder in the message (directly or inside a tuple, array, or
   instance) arrives as a fresh copy, so mutability never crosses a
   process boundary — mutations on either side stay unobservable to the
   other. Everything else is immutable data or identity and passes
   as-is. *)
let rec snapshot (v : value) : value =
  match v with
  | Box r -> Box (ref (snapshot !r))
  (* The one declared exception (CHECK.md, the atomic memory model): an
     Atomic copies as the handle to the same cell — every operation on
     the cell is synchronized, so the sharing is safe by construction. *)
  | Atomic _ -> v
  | Bytes b -> Bytes (Bytes.copy b)
  | Tuple vs -> Tuple (List.map snapshot vs)
  | Array xs -> Array (Array.map snapshot xs)
  | List l ->
      let copy = fresh_list () in
      List.iter (fun v -> list_push_back copy (snapshot v)) (list_values l);
      List copy
  | Builder b ->
      let copy = fresh_builder () in
      for i = 0 to b.bsize - 1 do
        builder_push copy (snapshot b.bitems.(i))
      done;
      Builder copy
  | Map m ->
      let copy = fresh_map () in
      List.iter
        (fun k ->
          Hashtbl.replace copy.entries k (snapshot (Hashtbl.find m.entries k));
          copy.order <- k :: copy.order)
        (map_keys m);
      Map copy
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
            | Net_connect (_, _, _, span) ->
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
            | File_read (_, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`file.read`")
            | File_write (_, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) -> refused span "`file.write`")
            | Compiled_receive _ ->
                Some
                  (fun (_ : (a, _) continuation) -> refused nowhere "`receive`")
            | Net_tls_connect (_, _, _, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_tls_connect`")
            | Net_tls_listen (_, _, _, _, _, span) ->
                Some
                  (fun (_ : (a, _) continuation) ->
                    refused span "`net_listen_tls`")
            | _ -> None);
      }
  with Halt_signal -> ()

let not_yet span what =
  error span "E3009" (Printf.sprintf "%s is not supported yet" what)

(* Builds the Emo exception a synchronous carved-out failure unwinds
   with (the [waitpid] decode path; the net and file failures below are
   values, not exceptions). *)
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
          ifields =
            [ ("message", String message); ("data", Map (fresh_map ())) ];
        },
      span,
      !call_trace )

(* The net failures are values: drivers finish the parked continuation
   with one of these — (R.ok, value) or (R.error, reason), the reason
   the same text the exceptions carried (CHECK.md, error handling). *)
let net_ok (v : value) : value = Tuple [ EnumMember ("R", "ok"); v ]

let net_error (message : string) : value =
  Tuple [ EnumMember ("R", "error"); String message ]

(* A failed assertion unwinds with the same Exception a `raise` carries —
   the `emo test` runner traps it per test. *)
let expect_raise span message = net_raise span message

let rec eval_unary env span op x =
  let v = eval_expr env x in
  match (op, v) with
  | Ast.Not, Bool b -> Bool (not b)
  | Ast.Not, v ->
      error span "E3001"
        (Printf.sprintf "operator `!` expects a Bool, got %s" (type_name v))
  | Ast.Neg, Int64 n -> Int64 (Int64.neg n)
  | Ast.Neg, Float f -> Float (-.f)
  | Ast.Neg, v ->
      error span "E3001"
        (Printf.sprintf "operator `-` expects a number, got %s" (type_name v))
  | Ast.Bit_not, Int64 n -> Int64 (Int64.lognot n)
  | Ast.Bit_not, Byte n -> Byte (lnot n land 255)
  | Ast.Bit_not, v ->
      error span "E3001"
        (Printf.sprintf "operator `~` expects an Int64, got %s" (type_name v))

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
    | Ast.Bit_and -> "&"
    | Ast.Bit_or -> "|"
    | Ast.Bit_xor -> "^"
    | Ast.Shl -> "<<"
    | Ast.Shr -> ">>"
    | Ast.And -> "&&"
    | Ast.Or -> "||"
  in
  (* `&&` and `||` short-circuit: the right operand evaluates only when
     its value is needed, matching the compiled targets, whose
     `&&`/`||` lower to branches. The eager path below would run a
     guarded right side (`i < n && data.get(i) == 32`) even when the
     guard is false. *)
  match op with
  | Ast.And | Ast.Or ->
      let bool_of what v =
        match v with
        | Bool b -> b
        | v ->
            error span "E3001"
              (Printf.sprintf "operator `%s` expects two Bools, got %s" what
                 (type_name v))
      in
      let what = op_name op in
      let left = bool_of what (eval_expr env left_expr) in
      if op = Ast.And then
        if left then Bool (bool_of what (eval_expr env right_expr))
        else Bool false
      else if left then Bool true
      else Bool (bool_of what (eval_expr env right_expr))
  | _ -> (
      let left = eval_expr env left_expr in
      let right = eval_expr env right_expr in
      let type_mismatch expects =
        error span "E3001"
          (Printf.sprintf "operator `%s` expects %s, got %s and %s" (op_name op)
             expects (type_name left) (type_name right))
      in
      let as_float = function
        | Int64 x -> Int64.to_float x
        | Float f -> f
        | v -> type_mismatch "two numbers"
      in
      let check_bool v =
        match v with Bool b -> b | v -> type_mismatch "two Bools"
      in
      let is_pair64 x y =
        match (x, y) with Int64 _, Int64 _ -> true | _ -> false
      in
      let is_pair_byte x y =
        match (x, y) with Byte _, Byte _ -> true | _ -> false
      in
      let i64_of = function Int64 x -> x | v -> type_mismatch "two Int64s" in
      let byte_of = function Byte x -> x | v -> type_mismatch "two Bytes" in
      (* Fixed-width arithmetic wraps in two's complement; Byte, being
     unsigned, wraps modulo 256. Shift counts are non-negative and
     saturate at the width, matching the Int64 rule. *)
      let i64_bin f = Int64 (f (i64_of left) (i64_of right)) in
      let byte_bin f = Byte (f (byte_of left) (byte_of right) land 255) in
      let i64_div f =
        if i64_of right = 0L then error span "E3005" "division by zero";
        i64_bin f
      in
      let byte_div f =
        if byte_of right = 0 then error span "E3005" "division by zero";
        byte_bin f
      in
      let i64_shift_count () =
        let c = i64_of right in
        if c < 0L then error span "E3005" "shift count must be non-negative";
        c
      in
      let i64_shl () =
        let c = i64_shift_count () in
        if c >= 64L then Int64 0L
        else Int64 (Int64.shift_left (i64_of left) (Int64.to_int c))
      in
      let i64_shr () =
        let c = i64_shift_count () in
        if c >= 64L then Int64 (if i64_of left < 0L then -1L else 0L)
        else Int64 (Int64.shift_right (i64_of left) (Int64.to_int c))
      in
      let byte_shl () =
        let c = byte_of right in
        if c >= 8 then Byte 0 else Byte ((byte_of left lsl c) land 255)
      in
      let byte_shr () =
        let c = byte_of right in
        if c >= 8 then Byte 0 else Byte (byte_of left lsr c)
      in
      match op with
      | Ast.And -> Bool (if check_bool left then check_bool right else false)
      | Ast.Or -> Bool (if check_bool left then true else check_bool right)
      | Ast.Eq -> Bool (equal_value left right)
      | Ast.Ne -> Bool (not (equal_value left right))
      | Ast.Lt when is_pair64 left right ->
          Bool (Int64.compare (i64_of left) (i64_of right) < 0)
      | Ast.Lt when is_pair_byte left right ->
          Bool (byte_of left < byte_of right)
      | Ast.Le when is_pair64 left right ->
          Bool (Int64.compare (i64_of left) (i64_of right) <= 0)
      | Ast.Le when is_pair_byte left right ->
          Bool (byte_of left <= byte_of right)
      | Ast.Gt when is_pair64 left right ->
          Bool (Int64.compare (i64_of left) (i64_of right) > 0)
      | Ast.Gt when is_pair_byte left right ->
          Bool (byte_of left > byte_of right)
      | Ast.Ge when is_pair64 left right ->
          Bool (Int64.compare (i64_of left) (i64_of right) >= 0)
      | Ast.Ge when is_pair_byte left right ->
          Bool (byte_of left >= byte_of right)
      | Ast.Lt -> Bool (as_float left < as_float right)
      | Ast.Le -> Bool (as_float left <= as_float right)
      | Ast.Gt -> Bool (as_float left > as_float right)
      | Ast.Ge -> Bool (as_float left >= as_float right)
      | Ast.Add when is_pair64 left right -> i64_bin Int64.add
      | Ast.Sub when is_pair64 left right -> i64_bin Int64.sub
      | Ast.Mul when is_pair64 left right -> i64_bin Int64.mul
      | Ast.Div when is_pair64 left right -> i64_div Int64.div
      | Ast.Mod when is_pair64 left right -> i64_div Int64.rem
      | Ast.Add when is_pair_byte left right -> byte_bin ( + )
      | Ast.Sub when is_pair_byte left right -> byte_bin ( - )
      | Ast.Mul when is_pair_byte left right -> byte_bin ( * )
      | Ast.Div when is_pair_byte left right -> byte_div ( / )
      | Ast.Mod when is_pair_byte left right -> byte_div ( mod )
      | Ast.Bit_and when is_pair64 left right -> i64_bin Int64.logand
      | Ast.Bit_or when is_pair64 left right -> i64_bin Int64.logor
      | Ast.Bit_xor when is_pair64 left right -> i64_bin Int64.logxor
      | Ast.Shl when is_pair64 left right -> i64_shl ()
      | Ast.Shr when is_pair64 left right -> i64_shr ()
      | Ast.Bit_and when is_pair_byte left right ->
          Byte (byte_of left land byte_of right)
      | Ast.Bit_or when is_pair_byte left right ->
          Byte (byte_of left lor byte_of right)
      | Ast.Bit_xor when is_pair_byte left right ->
          Byte (byte_of left lxor byte_of right)
      | Ast.Shl when is_pair_byte left right -> byte_shl ()
      | Ast.Shr when is_pair_byte left right -> byte_shr ()
      | Ast.Add -> (
          match (left, right) with
          | Float x, Float y -> Float (x +. y)
          | Int64 x, Float y -> Float (Int64.to_float x +. y)
          | Float x, Int64 y -> Float (x +. Int64.to_float y)
          | String x, String y -> String (x ^ y)
          | _ -> type_mismatch "two numbers or two strings")
      | Ast.Sub -> (
          match (left, right) with
          | Float x, Float y -> Float (x -. y)
          | Int64 x, Float y -> Float (Int64.to_float x -. y)
          | Float x, Int64 y -> Float (x -. Int64.to_float y)
          | _ -> type_mismatch "two numbers")
      | Ast.Mul -> (
          match (left, right) with
          | Float x, Float y -> Float (x *. y)
          | Int64 x, Float y -> Float (Int64.to_float x *. y)
          | Float x, Int64 y -> Float (x *. Int64.to_float y)
          | _ -> type_mismatch "two numbers")
      | Ast.Div | Ast.Mod -> (
          let zero_check d =
            match d with
            | Float f when f = 0.0 -> error span "E3005" "division by zero"
            | _ -> ()
          in
          match (left, right) with
          | Float x, Float y ->
              zero_check right;
              if op = Ast.Div then Float (x /. y) else Float (Float.rem x y)
          | Int64 x, Float y ->
              zero_check right;
              if op = Ast.Div then Float (Int64.to_float x /. y)
              else Float (Float.rem (Int64.to_float x) y)
          | Float x, Int64 y ->
              zero_check right;
              if op = Ast.Div then Float (x /. Int64.to_float y)
              else Float (Float.rem x (Int64.to_float y))
          | _ -> type_mismatch "two numbers")
      | Ast.Bit_and | Ast.Bit_or | Ast.Bit_xor | Ast.Shl | Ast.Shr ->
          type_mismatch "two Int64s or two Bytes")

and eval_index env span base index =
  let b = eval_expr env base in
  let i = eval_expr env index in
  let at len =
    let len64 = Int64.of_int len in
    match i with
    | Int64 n when n >= 0L && n < len64 -> Int64.to_int n
    | Int64 n ->
        error span "E3004"
          (Printf.sprintf "index %Ld is out of bounds for a length-%d %s" n len
             (match b with Array _ -> "Array" | _ -> "Tuple"))
    | v ->
        error span "E3001"
          (Printf.sprintf "the index must be an Int64, got %s" (type_name v))
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
      (* A cross-module class name arrives as a bare TypeValue — the
         declaration binds only in its own module's environment — so
         construction resolves through the program's owner index. *)
      let base =
        match (base, mname) with
        | TypeValue t, "new" -> (
            match !type_owner_of t with
            | Some (ClassDef _ as v) -> v
            | _ -> base)
        | _ -> base
      in
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
              let empty_data = Map (fresh_map ()) in
              match args with
              | [ (Some "message", v) ] | [ (None, v) ] ->
                  Instance
                    {
                      iclass = c;
                      ifields = [ ("message", v); ("data", empty_data) ];
                    }
              | [ (Some "message", mv); (Some "data", dv) ]
              | [ (Some "message", mv); (None, dv) ]
              | [ (None, mv); (Some "data", dv) ]
              | [ (None, mv); (None, dv) ] ->
                  Instance
                    { iclass = c; ifields = [ ("message", mv); ("data", dv) ] }
              | _ ->
                  error span "E3007"
                    "`Exception.new` expects `message` and an optional `data` \
                     Map")
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
      | TypeValue "Atomic", "new" -> (
          let args = eval_args () in
          match args with
          | [ v ] -> Atomic (ref v)
          | _ ->
              error span "E3007"
                (Printf.sprintf "`Atomic.new` expects 1 argument, got %d" argc))
      | TypeValue "Byte", "from_int64" -> (
          let args = eval_args () in
          match args with
          | [ Int64 n ] when n >= 0L && n <= 255L -> Byte (Int64.to_int n)
          | [ Int64 n ] ->
              error span "E3004"
                (Printf.sprintf
                   "`Byte.from_int64` needs a value in 0-255, got %Ld" n)
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`Byte.from_int64` expects an Int64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`Byte.from_int64` expects 1 argument, got %d"
                   argc))
      | TypeValue "Float64", "from_bits" -> (
          let args = eval_args () in
          match args with
          | [ Int64 b ] -> Float (Int64.float_of_bits b)
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`Float64.from_bits` expects an Int64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`Float64.from_bits` expects 1 argument, got %d"
                   argc))
      | Int64 x, "to_byte" ->
          none_expected "to_byte";
          Byte (Int64.to_int (Int64.logand x 255L))
      | Byte n, "to_int64" ->
          none_expected "to_int64";
          Int64 (Int64.of_int n)
      | Float f, "to_bits" ->
          none_expected "to_bits";
          Int64 (Int64.bits_of_float f)
      | Float f, "sqrt" ->
          none_expected "sqrt";
          Float (Float.sqrt f)
      | Float f, "floor" ->
          none_expected "floor";
          Float (Float.floor f)
      | Float f, "ceil" ->
          none_expected "ceil";
          Float (Float.ceil f)
      | Float f, "trunc" ->
          none_expected "trunc";
          Float (Float.trunc f)
      | Float f, "to_int64" ->
          none_expected "to_int64";
          Int64 (Int64.of_float f)
      | Int64 n, "to_float64" ->
          none_expected "to_float64";
          Float (Int64.to_float n)
      | TypeValue "Bytes", "new" -> (
          let args = eval_args () in
          match args with
          | [ Int64 n ] when n >= 0L ->
              Bytes (Bytes.make (Int64.to_int n) '\000')
          | [ Int64 n ] ->
              error span "E3004"
                (Printf.sprintf
                   "`Bytes.new` needs a non-negative length, got %Ld" n)
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`Bytes.new` expects an Int64 length, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`Bytes.new` expects 1 argument, got %d" argc))
      | TypeValue "List", "new" -> (
          (* Copies the array's elements into a fresh deque, front to back. *)
          match eval_args () with
          | [ Array xs ] ->
              let l = fresh_list () in
              Array.iter (list_push_back l) xs;
              List l
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`List.new` expects an Array, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`List.new` expects 1 argument, got %d" argc))
      | TypeValue "ArrayBuilder", "new" ->
          (* The builder is born empty; its element type is a compile-time
             question the runtime never asks. *)
          if argc <> 0 then
            error span "E3007"
              (Printf.sprintf "`ArrayBuilder.new` expects no arguments, got %d"
                 argc)
          else Builder (fresh_builder ())
      | TypeValue "Map", "new" ->
          (* Each argument is a (key, value) pair; later pairs overwrite
             earlier ones. *)
          let m = fresh_map () in
          List.iter
            (fun a ->
              match a with
              | Tuple [ k; v ] -> map_set span m k v
              | _ ->
                  error span "E3007"
                    (Printf.sprintf "`Map.new` takes (key, value) pairs, got %s"
                       (type_name a)))
            (eval_args ());
          Map m
      | TypeValue t, m ->
          error span "E3009"
            (Printf.sprintf "type `%s` has no member `%s` yet" t m)
      | Bytes b, "to_string" ->
          none_expected "to_string";
          String (Bytes.to_string b)
      | v, "to_string" ->
          none_expected "to_string";
          String (to_string v)
      | Array xs, "length" ->
          none_expected "length";
          Int64 (Int64.of_int (Array.length xs))
      | Tuple xs, "length" ->
          none_expected "length";
          Int64 (Int64.of_int (List.length xs))
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
      | Atomic cell, "load" ->
          none_expected "load";
          !cell
      | Atomic cell, "store" -> (
          let args = eval_args () in
          match args with
          | [ v ] ->
              cell := v;
              Void
          | _ ->
              error span "E3007"
                (Printf.sprintf "`store` expects 1 argument, got %d" argc))
      | Atomic cell, "exchange" -> (
          let args = eval_args () in
          match args with
          | [ v ] ->
              let old = !cell in
              cell := v;
              old
          | _ ->
              error span "E3007"
                (Printf.sprintf "`exchange` expects 1 argument, got %d" argc))
      | Atomic cell, "compare_exchange" -> (
          let args = eval_args () in
          match args with
          | [ expected; fresh ] ->
              let old = !cell in
              let swapped = equal_value old expected in
              if swapped then cell := fresh;
              Tuple [ Bool swapped; old ]
          | _ ->
              error span "E3007"
                (Printf.sprintf "`compare_exchange` expects 2 arguments, got %d"
                   argc))
      | ( Atomic cell,
          (("fetch_add" | "fetch_sub" | "fetch_and" | "fetch_or" | "fetch_xor")
           as mname) ) -> (
          (* The payload dispatches on the value the cell holds: the
             arithmetic pair is Int64's, the bitwise family is Int64's and
             Bool's — the checker refuses the rest by name, and the
             runtime refuses what a gradual call could still reach. *)
          let args = eval_args () in
          match (mname, args, !cell) with
          | _, [ Int64 v ], Int64 old ->
              let computed =
                match mname with
                | "fetch_add" -> Int64 (Int64.add old v)
                | "fetch_sub" -> Int64 (Int64.sub old v)
                | "fetch_and" -> Int64 (Int64.logand old v)
                | "fetch_or" -> Int64 (Int64.logor old v)
                | _ -> Int64 (Int64.logxor old v)
              in
              cell := computed;
              Int64 old
          | ("fetch_and" | "fetch_or" | "fetch_xor"), [ Bool y ], Bool b ->
              let computed =
                match mname with
                | "fetch_and" -> Bool (b && y)
                | "fetch_or" -> Bool (b || y)
                | _ -> Bool (b <> y)
              in
              cell := computed;
              Bool b
          | _, [ v ], (Int64 _ | Bool _) ->
              error span "E3001"
                (Printf.sprintf "`%s` expects %s, got %s" mname
                   (match !cell with Bool _ -> "a Bool" | _ -> "an Int64")
                   (type_name v))
          | _, _, other ->
              error span "E3001"
                (Printf.sprintf "`%s` expects an Int64 or Bool cell, got %s"
                   mname (type_name other)))
      | List l, "push_front" -> (
          match eval_args () with
          | [ v ] ->
              list_push_front l v;
              List l
          | args ->
              error span "E3007"
                (Printf.sprintf "`push_front` expects 1 argument, got %d"
                   (List.length args)))
      | List l, "push_back" -> (
          match eval_args () with
          | [ v ] ->
              list_push_back l v;
              List l
          | args ->
              error span "E3007"
                (Printf.sprintf "`push_back` expects 1 argument, got %d"
                   (List.length args)))
      | List l, "pop_front" ->
          none_expected "pop_front";
          list_pop_front span l
      | List l, "pop_back" ->
          none_expected "pop_back";
          list_pop_back span l
      | List l, "length" ->
          none_expected "length";
          Int64 (Int64.of_int l.lsize)
      | Builder b, "push" -> (
          match eval_args () with
          | [ v ] ->
              builder_push b v;
              Builder b
          | args ->
              error span "E3007"
                (Printf.sprintf "`push` expects 1 argument, got %d"
                   (List.length args)))
      | Builder b, "get" -> (
          match eval_args () with
          | [ i ] -> builder_get span b i
          | args ->
              error span "E3007"
                (Printf.sprintf "`get` expects 1 argument, got %d"
                   (List.length args)))
      | Builder b, "to_array" ->
          none_expected "to_array";
          builder_to_array b
      | Builder b, "length" ->
          none_expected "length";
          Int64 (Int64.of_int b.bsize)
      | Bytes b, "length" ->
          none_expected "length";
          Int64 (Int64.of_int (Bytes.length b))
      | Bytes b, "get" -> (
          match eval_args () with
          | [ Int64 i ] when i >= 0L && i < Int64.of_int (Bytes.length b) ->
              Int64 (Int64.of_int (Char.code (Bytes.get b (Int64.to_int i))))
          | [ Int64 i ] ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a length-%d Bytes" i
                   (Bytes.length b))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`get` expects an Int64 index, got %s"
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`get` expects 1 argument, got %d"
                   (List.length args)))
      | Bytes b, "set" -> (
          match eval_args () with
          | [ Int64 i; Int64 v ]
            when i >= 0L
                 && i < Int64.of_int (Bytes.length b)
                 && v >= 0L && v <= 255L ->
              Bytes.set b (Int64.to_int i) (Char.chr (Int64.to_int v));
              Int64 v
          | [ Int64 i; Int64 v ]
            when i < 0L || i >= Int64.of_int (Bytes.length b) ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a length-%d Bytes" i
                   (Bytes.length b))
          | [ Int64 _; Int64 v ] ->
              error span "E3004"
                (Printf.sprintf
                   "byte value %Ld is out of range for a byte (0-255)" v)
          | [ Int64 _; v ] ->
              error span "E3001"
                (Printf.sprintf "`set` expects an Int64 byte value, got %s"
                   (type_name v))
          | [ v; _ ] ->
              error span "E3001"
                (Printf.sprintf "`set` expects an Int64 index, got %s"
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`set` expects 2 arguments, got %d"
                   (List.length args)))
      | Bytes b, (("get_u16_le" | "get_u32_le") as mname) -> (
          let width = if mname = "get_u16_le" then 2 else 4 in
          match eval_args () with
          | [ Int64 i ]
            when i >= 0L
                 && Int64.add i (Int64.of_int width)
                    <= Int64.of_int (Bytes.length b) ->
              let i = Int64.to_int i in
              let acc = ref 0 in
              for k = width - 1 downto 0 do
                acc := (!acc lsl 8) lor Char.code (Bytes.get b (i + k))
              done;
              Int64 (Int64.of_int !acc)
          | [ Int64 i ] ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a %s read on a length-%d \
                    Bytes"
                   i mname (Bytes.length b))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`%s` expects an Int64 index, got %s" mname
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`%s` expects 1 argument, got %d" mname
                   (List.length args)))
      | Bytes b, (("set_u16_le" | "set_u32_le") as mname) -> (
          let width = if mname = "set_u16_le" then 2 else 4 in
          match eval_args () with
          | [ Int64 i; Int64 v ]
            when i >= 0L
                 && Int64.add i (Int64.of_int width)
                    <= Int64.of_int (Bytes.length b) ->
              let i = Int64.to_int i in
              let v =
                Int64.to_int v land if width = 2 then 0xFFFF else 0xFFFFFFFF
              in
              for k = 0 to width - 1 do
                Bytes.set b (i + k) (Char.chr ((v lsr (8 * k)) land 0xFF))
              done;
              Int64 (Int64.of_int v)
          | [ Int64 i; Int64 _ ] ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a %s write on a length-%d \
                    Bytes"
                   i mname (Bytes.length b))
          | [ Int64 _; v ] ->
              error span "E3001"
                (Printf.sprintf "`%s` expects an Int64 value, got %s" mname
                   (type_name v))
          | [ v; _ ] ->
              error span "E3001"
                (Printf.sprintf "`%s` expects an Int64 index, got %s" mname
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`%s` expects 2 arguments, got %d" mname
                   (List.length args)))
      | Bytes b, "get_u64_le" -> (
          match eval_args () with
          | [ Int64 i ]
            when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
              let i = Int64.to_int i in
              let acc = ref 0L in
              for k = 7 downto 0 do
                acc :=
                  Int64.logor (Int64.shift_left !acc 8)
                    (Int64.of_int (Char.code (Bytes.get b (i + k))))
              done;
              Int64 !acc
          | [ Int64 i ] ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a get_u64_le read on a \
                    length-%d Bytes"
                   i (Bytes.length b))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`get_u64_le` expects an Int64 index, got %s"
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`get_u64_le` expects 1 argument, got %d"
                   (List.length args)))
      | Bytes b, "set_u64_le" -> (
          match eval_args () with
          | [ Int64 i; Int64 v ]
            when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
              let i = Int64.to_int i in
              for k = 0 to 7 do
                Bytes.set b (i + k)
                  (Char.chr
                     (Int64.to_int
                        (Int64.logand
                           (Int64.shift_right_logical v (8 * k))
                           0xFFL)))
              done;
              Int64 v
          | [ Int64 i; Int64 _ ] ->
              error span "E3004"
                (Printf.sprintf
                   "index %Ld is out of bounds for a set_u64_le write on a \
                    length-%d Bytes"
                   i (Bytes.length b))
          | [ Int64 _; v ] ->
              error span "E3001"
                (Printf.sprintf "`set_u64_le` expects an Int64 value, got %s"
                   (type_name v))
          | [ v; _ ] ->
              error span "E3001"
                (Printf.sprintf "`set_u64_le` expects an Int64 index, got %s"
                   (type_name v))
          | args ->
              error span "E3007"
                (Printf.sprintf "`set_u64_le` expects 2 arguments, got %d"
                   (List.length args)))
      | String s, "to_bytes" ->
          none_expected "to_bytes";
          Bytes (Bytes.of_string s)
      | TcpConn c, "read_line" ->
          none_expected "read_line";
          Effect.perform (Net_read_line (c, span))
      | TcpConn c, "read_exactly" -> (
          match eval_args () with
          | [ Int64 n ] ->
              Effect.perform (Net_read_exactly (c, Int64.to_int n, span))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`read_exactly` expects an Int64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`read_exactly` expects 1 argument, got %d" argc)
          )
      | TcpConn c, "read_all" ->
          none_expected "read_all";
          Effect.perform (Net_read_all (c, span))
      | TcpConn c, "write" -> (
          match eval_args () with
          | [ String s ] -> Effect.perform (Net_write (c, s, span))
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`write` expects a String, got %s" (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`write` expects 1 argument, got %d" argc))
      | TcpConn c, "close" ->
          none_expected "close";
          Effect.perform (Net_close_conn (c, span))
      | TcpConn c, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              c.ctimeout <- f;
              TcpConn c
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | TcpListener l, "accept" ->
          none_expected "accept";
          Effect.perform (Net_accept (l, span))
      | TcpListener { lunix = true; ldesc; _ }, "port" ->
          error span "E3007"
            (Printf.sprintf "a unix-domain listener (%s) has no port" ldesc)
      | TcpListener l, "port" ->
          none_expected "port";
          Int64 (Int64.of_int l.lport)
      | TcpListener l, "close" ->
          none_expected "close";
          Effect.perform (Net_close_listener (l, span))
      | TcpListener l, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              l.ltimeout <- f;
              TcpListener l
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | UdpSocket u, "send_to" -> (
          match eval_args () with
          | [ String host; Int64 port; String data ] ->
              (* The handler resolves the host; failure rides back in
                 the tuple like every other data-driven net failure. *)
              Effect.perform
                (Net_udp_send_to (u, host, Int64.to_int port, data, span))
          | _ ->
              error span "E3007"
                "`send_to` expects (host String, port Int64, data String)")
      | UdpSocket u, "recv_from" ->
          none_expected "recv_from";
          let received = Effect.perform (Net_udp_recv_from (u, span)) in
          received
      | UdpSocket u, "port" ->
          none_expected "port";
          Int64 (Int64.of_int u.uport)
      | UdpSocket u, "close" ->
          none_expected "close";
          Effect.perform (Net_udp_close (u, span))
      | UdpSocket u, "set_timeout" -> (
          match eval_args () with
          | [ Float f ] when f >= 0.0 ->
              u.utimeout <- f;
              UdpSocket u
          | [ Float _ ] -> error span "E3007" "the timeout must not be negative"
          | [ v ] ->
              error span "E3001"
                (Printf.sprintf "`set_timeout` expects a Float64, got %s"
                   (type_name v))
          | _ ->
              error span "E3007"
                (Printf.sprintf "`set_timeout` expects 1 argument, got %d" argc)
          )
      | String s, "length" ->
          none_expected "length";
          Int64 (Int64.of_int (String.length s))
      | String s, "substring" -> (
          match eval_args () with
          | [ Int64 start; Int64 len ]
            when start >= 0L && len >= 0L
                 && Int64.add start len <= Int64.of_int (String.length s) ->
              String (String.sub s (Int64.to_int start) (Int64.to_int len))
          | [ Int64 start; Int64 len ] ->
              error span "E3004"
                (Printf.sprintf
                   "substring (%Ld, %Ld) is out of bounds for a length-%d \
                    String"
                   start len (String.length s))
          | _ ->
              error span "E3007"
                "`substring` expects (start Int64, length Int64)")
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
              Int64
                (Int64.of_int (match find 0 with Some i -> i | None -> -1))
          | _ -> error span "E3007" "`index_of` expects a String needle")
      | String s, "starts_with" -> (
          match eval_args () with
          | [ String prefix ] -> Bool (String.starts_with ~prefix s)
          | _ -> error span "E3007" "`starts_with` expects a String prefix")
      | String s, "to_int64" -> (
          match parse_decimal s with
          | Some n -> Int64 n
          | None ->
              error span "E3007"
                (Printf.sprintf "cannot parse `%s` as an Int64" s))
      | Array xs, "append" -> (
          match eval_args () with
          | [ v ] -> Array (Array.append xs [| v |])
          | _ ->
              error span "E3007"
                (Printf.sprintf "`append` expects 1 argument, got %d" argc))
      | Map m, "get" -> (
          match eval_args () with
          | [ k ] -> map_get span m k
          | args ->
              error span "E3007"
                (Printf.sprintf "`get` expects 1 argument, got %d"
                   (List.length args)))
      | Map m, "set" -> (
          match eval_args () with
          | [ k; v ] ->
              map_set span m k v;
              Map m
          | _ -> error span "E3007" "`set` expects (key, value)")
      | Map m, "has" -> (
          match eval_args () with
          | [ k ] -> Bool (map_key_ok k && Hashtbl.mem m.entries k)
          | args ->
              error span "E3007"
                (Printf.sprintf "`has` expects 1 argument, got %d"
                   (List.length args)))
      | Map m, "remove" -> (
          match eval_args () with
          | [ k ] ->
              if map_key_ok k && Hashtbl.mem m.entries k then (
                Hashtbl.remove m.entries k;
                m.order <-
                  List.filter (fun kk -> not (equal_value kk k)) m.order);
              Map m
          | args ->
              error span "E3007"
                (Printf.sprintf "`remove` expects 1 argument, got %d"
                   (List.length args)))
      | Map m, "length" ->
          none_expected "length";
          Int64 (Int64.of_int (Hashtbl.length m.entries))
      | Map m, "keys" ->
          none_expected "keys";
          Array (Array.of_list (map_keys m))
      | Map m, "values" ->
          none_expected "values";
          Array
            (Array.of_list
               (List.map (fun k -> Hashtbl.find m.entries k) (map_keys m)))
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
  let check_positional kind name =
    List.iter
      (fun (name_, _) ->
        match name_ with
        | Some _ ->
            error span "E3007"
              (Printf.sprintf "%s `%s` takes positional arguments only" kind
                 name)
        | None -> ())
      args
  in
  match f with
  | ArrowBlock closure -> apply_closure closure span args
  | BuiltinFn name ->
      check_positional "builtin" name;
      apply_builtin span name (List.map snd args)
  | RuntimeImplFn name ->
      check_positional "runtime implementation" name;
      apply_runtime_impl span name (List.map snd args)
  | ForeignFn name ->
      error span "E3009"
        (Printf.sprintf
           "the foreign definition `%s` runs only in compiled programs (use \
            emo build)"
           name)
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

(* The os module's syscalls run synchronously; OS failures surface as
   ordinary Emo exceptions with the OS reason attached. *)
(* Unix.file_descr is int-represented in this runtime and the module
   exposes no converters; the interop goes through representation. *)
and fd_int (fd : Unix.file_descr) : int = Obj.magic fd
and fd_of_int (n : int) : Unix.file_descr = Obj.magic n

and os_try span (f : unit -> value) : value =
  match f () with
  | v -> v
  | exception Unix.Unix_error (e, fn, arg) ->
      raise
        (net_raise span
           (Printf.sprintf "os: %s%s: %s" fn
              (if arg = "" then "" else " " ^ arg)
              (Unix.error_message e)))
  | exception Sys_error message -> raise (net_raise span ("os: " ^ message))

(* The data-driven os failures are values: the call answers
   (R.ok, value) or (R.error, reason), the reason the same text the
   exception carried (CHECK.md, error handling). [os_try] remains only
   for the carved-out [waitpid]. *)
and os_result span (f : unit -> value) : value =
  match f () with
  | v -> Tuple [ EnumMember ("R", "ok"); v ]
  | exception Unix.Unix_error (e, fn, arg) ->
      Tuple
        [
          EnumMember ("R", "error");
          String
            (Printf.sprintf "os: %s%s: %s" fn
               (if arg = "" then "" else " " ^ arg)
               (Unix.error_message e));
        ]
  | exception Sys_error message ->
      Tuple [ EnumMember ("R", "error"); String ("os: " ^ message) ]

(* ---- printf ----

   The renderer anchors on C17 §7.21.6.1: the numeric conversions go
   through the platform's snprintf (via Printf), so the interpreter, the
   C target, and the OCaml target agree byte-for-byte by construction.
   `%s` pads by bytes on its own — Emo strings carry explicit lengths and
   may hold NULs, which a C `%s` could not carry across. The `0` flag is
   ignored there (the standard leaves it undefined for `%s`); space
   padding applies. *)

and printf_type_name (v : value) : string =
  match v with
  | Int64 _ -> "Int64"
  | Byte _ -> "Byte"
  | Float _ -> "Float64"
  | Bool _ -> "Bool"
  | Char _ -> "Char"
  | String _ -> "String"
  | Array _ -> "Array"
  | _ -> "value"

and printf_pull span items idx conv =
  if !idx >= Array.length items then assert false;
  let v = items.(!idx) in
  incr idx;
  match (conv, v) with
  | ('*' | 'd' | 'i' | 'u' | 'o' | 'x' | 'X'), Int64 n -> `I64 n
  | ('*' | 'd' | 'i' | 'u' | 'o' | 'x' | 'X'), Byte n -> `I n
  | 'c', Char c -> `C c
  | 'c', Byte n -> `C (Char.chr (n land 255))
  | 'c', Int64 n -> `C (Char.chr (Int64.to_int n land 255))
  | 's', String str -> `S str
  | ('f' | 'F' | 'e' | 'E' | 'g' | 'G'), Float f -> `F f
  | _, v ->
      error span "E3001"
        (Printf.sprintf "printf: `%%%c` expects %s, got %s" conv
           (match conv with
           | 'c' -> "a Char, Byte, or Int64"
           | 's' -> "a String"
           | 'f' | 'F' | 'e' | 'E' | 'g' | 'G' -> "a Float64"
           | _ -> "an Int64")
           (printf_type_name v))

(* C's %F is %f with INF and NAN spelled uppercase. *)
and printf_upper_special (s : string) : string =
  let b = Buffer.create (String.length s) in
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    if !i + 3 <= len && (String.sub s !i 3 = "inf" || String.sub s !i 3 = "nan")
    then begin
      Buffer.add_string b (String.uppercase_ascii (String.sub s !i 3));
      i := !i + 3
    end
    else begin
      Buffer.add_char b s.[!i];
      incr i
    end
  done;
  Buffer.contents b

(* '#' on the float conversions: OCaml's Printf drops the flag, so
   these paths build C's '#'' semantics by hand. f and e need the point
   at precision zero; g re-derives its body from the correctly rounded
   %.Pe digits (the platform's own rounding), keeping every digit. *)
and printf_num_pad sign body width minus zero =
  let total = String.length sign + String.length body in
  if width <= total then sign ^ body
  else begin
    let fill = width - total in
    if minus then sign ^ body ^ String.make fill ' '
    else if zero then sign ^ String.make fill '0' ^ body
    else String.make fill ' ' ^ sign ^ body
  end

and printf_hash_float conv minus plus space letter width prec f =
  let zero = false in
  match conv with
  | 'f' | 'F' ->
      let rendered =
        Printf.sprintf "%.*f" (match prec with Some p -> p | None -> 6) f
      in
      let body =
        match prec with
        | Some 0 when not (String.contains rendered '.') -> rendered ^ "."
        | _ -> rendered
      in
      let sign =
        if body <> "" && body.[0] = '-' then "-"
        else if plus then "+"
        else if space then " "
        else ""
      in
      let body =
        if sign = "-" then String.sub body 1 (String.length body - 1) else body
      in
      printf_num_pad sign body width minus zero
  | 'e' | 'E' ->
      let rendered =
        Printf.sprintf "%.*e" (match prec with Some p -> p | None -> 6) f
      in
      let body =
        match prec with
        | Some 0 when not (String.contains rendered '.') ->
            let epos = String.index rendered 'e' in
            String.sub rendered 0 epos ^ "."
            ^ String.sub rendered epos (String.length rendered - epos)
        | _ -> rendered
      in
      let sign =
        if body <> "" && body.[0] = '-' then "-"
        else if plus then "+"
        else if space then " "
        else ""
      in
      let body =
        if sign = "-" then String.sub body 1 (String.length body - 1) else body
      in
      printf_num_pad sign body width minus zero
  | _ ->
      (* C's %g with '#': the trailing zeros stay. *)
      let p = match prec with Some p -> if p = 0 then 1 else p | None -> 6 in
      let sci = Printf.sprintf "%.*e" (p - 1) f in
      let epos = String.index sci 'e' in
      let mantissa = String.sub sci 0 epos in
      let x =
        int_of_string (String.sub sci (epos + 1) (String.length sci - epos - 1))
      in
      let digits = String.concat "" (String.split_on_char '.' mantissa) in
      let negative = digits <> "" && digits.[0] = '-' in
      let digits =
        if negative then String.sub digits 1 (String.length digits - 1)
        else digits
      in
      let count = String.length digits in
      let body =
        if x >= -4 && x < p then begin
          let point = x + 1 in
          if point <= 0 then "0." ^ String.make (-point) '0' ^ digits
          else if point >= count then digits ^ String.make (point - count) '0'
          else
            String.sub digits 0 point ^ "."
            ^ String.sub digits point (count - point)
        end
        else begin
          let frac =
            if count > 1 then String.sub digits 1 (count - 1) else ""
          in
          let e = if conv = 'G' then "E" else "e" in
          let a = abs x in
          let xstr =
            (if x < 0 then "-" else "+")
            ^ (if a < 10 then "0" else "")
            ^ string_of_int a
          in
          if count > 1 then String.make 1 digits.[0] ^ "." ^ frac ^ e ^ xstr
          else String.make 1 digits.[0] ^ e ^ xstr
        end
      in
      let sign =
        if negative then "-"
        else if plus then "+"
        else if space then " "
        else ""
      in
      ignore letter;
      printf_num_pad sign body width minus zero

and printf_render span (fmt : string) (items : value array) : string =
  let parts =
    try Emo_support.Printf_format.parse fmt
    with Emo_support.Printf_format.Bad message -> error span "E3001" message
  in
  let slots = Emo_support.Printf_format.consumed_slots parts in
  if slots <> Array.length items then
    error span "E3001"
      (Printf.sprintf
         "printf: the format consumes %d argument(s), the array has %d \
          element(s)"
         slots (Array.length items));
  let buf = Buffer.create (String.length fmt * 2) in
  let idx = ref 0 in
  (* One numeric conversion through snprintf with a constructed C
     format; [template] types the dynamic format for the checker. *)
  let via_snprintf template flags width prec (letter : string) value =
    let b = Buffer.create 16 in
    Buffer.add_char b '%';
    Buffer.add_string b flags;
    if width > 0 then Buffer.add_string b (string_of_int width);
    (match prec with
    | Some p ->
        Buffer.add_char b '.';
        Buffer.add_string b (string_of_int p)
    | None -> ());
    Buffer.add_string b letter;
    Printf.sprintf (Scanf.format_from_string (Buffer.contents b) template) value
  in
  let pad body width minus =
    let missing = width - String.length body in
    if missing <= 0 then Buffer.add_string buf body
    else if minus then begin
      Buffer.add_string buf body;
      Buffer.add_string buf (String.make missing ' ')
    end
    else begin
      Buffer.add_string buf (String.make missing ' ');
      Buffer.add_string buf body
    end
  in
  List.iter
    (fun part ->
      match part with
      | Emo_support.Printf_format.Text text -> Buffer.add_string buf text
      | Emo_support.Printf_format.Spec s when s.conv = '%' ->
          Buffer.add_char buf '%'
      | Emo_support.Printf_format.Spec s -> (
          let minus = ref s.minus in
          let width =
            match s.width with
            | Some Star -> (
                match printf_pull span items idx '*' with
                | `I64 n ->
                    let w = Int64.to_int n in
                    if w < 0 then begin
                      minus := true;
                      -w
                    end
                    else w
                | `I n ->
                    if n < 0 then (
                      minus := true;
                      -n)
                    else n
                | _ -> assert false)
            | Some (Fixed n) -> n
            | None -> 0
          in
          let prec =
            match s.prec with
            | Some Star -> (
                match printf_pull span items idx '*' with
                | `I64 n ->
                    let p = Int64.to_int n in
                    if p < 0 then None else Some p
                | `I n -> if n < 0 then None else Some n
                | _ -> assert false)
            | Some (Fixed p) -> Some p
            | None -> None
          in
          let flags =
            let b = Buffer.create 8 in
            if !minus then Buffer.add_char b '-';
            if s.plus then Buffer.add_char b '+';
            if s.space then Buffer.add_char b ' ';
            if s.hash then Buffer.add_char b '#';
            (* '-' wins over '0', per C. *)
            if s.zero && not !minus then Buffer.add_char b '0';
            Buffer.contents b
          in
          match printf_pull span items idx s.conv with
          | `I64 n ->
              let letter =
                match s.conv with
                | 'd' | 'i' -> "d"
                | 'u' -> "u"
                | 'o' -> "o"
                | 'x' -> "x"
                | c -> String.make 1 c
              in
              pad
                (via_snprintf "%Ld" flags width prec ("L" ^ letter) n)
                width !minus
          | `I n ->
              let letter =
                match s.conv with 'd' | 'i' -> "d" | c -> String.make 1 c
              in
              pad (via_snprintf "%d" flags width prec letter n) width !minus
          | `C c -> pad (String.make 1 c) width !minus
          | `S str ->
              let body =
                match prec with
                | Some p when p < String.length str -> String.sub str 0 p
                | _ -> str
              in
              pad body width !minus
          | `F f ->
              let letter = if s.conv = 'F' then "f" else String.make 1 s.conv in
              let rendered =
                if s.hash then
                  printf_hash_float s.conv !minus s.plus s.space letter width
                    prec f
                else via_snprintf "%f" flags width prec letter f
              in
              let rendered =
                if s.conv = 'F' then printf_upper_special rendered else rendered
              in
              pad rendered width !minus))
    parts;
  Buffer.contents buf

and apply_builtin span name args =
  match (name, args) with
  | "println", [ v ] ->
      !output (to_string v ^ "\n");
      v
  | "println", vs ->
      error span "E3007"
        (Printf.sprintf "`println` expects 1 argument, got %d" (List.length vs))
  | "printf", [ String fmt; Array items ] ->
      !output (printf_render span fmt items);
      Void
  | "printf", [ _; _ ] ->
      error span "E3001" "`printf` expects (format String, data Array)"
  | "printf", vs ->
      error span "E3007"
        (Printf.sprintf "`printf` expects 2 arguments, got %d" (List.length vs))
  (* ---- the expect builtins: test assertions. A failure raises an
     ordinary Emo exception; the `emo test` runner traps it per test. ---- *)
  | "expect_equal", [ expected; actual ] ->
      if not (equal_value expected actual) then
        raise
          (expect_raise span
             (Printf.sprintf "expect_equal: expected %s, got %s"
                (to_string expected) (to_string actual)));
      Void
  | "expect_equal", vs ->
      error span "E3007"
        (Printf.sprintf "`expect_equal` expects 2 arguments, got %d"
           (List.length vs))
  | "expect_true", [ Bool true ] -> Void
  | "expect_true", [ Bool false ] ->
      raise (expect_raise span "expect_true: got false")
  | "expect_true", [ v ] ->
      error span "E3001"
        (Printf.sprintf "`expect_true` expects a Bool, got %s" (type_name v))
  | "expect_true", vs ->
      error span "E3007"
        (Printf.sprintf "`expect_true` expects 1 argument, got %d"
           (List.length vs))
  | "expect_false", [ Bool false ] -> Void
  | "expect_false", [ Bool true ] ->
      raise (expect_raise span "expect_false: got true")
  | "expect_false", [ v ] ->
      error span "E3001"
        (Printf.sprintf "`expect_false` expects a Bool, got %s" (type_name v))
  | "expect_false", vs ->
      error span "E3007"
        (Printf.sprintf "`expect_false` expects 1 argument, got %d"
           (List.length vs))
  | "expect_fail", [ String message ] -> raise (expect_raise span message)
  | "expect_fail", [ v ] ->
      error span "E3001"
        (Printf.sprintf "`expect_fail` expects a String message, got %s"
           (type_name v))
  | "expect_fail", vs ->
      error span "E3007"
        (Printf.sprintf "`expect_fail` expects 1 argument, got %d"
           (List.length vs))
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
  | "fence", [] ->
      (* The exact no-op (CHECK.md, the atomic memory model): every Emo
         process here cooperates on one OS thread and switches only at
         defined points, so sequential consistency holds vacuously and
         the barrier is a correct lowering of nothing to do. *)
      Void
  | "fence", vs ->
      error span "E3007"
        (Printf.sprintf "`fence` expects no arguments, got %d" (List.length vs))
  | (("peek8" | "poke8" | "peek64" | "poke64" | "device_wait") as name), _ ->
      error span "E4028"
        (Printf.sprintf
           "`%s` reaches raw memory: only the `riscv64` target admits it, not \
            the interpreter"
           name)
  | _, _ -> error span "E3007" (Printf.sprintf "unknown builtin `%s`" name)

(* The standard library's runtime implementations — what a package's own
   Emo source calls underneath its API. Every arm here is named for the
   package that owns it. *)
and apply_runtime_impl span name args =
  match (name, args) with
  | "net_connect", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_connect` expects (host String, port Int64, timeout Float), \
            got %d arguments"
           (List.length args))
  | "net_connect", [ String host; Int64 port; Float timeout ] ->
      (* The handler resolves the host, then connects; failure rides
         back in the tuple. *)
      Effect.perform (Net_connect (host, Int64.to_int port, timeout, span))
  | "net_resolve", [ String host ] -> Effect.perform (Net_resolve (host, span))
  | "net_resolve", vs ->
      error span "E3007"
        (Printf.sprintf "`net_resolve` expects 1 argument, got %d"
           (List.length vs))
  | "net_connect", _ ->
      error span "E3001"
        "`net_connect` expects (host String, port Int64, timeout Float)"
  | "net_listen", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen` expects (host String, port Int64), got %d arguments"
           (List.length args))
  | "net_listen", [ String host; Int64 port ] ->
      Effect.perform (Net_listen (host, Int64.to_int port, span))
  | "net_listen", _ ->
      error span "E3001" "`net_listen` expects (host String, port Int64)"
  | "net_udp_bind", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_udp_bind` expects (host String, port Int64), got %d arguments"
           (List.length args))
  | "net_udp_bind", [ String host; Int64 port ] ->
      Effect.perform (Net_udp_bind (host, Int64.to_int port, span))
  | "net_udp_bind", _ ->
      error span "E3001" "`net_udp_bind` expects (host String, port Int64)"
  | "file_read", args when List.length args <> 1 ->
      error span "E3007"
        (Printf.sprintf "`file_read` expects (path String), got %d arguments"
           (List.length args))
  | "file_read", [ String path ] -> Effect.perform (File_read (path, span))
  | "file_read", [ v ] ->
      error span "E3001"
        (Printf.sprintf "`file_read` expects a String path, got %s"
           (type_name v))
  | "file_write", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`file_write` expects (path String, contents String), got \
            %d             arguments"
           (List.length args))
  | "file_write", [ String path; String contents ] ->
      Effect.perform (File_write (path, contents, span))
  | "file_write", [ String _; v ] ->
      error span "E3001"
        (Printf.sprintf "`file_write` expects String contents, got %s"
           (type_name v))
  | "file_write", [ v; _ ] ->
      error span "E3001"
        (Printf.sprintf "`file_write` expects a String path, got %s"
           (type_name v))
  (* ---- the os module: synchronous POSIX syscalls (fork, unbuffered
     file descriptors, directories, pipes). Every failure raises an
     ordinary Emo exception carrying the OS reason. ---- *)
  | "os_getpid", [] -> Int64 (Int64.of_int (Unix.getpid ()))
  | "os_getpid", vs ->
      error span "E3007"
        (Printf.sprintf "`os_getpid` expects no arguments, got %d"
           (List.length vs))
  | "os_getppid", [] -> Int64 (Int64.of_int (Unix.getppid ()))
  | "os_getppid", vs ->
      error span "E3007"
        (Printf.sprintf "`os_getppid` expects no arguments, got %d"
           (List.length vs))
  | "os_fork", [] ->
      os_result span (fun () -> Int64 (Int64.of_int (Unix.fork ())))
  | "os_fork", vs ->
      error span "E3007"
        (Printf.sprintf "`os_fork` expects no arguments, got %d"
           (List.length vs))
  | "os_waitpid", [ Int64 pid ] ->
      os_try span (fun () ->
          let wpid, status = Unix.waitpid [] (Int64.to_int pid) in
          (* The kernel's raw 16-bit wait encoding, so the Emo-level
             decoders (exited / exit code / signal) are portable. *)
          let raw =
            match status with
            | WEXITED code -> Int64.shift_left (Int64.of_int code) 8
            | WSIGNALED sgn -> Int64.of_int sgn
            | WSTOPPED sgn ->
                Int64.logor (Int64.shift_left (Int64.of_int sgn) 8) 127L
          in
          Tuple [ Int64 (Int64.of_int wpid); Int64 raw ])
  | "os_waitpid", vs ->
      error span "E3007"
        (Printf.sprintf "`os_waitpid` expects (pid Int64), got %d"
           (List.length vs))
  | "os_pipe", [] ->
      os_result span (fun () ->
          let r, w = Unix.pipe () in
          Tuple
            [ Int64 (Int64.of_int (fd_int r)); Int64 (Int64.of_int (fd_int w)) ])
  | "os_pipe", vs ->
      error span "E3007"
        (Printf.sprintf "`os_pipe` expects no arguments, got %d"
           (List.length vs))
  | "os_execv", [ String path; Array items ] -> (
      (* Success never returns — the process is replaced. Failure is a
         data-driven value: the call returns Void, and the fork child
         follows it with `_exit` (the POSIX idiom; a raise here would
         run the parent's cleanup a second time). *)
      try
        let argv = Array.of_list (List.map to_string (Array.to_list items)) in
        Unix.execv path argv
      with Unix.Unix_error _ -> Void)
  | "os_execv", vs ->
      error span "E3007"
        (Printf.sprintf
           "`os_execv` expects (path String, argv Array String), got %d \
            arguments"
           (List.length vs))
  | "os__exit", [ Int64 status ] ->
      (* Never returns: the fork child leaves without at_exit flushes. *)
      let (_ : unit) = Unix._exit (Int64.to_int status) in
      raise Halt_signal
  | "os__exit", vs ->
      error span "E3007"
        (Printf.sprintf "`os__exit` expects (status Int64), got %d"
           (List.length vs))
  | "os_open_read", [ String path ] ->
      os_result span (fun () ->
          Int64 (Int64.of_int (fd_int (Unix.openfile path [ O_RDONLY ] 0))))
  | "os_open_read", vs ->
      error span "E3007"
        (Printf.sprintf "`os_open_read` expects (path String), got %d"
           (List.length vs))
  | "os_open_write", [ String path ] ->
      os_result span (fun () ->
          Int64
            (Int64.of_int
               (fd_int
                  (Unix.openfile path [ O_WRONLY; O_CREAT; O_TRUNC ] 0o644))))
  | "os_open_write", vs ->
      error span "E3007"
        (Printf.sprintf "`os_open_write` expects (path String), got %d"
           (List.length vs))
  | "os_open_append", [ String path ] ->
      os_result span (fun () ->
          Int64
            (Int64.of_int
               (fd_int
                  (Unix.openfile path [ O_WRONLY; O_CREAT; O_APPEND ] 0o644))))
  | "os_open_append", vs ->
      error span "E3007"
        (Printf.sprintf "`os_open_append` expects (path String), got %d"
           (List.length vs))
  | "os_read", [ Int64 fd; Int64 n ] ->
      if n < 0L then error span "E3007" "`os_read` expects a non-negative count"
      else
        os_result span (fun () ->
            let buf = Bytes.create (Int64.to_int n) in
            let got =
              Unix.read (fd_of_int (Int64.to_int fd)) buf 0 (Int64.to_int n)
            in
            String (Bytes.sub_string buf 0 got))
  | "os_read", vs ->
      error span "E3007"
        (Printf.sprintf "`os_read` expects (fd Int64, n Int64), got %d"
           (List.length vs))
  | "os_write", [ Int64 fd; String data ] ->
      os_result span (fun () ->
          let bytes = Bytes.of_string data in
          Int64
            (Int64.of_int
               (Unix.write
                  (fd_of_int (Int64.to_int fd))
                  bytes 0 (Bytes.length bytes))))
  | "os_write", vs ->
      error span "E3007"
        (Printf.sprintf "`os_write` expects (fd Int64, data String), got %d"
           (List.length vs))
  | "os_close", [ Int64 fd ] ->
      os_result span (fun () ->
          Unix.close (fd_of_int (Int64.to_int fd));
          Int64 0L)
  | "os_close", vs ->
      error span "E3007"
        (Printf.sprintf "`os_close` expects (fd Int64), got %d" (List.length vs))
  | "os_list_dir", [ String path ] ->
      os_result span (fun () ->
          (* opendir, not Sys.readdir: the failure rides the Unix_error
             branch, so the reason names the call (`os: opendir p: ...`)
             — the text the c runtime prints for the same miss. *)
          let dir = Unix.opendir path in
          let rec collect acc =
            match Unix.readdir dir with
            | "." | ".." -> collect acc
            | name -> collect (name :: acc)
            | exception End_of_file ->
                Unix.closedir dir;
                Array.of_list (List.rev acc)
          in
          let names = collect [] in
          Array.sort compare names;
          Array (Array.map (fun s -> String s) names))
  | "os_list_dir", vs ->
      error span "E3007"
        (Printf.sprintf "`os_list_dir` expects (path String), got %d"
           (List.length vs))
  | "os_mkdir", [ String path ] ->
      os_result span (fun () ->
          Unix.mkdir path 0o755;
          Int64 0L)
  | "os_mkdir", vs ->
      error span "E3007"
        (Printf.sprintf "`os_mkdir` expects (path String), got %d"
           (List.length vs))
  | "os_rmdir", [ String path ] ->
      os_result span (fun () ->
          Unix.rmdir path;
          Int64 0L)
  | "os_rmdir", vs ->
      error span "E3007"
        (Printf.sprintf "`os_rmdir` expects (path String), got %d"
           (List.length vs))
  | "os_unlink", [ String path ] ->
      os_result span (fun () ->
          Unix.unlink path;
          Int64 0L)
  | "os_unlink", vs ->
      error span "E3007"
        (Printf.sprintf "`os_unlink` expects (path String), got %d"
           (List.length vs))
  | "os_rename", [ String old_path; String new_path ] ->
      os_result span (fun () ->
          Unix.rename old_path new_path;
          Int64 0L)
  | "os_rename", vs ->
      error span "E3007"
        (Printf.sprintf
           "`os_rename` expects (old_path String, new_path String), got %d"
           (List.length vs))
  | "os_getcwd", [] -> String (Sys.getcwd ())
  | "os_getcwd", vs ->
      error span "E3007"
        (Printf.sprintf "`os_getcwd` expects no arguments, got %d"
           (List.length vs))
  | "os_chdir", [ String path ] ->
      os_result span (fun () ->
          Unix.chdir path;
          Int64 0L)
  | "os_chdir", vs ->
      error span "E3007"
        (Printf.sprintf "`os_chdir` expects (path String), got %d"
           (List.length vs))
  | "net_connect_unix", args when List.length args <> 2 ->
      error span "E3007"
        (Printf.sprintf
           "`net_connect_unix` expects (path String, timeout Float64), got \
            %d             arguments"
           (List.length args))
  | "net_connect_unix", [ String path; Float timeout ] ->
      Effect.perform (Net_connect_unix (path, timeout, span))
  | "net_connect_unix", _ ->
      error span "E3001"
        "`net_connect_unix` expects (path String, timeout Float64)"
  | "net_listen_unix", args when List.length args <> 1 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen_unix` expects (path String), got %d arguments"
           (List.length args))
  | "net_listen_unix", [ String path ] ->
      Effect.perform (Net_listen_unix (path, span))
  | "net_listen_unix", _ ->
      error span "E3001" "`net_listen_unix` expects (path String)"
  | "net_tls_connect", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_tls_connect` expects (host String, port Int64, timeout \
            Float64),             got %d arguments"
           (List.length args))
  | "net_tls_connect", [ String host; Int64 port; Float timeout ] ->
      (* The handler resolves the host, then connects and shakes hands;
         failure rides back in the tuple. *)
      Effect.perform
        (Net_tls_connect
           (host, Int64.to_int port, timeout, default_tls_client_options, span))
  | "net_tls_connect", _ ->
      error span "E3001"
        "`net_tls_connect` expects (host String, port Int64, timeout Float64)"
  | "net_tls_connect_insecure", args when List.length args <> 3 ->
      error span "E3007"
        (Printf.sprintf
           "`net_tls_connect_insecure` expects (host String, port Int64, \
            timeout             Float64), got %d arguments"
           (List.length args))
  | "net_tls_connect_insecure", [ String host; Int64 port; Float timeout ] ->
      Effect.perform
        (Net_tls_connect
           ( host,
             Int64.to_int port,
             timeout,
             { default_tls_client_options with tls_insecure = true },
             span ))
  | "net_tls_connect_insecure", _ ->
      error span "E3001"
        "`net_tls_connect_insecure` expects (host String, port Int64, \
         timeout          Float64)"
  | "net_tls_connect_with", args when List.length args <> 8 ->
      error span "E3007"
        (Printf.sprintf
           "`net_tls_connect_with` expects (host String, port Int64, timeout \
            Float64, ca_file String, client_cert_file String, client_key_file \
            String, server_name String, insecure Bool), got %d arguments"
           (List.length args))
  | ( "net_tls_connect_with",
      [
        String host;
        Int64 port;
        Float timeout;
        String ca_file;
        String cert_file;
        String key_file;
        String server_name;
        Bool insecure;
      ] ) ->
      Effect.perform
        (Net_tls_connect
           ( host,
             Int64.to_int port,
             timeout,
             {
               tls_ca_file = ca_file;
               tls_client_cert_file = cert_file;
               tls_client_key_file = key_file;
               tls_server_name = server_name;
               tls_insecure = insecure;
             },
             span ))
  | "net_tls_connect_with", _ ->
      error span "E3001"
        "`net_tls_connect_with` expects (host String, port Int64, timeout \
         Float64, ca_file String, client_cert_file String, client_key_file \
         String, server_name String, insecure Bool)"
  | "net_listen_tls", args when List.length args <> 4 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen_tls` expects (host String, port Int64, cert_path \
            String,             key_path String), got %d arguments"
           (List.length args))
  | "net_listen_tls", [ String host; Int64 port; String cert; String key ] ->
      Effect.perform
        (Net_tls_listen
           (host, Int64.to_int port, cert, key, default_tls_server_options, span))
  | "net_listen_tls", _ ->
      error span "E3001"
        "`net_listen_tls` expects (host String, port Int64, cert_path \
         String,          key_path String)"
  | "net_listen_tls_with", args when List.length args <> 6 ->
      error span "E3007"
        (Printf.sprintf
           "`net_listen_tls_with` expects (host String, port Int64, cert_path \
            String, key_path String, ca_file String, require_client_cert \
            Bool), got %d arguments"
           (List.length args))
  | ( "net_listen_tls_with",
      [
        String host;
        Int64 port;
        String cert;
        String key;
        String ca_file;
        Bool require_client_cert;
      ] ) ->
      Effect.perform
        (Net_tls_listen
           ( host,
             Int64.to_int port,
             cert,
             key,
             {
               tls_client_ca_file = ca_file;
               tls_require_client_cert = require_client_cert;
             },
             span ))
  | "net_listen_tls_with", _ ->
      error span "E3001"
        "`net_listen_tls_with` expects (host String, port Int64, cert_path \
         String, key_path String, ca_file String, require_client_cert Bool)"
  | _, _ ->
      error span "E3007"
        (Printf.sprintf "unknown runtime implementation `%s`" name)

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
                if closure.void_ok then Void
                else
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
        | Break_signal | Continue_signal ->
            (* The checker refuses `break` outside a loop and across a
               closure; this is the boundary for anything unchecked. *)
            error span "E3014"
              "`break` and `continue` leave a loop; none encloses this call"
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
  | Ast.Binding { mutable_; pattern; init } -> (
      match pattern.Ast.pattern_desc with
      | Ast.Pattern_binding name ->
          define env name ~mutable_ (eval_expr env init)
      | _ ->
          (* A destructured binding binds like a one-arm case whose match
             lands in this scope; a value matching nothing dies the
             case-no-match death. *)
          let v = eval_expr env init in
          if not (match_pattern env span pattern v) then
            error span "E3006"
              (Printf.sprintf "no `case` branch matched this %s value"
                 (type_name v)))
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
      (* The checker's raise discipline, at run time — the paths that
         skip static checking (the REPL, unchecked embedding) answer to
         the same rule. *)
      (match v with
      | Instance i when i.iclass.builtin_exception -> ()
      | other ->
          error span "E4024"
            (Printf.sprintf "`raise` carries an `Exception` instance, got %s"
               (type_name other)));
      raise (Emo_raise (v, span, !call_trace))
  | Ast.While { cond; body } -> (
      (* The iteration is this OCaml loop, not recursion: a self tail
         call compiles to a jump, so ten million iterations stay flat.
         Each iteration runs its body in a fresh child frame, and the
         step budget counts every iteration. *)
      let rec iterate () =
        count_step ();
        match eval_expr env cond with
        | Bool true ->
            let body_env = child env in
            (try List.iter (eval_stmt body_env) body
             with Continue_signal -> ());
            iterate ()
        | Bool false -> ()
        | v ->
            error cond.Ast.span "E3001"
              (Printf.sprintf "the `while` condition must be a Bool, got %s"
                 (type_name v))
      in
      try iterate () with Break_signal -> ())
  | Ast.For { init; cond; post; body } -> (
      (* The header `var` is one binding across the loop; the body's
         frame is fresh every iteration. `continue` still runs the post
         clause — the update is the loop's, not the body's. *)
      let loop_env = child env in
      eval_stmt loop_env init;
      let rec iterate () =
        count_step ();
        match eval_expr loop_env cond with
        | Bool true ->
            let body_env = child loop_env in
            (try List.iter (eval_stmt body_env) body
             with Continue_signal -> ());
            eval_stmt loop_env post;
            iterate ()
        | Bool false -> ()
        | v ->
            error cond.Ast.span "E3001"
              (Printf.sprintf "the `for` condition must be a Bool, got %s"
                 (type_name v))
      in
      try iterate () with Break_signal -> ())
  | Ast.Break -> raise Break_signal
  | Ast.Continue -> raise Continue_signal

and eval_expr env e =
  count_step ();
  let span = e.Ast.span in
  match e.Ast.desc with
  | Ast.Int64 n -> Int64 n
  | Ast.Byte n -> Byte n
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
      | TypeValue t -> (
          (* A cross-module enum: the bare name binds only in its own
             module's environment, so member access resolves through the
             program's owner index (CHECK.md, cross-module types). *)
          match !type_owner_of t with
          | Some (EnumType e) -> (
              match List.assoc_opt name e.emembers with
              | Some v -> v
              | None ->
                  error span "E3007"
                    (Printf.sprintf "enum `%s` has no member `%s`" e.ename name)
              )
          | _ ->
              error span "E3007"
                "a member access must be a call, like `x.read()`")
      | _ ->
          error span "E3007" "a member access must be a call, like `x.read()`")
  | Ast.Index (base, index) -> eval_index env span base index
  | Ast.Tuple es -> Tuple (List.map (eval_expr env) es)
  | Ast.Array_literal es -> Array (Array.of_list (List.map (eval_expr env) es))
  | Ast.Map_literal entries ->
      let m = fresh_map () in
      List.iter
        (fun (k, v) ->
          let key = eval_expr env k in
          let value = eval_expr env v in
          map_set span m key value)
        entries;
      Map m
  | Ast.Arrow_block (params, body) ->
      ArrowBlock
        { def_name = "<arrow block>"; params; body; env; void_ok = true }
  | Ast.Unary (op, x) -> eval_unary env span op x
  | Ast.Binary (op, l, r) -> eval_binary env span op l r
  | Ast.If_expr { cond; then_expr; else_expr } -> (
      match eval_expr env cond with
      | Bool true -> eval_expr env then_expr
      | Bool false -> eval_expr env else_expr
      | v ->
          error span "E3001"
            (Printf.sprintf
               "the if expression's condition must be a Bool, got %s"
               (type_name v)))
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

(* A def whose signature declares no return type — or declares Void —
   ends without `return`; the checker rejects any `return` in such a
   body, so falling off the end is the normal exit. *)
let may_end_without_return (d : Ast.fun_def) =
  match d.Ast.def_return with
  | None -> true
  | Some { Ast.type_desc = Ast.Named_type "Void"; _ } -> true
  | Some _ -> false

(* Rendering calls a class's `to_string` the way any method call does:
   an empty argument frame, `self` bound to the instance. *)
let () =
  call_to_string :=
    fun i closure ->
      let span = Emo_support.Span.zero in
      let frame = bind_params closure span [] in
      define frame "self" ~mutable_:false (Instance i);
      eval_frame closure frame span

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
    void_ok = may_end_without_return d;
  }

(* Type identity is the qualified name — `sync.WaitGroup` — so two
   modules may declare the same short name; the runtime keys classes,
   enums, and interfaces by it. A closure's body resolves its module's
   own declarations through the env (bare), so only the identity carries
   the prefix. *)
let qualify_ename (module_path : string list) (name : string) : string =
  if module_path = [] then name else String.concat "." (module_path @ [ name ])

let eval_item ?(module_path = []) env item =
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
             void_ok = may_end_without_return d;
           })
  | Ast.Item_class c ->
      let cname = qualify_ename module_path c.Ast.class_name in
      define env c.Ast.class_name ~mutable_:false
        (ClassDef
           {
             cname;
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
      let iname = qualify_ename module_path i.Ast.interface_name in
      let sigs =
        List.map
          (fun s -> (s.Ast.sig_name, List.length s.Ast.sig_params))
          i.Ast.interface_methods
      in
      Hashtbl.replace interface_registry iname sigs;
      define env i.Ast.interface_name ~mutable_:false (TypeValue iname)
  | Ast.Item_enum e ->
      let ename = qualify_ename module_path e.Ast.enum_name in
      let members =
        List.map
          (fun m -> (m.Ast.member_name, EnumMember (ename, m.Ast.member_name)))
          e.Ast.enum_members
      in
      define env e.Ast.enum_name ~mutable_:false
        (EnumType { ename; emembers = members })
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
                 void_ok = may_end_without_return d;
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
      (* Inert at load time: a package may declare a native binding on
         every target it names, and only a call to it is a mistake. *)
      define env f.Ast.foreign_name ~mutable_:false
        (ForeignFn f.Ast.foreign_name)

(* Restricted-profile schema errors: the manifest reader maps them onto the
   E51xx codes. A field defined twice, and a value that is not literal data
   (the manifest is data, not program logic). *)
exception Duplicate_field of string
exception Impure_field of string

(* A manifest block's shape: a deps entry names its package with a string
   literal, while a package field's name is a bare identifier. *)
type manifest_shape =
  | Dep_key_empty
  | Dep_key_not_string
  | Field_name_not_ident
  | Dep_entry_expected

exception Manifest_shape_error of manifest_shape * Emo_support.Span.t

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
      | Ast.String _ | Ast.Float _ | Ast.Bool _ | Ast.Char _ -> true
      | Ast.Array_literal es -> List.for_all go es
      | _ -> false
    in
    go e
  in
  let field_target (s : Ast.stmt) =
    match s.Ast.stmt_desc with
    | Ast.Binding
        {
          pattern = { Ast.pattern_desc = Ast.Pattern_binding name; _ };
          init;
          _;
        } ->
        Some (name, init)
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
  (* A deps entry names its package with a string literal, as `require` does.
     Anything else in the block is a mistake the reader must be told about. *)
  let dep_entry (s : Ast.stmt) =
    match s.Ast.stmt_desc with
    | Ast.Assign { target = { Ast.desc = Ast.String ""; _ }; _ } ->
        raise (Manifest_shape_error (Dep_key_empty, s.Ast.stmt_span))
    | Ast.Assign { target = { Ast.desc = Ast.String name; _ }; value } ->
        (name, value)
    | Ast.Assign _ | Ast.Binding _ ->
        raise (Manifest_shape_error (Dep_key_not_string, s.Ast.stmt_span))
    | _ -> raise (Manifest_shape_error (Dep_entry_expected, s.Ast.stmt_span))
  in
  let handle_stmt (s : Ast.stmt) =
    match s.Ast.stmt_desc with
    | Ast.Assign { target = { Ast.desc = Ast.String _; _ }; _ } ->
        raise (Manifest_shape_error (Field_name_not_ident, s.Ast.stmt_span))
    | _ -> (
        match field_target s with
        | Some (name, init) -> define_field env name init
        | None -> ())
  in
  let rec handle_block name body =
    if name = "deps" then
      List.iter
        (fun s ->
          let name, init = dep_entry s in
          add_dep name init)
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
  reset_program_registries ();
  call_trace := [];
  let env = global_env () in
  (* Unscheduled runs refuse the process operations with E3009. *)
  try run_without_scheduler (fun () -> List.iter (eval_item env) items)
  with Emo_raise (v, span, trace) ->
    raise (Error (uncaught_diagnostic (v, span, trace)))

(* Bridge compiled code into each population's surface: the same argument
   shapes and runtime errors as interpreted calls. *)
let native_span =
  Emo_support.Span.make ~file:"<native>" ~line:1 ~col:1 ~start:0 ~stop:0

let call_builtin (name : string) (args : value list) : value =
  apply_builtin native_span name args

let call_runtime_impl (name : string) (args : value list) : value =
  apply_runtime_impl native_span name args

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

   Each performs its effect and hands back the final (R.ok, ...) /
   (R.error, ...) tuple the driver built; they only run under the
   scheduler, exactly like the interpreted paths. *)

let read_line_sync (c : conn) : value =
  Effect.perform (Net_read_line (c, Emo_support.Span.zero))

let read_exactly_sync (c : conn) (n : int) : value =
  Effect.perform (Net_read_exactly (c, n, Emo_support.Span.zero))

let read_all_sync (c : conn) : value =
  Effect.perform (Net_read_all (c, Emo_support.Span.zero))

let write_sync (c : conn) (data : string) : value =
  Effect.perform (Net_write (c, data, Emo_support.Span.zero))

let close_sync (c : conn) : value =
  Effect.perform (Net_close_conn (c, Emo_support.Span.zero))

let accept_sync (l : listener) : value =
  Effect.perform (Net_accept (l, Emo_support.Span.zero))

let close_listener_sync (l : listener) : value =
  Effect.perform (Net_close_listener (l, Emo_support.Span.zero))

let udp_send_sync (u : udp) (host : string) (port : int) (data : string) : value
    =
  Effect.perform (Net_udp_send_to (u, host, port, data, Emo_support.Span.zero))

let udp_recv_sync (u : udp) : value =
  Effect.perform (Net_udp_recv_from (u, Emo_support.Span.zero))

let udp_close_sync (u : udp) : value =
  Effect.perform (Net_udp_close (u, Emo_support.Span.zero))

let net_resolve_sync (host : string) : value =
  Effect.perform (Net_resolve (host, Emo_support.Span.zero))

let net_connect_sync (host : string) (port : int) (timeout : float) : value =
  Effect.perform (Net_connect (host, port, timeout, Emo_support.Span.zero))

let net_listen_sync (host : string) (port : int) : value =
  Effect.perform (Net_listen (host, port, Emo_support.Span.zero))

(* Runs a whole file: declarations register, statements execute in order. *)
let run_program ~file ~source =
  run_items (Emo_parser.parse_program ~file ~source)
