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
  buf : Buffer.t;
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
  funsigs : (string, (string * Emo_check.t) list) Hashtbl.t;
      (* every function's parameter types, for regime conversion at
         call sites *)
}

let put env fmt = Printf.ksprintf (Buffer.add_string env.buf) fmt

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
  | Emo_check.String -> Some "emo_str"
  | Emo_check.Unknown | Emo_check.TupleType _ | Emo_check.ArrayType _
  | Emo_check.BoxType _ ->
      Some "emo_value"
  | Emo_check.Void -> Some "void"
  | _ -> None

(* Whether a type lives in the dynamic world (the tagged word) or the
   native one (a C scalar). *)
let is_dyn (t : Emo_check.t) : bool =
  match t with
  | Emo_check.Unknown | Emo_check.TupleType _ | Emo_check.ArrayType _
  | Emo_check.BoxType _ ->
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
  | Emo_check.BoxType _ ->
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

and emit_expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Const (Ast.L_int n) ->
      if n = Int64.min_int then "INT64_MIN"
      else if n < 0L then Printf.sprintf "(-(INT64_C(%Ld)))" (Int64.abs n)
      else Printf.sprintf "INT64_C(%Ld)" n
  | Const (Ast.L_bool b) -> if b then "true" else "false"
  | Const (Ast.L_float f) -> c_float f
  | Const (Ast.L_char c) -> Printf.sprintf "INT32_C(%d)" (Char.code c)
  | Const (Ast.L_string s) -> c_str_literal s
  | Const _ -> refuse "Byte literals"
  | Var name -> c_name env name
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
  | Call { func; args } -> (
      let param_types =
        match Hashtbl.find_opt env.funsigs func with
        | Some ps -> ps
        | None -> []
      in
      match List.combine args param_types with
      | pairs ->
          let arg_code =
            List.map
              (fun (arg, (_, pty)) ->
                if is_dyn pty then as_dyn env arg else as_native env arg pty)
              pairs
          in
          Printf.sprintf "%s(%s)"
            (Emo_ir.sanitize_ident func)
            (String.concat ", " arg_code)
      | exception Invalid_argument _ ->
          (* arity mismatches are the checker's to refuse *)
          let arg_code = List.map (emit_expr env) args in
          Printf.sprintf "%s(%s)"
            (Emo_ir.sanitize_ident func)
            (String.concat ", " arg_code))
  | Tuple es ->
      let elems = String.concat ", " (List.map (as_dyn env) es) in
      Printf.sprintf "emo_tuple_new(INT64_C(%d), (emo_value[]){%s})"
        (List.length es) elems
  | Array_lit es ->
      let elems = String.concat ", " (List.map (as_dyn env) es) in
      Printf.sprintf "emo_array_new(INT64_C(%d), (emo_value[]){%s})"
        (List.length es) elems
  | Index (base, idx) ->
      let v =
        Printf.sprintf "emo_index(%s, %s)" (as_dyn env base)
          (as_native env idx Emo_check.Int64)
      in
      if is_dyn e.Emo_ir.ety then v else unbox_code v e.Emo_ir.ety
  | Box_new arg -> Printf.sprintf "emo_box_new(%s)" (as_dyn env arg)
  | _ -> refuse "this expression form"

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
and emit_method env (result_ty : Emo_check.t) (self_ : Emo_ir.expr)
    (name : string) (args : Emo_ir.expr list) : string =
  let finish v = if is_dyn result_ty then v else unbox_code v result_ty in
  match (name, args, self_.Emo_ir.ety) with
  | "to_string", [], _ ->
      if is_dyn self_.Emo_ir.ety then
        Printf.sprintf "emo_to_string_dyn(%s)" (emit_expr env self_)
      else to_str env self_
  | "read", [], _ ->
      finish (Printf.sprintf "emo_box_read(%s)" (as_dyn env self_))
  | "replace", [ v ], _ ->
      finish
        (Printf.sprintf "emo_box_replace(%s, %s)" (as_dyn env self_)
           (as_dyn env v))
  | ( "length",
      [],
      (Emo_check.ArrayType _ | Emo_check.TupleType _ | Emo_check.Unknown) ) ->
      Printf.sprintf "emo_length(%s)" (as_dyn env self_)
  | _ -> refuse "method calls"

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
    | Ast.Neg, _ | Ast.Not, _ -> refuse "this unary operation"
    | Ast.Bit_not, _ -> refuse "the bitwise operators"

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
    | Bit_and | Bit_or | Bit_xor | Shl | Shr -> refuse "the bitwise operators"
  else
    let a = emit_expr env l and b = emit_expr env r in
    let plain text = Printf.sprintf "(%s %s %s)" a text b in
    let wrap text =
      Printf.sprintf "(int64_t)((uint64_t)(%s) %s (uint64_t)(%s))" a text b
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
    | Emo_check.Int64, (Bit_and | Bit_or | Bit_xor | Shl | Shr) ->
        refuse "the bitwise operators"
    | Emo_check.Int64, _ -> refuse "this integer operation"
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

(* Drop a redundant outermost parenthesis pair — a comparison at an
   if-condition's top level keeps clang's -Wparentheses-equality
   quiet. Only when the first `(` really matches the last `)`. *)
let unwrap (s : string) : string =
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

let emit_builtin env (name : string) (args : Emo_ir.expr list) : unit =
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
        | t ->
            refuse
              (Printf.sprintf "println of `%s` values" (Emo_check.to_string t)))
  | "println", _ -> refuse "println with more than one argument"
  | _ -> refuse (Printf.sprintf "the builtin `%s`" name)

(* A tail call becomes a parameter rebind and a jump: the arguments
   land in fresh temporaries first, so one rebind cannot observe
   another. *)
let emit_tail_rebind env (callee : string) (args : Emo_ir.expr list) : unit =
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
      put env "    goto emo_head_%s;\n  }\n" (Emo_ir.sanitize_ident callee)

let rec emit_stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Effect { desc = Builtin { name; args }; _ } -> emit_builtin env name args
  | Effect { desc = Call { func; args }; _ } -> (
      let param_types =
        match Hashtbl.find_opt env.funsigs func with
        | Some ps -> ps
        | None -> []
      in
      match List.combine args param_types with
      | pairs ->
          let arg_code =
            List.map
              (fun (arg, (_, pty)) ->
                if is_dyn pty then as_dyn env arg else as_native env arg pty)
              pairs
          in
          put env "  %s(%s);\n"
            (Emo_ir.sanitize_ident func)
            (String.concat ", " arg_code)
      | exception Invalid_argument _ ->
          let arg_code = String.concat ", " (List.map (emit_expr env) args) in
          put env "  %s(%s);\n" (Emo_ir.sanitize_ident func) arg_code)
  | Effect { ety; desc = Method { self_; name; args; _ }; _ } ->
      let code = emit_method env ety self_ name args in
      put env "  (void)(%s);\n" code
  | Effect _ -> refuse "this expression statement"
  | Let { name; init; _ } -> (
      let value = emit_expr env init in
      match c_type init.Emo_ir.ety with
      | Some "void" -> refuse "Void bindings"
      | Some t ->
          let c_name = Emo_ir.sanitize_ident name in
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
  | Set_global_var _ -> refuse "module-level variable assignment"
  | Set_field _ -> refuse "field assignment"
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
  | Case _ -> refuse "`case` statements"
  | Receive _ -> refuse "`receive` statements"
  | Send _ -> refuse "message sends"
  | Raise _ -> refuse "`raise`"
  | Return_stmt e -> (
      if env.in_main then refuse "`return` at the top level";
      let tail_callee =
        match e.Emo_ir.desc with
        | Call { func; _ } when List.mem_assoc func env.tail_rebinds ->
            Some func
        | _ -> None
      in
      match tail_callee with
      | Some callee -> (
          match e.Emo_ir.desc with
          | Call { args; _ } -> emit_tail_rebind env callee args
          | _ -> assert false)
      | None ->
          if env.fresult = Emo_check.Void then put env "  goto emo_return;\n"
          else
            let value =
              if is_dyn env.fresult then as_dyn env e
              else as_native env e env.fresult
            in
            put env "  __result = %s;\n  goto emo_return;\n" value)

and emit_stmts env (stmts : Emo_ir.stmt list) : unit =
  List.iter (emit_stmt env) stmts

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
let rec has_return (stmts : Emo_ir.stmt list) : bool =
  List.exists
    (fun s ->
      match s with
      | Emo_ir.Return_stmt _ -> true
      | Emo_ir.If { then_; else_; _ } -> has_return then_ || has_return else_
      | Emo_ir.Case { branches; _ } ->
          List.exists (fun b -> has_return b.Emo_ir.body) branches
      | _ -> false)
    stmts

(* ---- Functions ---- *)

let signature (f : Emo_ir.func) : string * string =
  let params =
    match f.Emo_ir.fparams with
    | [] -> "void"
    | ps ->
        String.concat ", "
          (List.map
             (fun (name, ty) ->
               Printf.sprintf "%s %s" (param_type ty)
                 (Emo_ir.sanitize_ident name))
             ps)
  in
  (result_type f, params)

(* A standalone function: the head label carries the tail-call
   rebind, the epilogue label receives every `return`. *)
let emit_single env0 (f : Emo_ir.func) : unit =
  let ret, params = signature f in
  let env =
    {
      env0 with
      fresh = 0;
      fname = f.Emo_ir.fname;
      fresult = f.Emo_ir.fresult;
      scope =
        List.map
          (fun (n, ty) -> (n, Emo_ir.sanitize_ident n, ty))
          f.Emo_ir.fparams;
      tail_rebinds =
        [
          ( f.Emo_ir.fname,
            List.map
              (fun (n, ty) -> (Emo_ir.sanitize_ident n, ty))
              f.Emo_ir.fparams );
        ];
      in_main = false;
    }
  in
  put env "%s %s(%s) {\n" ret (Emo_ir.sanitize_ident f.Emo_ir.fname) params;
  if ret <> "void" then put env "  %s __result = %s;\n" ret (zero_value ret);
  (* The head label exists only when a self-tail call jumps to it. *)
  if List.mem f.Emo_ir.fname (tail_callees f.Emo_ir.fbody) then
    put env "emo_head_%s:;\n" (Emo_ir.sanitize_ident f.Emo_ir.fname);
  emit_stmts env f.Emo_ir.fbody;
  if has_return f.Emo_ir.fbody then put env "emo_return:;\n";
  if ret = "void" then put env "  return;\n" else put env "  return __result;\n";
  put env "}\n\n"

(* A cluster slot: the member's parameter, prefixed to stay unique
   across the merged signature. *)
let slot_name member param =
  Printf.sprintf "%s__p_%s" member (Emo_ir.sanitize_ident param)

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
  List.iter
    (fun (m : Emo_ir.func) ->
      let m_ret, m_params = signature m in
      let args =
        List.map
          (fun (other, n, ty) ->
            if other = m.Emo_ir.fname then Emo_ir.sanitize_ident n
            else dummy_value ty)
          slots
      in
      put env0 "%s %s(%s) {\n  return %s(%s);\n}\n\n" m_ret
        (Emo_ir.sanitize_ident m.Emo_ir.fname)
        m_params cluster (String.concat ", " args))
    members;
  put env0 "%s %s(%s) {\n" ret cluster cluster_params;
  if ret <> "void" then put env0 "  %s __result = %s;\n" ret (zero_value ret);
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
         always has an incoming jump. *)
      put env "emo_head_%s:;\n" (Emo_ir.sanitize_ident m.Emo_ir.fname);
      emit_stmts env m.Emo_ir.fbody)
    members;
  if List.exists (fun (m : Emo_ir.func) -> has_return m.Emo_ir.fbody) members
  then put env0 "emo_return:;\n";
  if ret = "void" then put env0 "  return;\n"
  else put env0 "  return __result;\n";
  put env0 "}\n\n"

(* ---- The program ---- *)

let emit (program : Emo_ir.program) : string =
  if List.exists (fun f -> f.Emo_ir.fforeign <> None) program.pfuncs then
    raise
      (Emo_ir.Lower_error
         "foreign definitions are not supported on the c target yet");
  if program.pclasses <> [] then refuse "classes";
  if program.pinterfaces <> [] then refuse "interfaces";
  if program.pglobals <> [] then refuse "module-level variables";
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
  let buf = Buffer.create (16 * 1024) in
  let funsigs = Hashtbl.create 32 in
  List.iter
    (fun (f : Emo_ir.func) ->
      Hashtbl.replace funsigs f.Emo_ir.fname f.Emo_ir.fparams)
    program.pfuncs;
  let env0 =
    {
      buf;
      fresh = 0;
      scope = [];
      fname = "";
      fresult = Emo_check.Void;
      tail_rebinds = [];
      in_main = true;
      funsigs;
    }
  in
  put env0 "/* Generated by the Emo compiler (target: c) — do not edit. */\n\n";
  put env0 "#include \"emo_c_runtime.h\"\n\n";
  (* Forward declarations: every function keeps its mangled name, and
     each cluster contributes its merged function. *)
  List.iter
    (fun f ->
      let ret, params = signature f in
      put env0 "%s %s(%s);\n" ret (Emo_ir.sanitize_ident f.Emo_ir.fname) params)
    program.pfuncs;
  List.iteri
    (fun i members ->
      let cluster, ret, cluster_params, _ =
        cluster_layout i (member_funcs members)
      in
      put env0 "%s %s(%s);\n" ret cluster cluster_params)
    clusters;
  put env0 "\n";
  (* Definitions. *)
  List.iter
    (fun f -> if not (in_cluster f.Emo_ir.fname) then emit_single env0 f)
    program.pfuncs;
  List.iteri
    (fun i members -> emit_cluster env0 i (member_funcs members))
    clusters;
  (* The entry module's top level. *)
  let env = { env0 with fresh = 0; scope = [] } in
  put env "int main(void) {\n";
  put env "  emo_startup();\n";
  emit_stmts env program.pinit;
  put env "  return 0;\n}\n";
  Buffer.contents buf
