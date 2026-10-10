(* The C backend: the IR lowered to one C translation unit that the
   system cc compiles next to the Emo runtime sources into a single
   standalone binary — no OCaml runtime (plan/step-24-c-target.md;
   docs/native-backend.md records the emit-and-delegate precedent).

   The two-world structure starts at the signature: native types cross
   as C scalars, and the dynamic world's tagged word arrives with its
   task (T24.4).

   Tail calls lower explicitly (CHECK.md): a self-tail call is a
   parameter rebind and a jump to the function head; a mutual-tail
   cluster — a cycle in the tail-call graph — merges into one C
   function, so every edge on the cycle is a rebind and a jump, giving
   constant stack without betting on cc's TCO. A cross-function tail
   call that is not on a cycle returns the callee's value through the
   epilogue; such chains are acyclic, so the stack stays bounded.
   `return` is always a branch to the epilogue, never a raised signal.
   Int64 arithmetic wraps: +, -, *, and unary minus go through
   uint64_t; division and remainder guard INT64_MIN / -1 in the
   runtime. *)

module Ast = Emo_ast

(* The runtime sources, carried as generated data so the backend works
   wherever the compiler runs — no file lookup against the
   installation. *)
let runtime_c = Emo_c_runtime_data.runtime_c
let runtime_h = Emo_c_runtime_data.runtime_h

type env = {
  mutable buf : Buffer.t;
  mutable fresh : int; (* unique temporaries, for tail-call rebinds *)
  mutable scope : (string * string * Emo_check.t) list;
      (* Emo name → (C name, bound type), innermost first: parameters
         and lets — the type drives the regime at assignment *)
  fname : string; (* the function whose body is being emitted *)
  fresult : Emo_check.t;
  tail_rebinds : (string * (string * Emo_check.t) list) list;
      (* callee name → its parameter C names/types, for the rebind;
         the self entry and every cluster sibling are here *)
  in_main : bool; (* the entry module's top level: no `return` *)
  fclass : string option;
      (* the mangled class name when emitting a
                             method or constructor: `self` resolves
                             fields against it *)
  funsigs : (string, (string * Emo_check.t) list * Emo_check.t) Hashtbl.t;
      (* every function's parameter types and result: call sites
         convert arguments and the result between the callee's
         declared regime and the use site's *)
  classes : (string, Emo_ir.class_) Hashtbl.t; (* mangled class name → its IR *)
  ifaces : (string, (string * int) list) Hashtbl.t;
      (* interface name → its method name/arity contract *)
  fields : (string, string list) Hashtbl.t;
      (* mangled class name → field names, init-assignment order *)
  closures : Buffer.t; (* closure function definitions, hoisted *)
  mutable closure_decls : string list; (* their forward declarations *)
  forfuncs : (string, Emo_ir.func) Hashtbl.t;
      (* foreign def's mangled name -> its IR: calls go straight to
         the C symbol, no wrapper (T24.8) *)
}

let put env fmt = Printf.ksprintf (Buffer.add_string env.buf) fmt

(* Fiber-wrapper numbering across the whole program: per-function env
   copies would give every function's sites the same names. *)
let spawn_counter = ref 0
let closure_counter = ref 0

(* C reserved words (C11) and the emitted entry: an Emo def named
   `double` would otherwise emit an illegal C declaration. The guard
   appends a suffix; Emo names never collide because `_c` cannot end
   a mangled Emo name... it can, so the check is on the exact word. *)
let c_ident (name : string) : string =
  let n = Emo_ir.sanitize_ident name in
  let reserved =
    List.mem n
      [
        "auto";
        "break";
        "case";
        "char";
        "const";
        "continue";
        "default";
        "do";
        "double";
        "else";
        "enum";
        "extern";
        "float";
        "for";
        "goto";
        "if";
        "inline";
        "int";
        "long";
        "register";
        "restrict";
        "return";
        "short";
        "signed";
        "sizeof";
        "static";
        "struct";
        "switch";
        "typedef";
        "union";
        "unsigned";
        "void";
        "volatile";
        "while";
        "_Alignas";
        "_Alignof";
        "_Atomic";
        "_Bool";
        "_Complex";
        "_Generic";
        "_Imaginary";
        "_Noreturn";
        "_Static_assert";
        "_Thread_local";
        "main";
      ]
  in
  if reserved then n ^ "_c" else n

let refuse what =
  raise
    (Emo_ir.Lower_error
       (Printf.sprintf "the c target does not support %s yet" what))

(* ---- Literals and types ---- *)

(* A C string literal: printable ASCII verbatim, everything else as
   fixed-width octal escapes. Three-digit octal is the safe form —
   \1012 reads as \101 then '2', unlike \x escapes whose length is
   unbounded. *)
let c_string (s : string) : string =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c when c >= ' ' && c <= '~' -> Buffer.add_char buf c
      | c -> Buffer.add_string buf (Printf.sprintf "\\%03o" (Char.code c)))
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* A String literal as an emo_str value. *)
let c_str_literal (s : string) : string =
  Printf.sprintf "((emo_str){INT64_C(%d), %s})" (String.length s) (c_string s)

(* A Float64 literal with exact round-trip: %.17g carries every IEEE
   bit pattern back. A rendering that is all digits (1.0 prints as
   "1") would be an int literal in C — integer division semantics —
   so it gains a ".0"; the infinities and NaN spell their C names. *)
let c_float (f : float) : string =
  if f = infinity then "INFINITY"
  else if f = neg_infinity then "(-INFINITY)"
  else if f <> f then "NAN"
  else
    let s = Printf.sprintf "%.17g" f in
    let digits =
      String.for_all (fun c -> (c >= '0' && c <= '9') || c = '-') s
    in
    if s <> "" && digits then s ^ ".0" else s

(* Native Emo types cross as C scalars — Int64/Float64/Bool/Char as
   machine words, String as the runtime's length-prefixed [emo_str].
   The dynamic world — Unknown, tuples, arrays, Box — crosses as one
   tagged [emo_value] word (T24.4). [Void] is a result type only. *)
let c_type (t : Emo_check.t) : string option =
  match t with
  | Emo_check.Int64 -> Some "int64_t"
  | Emo_check.Float64 -> Some "double"
  | Emo_check.Bool -> Some "bool"
  | Emo_check.Char -> Some "int32_t"
  | Emo_check.Byte -> Some "uint8_t"
  | Emo_check.Pid -> Some "int64_t"
  | Emo_check.TcpConn | Emo_check.TcpListener | Emo_check.UdpSocket ->
      Some "int64_t"
  | Emo_check.String -> Some "emo_str"
  | Emo_check.Unknown | Emo_check.TupleType _ | Emo_check.ArrayType _
  | Emo_check.MapType _ | Emo_check.BoxType _ | Emo_check.ListType _
  | Emo_check.ClassType _ | Emo_check.InterfaceType _ | Emo_check.EnumType _
  | Emo_check.FuncType _ | Emo_check.Bytes ->
      Some "emo_value"
  | Emo_check.Void -> Some "void"

(* Whether a type lives in the dynamic world (the tagged word) or the
   native one (a C scalar). *)
let is_dyn (t : Emo_check.t) : bool =
  match t with
  | Emo_check.Unknown | Emo_check.TupleType _ | Emo_check.ArrayType _
  | Emo_check.MapType _ | Emo_check.BoxType _ | Emo_check.ListType _
  | Emo_check.ClassType _ | Emo_check.InterfaceType _ | Emo_check.EnumType _
  | Emo_check.FuncType _ | Emo_check.Bytes ->
      true
  | _ -> false

let result_type (f : Emo_ir.func) : string =
  match c_type f.Emo_ir.fresult with
  | Some t -> t
  | None ->
      refuse
        (Printf.sprintf "`%s` results" (Emo_check.to_string f.Emo_ir.fresult))

let param_type (t : Emo_check.t) : string =
  match c_type t with
  | Some "void" -> refuse "Void parameters"
  | Some t -> t
  | None -> refuse (Printf.sprintf "`%s` parameters" (Emo_check.to_string t))

let dummy_value (t : Emo_check.t) : string =
  match t with
  | Emo_check.Float64 -> "0.0"
  | Emo_check.Bool -> "false"
  | Emo_check.String -> "(emo_str){INT64_C(0), \"\"}"
  | Emo_check.Unknown | Emo_check.TupleType _ | Emo_check.ArrayType _
  | Emo_check.MapType _ | Emo_check.BoxType _ | Emo_check.ListType _
  | Emo_check.ClassType _ | Emo_check.InterfaceType _ | Emo_check.EnumType _
  | Emo_check.FuncType _ ->
      "(emo_value)0"
  | _ -> "0"

(* The zero of a result type: initializes the epilogue's result slot
   against -Wall; the value is never observed (a non-Void body returns
   on every path). *)
let zero_value (c_ty : string) : string =
  match c_ty with
  | "double" -> "0.0"
  | "bool" -> "false"
  | "emo_str" -> "(emo_str){INT64_C(0), \"\"}"
  | "emo_value" -> "(emo_value)0"
  | _ -> "0"

(* ---- Expressions ---- *)

let compare_text (op : Ast.binop) : string =
  match op with
  | Ast.Eq -> "=="
  | Ast.Ne -> "!="
  | Ast.Lt -> "<"
  | Ast.Le -> "<="
  | Ast.Gt -> ">"
  | Ast.Ge -> ">="
  | _ -> assert false

let arith_text (op : Ast.binop) : string =
  match op with
  | Ast.Add -> "+"
  | Ast.Sub -> "-"
  | Ast.Mul -> "*"
  | Ast.Div -> "/"
  | _ -> assert false

(* One value as C code of a native scalar type: what a use site needs
   when the static type is native. *)
let rec box_code (v : string) (ty : Emo_check.t) : string =
  match ty with
  | Emo_check.Int64 -> Printf.sprintf "emo_box_i64(%s)" v
  | Emo_check.Float64 -> Printf.sprintf "emo_box_f64(%s)" v
  | Emo_check.Bool -> Printf.sprintf "emo_vbool(%s)" v
  | Emo_check.Char -> Printf.sprintf "emo_vchar(%s)" v
  | Emo_check.String -> Printf.sprintf "emo_box_str(%s)" v
  (* a Byte in the dynamic world is an Int64 cell carrying 0-255 *)
  | Emo_check.Byte -> Printf.sprintf "emo_box_i64((int64_t)(%s))" v
  | Emo_check.Pid -> Printf.sprintf "emo_box_pid(%s)" v
  | Emo_check.TcpConn | Emo_check.TcpListener | Emo_check.UdpSocket ->
      Printf.sprintf "emo_box_i64(%s)" v
  | t ->
      refuse
        (Printf.sprintf "`%s` values in the dynamic world"
           (Emo_check.to_string t))

and unbox_code (v : string) (ty : Emo_check.t) : string =
  match ty with
  | Emo_check.Int64 -> Printf.sprintf "emo_unbox_i64(%s)" v
  | Emo_check.Float64 -> Printf.sprintf "emo_unbox_f64(%s)" v
  | Emo_check.Bool -> Printf.sprintf "emo_bool_of(%s)" v
  | Emo_check.Char -> Printf.sprintf "emo_char_of(%s)" v
  | Emo_check.String -> Printf.sprintf "emo_str_of(%s)" v
  | Emo_check.Byte -> Printf.sprintf "(uint8_t)emo_unbox_i64(%s)" v
  | Emo_check.Pid -> Printf.sprintf "emo_unbox_pid(%s)" v
  | Emo_check.TcpConn | Emo_check.TcpListener | Emo_check.UdpSocket ->
      Printf.sprintf "emo_unbox_i64(%s)" v
  | t ->
      refuse
        (Printf.sprintf "`%s` out of the dynamic world" (Emo_check.to_string t))

(* e as a dynamic word: no conversion when it already is one. *)
and as_dyn env (e : Emo_ir.expr) : string =
  let v = emit_expr env e in
  if is_dyn e.Emo_ir.ety then v else box_code v e.Emo_ir.ety

(* e as a native scalar of type ty — the crossing is checked at
   runtime. *)
and as_native env (e : Emo_ir.expr) (ty : Emo_check.t) : string =
  let v = emit_expr env e in
  if is_dyn e.Emo_ir.ety then unbox_code v ty else v

and c_name env name =
  match List.find_opt (fun (n, _, _) -> String.equal n name) env.scope with
  | Some (_, c, _) -> c
  | None -> refuse (Printf.sprintf "the variable `%s` here" name)

(* One `do f(a1, ..)` site: a static fiber wrapper converts the boxed
   arguments to f's parameters and calls it; the site spawns the fiber
   and yields the pid. *)
and emit_spawn_site env (func : string) (args : Emo_ir.expr list)
    (use_ty : Emo_check.t) : string =
  match Hashtbl.find_opt env.funsigs func with
  | None -> refuse (Printf.sprintf "the spawn target `%s`" func)
  | Some (fparams, _fres) ->
      incr spawn_counter;
      let wrapper = Printf.sprintf "emo_spawn%d" !spawn_counter in
      let words = List.map (as_dyn env) args in
      let wenv = { env with buf = env.closures; fresh = 0 } in
      put wenv "static void %s(void) {\n" wrapper;
      put wenv "  emo_value *__args = emo_process_spawn_args();\n";
      List.iteri
        (fun i (_, ty) ->
          if not (is_dyn ty) then
            put wenv "  %s __a%d = %s;\n" (param_type ty) i
              (unbox_code (Printf.sprintf "__args[%d]" i) ty))
        fparams;
      let call_args =
        List.mapi
          (fun i (_, ty) ->
            if is_dyn ty then Printf.sprintf "__args[%d]" i
            else Printf.sprintf "__a%d" i)
          fparams
      in
      put wenv "  (void)(%s(%s));\n" (c_ident func)
        (String.concat ", " call_args);
      put wenv "}\n\n";
      let pid_expr =
        Printf.sprintf "emo_spawn_process(%s, INT64_C(%d), (emo_value[]){%s})"
          wrapper (List.length words) (String.concat ", " words)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_pid(%s)" pid_expr
      else pid_expr

(* The IO builtins (T24.10): files and TCP over the hosted OS. The
   net surface beyond this tier — TLS, unix sockets, UDP, DNS —
   compiles and fails at runtime, honestly. *)
and emit_io_builtin env (use_ty : Emo_check.t) (name : string)
    (args : Emo_ir.expr list) : string =
  let arg n (ty : Emo_check.t) =
    match List.nth_opt args n with
    | Some a -> as_native env a ty
    | None -> refuse (Printf.sprintf "the builtin `%s`" name)
  in
  match name with
  | "file_read" ->
      let v = Printf.sprintf "emo_file_read(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_str(%s)" v else v
  | "file_write" ->
      let v =
        Printf.sprintf "emo_file_write(%s, %s)" (arg 0 Emo_check.String)
          (arg 1 Emo_check.String)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "net_listen" ->
      let v =
        Printf.sprintf "emo_net_listen(%s, %s)" (arg 0 Emo_check.String)
          (arg 1 Emo_check.Int64)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "net_connect" ->
      let v =
        Printf.sprintf "emo_net_connect(%s, %s, %s)" (arg 0 Emo_check.String)
          (arg 1 Emo_check.Int64) (arg 2 Emo_check.Float64)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "printf" ->
      (* The format rides as a String, the data as its dynamic array —
         the runtime walks the elements against the conversions. *)
      Printf.sprintf "emo_printf(%s, %s)" (arg 0 Emo_check.String)
        (as_dyn env (List.nth args 1))
  (* ---- the os module: synchronous POSIX syscalls (ocaml/c targets) ---- *)
  | "os_getpid" ->
      let v = Printf.sprintf "emo_os_getpid()" in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_getppid" ->
      let v = Printf.sprintf "emo_os_getppid()" in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_fork" ->
      let v = Printf.sprintf "emo_os_fork()" in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_waitpid" ->
      let v = Printf.sprintf "emo_os_waitpid(%s)" (arg 0 Emo_check.Int64) in
      v
  | "os_pipe" ->
      let v = Printf.sprintf "emo_os_pipe()" in
      v
  | "os_execv" ->
      let v =
        Printf.sprintf "emo_os_execv(%s, %s)" (arg 0 Emo_check.String)
          (as_dyn env (List.nth args 1))
      in
      v
  | "os__exit" -> Printf.sprintf "emo_os__exit(%s)" (arg 0 Emo_check.Int64)
  | "os_open_read" ->
      let v = Printf.sprintf "emo_os_open_read(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_open_write" ->
      let v = Printf.sprintf "emo_os_open_write(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_open_append" ->
      let v =
        Printf.sprintf "emo_os_open_append(%s)" (arg 0 Emo_check.String)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_read" ->
      let v =
        Printf.sprintf "emo_os_read(%s, %s)" (arg 0 Emo_check.Int64)
          (arg 1 Emo_check.Int64)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_str(%s)" v else v
  | "os_write" ->
      let v =
        Printf.sprintf "emo_os_write(%s, %s)" (arg 0 Emo_check.Int64)
          (arg 1 Emo_check.String)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_close" ->
      let v = Printf.sprintf "emo_os_close(%s)" (arg 0 Emo_check.Int64) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_list_dir" ->
      let v = Printf.sprintf "emo_os_list_dir(%s)" (arg 0 Emo_check.String) in
      v
  | "os_mkdir" ->
      let v = Printf.sprintf "emo_os_mkdir(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_rmdir" ->
      let v = Printf.sprintf "emo_os_rmdir(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_unlink" ->
      let v = Printf.sprintf "emo_os_unlink(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_rename" ->
      let v =
        Printf.sprintf "emo_os_rename(%s, %s)" (arg 0 Emo_check.String)
          (arg 1 Emo_check.String)
      in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | "os_getcwd" ->
      let v = Printf.sprintf "emo_os_getcwd()" in
      if is_dyn use_ty then Printf.sprintf "emo_box_str(%s)" v else v
  | "os_chdir" ->
      let v = Printf.sprintf "emo_os_chdir(%s)" (arg 0 Emo_check.String) in
      if is_dyn use_ty then Printf.sprintf "emo_box_i64(%s)" v else v
  | other -> Printf.sprintf "emo_unsupported(\"%s\")" other

and foreign_call env (use_ty : Emo_check.t) (f : Emo_ir.func)
    (args : Emo_ir.expr list) : string =
  let symbol = Option.get f.Emo_ir.fforeign in
  let arg_code =
    List.map2
      (fun (arg : Emo_ir.expr) (_, ty) ->
        let v = as_native env arg ty in
        if ty = Emo_check.String then Printf.sprintf "emo_str_cstr(%s)" v else v)
      args f.Emo_ir.fparams
  in
  let call = Printf.sprintf "%s(%s)" symbol (String.concat ", " arg_code) in
  if f.Emo_ir.fresult = Emo_check.String then
    (* the C result is a char *: copy into a cell first — every Emo
       String representation is an emo_str from here on *)
    let v = Printf.sprintf "emo_str_from_cstr(%s)" call in
    if is_dyn use_ty then Printf.sprintf "emo_box_str(%s)" v else v
  else if is_dyn use_ty then box_code call f.Emo_ir.fresult
  else call

and emit_expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Const (Ast.L_int n) ->
      if n = Int64.min_int then "INT64_MIN"
      else if n < 0L then Printf.sprintf "(-(INT64_C(%Ld)))" (Int64.abs n)
      else Printf.sprintf "INT64_C(%Ld)" n
  | Const (Ast.L_bool b) -> if b then "true" else "false"
  | Const (Ast.L_float f) -> c_float f
  | Const (Ast.L_char c) -> Printf.sprintf "INT32_C(%d)" (Char.code c)
  | Const (Ast.L_byte n) -> Printf.sprintf "UINT8_C(%d)" n
  | Const (Ast.L_string s) -> c_str_literal s
  | Var name -> (
      (* the binding's regime may differ from this use's type — a
         closure parameter or pattern binding is dynamic while its
         uses are typed *)
      match List.find_opt (fun (n, _, _) -> String.equal n name) env.scope with
      | Some (_, c, ty) ->
          if ty = e.Emo_ir.ety then c
          else if is_dyn ty && is_dyn e.Emo_ir.ety then c
          else if is_dyn e.Emo_ir.ety then box_code c ty
          else unbox_code c e.Emo_ir.ety
      | None -> refuse (Printf.sprintf "the variable `%s` here" name))
  | Unary (op, x) -> emit_unary env e.Emo_ir.ety op x
  | Binary (op, l, r) -> emit_binary env e.Emo_ir.ety op l r
  | Cond { c; t; e = else_ } ->
      let cond = emit_expr env c in
      let cond =
        if is_dyn c.Emo_ir.ety then unbox_code cond Emo_check.Bool else cond
      in
      let a, b =
        if is_dyn e.Emo_ir.ety then (as_dyn env t, as_dyn env else_)
        else (as_native env t e.Emo_ir.ety, as_native env else_ e.Emo_ir.ety)
      in
      Printf.sprintf "(%s ? %s : %s)" cond a b
  | Interpolate parts -> (
      let rendered =
        List.map
          (fun (part : Emo_ir.expr) ->
            match part.Emo_ir.desc with
            | Const (Ast.L_string s) -> c_str_literal s
            | _ -> to_str env part)
          parts
      in
      match rendered with
      | [] -> c_str_literal ""
      | x :: rest ->
          List.fold_left
            (fun acc part -> Printf.sprintf "emo_str_concat(%s, %s)" acc part)
            x rest)
  | Method { self_; name; args } -> emit_method env e.Emo_ir.ety self_ name args
  | Builtin { name = "self_pid"; args = [] } ->
      let v = "emo_process_self_pid()" in
      if is_dyn e.Emo_ir.ety then Printf.sprintf "emo_box_pid(%s)" v else v
  | Builtin { name = "self_pid"; _ } -> refuse "self_pid with arguments"
  | Builtin { name = "halt"; _ } ->
      (* `return halt()` / `do halt()`: the process never resumes —
         the statement forms emit the call; an expression position
         (this arm) only arises through a value use, which refuses *)
      refuse "halt in a value position"
  | Builtin { name; args } -> emit_io_builtin env e.Emo_ir.ety name args
  | Call { func; args } -> (
      (* A foreign def calls its C symbol directly (T24.8). *)
      match Hashtbl.find_opt env.forfuncs func with
      | Some f -> foreign_call env e.Emo_ir.ety f args
      | None -> (
          (* The callee's declared regime governs: a cross-module call the
         checker types Unknown still returns the callee's native
         result, and the use site converts either way. *)
          match Hashtbl.find_opt env.funsigs func with
          | Some (param_types, fres) -> (
              match List.combine args param_types with
              | pairs ->
                  let arg_code =
                    List.map
                      (fun (arg, (_, pty)) ->
                        if is_dyn pty then as_dyn env arg
                        else as_native env arg pty)
                      pairs
                  in
                  let call =
                    Printf.sprintf "%s(%s)" (c_ident func)
                      (String.concat ", " arg_code)
                  in
                  if fres = e.Emo_ir.ety then call
                  else if is_dyn fres && is_dyn e.Emo_ir.ety then call
                  else if is_dyn e.Emo_ir.ety then box_code call fres
                  else unbox_code call e.Emo_ir.ety
              | exception Invalid_argument _ ->
                  (* arity mismatches are the checker's to refuse *)
                  let arg_code = List.map (emit_expr env) args in
                  Printf.sprintf "%s(%s)" (c_ident func)
                    (String.concat ", " arg_code))
          | None ->
              let arg_code = List.map (emit_expr env) args in
              Printf.sprintf "%s(%s)" (c_ident func)
                (String.concat ", " arg_code)))
  | Tuple es ->
      let elems = String.concat ", " (List.map (as_dyn env) es) in
      Printf.sprintf "emo_tuple_new(INT64_C(%d), (emo_value[]){%s})"
        (List.length es) elems
  | Array_lit es ->
      let elems = String.concat ", " (List.map (as_dyn env) es) in
      Printf.sprintf "emo_array_new(INT64_C(%d), (emo_value[]){%s})"
        (List.length es) elems
  | Map_lit pairs ->
      let elems = String.concat ", " (List.map (as_dyn env) pairs) in
      Printf.sprintf "emo_map_new(INT64_C(%d), (emo_value[]){%s})"
        (List.length pairs) elems
  | Index (base, idx) ->
      let v =
        Printf.sprintf "emo_index(%s, %s)" (as_dyn env base)
          (as_native env idx Emo_check.Int64)
      in
      if is_dyn e.Emo_ir.ety then v else unbox_code v e.Emo_ir.ety
  | Do_spawn { func; args } ->
      let use_ty = e.Emo_ir.ety in
      let pid_expr = emit_spawn_site env func args use_ty in
      pid_expr
  | Box_new arg -> Printf.sprintf "emo_box_new(%s)" (as_dyn env arg)
  | Bytes_new n ->
      Printf.sprintf "emo_bytes_new(%s)" (as_native env n Emo_check.Int64)
  | List_new arg -> Printf.sprintf "emo_list_new(%s)" (as_dyn env arg)
  | Make_enum { enum_name; member } ->
      Printf.sprintf "emo_enum_new(%s, %s)" (c_string enum_name)
        (c_string member)
  | Field_read { obj; name } when is_dyn obj.Emo_ir.ety ->
      (* cross-module field access: the checker lost the class, but the
         instance's vtable carries the field names *)
      let v =
        Printf.sprintf "emo_field_by_name(%s, %s)" (as_dyn env obj)
          (c_string name)
      in
      if is_dyn e.Emo_ir.ety then v else v (* fields are dynamic words *)
  | Field_read { obj; name } -> emit_field_read env e.Emo_ir.ety obj name
  | Call_value { f; args } ->
      let v = closure_call env f args in
      if is_dyn e.Emo_ir.ety then v else unbox_code v e.Emo_ir.ety
  | Closure { cparams; cbody } -> emit_closure env cparams cbody
  | Spawn_value _ -> refuse "spawning a first-class block yet"
  | Make_exception { message; data = None } ->
      Printf.sprintf "emo_make_exception(%s)" (to_str env message)
  | Make_exception _ ->
      refuse "the c target does not support exception data yet"
  | other ->
      refuse
        (Printf.sprintf "this expression form (%s)"
           (match other with
           | Emo_ir.Const _ -> "Const"
           | Emo_ir.Type_ref _ -> "Type_ref"
           | Emo_ir.Var _ -> "Var"
           | Emo_ir.Global _ -> "Global"
           | Emo_ir.Tuple _ -> "Tuple"
           | Emo_ir.Array_lit _ -> "Array_lit"
           | Emo_ir.Map_lit _ -> "Map_lit"
           | Emo_ir.Make_enum _ -> "Make_enum"
           | Emo_ir.Interpolate _ -> "Interpolate"
           | Emo_ir.Unary _ -> "Unary"
           | Emo_ir.Binary _ -> "Binary"
           | Emo_ir.Cond _ -> "Cond"
           | Emo_ir.Index _ -> "Index"
           | Emo_ir.Field_read _ -> "Field_read"
           | Emo_ir.Call _ -> "Call"
           | Emo_ir.Call_value _ -> "Call_value"
           | Emo_ir.Method _ -> "Method"
           | Emo_ir.Builtin _ -> "Builtin"
           | Emo_ir.Box_new _ -> "Box_new"
           | Emo_ir.Global_var _ -> "Global_var"
           | Emo_ir.Bytes_new _ -> "Bytes_new"
           | Emo_ir.List_new _ -> "List_new"
           | Emo_ir.Make_exception _ -> "Make_exception"
           | Emo_ir.Do_spawn _ -> "Do_spawn"
           | Emo_ir.Spawn_value _ -> "Spawn_value"
           | Emo_ir.Closure _ -> "Closure"))

(* One value as an emo_str expression — what an interpolation part
   and a scalar to_string() lower to. Dynamic values render through
   the runtime's kind dispatch. *)
and to_str env (e : Emo_ir.expr) : string =
  if is_dyn e.Emo_ir.ety then
    Printf.sprintf "emo_to_string_dyn(%s)" (emit_expr env e)
  else
    let v = emit_expr env e in
    match e.Emo_ir.ety with
    | Emo_check.String -> v
    | Emo_check.Int64 -> Printf.sprintf "emo_str_from_i64(%s)" v
    | Emo_check.Float64 -> Printf.sprintf "emo_str_from_f64(%s)" v
    | Emo_check.Bool -> Printf.sprintf "emo_str_from_bool(%s)" v
    | Emo_check.Char -> Printf.sprintf "emo_str_from_char(%s)" v
    | t ->
        refuse
          (Printf.sprintf "`%s` values in a string" (Emo_check.to_string t))

(* The supported methods of the dynamic world: Box's read/replace,
   sequence length, and the scalar to_string. Instances arrive with
   T24.5. *)
(* The Bytes accessors return native int64_t; a dynamic use site
   takes the boxed form. *)
and box_int env (result_ty : Emo_check.t) (v : string) : string =
  if is_dyn result_ty then Printf.sprintf "emo_box_i64(%s)" v else v

and emit_method env (result_ty : Emo_check.t) (self_ : Emo_ir.expr)
    (name : string) (args : Emo_ir.expr list) : string =
  let finish v = if is_dyn result_ty then v else unbox_code v result_ty in
  let arity = List.length args in
  (* The type-level methods (`Byte.from_int64`, `Float64.from_bits`)
     arrive with a Type_ref receiver. *)
  match self_.Emo_ir.desc with
  | Emo_ir.Type_ref t -> (
      (* the checker types these calls Unknown — convert from the
         method's static result; a Byte materializes as an Int64 cell
         in the dynamic world *)
      match (t, name, args) with
      | "Byte", "from_int64", [ x ] ->
          let v =
            Printf.sprintf "(uint8_t)((%s) & 255)"
              (as_native env x Emo_check.Int64)
          in
          if is_dyn result_ty then Printf.sprintf "emo_box_i64((int64_t)(%s))" v
          else v
      | "Float64", "from_bits", [ x ] ->
          let v =
            Printf.sprintf "emo_f64_from_bits(%s)"
              (as_native env x Emo_check.Int64)
          in
          if is_dyn result_ty then box_code v Emo_check.Float64 else v
      | _ -> refuse (Printf.sprintf "the type-level method `%s.%s`" t name))
  | _ -> (
      match (name, args) with
      | "to_string", [] when self_.Emo_ir.ety = Emo_check.Bytes ->
          Printf.sprintf "emo_to_string_method(%s)" (as_dyn env self_)
      | "to_string", [] when self_.Emo_ir.ety <> Emo_check.Unknown ->
          if is_dyn self_.Emo_ir.ety then
            Printf.sprintf "emo_to_string_dyn(%s)" (emit_expr env self_)
          else to_str env self_
      | "read", [] ->
          finish (Printf.sprintf "emo_box_read(%s)" (as_dyn env self_))
      | "replace", [ v ] ->
          finish
            (Printf.sprintf "emo_box_replace(%s, %s)" (as_dyn env self_)
               (as_dyn env v))
      (* The List deque: O(1) push and pop at both ends. Push returns the
         list itself; pop yields the element (a static element type
         crosses the regime boundary through finish). *)
      | "push_front", [ v ]
        when match self_.Emo_ir.ety with
             | Emo_check.ListType _ -> true
             | _ -> false ->
          Printf.sprintf "emo_list_push_front(%s, %s)" (as_dyn env self_)
            (as_dyn env v)
      | "push_back", [ v ]
        when match self_.Emo_ir.ety with
             | Emo_check.ListType _ -> true
             | _ -> false ->
          Printf.sprintf "emo_list_push_back(%s, %s)" (as_dyn env self_)
            (as_dyn env v)
      | "pop_front", []
        when match self_.Emo_ir.ety with
             | Emo_check.ListType _ -> true
             | _ -> false ->
          finish (Printf.sprintf "emo_list_pop_front(%s)" (as_dyn env self_))
      | "pop_back", []
        when match self_.Emo_ir.ety with
             | Emo_check.ListType _ -> true
             | _ -> false ->
          finish (Printf.sprintf "emo_list_pop_back(%s)" (as_dyn env self_))
      | "length", [] when self_.Emo_ir.ety = Emo_check.Bytes ->
          Printf.sprintf "emo_bytes_length(%s)" (as_dyn env self_)
      | "length", []
        when match self_.Emo_ir.ety with
             | Emo_check.ArrayType _ | Emo_check.TupleType _ | Emo_check.Unknown
             | Emo_check.ListType _ ->
                 true
             | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_length(%s)" (as_dyn env self_))
      | "append", [ v ]
        when match self_.Emo_ir.ety with
             | Emo_check.ArrayType _ -> true
             | _ -> false ->
          Printf.sprintf "emo_array_append(%s, %s)" (as_dyn env self_)
            (as_dyn env v)
      (* The map's methods: the receiver's MapType keys the arm, and the
         runtime dispatches by kind — an Unknown receiver's `get` stays
         the Bytes accessor. *)
      | "get", [ k ]
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          finish
            (Printf.sprintf "emo_map_get(%s, %s)" (as_dyn env self_)
               (as_dyn env k))
      | "set", [ k; v ]
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          finish
            (Printf.sprintf "emo_map_set(%s, %s, %s)" (as_dyn env self_)
               (as_dyn env k) (as_dyn env v))
      | "has", [ k ]
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          (* emo_map_has answers a C bool: box it for a dynamic use
             site, pass it through a native one *)
          let v =
            Printf.sprintf "emo_map_has(%s, %s)" (as_dyn env self_)
              (as_dyn env k)
          in
          if is_dyn result_ty then Printf.sprintf "emo_vbool(%s)" v else v
      | "remove", [ k ]
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          finish
            (Printf.sprintf "emo_map_remove(%s, %s)" (as_dyn env self_)
               (as_dyn env k))
      | "length", []
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_map_length(%s)" (as_dyn env self_))
      | "keys", []
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          finish (Printf.sprintf "emo_map_keys(%s)" (as_dyn env self_))
      | "values", []
        when match self_.Emo_ir.ety with
             | Emo_check.MapType _ -> true
             | _ -> false ->
          finish (Printf.sprintf "emo_map_values(%s)" (as_dyn env self_))
      (* The systems layer: Bytes accessors, conversions, and bit-casts.
     The type-level methods (`Byte.from_int64`, `Float64.from_bits`)
     arrive with a Type_ref receiver. *)
      | "get", [ i ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_get(%s, %s)" (as_dyn env self_)
               (as_native env i Emo_check.Int64))
      | "set", [ i; v ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_set(%s, %s, %s)" (as_dyn env self_)
               (as_native env i Emo_check.Int64)
               (as_native env v Emo_check.Int64))
      | "get_u16_le", [ i ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_get_u16_le(%s, %s)" (as_dyn env self_)
               (as_native env i Emo_check.Int64))
      | "get_u32_le", [ i ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_get_u32_le(%s, %s)" (as_dyn env self_)
               (as_native env i Emo_check.Int64))
      | "get_u64_le", [ i ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_get_u64_le(%s, %s)" (as_dyn env self_)
               (as_native env i Emo_check.Int64))
      | "set_u16_le", [ i; v ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_set_u16_le(%s, %s, %s)"
               (as_dyn env self_)
               (as_native env i Emo_check.Int64)
               (as_native env v Emo_check.Int64))
      | "set_u32_le", [ i; v ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_set_u32_le(%s, %s, %s)"
               (as_dyn env self_)
               (as_native env i Emo_check.Int64)
               (as_native env v Emo_check.Int64))
      | "set_u64_le", [ i; v ]
        when match self_.Emo_ir.ety with Emo_check.Bytes -> true | _ -> false ->
          box_int env result_ty
            (Printf.sprintf "emo_bytes_set_u64_le(%s, %s, %s)"
               (as_dyn env self_)
               (as_native env i Emo_check.Int64)
               (as_native env v Emo_check.Int64))
      | "to_bytes", [] when self_.Emo_ir.ety = Emo_check.String ->
          Printf.sprintf "emo_bytes_of_str(%s)" (emit_expr env self_)
      | "to_bits", [] when self_.Emo_ir.ety = Emo_check.Float64 ->
          Printf.sprintf "emo_f64_bits(%s)" (emit_expr env self_)
      | "to_byte", [] when self_.Emo_ir.ety = Emo_check.Int64 ->
          Printf.sprintf "(uint8_t)((%s) & 255)" (emit_expr env self_)
      | "to_int64", [] when self_.Emo_ir.ety = Emo_check.Byte ->
          Printf.sprintf "((int64_t)(%s))" (emit_expr env self_)
      | "is", [ { Emo_ir.desc = Type_ref target; _ } ] -> (
          (* a class target compares vtable identity; an interface target
         matches the shape *)
          match Hashtbl.find_opt env.classes target with
          | Some c ->
              Printf.sprintf "emo_is_class(%s, &vt_%s)" (as_dyn env self_)
                c.Emo_ir.cname
          | None -> (
              match Hashtbl.find_opt env.ifaces target with
              | Some _ ->
                  Printf.sprintf "emo_is_iface(%s, &iface_%s)"
                    (as_dyn env self_) (c_ident target)
              | None ->
                  refuse (Printf.sprintf "`is(%s)`" target)
                  (* Native handles: TCP endpoints and listeners are fds; the methods
     translate 1:1 onto the runtime's calls. *)
              ))
      | _, _
        when match self_.Emo_ir.ety with
             | Emo_check.TcpConn | Emo_check.TcpListener | Emo_check.UdpSocket
               ->
                 true
             | _ -> false -> (
          let recv = emit_expr env self_ in
          (* The helpers return native values; each case states its return
         so a dynamic use site takes the boxed form. *)
          let ret (t : Emo_check.t) (v : string) : string =
            if is_dyn result_ty then box_code v t else v
          in
          match (name, args) with
          | "accept", [] ->
              ret Emo_check.Int64 (Printf.sprintf "emo_net_accept(%s)" recv)
          | "port", [] ->
              ret Emo_check.Int64 (Printf.sprintf "emo_net_port(%s)" recv)
          | "read_line", [] ->
              ret Emo_check.String (Printf.sprintf "emo_net_read_line(%s)" recv)
          | "read_exactly", [ n ] ->
              ret Emo_check.String
                (Printf.sprintf "emo_net_read_exactly(%s, %s)" recv
                   (as_native env n Emo_check.Int64))
          | "read_all", [] ->
              ret Emo_check.String (Printf.sprintf "emo_net_read_all(%s)" recv)
          | "write", [ data ] ->
              ret Emo_check.Int64
                (Printf.sprintf "emo_net_write(%s, %s)" recv
                   (as_native env data Emo_check.String))
          | "close", [] ->
              ret Emo_check.Int64 (Printf.sprintf "emo_net_close(%s)" recv)
          | "set_timeout", [ t ] ->
              ret Emo_check.Int64
                (Printf.sprintf "emo_net_set_timeout(%s, %s)" recv
                   (as_native env t Emo_check.Float64))
          | _ -> refuse (Printf.sprintf "this method on a socket handle"))
      | _, _ when self_.Emo_ir.ety = Emo_check.String -> (
          (* The interpreter's String method set. *)
          match (name, args) with
          | "substring", [ start; len ] ->
              Printf.sprintf "emo_str_substring(%s, %s, %s)"
                (emit_expr env self_)
                (as_native env start Emo_check.Int64)
                (as_native env len Emo_check.Int64)
          | "index_of", [ needle ] ->
              Printf.sprintf "emo_str_index_of(%s, %s)" (emit_expr env self_)
                (as_native env needle Emo_check.String)
          | "starts_with", [ prefix ] ->
              Printf.sprintf "emo_str_starts_with(%s, %s)" (emit_expr env self_)
                (as_native env prefix Emo_check.String)
          | "lower", [] ->
              Printf.sprintf "emo_str_lower(%s)" (emit_expr env self_)
          | "trim", [] ->
              Printf.sprintf "emo_str_trim(%s)" (emit_expr env self_)
          | "to_int64", [] ->
              Printf.sprintf "emo_str_to_int64(%s)" (emit_expr env self_)
          | "length", [] ->
              Printf.sprintf "emo_str_length(%s)" (emit_expr env self_)
          | "split", [ sep ] ->
              Printf.sprintf "emo_str_split(%s, %s)" (emit_expr env self_)
                (as_native env sep Emo_check.String)
          | _ -> refuse (Printf.sprintf "the String method `%s`" name))
      | _, _
        when match self_.Emo_ir.ety with
             | Emo_check.Unknown when is_dyn result_ty || true -> true
             | _ -> false ->
          (* An Unknown receiver: the checker loses the static type at
             cross-module calls, so the value could be an instance of
             any class, a String, a socket fd, or a List. The runtime
             dispatches once — an instance answers through its vtable
             (these names may be that very method), a non-instance
             through the builtin that owns the name — so the receiver
             expression is emitted exactly once and the result arrives
             boxed for [finish] to unbox. *)
          let recv_dyn = as_dyn env self_ in
          let dyn_args =
            if args = [] then "NULL"
            else
              Printf.sprintf "(emo_value[]){%s}"
                (String.concat ", " (List.map (as_dyn env) args))
          in
          finish
            (Printf.sprintf "emo_dynamic_builtin(%s, %s, INT64_C(%d), %s)"
               recv_dyn (c_string name) (List.length args) dyn_args)
      | _ when is_dyn self_.Emo_ir.ety -> (
          (* an instance method: direct on a class-typed receiver, through
         the vtable's thunk otherwise (interfaces, Unknown) *)
          match self_.Emo_ir.ety with
          | Emo_check.ClassType display -> (
              match Hashtbl.find_opt env.classes display with
              | Some c -> (
                  let mangled = c.Emo_ir.cname ^ "__" ^ c_ident name in
                  match
                    List.find_opt
                      (fun (m : Emo_ir.func) ->
                        String.equal m.Emo_ir.fname mangled
                        && List.length m.Emo_ir.fparams - 1 = arity)
                      c.Emo_ir.cmethods
                  with
                  | Some m ->
                      let self_code = as_dyn env self_ in
                      let arg_code =
                        List.map2
                          (fun (arg : Emo_ir.expr) (_, ty) ->
                            if is_dyn ty then as_dyn env arg
                            else as_native env arg ty)
                          args (List.tl m.Emo_ir.fparams)
                      in
                      let v =
                        Printf.sprintf "%s(%s%s)" (c_ident mangled) self_code
                          (if arg_code = [] then ""
                           else ", " ^ String.concat ", " arg_code)
                      in
                      (* A Void method keeps its call: in statement
                         position the discard is the wrapper's job, and
                         dropping the call here would drop the side
                         effect. *)
                      if m.Emo_ir.fresult = Emo_check.Void then v
                      else if is_dyn result_ty = is_dyn m.Emo_ir.fresult then v
                      else if is_dyn result_ty then box_code v m.Emo_ir.fresult
                      else unbox_code v m.Emo_ir.fresult
                  | None ->
                      refuse
                        (Printf.sprintf "the method `%s` on `%s`" name display))
              | None -> refuse (Printf.sprintf "the class `%s`" display))
          | _ ->
              if arity > 4 then
                refuse "method calls with more than four arguments";
              let arg_code = String.concat ", " (List.map (as_dyn env) args) in
              let v =
                Printf.sprintf "emo_send(%s, %s, INT64_C(%d), %s)"
                  (as_dyn env self_) (c_string name) arity
                  (if args = [] then "NULL"
                   else Printf.sprintf "(emo_value[]){%s}" arg_code)
              in
              if is_dyn result_ty then v else unbox_code v result_ty)
      | _ -> refuse "method calls")

(* The class a field access resolves against: the receiver's static
   type when it names a class, otherwise the method being emitted
   (`self` is Unknown inside method bodies). *)
and field_class env (obj : Emo_ir.expr) : string =
  match obj.Emo_ir.ety with
  | Emo_check.ClassType display -> (
      match Hashtbl.find_opt env.classes display with
      | Some c -> c.Emo_ir.cname
      | None -> refuse (Printf.sprintf "the class `%s`" display))
  | _ -> (
      match env.fclass with
      | Some c -> c
      | None -> refuse "field access outside a class")

and field_index env (obj : Emo_ir.expr) (name : string) : int =
  let cname = field_class env obj in
  let fields =
    match Hashtbl.find_opt env.fields cname with
    | Some fs -> fs
    | None -> refuse (Printf.sprintf "fields of `%s`" cname)
  in
  match List.find_index (fun f -> String.equal f name) fields with
  | Some i -> i
  | None -> refuse (Printf.sprintf "the field `%s`" name)

and emit_field_read env (result_ty : Emo_check.t) (obj : Emo_ir.expr)
    (name : string) : string =
  let inst = emit_expr env obj in
  let idx = field_index env obj name in
  let v = Printf.sprintf "emo_instance_field(%s, INT64_C(%d))" inst idx in
  if is_dyn result_ty then v else unbox_code v result_ty

(* A closure call: the canonical dynamic convention, arity known at
   the call site. *)
and closure_call env (f : Emo_ir.expr) (args : Emo_ir.expr list) : string =
  let arity = List.length args in
  if arity > 4 then refuse "calls of blocks with more than four arguments";
  Printf.sprintf "emo_closure_call%d(%s%s)" arity (as_dyn env f)
    (if args = [] then ""
     else ", " ^ String.concat ", " (List.map (as_dyn env) args))

(* The variables a closure body captures: names it references, minus
   the ones it binds itself, taken from the creation scope in scope
   order (stable capture indices). Nested closures are walked into —
   their free references are this closure's captures too. *)
and closure_free env (cparams : (string * Emo_check.t) list)
    (body : Emo_ir.stmt list) : (string * string * Emo_check.t) list =
  let referenced = ref [] in
  let add n =
    if not (List.mem n !referenced) then referenced := n :: !referenced
  in
  let bound = ref (List.map fst cparams) in
  let rec ex (e : Emo_ir.expr) =
    match e.Emo_ir.desc with
    | Var n -> add n
    | Unary (_, x) -> ex x
    | List_new x -> ex x
    | Binary (_, l, r) ->
        ex l;
        ex r
    | Cond { c; t; e } ->
        ex c;
        ex t;
        ex e
    | Interpolate es -> List.iter ex es
    | Tuple es | Array_lit es -> List.iter ex es
    | Map_lit pairs -> List.iter ex pairs
    | Index (b, i) ->
        ex b;
        ex i
    | Field_read { obj; _ } -> ex obj
    | Call { args; _ } -> List.iter ex args
    | Call_value { f; args } ->
        ex f;
        List.iter ex args
    | Method { self_; args; _ } ->
        ex self_;
        List.iter ex args
    | Builtin { args; _ } -> List.iter ex args
    | Box_new x | Bytes_new x -> ex x
    | Make_exception { message; data } ->
        ex message;
        Option.iter ex data
    | Do_spawn { args; _ } -> List.iter ex args
    | Spawn_value { f; args } ->
        ex f;
        List.iter ex args
    | Closure { cbody; _ } -> List.iter st cbody
    | Make_enum _ -> ()
    | Const _ | Type_ref _ | Global _ | Global_var _ -> ()
  and st (s : Emo_ir.stmt) =
    match s with
    | Effect e -> ex e
    | Let { name; init; _ } ->
        ex init;
        bound := name :: !bound
    | Assign_var { name; value } ->
        ex value;
        bound := name :: !bound
    | Set_global_var { value; _ } -> ex value
    | Set_field { self_; value; _ } ->
        ex self_;
        ex value
    | If { cond; then_; else_ } ->
        ex cond;
        List.iter st then_;
        List.iter st else_
    | Case { scrutinee; branches } ->
        ex scrutinee;
        List.iter
          (fun (b : Emo_ir.branch) ->
            Option.iter ex b.Emo_ir.guard;
            pattern_bound_names b.Emo_ir.pattern bound;
            List.iter st b.Emo_ir.body)
          branches
    | Receive _ | Send _ | Raise _ -> ()
    | Return_stmt e -> ex e
  in
  List.iter st body;
  List.filter
    (fun (n, _, _) -> List.mem n !referenced && not (List.mem n !bound))
    env.scope

and pattern_bound_names (p : Ast.pattern) (bound : string list ref) : unit =
  match p.Ast.pattern_desc with
  | Ast.Pattern_binding n -> bound := n :: !bound
  | Ast.Tuple_pattern ps ->
      List.iter (fun sub -> pattern_bound_names sub bound) ps
  | _ -> ()

(* One closure: a hoisted static function in the canonical dynamic
   convention (the closure word plus args as dynamic words), with the
   captured variables loaded from the cell at entry. Returns the
   creation expression. *)
and emit_closure env (cparams : (string * Emo_check.t) list)
    (body : Emo_ir.stmt list) : string =
  incr closure_counter;
  let name = Printf.sprintf "emo__closure%d" !closure_counter in
  let caps = closure_free env cparams body in
  let param_scope =
    List.mapi (fun i (n, _) -> (n, c_ident n, Emo_check.Unknown)) cparams
  in
  let cap_scope = List.map (fun (n, c, ty) -> (n, c, ty)) caps in
  let env =
    {
      env with
      buf = env.closures;
      fresh = 0;
      fname = name;
      fresult = Emo_check.Unknown;
      fclass = None;
      tail_rebinds = [];
      in_main = false;
    }
  in
  put env "static emo_value %s(emo_value __cl, const emo_value *__args) {\n"
    name;
  put env "  (void)__cl;\n  (void)__args;\n";
  List.iteri
    (fun i (n, c, _) -> put env "  emo_value %s = __args[%d];\n" c i)
    param_scope;
  List.iteri
    (fun i (_, c, ty) ->
      let word = Printf.sprintf "emo_closure_get(__cl, INT64_C(%d))" i in
      if is_dyn ty then put env "  emo_value %s = %s;\n" c word
      else put env "  %s %s = %s;\n" (param_type ty) c (unbox_code word ty))
    cap_scope;
  env.scope <- param_scope @ cap_scope;
  emit_stmts env body;
  put env "  return emo_vbool(false);\n}\n\n";
  let cap_values =
    String.concat ", "
      (List.map
         (fun (n, _, ty) -> as_dyn env { Emo_ir.ety = ty; Emo_ir.desc = Var n })
         caps)
  in
  Printf.sprintf "emo_closure_new(&%s, INT64_C(%d), (emo_value[]){%s})" name
    (List.length caps) cap_values

(* Native-scrutinee patterns: literals compare directly. *)
and pattern_test_native env (s : string) (ty : Emo_check.t) (p : Ast.pattern) :
    string =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> "true"
  | Ast.Pattern_literal lit ->
      let lit_expr =
        match lit with
        | Ast.L_int n ->
            { Emo_ir.ety = Emo_check.Int64; Emo_ir.desc = Const (Ast.L_int n) }
        | Ast.L_byte n ->
            { Emo_ir.ety = Emo_check.Byte; Emo_ir.desc = Const (Ast.L_byte n) }
        | Ast.L_float f ->
            {
              Emo_ir.ety = Emo_check.Float64;
              Emo_ir.desc = Const (Ast.L_float f);
            }
        | Ast.L_bool b ->
            { Emo_ir.ety = Emo_check.Bool; Emo_ir.desc = Const (Ast.L_bool b) }
        | Ast.L_char c ->
            { Emo_ir.ety = Emo_check.Char; Emo_ir.desc = Const (Ast.L_char c) }
        | Ast.L_string str ->
            {
              Emo_ir.ety = Emo_check.String;
              Emo_ir.desc = Const (Ast.L_string str);
            }
      in
      (* both sides native: a plain comparison, strings through
         content equality *)
      if ty = Emo_check.String then
        Printf.sprintf "emo_str_eq(%s, %s)" s (emit_expr env lit_expr)
      else Printf.sprintf "(%s == %s)" s (emit_expr env lit_expr)
  | Ast.Enum_member _ | Ast.Tuple_pattern _ ->
      refuse "this pattern on a native scrutinee"

and pattern_bind_native env (s : string) (ty : Emo_check.t) (p : Ast.pattern) :
    unit =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_literal _ | Ast.Enum_member _ -> ()
  | Ast.Pattern_binding name ->
      let c = c_ident name in
      let cty =
        match c_type ty with Some t -> t | None -> refuse "this binding"
      in
      put env "  %s %s = %s;\n" cty c s;
      env.scope <- (name, c, ty) :: env.scope
  | Ast.Tuple_pattern _ -> refuse "this pattern on a native scrutinee"

and emit_unary env (result_ty : Emo_check.t) (op : Ast.unop) (x : Emo_ir.expr) :
    string =
  let finish v = if is_dyn result_ty then v else unbox_code v result_ty in
  if is_dyn x.Emo_ir.ety then
    match op with
    | Ast.Neg -> finish (Printf.sprintf "emo_neg_dyn(%s)" (as_dyn env x))
    | Ast.Not -> Printf.sprintf "(!emo_bool_of(%s))" (as_dyn env x)
    | Ast.Bit_not -> refuse "the bitwise operators"
  else
    let v = emit_expr env x in
    match (op, x.Emo_ir.ety) with
    | Ast.Neg, Emo_check.Int64 ->
        Printf.sprintf "(int64_t)(0ULL - (uint64_t)(%s))" v
    | Ast.Neg, Emo_check.Float64 -> Printf.sprintf "(-(%s))" v
    | Ast.Not, Emo_check.Bool -> Printf.sprintf "(!(%s))" v
    | Ast.Bit_not, Emo_check.Int64 ->
        Printf.sprintf "(int64_t)(~(uint64_t)(%s))" v
    | Ast.Bit_not, Emo_check.Byte ->
        Printf.sprintf "(uint8_t)(~(uint64_t)(%s))" v
    | Ast.Neg, _ | Ast.Not, _ -> refuse "this unary operation"
    | Ast.Bit_not, _ -> refuse "`~` on this type"

and emit_binary env (result_ty : Emo_check.t) (op : Ast.binop) (l : Emo_ir.expr)
    (r : Emo_ir.expr) : string =
  if is_dyn l.Emo_ir.ety || is_dyn r.Emo_ir.ety then
    (* The runtime dispatches on the values; arithmetic yields a word,
       comparisons a C bool. Arithmetic converts to the operation's
       own static type when that is native. *)
    let a = as_dyn env l and b = as_dyn env r in
    let dyn_arith helper =
      let code = Printf.sprintf "%s(%s, %s)" helper a b in
      if is_dyn result_ty then code else unbox_code code result_ty
    in
    match op with
    | Add -> dyn_arith "emo_add_dyn"
    | Sub -> dyn_arith "emo_sub_dyn"
    | Mul -> dyn_arith "emo_mul_dyn"
    | Div -> dyn_arith "emo_div_dyn"
    | Mod -> dyn_arith "emo_mod_dyn"
    | Eq -> Printf.sprintf "emo_eq_dyn(%s, %s)" a b
    | Ne -> Printf.sprintf "(!emo_eq_dyn(%s, %s))" a b
    | Lt -> Printf.sprintf "emo_lt_dyn(%s, %s)" a b
    | Le -> Printf.sprintf "emo_le_dyn(%s, %s)" a b
    | Gt -> Printf.sprintf "emo_lt_dyn(%s, %s)" b a
    | Ge -> Printf.sprintf "emo_le_dyn(%s, %s)" b a
    | And -> Printf.sprintf "(emo_bool_of(%s) && emo_bool_of(%s))" a b
    | Or -> Printf.sprintf "(emo_bool_of(%s) || emo_bool_of(%s))" a b
    | Bit_and | Bit_or | Bit_xor | Shl | Shr ->
        refuse "the bitwise operators in the dynamic world"
  else
    let a = emit_expr env l and b = emit_expr env r in
    let plain text = Printf.sprintf "(%s %s %s)" a text b in
    let wrap text =
      Printf.sprintf "(int64_t)((uint64_t)(%s) %s (uint64_t)(%s))" a text b
    in
    let byte wrap_op =
      Printf.sprintf "(uint8_t)((uint8_t)(%s) %s (uint8_t)(%s))" a wrap_op b
    in
    match (l.Emo_ir.ety, op) with
    (* Int64: +, -, * wrap through uint64_t; div and remainder guard
       INT64_MIN / -1 in the runtime. *)
    | Emo_check.Int64, Add -> wrap "+"
    | Emo_check.Int64, Sub -> wrap "-"
    | Emo_check.Int64, Mul -> wrap "*"
    | Emo_check.Int64, Div -> Printf.sprintf "emo_div_i64(%s, %s)" a b
    | Emo_check.Int64, Mod -> Printf.sprintf "emo_mod_i64(%s, %s)" a b
    | Emo_check.Int64, (Eq | Ne | Lt | Le | Gt | Ge) -> plain (compare_text op)
    (* two's complement is exact on int64_t; shifts guard the count *)
    | Emo_check.Int64, Bit_and -> plain "&"
    | Emo_check.Int64, Bit_or -> plain "|"
    | Emo_check.Int64, Bit_xor -> plain "^"
    | Emo_check.Int64, Shl -> Printf.sprintf "emo_shl_i64(%s, %s)" a b
    | Emo_check.Int64, Shr -> Printf.sprintf "emo_shr_i64(%s, %s)" a b
    | Emo_check.Int64, _ -> refuse "this integer operation"
    (* Byte wraps at 256 by truncation; div and remainder reuse the
       Int64 guards, shifts the Int64 count rules *)
    | Emo_check.Byte, Add -> byte "+"
    | Emo_check.Byte, Sub -> byte "-"
    | Emo_check.Byte, Mul -> byte "*"
    | Emo_check.Byte, Div -> Printf.sprintf "(uint8_t)emo_div_i64(%s, %s)" a b
    | Emo_check.Byte, Mod -> Printf.sprintf "(uint8_t)emo_mod_i64(%s, %s)" a b
    | Emo_check.Byte, (Eq | Ne | Lt | Le | Gt | Ge) -> plain (compare_text op)
    | Emo_check.Byte, Bit_and -> byte "&"
    | Emo_check.Byte, Bit_or -> byte "|"
    | Emo_check.Byte, Bit_xor -> byte "^"
    | Emo_check.Byte, Shl ->
        Printf.sprintf "(uint8_t)emo_shl_i64((int64_t)(%s), (int64_t)(%s))" a b
    | Emo_check.Byte, Shr ->
        Printf.sprintf "(uint8_t)emo_shr_i64((int64_t)(%s), (int64_t)(%s))" a b
    | Emo_check.Byte, _ -> refuse "this Byte operation"
    (* Float64: plain IEEE arithmetic and comparison. *)
    | Emo_check.Float64, (Add | Sub | Mul | Div) -> plain (arith_text op)
    | Emo_check.Float64, (Eq | Ne | Lt | Le | Gt | Ge) ->
        plain (compare_text op)
    | Emo_check.Float64, _ -> refuse "this Float64 operation"
    (* Bool *)
    | Emo_check.Bool, (Eq | Ne) -> plain (compare_text op)
    | Emo_check.Bool, And -> plain "&&"
    | Emo_check.Bool, Or -> plain "||"
    | Emo_check.Bool, _ -> refuse "this Boolean operation"
    (* String: concatenation and content equality. *)
    | Emo_check.String, Add -> Printf.sprintf "emo_str_concat(%s, %s)" a b
    | Emo_check.String, Eq -> Printf.sprintf "emo_str_eq(%s, %s)" a b
    | Emo_check.String, Ne -> Printf.sprintf "(!emo_str_eq(%s, %s))" a b
    | Emo_check.String, _ -> refuse "this String operation"
    (* Char *)
    | Emo_check.Char, (Eq | Ne) -> plain (compare_text op)
    | Emo_check.Char, _ -> refuse "this Char operation"
    | _ -> refuse "this expression form"

and fresh_c env base =
  env.fresh <- env.fresh + 1;
  Printf.sprintf "%s%d" base env.fresh

(* One branch's pattern as a predicate over the scrutinee word. *)
and pattern_test env (s : string) (p : Ast.pattern) : string =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> "true"
  | Ast.Pattern_literal lit ->
      let lit_expr =
        match lit with
        | Ast.L_int n ->
            { Emo_ir.ety = Emo_check.Int64; Emo_ir.desc = Const (Ast.L_int n) }
        | Ast.L_float f ->
            {
              Emo_ir.ety = Emo_check.Float64;
              Emo_ir.desc = Const (Ast.L_float f);
            }
        | Ast.L_string str ->
            {
              Emo_ir.ety = Emo_check.String;
              Emo_ir.desc = Const (Ast.L_string str);
            }
        | Ast.L_bool b ->
            { Emo_ir.ety = Emo_check.Bool; Emo_ir.desc = Const (Ast.L_bool b) }
        | Ast.L_char c ->
            { Emo_ir.ety = Emo_check.Char; Emo_ir.desc = Const (Ast.L_char c) }
        | Ast.L_byte _ -> refuse "Byte patterns"
      in
      Printf.sprintf "emo_eq_dyn(%s, %s)" s (as_dyn env lit_expr)
  | Ast.Enum_member (t, m) ->
      Printf.sprintf "emo_enum_is(%s, %s, %s)" s (c_string t) (c_string m)
  | Ast.Tuple_pattern ps ->
      let subs =
        List.mapi
          (fun i sub ->
            pattern_test env
              (Printf.sprintf "emo_index(%s, INT64_C(%d))" s i)
              sub)
          ps
      in
      Printf.sprintf "(emo_is_tuple(%s) && emo_length(%s) == INT64_C(%d)%s)" s s
        (List.length ps)
        (if subs = [] then "" else " && " ^ String.concat " && " subs)

(* The binding statements that recover a pattern's variables. [sfx]
   keeps same-named bindings of sibling branches distinct (receive's
   branches share one scope level). *)
and pattern_bind_sfx env (get : string) (p : Ast.pattern) (sfx : string) : unit
    =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_literal _ | Ast.Enum_member _ -> ()
  | Ast.Pattern_binding name ->
      let c = c_ident name ^ sfx in
      put env "  emo_value %s = %s;\n" c get;
      env.scope <- (name, c, Emo_check.Unknown) :: env.scope
  | Ast.Tuple_pattern ps ->
      List.iteri
        (fun i sub ->
          pattern_bind_sfx env
            (Printf.sprintf "emo_index(%s, INT64_C(%d))" get i)
            sub sfx)
        ps

and pattern_bind env (get : string) (p : Ast.pattern) : unit =
  pattern_bind_sfx env get p ""

(* Drop a redundant outermost parenthesis pair — a comparison at an
   if-condition's top level keeps clang's -Wparentheses-equality
   quiet. Only when the first `(` really matches the last `)`. *)
and unwrap (s : string) : string =
  let n = String.length s in
  if n >= 2 && s.[0] = '(' && s.[n - 1] = ')' then begin
    let depth = ref 0 in
    let outer = ref true in
    String.iteri
      (fun i c ->
        if c = '(' then incr depth
        else if c = ')' then begin
          decr depth;
          if !depth = 0 && i <> n - 1 then outer := false
        end)
      s;
    if !outer then String.sub s 1 (n - 2) else s
  end
  else s

(* ---- Statements ---- *)

and emit_builtin env (name : string) (args : Emo_ir.expr list) : unit =
  match (name, args) with
  | "println", [ e ] -> (
      if is_dyn e.Emo_ir.ety then
        put env "  emo_println_dyn(%s);\n" (as_dyn env e)
      else
        let arg = emit_expr env e in
        match e.Emo_ir.ety with
        | Emo_check.Int64 -> put env "  emo_println_i64(%s);\n" arg
        | Emo_check.String -> put env "  emo_println_str(%s);\n" arg
        | Emo_check.Float64 -> put env "  emo_println_f64(%s);\n" arg
        | Emo_check.Bool -> put env "  emo_println_bool(%s);\n" arg
        | Emo_check.Char -> put env "  emo_println_char(%s);\n" arg
        | Emo_check.Byte -> put env "  emo_println_byte(%s);\n" arg
        | t ->
            refuse
              (Printf.sprintf "println of `%s` values" (Emo_check.to_string t)))
  | "println", _ -> refuse "println with more than one argument"
  | "halt", [] -> put env "  emo_process_halt_current();\n"
  | "self_pid", [] -> put env "  (void)(emo_box_pid(emo_process_self_pid()));\n"
  | name, args ->
      put env "  (void)(%s);\n" (emit_io_builtin env Emo_check.Void name args)

(* A tail call becomes a parameter rebind and a jump: the arguments
   land in fresh temporaries first, so one rebind cannot observe
   another. *)
and emit_tail_rebind env (callee : string) (args : Emo_ir.expr list) : unit =
  match List.assoc_opt callee env.tail_rebinds with
  | None -> assert false (* only called with a rebindable callee *)
  | Some slots ->
      let values =
        List.map2
          (fun (arg : Emo_ir.expr) (_, ty) ->
            if is_dyn ty then as_dyn env arg else as_native env arg ty)
          args slots
      in
      put env "  {\n";
      (match List.combine slots values with
      | pairs ->
          List.iteri
            (fun i ((_, ty), value) ->
              put env "    %s __t%d = %s;\n" (param_type ty) i value)
            pairs;
          List.iteri
            (fun i (c_name, _) -> put env "    %s = __t%d;\n" c_name i)
            slots);
      put env "    goto emo_head_%s;\n  }\n" (c_ident callee)

and emit_stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Effect { desc = Builtin { name = "println"; args }; _ } ->
      emit_builtin env "println" args
  | Effect { desc = Builtin { name = "halt"; args = [] }; _ } ->
      emit_builtin env "halt" []
  | Effect { desc = Builtin { name = "self_pid"; args = [] }; _ } ->
      put env "  (void)(emo_box_pid(emo_process_self_pid()));\n"
  | Effect { ety; desc = Builtin { name; args; _ }; _ } ->
      let code = emit_io_builtin env ety name args in
      put env "  (void)(%s);\n" code
  | Effect { ety; desc = Do_spawn { func; args }; _ } ->
      let code = emit_spawn_site env func args ety in
      put env "  (void)(%s);\n" code
  | Effect { ety; desc = Call { func; args }; _ } -> (
      match Hashtbl.find_opt env.forfuncs func with
      | Some f -> put env "  (void)(%s);\n" (foreign_call env ety f args)
      | None -> (
          match Hashtbl.find_opt env.funsigs func with
          | Some (param_types, _fres) -> (
              match List.combine args param_types with
              | pairs ->
                  let arg_code =
                    List.map
                      (fun (arg, (_, pty)) ->
                        if is_dyn pty then as_dyn env arg
                        else as_native env arg pty)
                      pairs
                  in
                  put env "  %s(%s);\n" (c_ident func)
                    (String.concat ", " arg_code)
              | exception Invalid_argument _ ->
                  let arg_code =
                    String.concat ", " (List.map (emit_expr env) args)
                  in
                  put env "  %s(%s);\n" (c_ident func) arg_code)
          | None ->
              let arg_code =
                String.concat ", " (List.map (emit_expr env) args)
              in
              put env "  %s(%s);\n" (c_ident func) arg_code))
  | Effect { ety; desc = Method { self_; name; args; _ }; _ } ->
      let code = emit_method env ety self_ name args in
      put env "  (void)(%s);\n" code
  | Effect { ety; desc = Call_value { f; args }; _ } ->
      let code = closure_call env f args in
      let code = if is_dyn ety then code else unbox_code code ety in
      put env "  (void)(%s);\n" code
  | Effect _ -> refuse "this expression statement"
  | Let { name; init; _ } -> (
      let value = emit_expr env init in
      match c_type init.Emo_ir.ety with
      | Some "void" -> refuse "Void bindings"
      | Some t ->
          let c_name = c_ident name in
          env.scope <- (name, c_name, init.Emo_ir.ety) :: env.scope;
          put env "  %s %s = %s;\n" t c_name value
      | None ->
          refuse
            (Printf.sprintf "`%s` bindings"
               (Emo_check.to_string init.Emo_ir.ety)))
  | Assign_var { name; value } -> (
      match List.find_opt (fun (n, _, _) -> String.equal n name) env.scope with
      | Some (_, c_name, ty) ->
          let v =
            if is_dyn ty then as_dyn env value else as_native env value ty
          in
          put env "  %s = %s;\n" c_name v
      | None -> refuse (Printf.sprintf "assignment to `%s` here" name))
  | Send { target; message } ->
      let pid =
        if is_dyn target.Emo_ir.ety then
          Printf.sprintf "emo_unbox_pid(%s)" (as_dyn env target)
        else emit_expr env target
      in
      put env "  emo_process_send(%s, %s);\n" pid (as_dyn env message)
  | Set_global_var _ -> refuse "module-level variable assignment"
  | Set_field { self_; name; value } ->
      let idx = field_index env self_ name in
      put env "  emo_set_field(%s, INT64_C(%d), %s);\n" (as_dyn env self_) idx
        (as_dyn env value)
  | If { cond; then_; else_ } ->
      let c = emit_expr env cond in
      let c =
        if is_dyn cond.Emo_ir.ety then unbox_code c Emo_check.Bool else c
      in
      put env "  if (%s) {\n" (unwrap c);
      emit_stmts env then_;
      if else_ = [] then put env "  }\n"
      else (
        put env "  } else {\n";
        emit_stmts env else_;
        put env "  }\n")
  | Case { scrutinee; branches } ->
      (* Sequential branches: each tests, binds, and — when the guard
         allows — runs its body and jumps to the end; a failed guard
         falls through to the next branch. Bindings live inside the
         test's block, so the guard sees them and a non-matching
         scrutinee never evaluates an accessor. A native scrutinee
         (Byte, Int64, ...) keeps its C type; only the dynamic world
         takes accessors. *)
      let s = fresh_c env "__case" in
      let end_label = fresh_c env "__case_end" in
      let native_ty =
        if is_dyn scrutinee.Emo_ir.ety then None
        else c_type scrutinee.Emo_ir.ety
      in
      (match native_ty with
      | Some cty -> put env "  %s %s = %s;\n" cty s (emit_expr env scrutinee)
      | None -> put env "  emo_value %s = %s;\n" s (as_dyn env scrutinee));
      List.iter
        (fun (b : Emo_ir.branch) ->
          let test =
            match native_ty with
            | Some _ ->
                pattern_test_native env s scrutinee.Emo_ir.ety b.Emo_ir.pattern
            | None -> pattern_test env s b.Emo_ir.pattern
          in
          put env "  if (%s) {\n" (unwrap test);
          (match native_ty with
          | Some _ ->
              pattern_bind_native env s scrutinee.Emo_ir.ety b.Emo_ir.pattern
          | None -> pattern_bind env s b.Emo_ir.pattern);
          let run_body () =
            emit_stmts env b.Emo_ir.body;
            put env "    goto %s;\n" end_label
          in
          match b.Emo_ir.guard with
          | Some g ->
              let g_code = emit_expr env g in
              let g_code =
                if is_dyn g.Emo_ir.ety then unbox_code g_code Emo_check.Bool
                else g_code
              in
              put env "    if (%s) {\n" g_code;
              run_body ();
              put env "    }\n  }\n"
          | None ->
              run_body ();
              put env "  }\n")
        branches;
      put env "  emo_no_match();\n%s: ;\n" end_label
  | Receive { branches; _ } ->
      (* Selective receive: the generated code owns the matching — it
         scans the mailbox in order for the first message any branch
         accepts (a failed guard leaves the message queued), and parks
         the fiber when nothing matches, rescanning on wake. Branch
         bindings carry the branch index so same-named variables do
         not collide at C scope. *)
      let uniq = env.fresh + 1 in
      env.fresh <- uniq;
      let s = Printf.sprintf "__msg%d" uniq in
      let retry = Printf.sprintf "__recv_retry_%d" uniq in
      let end_label = Printf.sprintf "__recv_end_%d" uniq in
      put env "  emo_value %s = (emo_value)0;\n" s;
      put env "%s: ;\n" retry;
      put env "  if (emo_mailbox_empty()) {\n";
      put env "    emo_process_park_current();\n";
      put env "    goto %s;\n  }\n" retry;
      put env "  {\n    void *__m = emo_mailbox_first();\n";
      put env "    while (__m != NULL) {\n";
      put env "      %s = emo_msg_value(__m);\n" s;
      List.iteri
        (fun i (b : Emo_ir.branch) ->
          let test = pattern_test env s b.Emo_ir.pattern in
          let lbl = Printf.sprintf "__recv_b%d_%d" i uniq in
          put env "      if (%s) {\n" test;
          match b.Emo_ir.guard with
          | Some g ->
              let g_code = emit_expr env g in
              let g_code =
                if is_dyn g.Emo_ir.ety then unbox_code g_code Emo_check.Bool
                else g_code
              in
              put env "        if (%s) {\n" g_code;
              put env "          emo_mailbox_take_current(__m);\n";
              put env "          goto %s;\n        }\n" lbl;
              put env "      }\n"
          | None ->
              put env "        emo_mailbox_take_current(__m);\n";
              put env "        goto %s;\n" lbl;
              put env "      }\n")
        branches;
      put env "      __m = emo_mailbox_next(__m);\n";
      put env "    }\n  }\n";
      put env "  emo_process_park_current();\n";
      put env "  goto %s;\n" retry;
      List.iteri
        (fun i (b : Emo_ir.branch) ->
          put env "%s: ;\n" (Printf.sprintf "__recv_b%d_%d" i uniq);
          pattern_bind_sfx env s b.Emo_ir.pattern
            (Printf.sprintf "__r%d_%d" uniq i);
          emit_stmts env b.Emo_ir.body;
          put env "  goto %s;\n" end_label)
        branches;
      put env "%s: ;\n" end_label
  | Raise e -> put env "  emo_raise(%s);\n" (as_dyn env e)
  | Return_stmt e -> (
      if env.in_main then refuse "`return` at the top level";
      let tail_callee =
        match e.Emo_ir.desc with
        | Call { func; _ } when List.mem_assoc func env.tail_rebinds ->
            Some func
        | _ -> None
      in
      match e.Emo_ir.desc with
      | Builtin { name = "halt"; _ } ->
          (* `return halt()`: the process never resumes *)
          put env "  emo_process_halt_current();\n";
          ()
      | _ -> (
          match tail_callee with
          | Some callee -> (
              match e.Emo_ir.desc with
              | Call { args; _ } -> emit_tail_rebind env callee args
              | _ -> assert false)
          | None ->
              if env.fresult = Emo_check.Void then
                put env "  goto emo_return;\n"
              else if is_dyn env.fresult then
                (* the closure convention: a direct dynamic return *)
                put env "  return %s;\n" (as_dyn env e)
              else
                let value = as_native env e env.fresult in
                put env "  __result = %s;\n  goto emo_return;\n" value))

and emit_stmts env (stmts : Emo_ir.stmt list) : unit =
  List.iter (emit_stmt env) stmts

and has_return (stmts : Emo_ir.stmt list) : bool =
  List.exists
    (fun s ->
      match s with
      | Emo_ir.Return_stmt _ -> true
      | Emo_ir.If { then_; else_; _ } -> has_return then_ || has_return else_
      | Emo_ir.Case { branches; _ } ->
          List.exists (fun b -> has_return b.Emo_ir.body) branches
      | Emo_ir.Receive { branches; _ } ->
          List.exists (fun b -> has_return b.Emo_ir.body) branches
      | _ -> false)
    stmts

(* ---- Foreign defs (T24.8) ----

   The direct C ABI: a `foreign def` declares the C symbol and calls
   it with native types — no wrapper generator. A String crossing OUT
   gets a NUL-terminated copy; a char * coming IN is copied into a
   cell. Opaque handles ride pointer-sized Int64s. A Void return is
   the shape of a fire-and-forget call. *)

let foreign_c_type (t : Emo_check.t) : string =
  match t with
  | Emo_check.Int64 -> "int64_t"
  | Emo_check.Float64 -> "double"
  | Emo_check.Bool -> "bool"
  | Emo_check.String -> "const char *"
  | Emo_check.Void -> "void"
  | _ -> refuse (Printf.sprintf "`%s` across the C ABI" (Emo_check.to_string t))

(* ---- The tail-call graph ----

   A → B when A's body returns a direct call to B. A cycle of two or
   more functions is a mutual-tail cluster: it merges into one C
   function so every edge on the cycle is a jump. *)

let rec tail_callees (stmts : Emo_ir.stmt list) : string list =
  List.concat_map
    (fun s ->
      match s with
      | Emo_ir.Return_stmt { desc = Call { func; _ }; _ } -> [ func ]
      | Emo_ir.If { then_; else_; _ } -> tail_callees then_ @ tail_callees else_
      | Emo_ir.Case { branches; _ } ->
          List.concat_map (fun b -> tail_callees b.Emo_ir.body) branches
      | Emo_ir.Receive { branches; _ } ->
          List.concat_map (fun b -> tail_callees b.Emo_ir.body) branches
      | _ -> [])
    stmts

(* The clusters, in program order; each is the member list (size ≥ 2).
   A function is in a cluster with another when each tail-reaches the
   other. *)
let tail_clusters (funcs : Emo_ir.func list) : string list list =
  let module M = Map.Make (String) in
  let module S = Set.Make (String) in
  let edges =
    List.fold_left
      (fun acc (f : Emo_ir.func) ->
        M.add f.Emo_ir.fname
          (List.fold_left
             (fun a callee -> S.add callee a)
             S.empty
             (tail_callees f.Emo_ir.fbody))
          acc)
      M.empty funcs
  in
  let fixed = ref edges in
  let changed = ref true in
  while !changed do
    changed := false;
    fixed :=
      M.map
        (fun direct ->
          let closure =
            S.fold
              (fun next acc ->
                S.union acc
                  (Option.value ~default:S.empty (M.find_opt next !fixed)))
              direct direct
          in
          if not (S.equal closure direct) then (
            changed := true;
            closure)
          else direct)
        !fixed
  done;
  let reaches from to_ = S.mem to_ (M.find from !fixed) in
  let rec collect remaining acc =
    match remaining with
    | [] -> List.rev acc
    | head :: rest -> (
        let siblings =
          List.filter
            (fun other ->
              other <> head && reaches head other && reaches other head)
            rest
        in
        match siblings with
        | [] -> collect rest acc
        | _ ->
            collect
              (List.filter (fun n -> not (List.mem n siblings)) rest)
              ((head :: siblings) :: acc))
  in
  collect (List.map (fun f -> f.Emo_ir.fname) funcs) []

(* Whether a body has a `return` on any path — it is the only user of
   the epilogue label. *)
(* ---- Functions ---- *)

let signature (f : Emo_ir.func) : string * string =
  let params =
    match f.Emo_ir.fparams with
    | [] -> "void"
    | ps ->
        String.concat ", "
          (List.map
             (fun (name, ty) ->
               Printf.sprintf "%s %s" (param_type ty) (c_ident name))
             ps)
  in
  (result_type f, params)

(* A standalone function: the head label carries the tail-call
   rebind, the epilogue label receives every `return`. [fclass] makes
   `self` resolve fields when emitting a method. *)
let emit_single env0 ?(fclass : string option = None) (f : Emo_ir.func) : unit =
  let ret, params = signature f in
  let env =
    {
      env0 with
      fresh = 0;
      fname = f.Emo_ir.fname;
      fresult = f.Emo_ir.fresult;
      fclass;
      scope = List.map (fun (n, ty) -> (n, c_ident n, ty)) f.Emo_ir.fparams;
      tail_rebinds =
        [
          ( f.Emo_ir.fname,
            List.map (fun (n, ty) -> (c_ident n, ty)) f.Emo_ir.fparams );
        ];
      in_main = false;
    }
  in
  put env "%s %s(%s) {\n" ret (c_ident f.Emo_ir.fname) params;
  if ret <> "void" && not (is_dyn f.Emo_ir.fresult) then
    put env "  %s __result = %s;\n" ret (zero_value ret);
  (* The head label exists only when a self-tail call jumps to it. *)
  if List.mem f.Emo_ir.fname (tail_callees f.Emo_ir.fbody) then
    put env "emo_head_%s:;\n" (c_ident f.Emo_ir.fname);
  emit_stmts env f.Emo_ir.fbody;
  (* a dynamic result returns directly — the epilogue slot is native
     only *)
  if has_return f.Emo_ir.fbody && not (is_dyn f.Emo_ir.fresult) then
    put env "emo_return:;\n";
  if ret = "void" then put env "  return;\n"
  else if is_dyn f.Emo_ir.fresult then put env "  return (emo_value)0;\n"
  else put env "  return __result;\n";
  put env "}\n\n"

(* A cluster slot: the member's parameter, prefixed to stay unique
   across the merged signature. *)
let slot_name member param = Printf.sprintf "%s__p_%s" member (c_ident param)

(* The merged shape of a cluster: one return type (mixed result types
   refuse), the member bodies, and the slot list of every member
   parameter in member order. *)
let cluster_layout (index : int) (members : Emo_ir.func list) :
    string * string * string * (string * string * Emo_check.t) list =
  let rets = List.map result_type members in
  let ret = List.hd rets in
  if List.exists (fun r -> r <> ret) rets then
    refuse "a mutual-tail cluster with mixed result types";
  let slots =
    List.concat_map
      (fun (m : Emo_ir.func) ->
        List.map (fun (n, ty) -> (m.Emo_ir.fname, n, ty)) m.Emo_ir.fparams)
      members
  in
  let params =
    match slots with
    | [] -> "void"
    | _ ->
        String.concat ", "
          (List.map
             (fun (m, n, ty) ->
               Printf.sprintf "%s %s" (param_type ty) (slot_name m n))
             slots)
  in
  (Printf.sprintf "emo__scc%d" index, ret, params, slots)

(* A mutual-tail cluster: one C function holding every member body.
   Each member keeps its mangled name as a thin wrapper so call sites
   need not know about the merge. *)
let emit_cluster env0 (index : int) (members : Emo_ir.func list) : unit =
  let cluster, ret, cluster_params, slots = cluster_layout index members in
  let with_entry p = "int __entry" ^ if p = "void" then "" else ", " ^ p in
  List.iter
    (fun (m : Emo_ir.func) ->
      let m_ret, m_params = signature m in
      let entry =
        match
          List.find_index
            (fun (x : Emo_ir.func) -> x.Emo_ir.fname = m.Emo_ir.fname)
            members
        with
        | Some i -> i
        | None -> 0
      in
      let args =
        List.map
          (fun (other, n, ty) ->
            if other = m.Emo_ir.fname then c_ident n else dummy_value ty)
          slots
      in
      put env0 "%s %s(%s) {\n  return %s(%d, %s);\n}\n\n" m_ret
        (c_ident m.Emo_ir.fname) m_params cluster entry
        (String.concat ", " args))
    members;
  put env0 "%s %s(%s) {\n" ret cluster (with_entry cluster_params);
  (* An external call may target any member of the cluster: route to
     that member's head before its body runs. *)
  List.iteri
    (fun i (m : Emo_ir.func) ->
      put env0 "  if (__entry == %d) goto emo_head_%s;\n" i
        (c_ident m.Emo_ir.fname))
    members;
  let dyn_ret =
    List.exists (fun (m : Emo_ir.func) -> is_dyn m.Emo_ir.fresult) members
  in
  if ret <> "void" && not dyn_ret then
    put env0 "  %s __result = %s;\n" ret (zero_value ret);
  List.iter
    (fun (m : Emo_ir.func) ->
      let env =
        {
          env0 with
          fresh = 0;
          fname = m.Emo_ir.fname;
          fresult = m.Emo_ir.fresult;
          scope =
            List.map
              (fun (n, ty) -> (n, slot_name m.Emo_ir.fname n, ty))
              m.Emo_ir.fparams;
          tail_rebinds =
            List.map
              (fun (o : Emo_ir.func) ->
                ( o.Emo_ir.fname,
                  List.map
                    (fun (n, ty) -> (slot_name o.Emo_ir.fname n, ty))
                    o.Emo_ir.fparams ))
              members;
          in_main = false;
        }
      in
      (* Every member is on the cluster's cycle, so its head label
         always has an incoming jump. The body lives in its own block:
         C labels open no scope, and sibling members' locals would
         collide in the shared function scope. *)
      put env "emo_head_%s: {\n" (c_ident m.Emo_ir.fname);
      emit_stmts env m.Emo_ir.fbody;
      put env "}\n")
    members;
  if List.exists (fun (m : Emo_ir.func) -> has_return m.Emo_ir.fbody) members
  then put env0 "emo_return:;\n";
  if ret = "void" then put env0 "  return;\n"
  else if dyn_ret then put env0 "  return (emo_value)0;\n"
  else put env0 "  return __result;\n";
  put env0 "}\n\n"

(* A constructor: allocate the instance, run the init body with self
   bound, return it. *)
let emit_ctor env0 (c : Emo_ir.class_) : unit =
  let ctor = c.Emo_ir.cname ^ "__new" in
  let fields =
    match Hashtbl.find_opt env0.fields c.Emo_ir.cname with
    | Some fs -> fs
    | None -> []
  in
  match c.Emo_ir.cinit with
  | None ->
      put env0
        "emo_value %s(void) {\n  return emo_instance_new(&vt_%s, 0);\n}\n\n"
        ctor c.Emo_ir.cname
  | Some init ->
      let real_params = List.tl init.Emo_ir.fparams in
      let env =
        {
          env0 with
          fresh = 0;
          fname = ctor;
          fresult = Emo_check.Void;
          fclass = Some c.Emo_ir.cname;
          tail_rebinds = [];
          in_main = false;
          scope =
            ("self", "self", Emo_check.Unknown)
            :: List.map (fun (n, ty) -> (n, c_ident n, ty)) real_params;
        }
      in
      put env "emo_value %s(%s) {\n" ctor
        (if real_params = [] then "void"
         else
           String.concat ", "
             (List.map
                (fun (n, ty) ->
                  Printf.sprintf "%s %s" (param_type ty) (c_ident n))
                real_params));
      put env "  emo_value self = emo_instance_new(&vt_%s, %d);\n"
        c.Emo_ir.cname (List.length fields);
      emit_stmts env init.Emo_ir.fbody;
      if has_return init.Emo_ir.fbody then put env "emo_return:;\n";
      put env "  return self;\n}\n\n"

(* The dynamic-convention thunk for one method: convert the word
   arguments to the method's parameter types, the result back. *)
let emit_thunk env0 (c : Emo_ir.class_) (m : Emo_ir.func) : unit =
  ignore c;
  let thunk = c_ident m.Emo_ir.fname ^ "__dyn" in
  put env0 "static emo_value %s(emo_value self, const emo_value *args) {\n"
    thunk;
  put env0 "  (void)self;\n  (void)args;\n";
  let params = List.tl m.Emo_ir.fparams in
  List.iteri
    (fun i (_, ty) ->
      if not (is_dyn ty) then
        put env0 "  %s __a%d = %s;\n" (param_type ty) i
          (unbox_code (Printf.sprintf "args[%d]" i) ty))
    params;
  let arg_code =
    "self"
    :: List.mapi
         (fun i (_, ty) ->
           if is_dyn ty then Printf.sprintf "args[%d]" i
           else Printf.sprintf "__a%d" i)
         params
  in
  let call =
    Printf.sprintf "%s(%s)" (c_ident m.Emo_ir.fname)
      (String.concat ", " arg_code)
  in
  let result =
    if m.Emo_ir.fresult = Emo_check.Void then
      Printf.sprintf "((void)(%s), emo_vbool(false))" call
    else if is_dyn m.Emo_ir.fresult then call
    else box_code call m.Emo_ir.fresult
  in
  put env0 "  return %s;\n}\n\n" result

(* ---- The program ---- *)

(* Emit the program as (main.c, emo_defs.h). The defs header carries
   every externally linkable declaration — defs, foreign symbols,
   tail-call clusters, class constructors and methods — so an FFI shim
   can include it instead of hand-writing externs: a signature that
   drifts breaks at cc time in both directions instead of silently at
   run time. Static helpers (the __dyn thunks) stay TU-local. *)
let emit (program : Emo_ir.program) : string * string =
  spawn_counter := 0;
  closure_counter := 0;
  let clusters = tail_clusters program.pfuncs in
  let cluster_members name =
    List.find_opt (List.mem name) clusters |> Option.value ~default:[ name ]
  in
  let in_cluster name =
    let members = cluster_members name in
    List.length members > 1
  in
  let member_funcs (members : string list) : Emo_ir.func list =
    List.filter_map
      (fun f -> if List.mem f.Emo_ir.fname members then Some f else None)
      program.pfuncs
  in
  (* Class metadata: field names in init-assignment order, and the
     interface contracts. *)
  let fields_of (c : Emo_ir.class_) : string list =
    match c.Emo_ir.cinit with
    | None -> []
    | Some init ->
        List.filter_map
          (fun (st : Emo_ir.stmt) ->
            match st with
            | Emo_ir.Set_field { name; _ } -> Some name
            | _ -> None)
          init.Emo_ir.fbody
  in
  let classes_tbl = Hashtbl.create 8 in
  let ifaces_tbl = Hashtbl.create 8 in
  let fields_tbl = Hashtbl.create 8 in
  List.iter
    (fun (c : Emo_ir.class_) ->
      Hashtbl.replace classes_tbl c.Emo_ir.cdisplay c;
      Hashtbl.replace fields_tbl c.Emo_ir.cname (fields_of c))
    program.pclasses;
  List.iter
    (fun (name, sigs) -> Hashtbl.replace ifaces_tbl name sigs)
    program.pinterfaces;
  let buf = Buffer.create (16 * 1024) in
  let funsigs = Hashtbl.create 32 in
  List.iter
    (fun (f : Emo_ir.func) ->
      Hashtbl.replace funsigs f.Emo_ir.fname (f.Emo_ir.fparams, f.Emo_ir.fresult))
    program.pfuncs;
  List.iter
    (fun (c : Emo_ir.class_) ->
      let ctor = c.Emo_ir.cname ^ "__new" in
      let params =
        match c.Emo_ir.cinit with
        | Some init -> List.tl init.Emo_ir.fparams
        | None -> []
      in
      Hashtbl.replace funsigs ctor (params, Emo_check.Unknown))
    program.pclasses;
  let forfuncs = Hashtbl.create 8 in
  List.iter
    (fun (f : Emo_ir.func) ->
      match f.Emo_ir.fforeign with
      | Some _ -> Hashtbl.replace forfuncs f.Emo_ir.fname f
      | None -> ())
    program.pfuncs;
  let env0 =
    {
      buf;
      fresh = 0;
      scope = [];
      fname = "";
      fresult = Emo_check.Void;
      fclass = None;
      tail_rebinds = [];
      in_main = true;
      funsigs;
      classes = classes_tbl;
      ifaces = ifaces_tbl;
      fields = fields_tbl;
      closures = Buffer.create (16 * 1024);
      closure_decls = [];
      forfuncs;
    }
  in
  let head = Buffer.create 256 in
  Buffer.add_string head
    "/* Generated by the Emo compiler (target: c) — do not edit. */\n\n";
  Buffer.add_string head "#include \"emo_c_runtime.h\"\n\n";
  (* Forward declarations land in their own buffer: the fiber wrappers
     (spawn/closures) assemble before them and call declared targets. *)
  let forward = Buffer.create (16 * 1024) in
  let defs_h = Buffer.create (16 * 1024) in
  Buffer.add_string defs_h
    "/* Generated by the Emo compiler (target: c) — the externally\n\
    \  linkable declarations of this program, for FFI shims. Do not\n\
    \  edit. */\n\n\
     #include \"emo_c_runtime.h\"\n\n";
  env0.buf <- forward;
  (* Forward declarations: every function keeps its mangled name, each
     cluster contributes its merged function, and every class
     contributes its constructor and methods. Each declaration also
     lands in emo_defs.h. *)
  List.iter
    (fun f ->
      match f.Emo_ir.fforeign with
      | Some _ -> () (* the extern declaration below covers it *)
      | None ->
          let ret, params = signature f in
          let line =
            Printf.sprintf "%s %s(%s);\n" ret (c_ident f.Emo_ir.fname) params
          in
          put env0 "%s" line;
          Buffer.add_string defs_h line)
    program.pfuncs;
  List.iteri
    (fun i members ->
      let cluster, ret, cluster_params, _ =
        cluster_layout i (member_funcs members)
      in
      let line =
        Printf.sprintf "%s %s(int __entry, %s);\n" ret cluster cluster_params
      in
      put env0 "%s" line;
      Buffer.add_string defs_h line)
    clusters;
  List.iter
    (fun (c : Emo_ir.class_) ->
      let ret, params =
        match c.Emo_ir.cinit with
        | Some init ->
            ( "emo_value",
              String.concat ", "
                (List.map
                   (fun (n, ty) ->
                     Printf.sprintf "%s %s" (param_type ty) (c_ident n))
                   (List.tl init.Emo_ir.fparams)) )
        | None -> ("emo_value", "void")
      in
      let ctor_line =
        Printf.sprintf "%s %s__new(%s);\n" ret c.Emo_ir.cname params
      in
      put env0 "%s" ctor_line;
      Buffer.add_string defs_h ctor_line;
      List.iter
        (fun (m : Emo_ir.func) ->
          let m_ret, m_params = signature m in
          let line =
            Printf.sprintf "%s %s(%s);\n" m_ret (c_ident m.Emo_ir.fname)
              m_params
          in
          put env0 "%s" line;
          Buffer.add_string defs_h line)
        c.Emo_ir.cmethods;
      (* the dynamic-convention thunks runtime dispatch goes through *)
      List.iter
        (fun (m : Emo_ir.func) ->
          put env0 "static emo_value %s__dyn(emo_value, const emo_value *);\n"
            (c_ident m.Emo_ir.fname))
        c.Emo_ir.cmethods)
    program.pclasses;
  (* The forward declarations move ahead of the wrappers in the final
     assembly; the rest of the emission continues in the main buffer. *)
  env0.buf <- buf;
  (* Foreign defs: the C symbol declarations — the direct ABI. They
     also land in emo_defs.h, so a shim's definitions are checked
     against the compiler's declarations at cc time. *)
  List.iter
    (fun (f : Emo_ir.func) ->
      match f.Emo_ir.fforeign with
      | None -> ()
      | Some symbol ->
          let params =
            match f.Emo_ir.fparams with
            | [] -> "void"
            | ps ->
                String.concat ", "
                  (List.map (fun (_, t) -> foreign_c_type t) ps)
          in
          let line =
            Printf.sprintf "extern %s %s(%s);\n"
              (foreign_c_type f.Emo_ir.fresult)
              symbol params
          in
          put env0 "%s" line;
          Buffer.add_string defs_h line)
    program.pfuncs;
  put env0 "\n";
  (* Interface contracts and class vtables. *)
  List.iter
    (fun (name, sigs) ->
      let table = Printf.sprintf "iface_%s_sigs" (c_ident name) in
      put env0 "EMO_META_UNUSED static const emo_method_sig %s[] = {%s};\n"
        table
        (String.concat ", "
           (List.map
              (fun (m, a) -> Printf.sprintf "{ %s, %d, NULL }" (c_string m) a)
              sigs));
      put env0
        "EMO_META_UNUSED static const emo_iface iface_%s = { %s, %d, %s };\n\n"
        (c_ident name) (c_string name) (List.length sigs) table)
    program.pinterfaces;
  List.iter
    (fun (c : Emo_ir.class_) ->
      let methods =
        List.map
          (fun (m : Emo_ir.func) ->
            let n = String.length c.Emo_ir.cname + 2 in
            let stripped =
              if
                String.starts_with ~prefix:(c.Emo_ir.cname ^ "__")
                  m.Emo_ir.fname
              then String.sub m.Emo_ir.fname n (String.length m.Emo_ir.fname - n)
              else m.Emo_ir.fname
            in
            (* The IR spells a predicate's `?` as `_q` for symbol safety;
               the vtable's method name is the source spelling that the
               dynamic dispatch and the interface contracts compare. *)
            let n = String.length stripped in
            let display =
              if n >= 2 && String.sub stripped (n - 2) 2 = "_q" then
                String.sub stripped 0 (n - 2) ^ "?"
              else stripped
            in
            (display, List.length m.Emo_ir.fparams - 1, m))
          c.Emo_ir.cmethods
      in
      let fs = fields_of c in
      if methods <> [] then
        put env0 "static const emo_method_sig %s__methods[] = {%s};\n"
          c.Emo_ir.cname
          (String.concat ", "
             (List.map
                (fun (n, a, m) ->
                  Printf.sprintf "{ %s, %d, &%s__dyn }" (c_string n) a
                    (c_ident m.Emo_ir.fname))
                methods));
      if fs <> [] then
        put env0 "static const char *const %s__fields[] = {%s};\n"
          c.Emo_ir.cname
          (String.concat ", " (List.map c_string fs));
      put env0 "static const emo_vtable vt_%s = { %s, %d, %s, %d, %s };\n\n"
        c.Emo_ir.cname
        (c_string c.Emo_ir.cdisplay)
        (List.length methods)
        (if methods = [] then "NULL" else c.Emo_ir.cname ^ "__methods")
        (List.length fs)
        (if fs = [] then "NULL" else c.Emo_ir.cname ^ "__fields"))
    program.pclasses;
  (* Definitions. *)
  List.iter
    (fun f ->
      if f.Emo_ir.fforeign = None && not (in_cluster f.Emo_ir.fname) then
        emit_single env0 f)
    program.pfuncs;
  List.iteri
    (fun i members -> emit_cluster env0 i (member_funcs members))
    clusters;
  List.iter (emit_ctor env0) program.pclasses;
  List.iter
    (fun (c : Emo_ir.class_) ->
      List.iter
        (fun m -> emit_single env0 ~fclass:(Some c.Emo_ir.cname) m)
        c.Emo_ir.cmethods;
      List.iter (emit_thunk env0 c) c.Emo_ir.cmethods)
    program.pclasses;
  (* The entry module's top level runs in the root process's fiber;
     every generated main ends in the scheduler loop. *)
  let env =
    {
      env0 with
      fresh = 0;
      scope = [];
      in_main = false;
      fresult = Emo_check.Void;
    }
  in
  put env "static void emo_root_entry(void) {\n";
  emit_stmts env program.pinit;
  if has_return program.pinit then put env "emo_return:;\n";
  put env "}\n\n";
  put env "int main(void) {\n";
  put env "  emo_startup();\n";
  put env "  (void)emo_spawn_process(emo_root_entry, INT64_C(0), NULL);\n";
  put env "  emo_scheduler_run();\n";
  put env "  return 0;\n}\n";
  (* Assembly: the header, then the closure declarations and
     definitions, then the bodies that take their addresses. *)
  let decls = String.concat "\n" (List.rev env0.closure_decls) in
  ( Printf.sprintf "%s%s\n%s%s\n%s" (Buffer.contents head)
      (Buffer.contents forward) decls
      (Buffer.contents env0.closures)
      (Buffer.contents buf),
    Buffer.contents defs_h )
