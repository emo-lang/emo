module Ast = Emo_ast

(* The other backends, re-exported: a wrapped library exposes only its
   eponymous module. *)
module Ts = Emo_ts
module Wasm = Emo_wasm

(* Stage A/B backend: emits OCaml source from the IR, compiled by the
   OCaml toolchain into a single binary linked against emo_runtime (the
   scheduler and builtins ride along).

   Dynamic by default — every function takes and returns
   [Emo_eval.value] — with Stage B specialization: a function the IR
   marked [fspecializable] emits natively (unboxed parameters, direct
   arithmetic, direct calls) behind an auto-generated dynamic wrapper,
   so unannotated call sites keep dynamic semantics. *)

(* The current program's specialized functions; set by [emit]. *)
let specializables : Emo_ir.func list ref = ref []

let keywordish name =
  (* Emo locals that would collide with OCaml words get a prefix anyway;
     every local carries [v_] so this is belt and braces. *)
  List.mem name
    [ "match"; "let"; "in"; "if"; "then"; "else"; "type"; "begin"; "end" ]

let local name = if keywordish name then "v_" ^ name else "v_" ^ name

(* ---- The emitter environment: which locals are `var` refs ---- *)

type env = {
  buf : Buffer.t;
  mutable refs : string list; (* locals bound as refs, innermost first *)
  mutable immutables : string list;
      (* immutable bindings shadowing a ref (block params) *)
  specialize : bool; (* Stage B on/off for the whole build *)
  mutable native : bool; (* emitting a specialized body right now *)
}

let put env fmt = Printf.ksprintf (Buffer.add_string env.buf) fmt

(* statement sequencing: [emit_stmts env stmts ~tail] produces one OCaml
   expression of type value (dynamic) or the native type (specialized). *)

let rec emit_stmts env (stmts : Emo_ir.stmt list) ~(tail : bool) : string =
  match stmts with
  | [] -> if tail then "Emo_runtime.no_return ()" else "()"
  | [ stmt ] -> emit_stmt env stmt ~tail
  | stmt :: rest -> (
      match stmt with
      | Emo_ir.Let { mutable_ = true; name; init } ->
          (* The ref must be registered before the rest of the sequence
             is emitted: later statements read and assign through it. *)
          let init_code = emit_expr env init in
          env.refs <- local name :: env.refs;
          Printf.sprintf "let %s = ref (%s) in\n%s" (local name) init_code
            (emit_stmts env rest ~tail)
      | stmt -> (
          let rest_expr = emit_stmts env rest ~tail in
          match stmt with
          | Emo_ir.Let { mutable_ = false; name; init } ->
              Printf.sprintf "let %s = %s in\n%s" (local name)
                (emit_expr env init) rest_expr
          | Emo_ir.Effect e ->
              Printf.sprintf "let _ = %s in\n%s" (emit_expr env e) rest_expr
          | stmt ->
              let code = emit_stmt env stmt ~tail:false in
              Printf.sprintf "let _ = %s in\n%s" code rest_expr))

and emit_stmt env (stmt : Emo_ir.stmt) ~(tail : bool) : string =
  match stmt with
  | Emo_ir.Effect e ->
      if tail then emit_expr env e
      else Printf.sprintf "ignore (%s)" (emit_expr env e)
  | Emo_ir.Let { mutable_ = false; name; init } ->
      (* Sequenced lets are handled in [emit_stmts]; a trailing binding
         is the body's value. *)
      Printf.sprintf "let %s = %s in ()" (local name) (emit_expr env init)
  | Emo_ir.Let { mutable_ = true; name; init } ->
      env.refs <- local name :: env.refs;
      Printf.sprintf "let %s = ref (%s) in ()" (local name) (emit_expr env init)
  | Emo_ir.Assign_var { name; value } ->
      let v = emit_expr env value in
      if List.mem (local name) env.refs then
        Printf.sprintf "%s := %s" (local name) v
      else
        (* An assign to a non-ref can only be a rebinding the checker
           rejected; unreachable in checked programs. *)
        Printf.sprintf "let %s = %s in ()" (local name) v
  | Emo_ir.Set_field { self_; name; value } ->
      if tail then
        Printf.sprintf
          "(Emo_runtime.obj_set_field %s \"%s\" %s;\nEmo_eval.Int 0)"
          (emit_expr env self_) name (emit_expr env value)
      else
        Printf.sprintf "Emo_runtime.obj_set_field %s \"%s\" %s"
          (emit_expr env self_) name (emit_expr env value)
  | Emo_ir.If { cond; then_; else_ } ->
      let then_code = emit_stmts env then_ ~tail in
      let else_code = emit_stmts env else_ ~tail in
      Printf.sprintf "if %s then\n(%s)\nelse\n(%s)" (unbox env cond "Bool")
        then_code else_code
  | Emo_ir.Case { scrutinee; branches } ->
      emit_case env scrutinee branches ~tail
  | Emo_ir.Receive { branches } -> emit_receive env branches ~tail
  | Emo_ir.Send { target; message } ->
      Printf.sprintf "(Emo_runtime.send (%s) (%s))" (emit_expr env target)
        (emit_expr env message)
  | Emo_ir.Raise e -> Printf.sprintf "Emo_runtime.raise_ %s" (emit_expr env e)
  | Emo_ir.Return_stmt e ->
      let code = emit_expr env e in
      if tail then code
      else Printf.sprintf "raise (Emo_runtime.Return_signal (%s))" code

and unbox env (e : Emo_ir.expr) kind =
  if env.native && e.Emo_ir.ety = Emo_check.Bool then
    Printf.sprintf "(%s)" (emit_expr env e)
  else
    Printf.sprintf "(Emo_runtime.unbox_%s %s)"
      (String.lowercase_ascii kind)
      (emit_expr env e)

and emit_case env scrutinee branches ~tail =
  let scrutinee_code = emit_expr env scrutinee in
  let arms =
    List.mapi
      (fun i (b : Emo_ir.branch) ->
        let bindings = pattern_bindings b.Emo_ir.pattern in
        let pattern_code = emit_pattern b.Emo_ir.pattern in
        let bindings_code =
          String.concat ""
            (List.map
               (fun (name, index) ->
                 Printf.sprintf
                   "let %s = List.nth (match payload with Emo_eval.Tuple xs -> \
                    xs | _ -> []) %d in\n"
                   (local name) index)
               bindings)
        in
        let guard =
          match b.Emo_ir.guard with
          | Some g ->
              (* The guard sits before the arm body, where the pattern
                 bindings are recovered — recover them here too. *)
              Printf.sprintf " when (%s%s)\n" bindings_code (unbox env g "Bool")
          | None -> "\n"
        in
        let body =
          let saved = env.refs in
          env.refs <- List.map fst bindings @ env.refs;
          let code = emit_stmts env b.Emo_ir.body ~tail in
          env.refs <- saved;
          Printf.sprintf "(%s%s)" bindings_code code
        in
        let pattern_with_payload =
          if bindings = [] then pattern_code
          else
            (* capture the matched value as [payload] for the bindings *)
            Printf.sprintf "(%s as payload)" pattern_code
        in
        Printf.sprintf "| %s%s ->\n%s" pattern_with_payload guard body)
      branches
  in
  (* The runtime catchall covers non-exhaustive Emo matches; a wildcard
     Emo arm already covers everything, and a second catchall would be a
     redundant-case warning in the generated OCaml. *)
  let exhaustive =
    List.exists
      (fun (b : Emo_ir.branch) ->
        match b.Emo_ir.pattern.Ast.pattern_desc with
        | Ast.Wildcard | Ast.Pattern_binding _ -> true
        | _ -> false)
      branches
  in
  let arms = String.concat "\n" arms in
  let arms =
    if exhaustive then arms
    else Printf.sprintf "%s\n| other -> Emo_runtime.case_error other" arms
  in
  Printf.sprintf "(match %s with\n%s)" scrutinee_code arms

(* The OCaml pattern over [Emo_eval.value] for an IR pattern, plus the
   branch's pattern variables with their tuple positions. *)
and emit_pattern (p : Emo_ast.pattern) : string =
  match p.Ast.pattern_desc with
  | Ast.Wildcard -> "_"
  (* Bindings are recovered from [payload] by position (see the arm
     bodies), so the capture itself stays anonymous. *)
  | Ast.Pattern_binding _ -> "_"
  | Ast.Pattern_literal (L_int n) -> Printf.sprintf "Emo_eval.Int %d" n
  | Ast.Pattern_literal (L_float f) -> Printf.sprintf "Emo_eval.Float %g" f
  | Ast.Pattern_literal (L_string s) -> Printf.sprintf "Emo_eval.String %S" s
  | Ast.Pattern_literal (L_bool b) -> Printf.sprintf "Emo_eval.Bool %b" b
  | Ast.Pattern_literal (L_char c) -> Printf.sprintf "Emo_eval.Char %C" c
  | Ast.Enum_member (t, m) -> Printf.sprintf "Emo_eval.EnumMember (%S, %S)" t m
  | Ast.Tuple_pattern ps ->
      let inner = List.map emit_pattern ps in
      Printf.sprintf "Emo_eval.Tuple [%s]" (String.concat "; " inner)

and pattern_bindings (p : Emo_ast.pattern) : (string * int) list =
  let rec go p position acc =
    match p.Ast.pattern_desc with
    | Ast.Pattern_binding name -> (name, position) :: acc
    | Ast.Tuple_pattern ps ->
        List.fold_left
          (fun (pos, acc) sub -> (pos + 1, go sub pos acc))
          (position, acc) ps
        |> snd
    | _ -> acc
  in
  List.rev (go p 0 [])

and emit_receive env branches ~tail =
  ignore tail;
  let matchers =
    List.mapi
      (fun i (b : Emo_ir.branch) ->
        let bindings = pattern_bindings b.Emo_ir.pattern in
        let pattern_code = emit_pattern b.Emo_ir.pattern in
        let saved = (env.refs, env.immutables) in
        env.refs <- List.map fst bindings @ env.refs;
        env.immutables <-
          List.map (fun (n, _) -> local n) bindings @ env.immutables;
        let guard_inner =
          match b.Emo_ir.guard with
          | Some g -> unbox env g "Bool"
          | None -> "true"
        in
        env.refs <- fst saved;
        env.immutables <- snd saved;
        (* Guards and bindings read the payload's items by position —
           no partial list patterns in generated code. *)
        let items_at =
          String.concat "\n"
            (List.mapi
               (fun pos (n, _) ->
                 Printf.sprintf "let %s = List.nth __items %d in" (local n) pos)
               bindings)
        in
        let payload_unpack =
          if bindings = [] then "true"
          else
            Printf.sprintf
              "(match Emo_runtime.payload_items payload with\n\
               | __items ->\n\
               %s\n\
               %s)"
              items_at guard_inner
        in
        let payload_return =
          if bindings = [] then Printf.sprintf "Some (%d, [])" i
          else
            Printf.sprintf
              "(match Emo_runtime.payload_items payload with\n\
               | __items ->\n\
               Some (%d, __items))"
              i
        in
        Printf.sprintf
          "(fun v ->\n\
           (match v with\n\
           | %s as payload when %s ->\n\
           %s\n\
           | _ -> None))"
          pattern_code payload_unpack payload_return)
      branches
  in
  let dispatch =
    List.mapi
      (fun i (b : Emo_ir.branch) ->
        let bindings = pattern_bindings b.Emo_ir.pattern in
        let saved = env.refs in
        env.refs <- List.map fst bindings @ env.refs;
        let body = emit_stmts env b.Emo_ir.body ~tail in
        env.refs <- saved;
        let vars =
          String.concat "; " (List.map (fun (n, _) -> local n) bindings)
        in
        let unpack =
          if bindings = [] then ""
          else Printf.sprintf "let [%s] = payload in\n" vars
        in
        Printf.sprintf "| (%d, payload) ->\n%s%s" i unpack body)
      branches
  in
  Printf.sprintf
    "(match Emo_runtime.receive [%s] with\n%s\n| _ -> Emo_runtime.no_return ())"
    (String.concat ";\n" matchers)
    (String.concat "\n" dispatch)

and emit_expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Emo_ir.Const (L_int n) ->
      if env.native && e.Emo_ir.ety = Emo_check.Int then string_of_int n
      else Printf.sprintf "Emo_eval.Int %d" n
  | Emo_ir.Const (L_float f) ->
      if env.native && e.Emo_ir.ety = Emo_check.Float then
        Printf.sprintf "(%s)" (string_of_float f)
      else Printf.sprintf "Emo_eval.Float %s" (string_of_float f)
  | Emo_ir.Const (L_bool b) ->
      if env.native && e.Emo_ir.ety = Emo_check.Bool then
        if b then "true" else "false"
      else Printf.sprintf "Emo_eval.Bool %b" b
  | Emo_ir.Const (L_char c) ->
      if env.native && e.Emo_ir.ety = Emo_check.Char then Printf.sprintf "%C" c
      else Printf.sprintf "Emo_eval.Char %C" c
  | Emo_ir.Const (L_string s) ->
      if env.native && e.Emo_ir.ety = Emo_check.String then
        Printf.sprintf "%S" s
      else Printf.sprintf "Emo_eval.String %S" s
  | Emo_ir.Type_ref name -> Printf.sprintf "Emo_eval.TypeValue %S" name
  | Emo_ir.Var name ->
      let n = local name in
      if List.mem n env.refs && not (List.mem n env.immutables) then "!" ^ n
      else n
  | Emo_ir.Global g ->
      (* A def used as a value: its dynamic wrapper. *)
      Printf.sprintf
        "(Emo_eval.CompiledFn { Emo_eval.fdesc = %S; farity = -1; fapply = %s \
         })"
        g g
  | Emo_ir.Tuple es ->
      Printf.sprintf "Emo_eval.Tuple [%s]"
        (String.concat "; " (List.map (emit_expr env) es))
  | Emo_ir.Array_lit es ->
      Printf.sprintf "Emo_eval.Array (Array.of_list [%s])"
        (String.concat "; " (List.map (emit_expr env) es))
  | Emo_ir.Make_enum { enum_name; member } ->
      Printf.sprintf "Emo_eval.EnumMember (%S, %S)" enum_name member
  | Emo_ir.Interpolate es ->
      Printf.sprintf "Emo_runtime.interpolate [%s]"
        (String.concat "; " (List.map (emit_expr env) es))
  | Emo_ir.Unary (Ast.Not, x) ->
      Printf.sprintf "(Emo_runtime.not_ (%s))" (emit_expr env x)
  | Emo_ir.Unary (Ast.Neg, x) ->
      if env.native && e.Emo_ir.ety = Emo_check.Int then
        Printf.sprintf "(- %s)" (emit_expr env x)
      else Printf.sprintf "(Emo_runtime.negf (%s))" (emit_expr env x)
  | Emo_ir.Binary (op, l, r) ->
      let lname = emit_expr env l in
      let rname = emit_expr env r in
      let native =
        env.native
        && e.Emo_ir.ety = Emo_check.Int
        &&
        match op with
        | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> true
        | _ -> false
      in
      if native then
        Printf.sprintf "(%s %s %s)" lname
          (match op with
          | Ast.Add -> "+"
          | Ast.Sub -> "-"
          | Ast.Mul -> "*"
          | Ast.Div -> "/"
          | Ast.Mod -> "mod"
          | _ -> "+")
          rname
      else
        let fn =
          match op with
          | Ast.Eq -> "eq"
          | Ast.Ne -> "ne"
          | Ast.Lt -> "lt"
          | Ast.Le -> "le"
          | Ast.Gt -> "gt"
          | Ast.Ge -> "ge"
          | Ast.Add -> "add"
          | Ast.Sub -> "sub"
          | Ast.Mul -> "mul"
          | Ast.Div -> "div"
          | Ast.Mod -> "modulo"
          | Ast.And -> "and_"
          | Ast.Or -> "or_"
        in
        Printf.sprintf "(Emo_runtime.%s (%s) (%s))" fn lname rname
  | Emo_ir.Index (b, i) ->
      Printf.sprintf "(Emo_runtime.index (%s) (%s))" (emit_expr env b)
        (emit_expr env i)
  | Emo_ir.Field_read { obj; name } ->
      Printf.sprintf "(Emo_runtime.field (%s) %S)" (emit_expr env obj) name
  | Emo_ir.Call { func; args } ->
      let args_code = String.concat "; " (List.map (emit_expr env) args) in
      if
        env.native
        && List.exists
             (fun f -> f.Emo_ir.fname = func && f.Emo_ir.fspecializable)
             !specializables
      then
        (* Native context: direct specialized call with native args. *)
        Printf.sprintf "%s %s" (sp_name func)
          (String.concat " " (List.map (emit_native_expr env) args))
      else Printf.sprintf "%s [%s]" func args_code
  | Emo_ir.Call_value { f; args } ->
      Printf.sprintf "Emo_runtime.apply_value %s [%s]" (emit_expr env f)
        (String.concat "; " (List.map (emit_expr env) args))
  | Emo_ir.Method { self_; name; args } ->
      Printf.sprintf "(Emo_runtime.method_call (%s) %S [%s])"
        (emit_expr env self_) name
        (String.concat "; " (List.map (emit_expr env) args))
  | Emo_ir.Builtin { name; args } ->
      Printf.sprintf "Emo_eval.call_builtin %S [%s]" name
        (String.concat "; " (List.map (emit_expr env) args))
  | Emo_ir.Box_new e ->
      Printf.sprintf "(Emo_runtime.box_new (%s))" (emit_expr env e)
  | Emo_ir.Make_exception { message } ->
      Printf.sprintf "(Emo_runtime.exception_new (%s))" (emit_expr env message)
  | Emo_ir.Do_spawn { func; args } ->
      (* Arguments evaluate eagerly in the spawning process; the spawned
         process only runs the call. *)
      Printf.sprintf
        "(Emo_runtime.spawn_args [%s] (fun args -> ignore (%s args)))"
        (String.concat "; " (List.map (emit_expr env) args))
        func
  | Emo_ir.Spawn_value { f; args } ->
      Printf.sprintf
        "(Emo_runtime.spawn_args [%s] (fun args -> ignore \
         (Emo_runtime.apply_value %s args)))"
        (String.concat "; " (List.map (emit_expr env) args))
        (emit_expr env f)
  | Emo_ir.Closure { cparams; cbody } ->
      let names = List.map fst cparams in
      let arity = List.length names in
      let saved = (env.refs, env.immutables) in
      let params_pattern = String.concat "; " (List.map local names) in
      (* Block parameters are immutable bindings, never refs — even when
         they shadow an outer var. *)
      env.immutables <- List.map local names @ env.immutables;
      let body = emit_stmts env cbody ~tail:true in
      env.refs <- fst saved;
      env.immutables <- snd saved;
      Printf.sprintf
        "(Emo_eval.CompiledFn { Emo_eval.fdesc = \"<block>\"; farity = %d; \
         fapply = fun args -> (match args with [ %s ] -> (try %s with \
         Emo_runtime.Return_signal v -> v) | _ -> Emo_runtime.arity_error \
         \"<block>\" %d (List.length args)) })"
        arity params_pattern body arity

(* ---- Specialized (Stage B) emission ---- *)

and sp_name func = "sp_" ^ func

and emit_native_expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Emo_ir.Const (L_int n) -> string_of_int n
  | Emo_ir.Const (L_float f) -> Printf.sprintf "(%s)" (string_of_float f)
  | Emo_ir.Const (L_bool b) -> if b then "true" else "false"
  | Emo_ir.Const (L_char c) -> Printf.sprintf "%C" c
  | Emo_ir.Const (L_string s) -> Printf.sprintf "%S" s
  | Emo_ir.Var name -> local name
  | Emo_ir.Binary (op, l, r) ->
      (* OCaml spells float arithmetic with a dot — the expression's
         own type picks the operator family. Comparisons are
         polymorphic and serve both. *)
      let float = e.Emo_ir.ety = Emo_check.Float in
      let op_str =
        match op with
        | Ast.Add -> if float then "+." else "+"
        | Ast.Sub -> if float then "-." else "-"
        | Ast.Mul -> if float then "*." else "*"
        | Ast.Div -> if float then "/." else "/"
        | Ast.Mod -> if float then "Float.rem" else "mod"
        | Ast.Lt -> "<"
        | Ast.Le -> "<="
        | Ast.Gt -> ">"
        | Ast.Ge -> ">="
        | Ast.Eq -> "="
        | Ast.Ne -> "<>"
        | Ast.And -> "&&"
        | Ast.Or -> "||"
      in
      Printf.sprintf "(%s %s %s)" (emit_native_expr env l) op_str
        (emit_native_expr env r)
  | Emo_ir.Unary (Ast.Neg, x) ->
      if e.Emo_ir.ety = Emo_check.Float then
        Printf.sprintf "(-. %s)" (emit_native_expr env x)
      else Printf.sprintf "(- %s)" (emit_native_expr env x)
  | Emo_ir.Unary (Ast.Not, x) ->
      Printf.sprintf "(not %s)" (emit_native_expr env x)
  | Emo_ir.Call { func; args } ->
      Printf.sprintf "%s %s" (sp_name func)
        (String.concat " " (List.map (emit_native_expr env) args))
  | other ->
      let kind =
        match other with
        | Emo_ir.Const _ -> "Const"
        | Emo_ir.Type_ref n -> "Type_ref " ^ n
        | Emo_ir.Var n -> "Var " ^ n
        | Emo_ir.Global g -> "Global " ^ g
        | Emo_ir.Tuple _ -> "Tuple"
        | Emo_ir.Array_lit _ -> "Array"
        | Emo_ir.Make_enum _ -> "Make_enum"
        | Emo_ir.Interpolate _ -> "Interpolate"
        | Emo_ir.Unary _ -> "Unary"
        | Emo_ir.Binary _ -> "Binary"
        | Emo_ir.Index _ -> "Index"
        | Emo_ir.Field_read { name; _ } -> "Field " ^ name
        | Emo_ir.Call { func; _ } -> "Call " ^ func
        | Emo_ir.Call_value _ -> "Call_value"
        | Emo_ir.Method { name; _ } -> "Method " ^ name
        | Emo_ir.Builtin { name; _ } -> "Builtin " ^ name
        | Emo_ir.Box_new _ -> "Box_new"
        | Emo_ir.Make_exception _ -> "Make_exception"
        | Emo_ir.Do_spawn _ -> "Do_spawn"
        | Emo_ir.Spawn_value _ -> "Spawn_value"
        | Emo_ir.Closure _ -> "Closure"
      in
      Printf.eprintf "NONNATIVE %s\n%!" (kind : string);
      raise (Emo_ir.Lower_error "non-native expression in specialized body")

(* Statement-level native emission mirrors the dynamic one but with
   native types; only the shapes [stmts_native] admitted occur. *)
(* Native statement emission produces an expression of the function's
   result type. Fall-through (no return) is [no_return] — the checker
   admits it only where it cannot happen. An [if] followed by more
   statements joins them: both arms continue into the remaining
   statements, duplicated so each path stays a straight line; the
   remaining statements are in tail position inside the arms. *)
(* [arm_unit] marks emission inside an if-arm: an empty arm is a plain
   fall-through, while an empty function body is the E3008 error. *)
and emit_native_stmts env (stmts : Emo_ir.stmt list) ~(tail : bool)
    ~(arm_unit : bool) : string =
  (* Inside an if-arm, an explicit [return] leaves the function through
     the [Native_return] exception — its value is never dropped. *)
  (match stmts with
    | [ Emo_ir.Return_stmt e ] when arm_unit ->
        Some
          (Printf.sprintf "(raise (Native_return %s))" (emit_native_expr env e))
    | _ -> None)
  |> function
  | Some code -> code
  | None -> (
      match stmts with
      | [] -> if arm_unit then "()" else "Emo_runtime.no_return ()"
      | [ Emo_ir.Return_stmt e ] -> emit_native_expr env e
      | [ Emo_ir.Effect e ] ->
          if arm_unit then
            Printf.sprintf "(let _ = %s in ())" (emit_native_expr env e)
          else
            Printf.sprintf "(let _ = %s in Emo_runtime.no_return ())"
              (emit_native_expr env e)
      | [ Emo_ir.Let { mutable_ = false; name; init } ] ->
          env.refs <- local name :: env.refs;
          if arm_unit then
            Printf.sprintf "(let %s = %s in ())" (local name)
              (emit_native_expr env init)
          else
            Printf.sprintf "let %s = %s in\nEmo_runtime.no_return ()"
              (local name)
              (emit_native_expr env init)
      | [ Emo_ir.If { cond; then_; else_ } ] ->
          Printf.sprintf "(if %s then\n(%s)\nelse\n(%s))"
            (emit_native_expr env cond)
            (emit_native_stmts env then_ ~tail ~arm_unit)
            (emit_native_stmts env else_ ~tail ~arm_unit)
      | stmt :: rest -> (
          let rest_code = emit_native_stmts env rest ~tail ~arm_unit in
          match stmt with
          | Emo_ir.Let { mutable_ = false; name; init } ->
              env.refs <- local name :: env.refs;
              Printf.sprintf "let %s = %s in\n%s" (local name)
                (emit_native_expr env init)
                rest_code
          | Emo_ir.Effect e ->
              Printf.sprintf "(let _ = %s in\n%s)" (emit_native_expr env e)
                rest_code
          | Emo_ir.If { cond; then_; else_ } ->
              let then_code =
                emit_native_stmts env then_ ~tail:false ~arm_unit:true
              in
              let else_code =
                emit_native_stmts env else_ ~tail:false ~arm_unit:true
              in
              Printf.sprintf
                "(if %s then\n\
                 (let _ = (%s) in\n\
                 %s)\n\
                 else\n\
                 (let _ = (%s) in\n\
                 %s))"
                (emit_native_expr env cond)
                then_code rest_code else_code rest_code
          | Emo_ir.Return_stmt e ->
              let code = emit_native_expr env e in
              if tail then code
              else Printf.sprintf "(raise (Native_return %s))" code
          | _ ->
              raise
                (Emo_ir.Lower_error "non-native statement in specialized body"))
      )

(* The constructor wrapper's name: [C.new] lowers to this. *)
let mangle_class_ctor (c : Emo_ir.class_) : string = c.Emo_ir.cname ^ "__new"

(* ---- Program emission ---- *)

let indented code =
  String.concat "\n"
    (List.map
       (fun line -> if line = "" then line else "  " ^ line)
       (String.split_on_char '\n' code))

let ocaml_escape s = String.escaped s

let rec sp_name func = "sp_" ^ func

and emit_func env (f : Emo_ir.func) : string =
  let saved = (env.refs, env.immutables) in
  (* Def parameters are immutable bindings. *)
  env.immutables <-
    List.map (fun (p, _) -> local p) f.Emo_ir.fparams @ env.immutables;
  let params_pattern =
    String.concat "; " (List.map (fun (p, _) -> local p) f.Emo_ir.fparams)
  in
  let arity = List.length f.Emo_ir.fparams in
  let body = emit_stmts env f.Emo_ir.fbody ~tail:true in
  env.refs <- fst saved;
  env.immutables <- snd saved;
  Printf.sprintf
    "%s (args : Emo_eval.value list) : Emo_eval.value =\n\
    \  match args with\n\
    \  | [ %s ] ->\n\
    \    (try\n\
     %s\n\
     with Emo_runtime.Return_signal v -> v)\n\
    \  | _ -> Emo_runtime.arity_error %S %d (List.length args)"
    f.Emo_ir.fname params_pattern (indented body) f.Emo_ir.fname arity

and emit_specialized_func (f : Emo_ir.func) : string =
  let env =
    {
      buf = Buffer.create 256;
      refs = [];
      immutables = [];
      specialize = true;
      native = true;
    }
  in
  env.refs <- List.map (fun (p, _) -> local p) f.Emo_ir.fparams;
  let params =
    String.concat " "
      (List.map
         (fun (p, t) -> Printf.sprintf "(%s : %s)" (local p) (ocaml_type t))
         f.Emo_ir.fparams)
  in
  let result = ocaml_type f.Emo_ir.fresult in
  let body = emit_native_stmts env f.Emo_ir.fbody ~tail:true ~arm_unit:false in
  Printf.sprintf
    "%s %s : %s =\n\
     (let exception Native_return of %s in\n\
     (try %s with Native_return v -> v))"
    (sp_name f.Emo_ir.fname) params result
    (ocaml_type f.Emo_ir.fresult)
    body

and ocaml_type (t : Emo_check.t) : string =
  match t with
  | Emo_check.Int -> "int"
  | Emo_check.Float -> "float"
  | Emo_check.Bool -> "bool"
  | Emo_check.Char -> "char"
  | Emo_check.String -> "string"
  | _ -> "Emo_eval.value"

(* Emits a whole program: one OCaml source file. *)
(* One C wrapper per foreign binding, keyed by the binding's position in
   the program. The OCaml external binds to the wrapper, not the raw
   symbol: a raw external receives boxed [value]s the C function cannot
   read, and some symbol names (like "sqrt") collide with primitives
   the host compiler inlines. *)
let ffi_wrapper_map (program : Emo_ir.program) : (Emo_ir.func * string) list =
  List.mapi
    (fun i f -> (f, Printf.sprintf "emo_ffi_%d" i))
    (List.filter (fun f -> f.Emo_ir.fforeign <> None) program.Emo_ir.pfuncs)

let stub_c_type (t : Emo_check.t) : string =
  match t with
  | Emo_check.Float -> "double"
  | Emo_check.String -> "const char *"
  | Emo_check.Bool -> "int"
  | _ -> "int"

(* Return position: plain char * so known C builtins (strdup) redeclare
   without a prototype warning; the wrapper copies the bytes into a
   fresh OCaml string either way. *)
let stub_return_c_type (t : Emo_check.t) : string =
  match t with Emo_check.String -> "char *" | t -> stub_c_type t

let stub_unbox (t : Emo_check.t) (x : string) : string =
  match t with
  | Emo_check.Float -> Printf.sprintf "Double_val(%s)" x
  | Emo_check.String -> Printf.sprintf "String_val(%s)" x
  | Emo_check.Bool -> Printf.sprintf "Bool_val(%s)" x
  | _ -> "0"

let stub_box (t : Emo_check.t) (call : string) : string =
  match t with
  | Emo_check.Float -> Printf.sprintf "caml_copy_double(%s)" call
  | Emo_check.String -> Printf.sprintf "caml_copy_string(%s)" call
  | Emo_check.Bool -> Printf.sprintf "Val_bool(%s)" call
  | _ -> Printf.sprintf "Val_int(%s)" call

(* The C source for the foreign wrappers; empty when the program binds
   nothing. The checker (E4200) restricts foreign signatures to
   Float/String/Bool, the three types this marshaling covers. *)
let ffi_stubs (program : Emo_ir.program) : string =
  match ffi_wrapper_map program with
  | [] -> ""
  | bindings ->
      let buf = Buffer.create 512 in
      Buffer.add_string buf
        "/* Generated by emo build: C wrappers for `foreign def` bindings. */\n\
        \ #include <caml/mlvalues.h>\n\
        \ #include <caml/alloc.h>\n";
      List.iter
        (fun (f, wrapper) ->
          let symbol = Option.get f.Emo_ir.fforeign in
          let decl_params =
            String.concat ", "
              (List.map (fun (_, t) -> stub_c_type t) f.Emo_ir.fparams)
          in
          let decl_params = if decl_params = "" then "void" else decl_params in
          Buffer.add_string buf
            (Printf.sprintf "extern %s %s(%s);\n"
               (stub_return_c_type f.Emo_ir.fresult)
               symbol decl_params);
          let sig_params =
            String.concat ", "
              (List.mapi
                 (fun i _ -> Printf.sprintf "value a%d" i)
                 f.Emo_ir.fparams)
          in
          let sig_params = if sig_params = "" then "void" else sig_params in
          let call_args =
            String.concat ", "
              (List.mapi
                 (fun i (_, t) -> stub_unbox t (Printf.sprintf "a%d" i))
                 f.Emo_ir.fparams)
          in
          let call = Printf.sprintf "%s(%s)" symbol call_args in
          Buffer.add_string buf
            (Printf.sprintf "value %s(%s) {\n  return %s;\n}\n" wrapper
               sig_params
               (stub_box f.Emo_ir.fresult call)))
        bindings;
      Buffer.contents buf

let emit ~(specialize : bool) (program : Emo_ir.program) : string =
  specializables :=
    List.filter (fun f -> f.Emo_ir.fspecializable) program.Emo_ir.pfuncs;
  let env =
    {
      buf = Buffer.create 4096;
      refs = [];
      immutables = [];
      specialize;
      native = false;
    }
  in
  put env "(* generated by emo build — do not edit *)\n";
  put env "\n(* class method tables *)\n";
  List.iter
    (fun (c : Emo_ir.class_) ->
      put env
        "let __methods_%s : (string, int * (Emo_eval.value list -> \
         Emo_eval.value)) Hashtbl.t = Hashtbl.create 8\n"
        c.Emo_ir.cname)
    program.Emo_ir.pclasses;

  (* Specialized functions first (their own rec group). *)
  if env.specialize then begin
    put env "\n";
    let specialized =
      List.filter (fun f -> f.Emo_ir.fspecializable) program.Emo_ir.pfuncs
    in
    List.iteri
      (fun i f ->
        let code = emit_specialized_func f in
        let code =
          if i = 0 then code
          else
            match String.index_opt code ' ' with
            | Some j ->
                String.sub code 0 j ^ " "
                ^ String.sub code (j + 1) (String.length code - j - 1)
            | None -> code
        in
        put env "%s%s\n\n" (if i = 0 then "let rec " else "and ") code)
      specialized;
    (* Every specialized function keeps its dynamic wrapper: unannotated
       call sites and first-class references go through it. *)
    List.iter
      (fun f ->
        env.refs <- [];
        let params_pattern =
          String.concat "; " (List.map (fun (p, _) -> local p) f.Emo_ir.fparams)
        in
        let unboxes =
          String.concat " "
            (List.map
               (fun (p, t) ->
                 Printf.sprintf "(Emo_runtime.unbox_%s %s)"
                   (String.lowercase_ascii (Emo_check.to_string t))
                   (local p))
               f.Emo_ir.fparams)
        in
        let call = Printf.sprintf "%s %s" (sp_name f.Emo_ir.fname) unboxes in
        put env
          "let %s (args : Emo_eval.value list) : Emo_eval.value =\n\
          \  match args with\n\
          \  | [ %s ] ->\n\
          \    Emo_runtime.box_%s (%s)\n\
          \  | _ -> Emo_runtime.arity_error %S %d (List.length args)\n\n"
          f.Emo_ir.fname params_pattern
          (String.lowercase_ascii (Emo_check.to_string f.Emo_ir.fresult))
          call f.Emo_ir.fname
          (List.length f.Emo_ir.fparams))
      specialized
  end;
  (* Foreign bindings: the external binds to the compiled C wrapper
     (ffi_stubs); the dynamic wrapper unboxes and reboxes around it. *)
  List.iter
    (fun (f, wrapper) ->
      match f.Emo_ir.fforeign with
      | Some _ ->
          let params =
            String.concat " -> "
              (List.map (fun (_, t) -> ocaml_type t) f.Emo_ir.fparams)
          in
          let result = ocaml_type f.Emo_ir.fresult in
          let signature =
            if params = "" then result else params ^ " -> " ^ result
          in
          put env "\nexternal %s : %s = %S\n" (sp_name f.Emo_ir.fname) signature
            wrapper;
          let params_pattern =
            String.concat "; "
              (List.map (fun (p, _) -> local p) f.Emo_ir.fparams)
          in
          let unboxes =
            String.concat " "
              (List.map
                 (fun (p, t) ->
                   Printf.sprintf "(Emo_runtime.unbox_%s %s)"
                     (String.lowercase_ascii (Emo_check.to_string t))
                     (local p))
                 f.Emo_ir.fparams)
          in
          let call = Printf.sprintf "%s %s" (sp_name f.Emo_ir.fname) unboxes in
          put env
            "let %s (args : Emo_eval.value list) : Emo_eval.value =\n\
            \  match args with\n\
            \  | [ %s ] ->\n\
            \    Emo_runtime.box_%s (%s)\n\
            \  | _ -> Emo_runtime.arity_error %S %d (List.length args)\n\n"
            f.Emo_ir.fname params_pattern
            (String.lowercase_ascii (Emo_check.to_string f.Emo_ir.fresult))
            call f.Emo_ir.fname
            (List.length f.Emo_ir.fparams)
      | None -> ())
    (ffi_wrapper_map program);
  (* Dynamic functions: one rec group. *)
  put env "\n";
  let dynamic =
    List.filter
      (fun f ->
        ((not env.specialize) || not f.Emo_ir.fspecializable)
        && f.Emo_ir.fforeign = None)
      program.Emo_ir.pfuncs
  in
  (* Class inits and methods are part of the same recursion group. *)
  let class_funcs =
    List.concat_map
      (fun (c : Emo_ir.class_) ->
        (match c.Emo_ir.cinit with Some i -> [ i ] | None -> [])
        @ c.Emo_ir.cmethods)
      program.Emo_ir.pclasses
  in
  let dynamic = dynamic @ class_funcs in
  (match dynamic with
  | [] ->
      put env
        "let rec __nothing (args : Emo_eval.value list) : Emo_eval.value =\n\
        \    Emo_eval.Int 0"
  | f :: rest ->
      put env "let rec %s" (emit_func env f);
      List.iter
        (fun f ->
          env.refs <- [];
          env.immutables <- [];
          put env "\nand %s" (emit_func env f))
        rest);

  (* Class constructors join the same recursion group: they call the
     class's init (a group member) and their own method table. *)
  List.iter
    (fun (c : Emo_ir.class_) ->
      env.refs <- [];
      env.immutables <- [];
      let init_call =
        match c.Emo_ir.cinit with
        | Some init ->
            Printf.sprintf "let (_ : Emo_eval.value) = %s (self :: args) in"
              init.Emo_ir.fname
        | None -> ""
      in
      put env
        "\n\
         and %s (args : Emo_eval.value list) : Emo_eval.value =\n\
        \  let self = Emo_eval.Obj (Emo_runtime.new_obj %S __methods_%s) in\n\
        \  %s\n\
        \  self"
        (mangle_class_ctor c) c.Emo_ir.cdisplay c.Emo_ir.cname init_call)
    program.Emo_ir.pclasses;
  (* Method registrations: after the rec group so the method functions
     are in scope; method_call passes the receiver as the first
     argument. *)
  List.iter
    (fun (c : Emo_ir.class_) ->
      put env "\nlet () =\n";
      List.iter
        (fun m ->
          let prefix = c.Emo_ir.cname ^ "__" in
          let stripped =
            if
              String.length m.Emo_ir.fname > String.length prefix
              && String.sub m.Emo_ir.fname 0 (String.length prefix) = prefix
            then
              String.sub m.Emo_ir.fname (String.length prefix)
                (String.length m.Emo_ir.fname - String.length prefix)
            else m.Emo_ir.fname
          in
          let method_name =
            let n = String.length stripped in
            if n >= 2 && String.sub stripped (n - 2) 2 = "_q" then
              String.sub stripped 0 (n - 2) ^ "?"
            else stripped
          in
          put env "  Hashtbl.replace __methods_%s %S (%d, %s);\n" c.Emo_ir.cname
            method_name
            (List.length m.Emo_ir.fparams - 1)
            m.Emo_ir.fname)
        c.Emo_ir.cmethods;
      put env "()\n")
    program.Emo_ir.pclasses;
  put env "\n\n(* interfaces *)\n";
  List.iter
    (fun (name, methods) ->
      let entries =
        String.concat "; "
          (List.map
             (fun (m, arity) -> Printf.sprintf "(%S, %d)" m arity)
             methods)
      in
      put env "let () = Emo_runtime.register_interface %S [%s]\n" name entries)
    program.Emo_ir.pinterfaces;
  put env "\n";
  (* the constructor per class: creates the object, runs init (when the
     class has one), returns it — always [C.new], even for init-less
     classes like [English.new()] *)
  List.iter
    (fun (c : Emo_ir.class_) ->
      let init_call =
        match c.Emo_ir.cinit with
        | Some init ->
            Printf.sprintf "let (_ : Emo_eval.value) = %s (self :: args) in"
              init.Emo_ir.fname
        | None -> ""
      in
      put env
        "\n\
         let %s (args : Emo_eval.value list) : Emo_eval.value =\n\
        \  let self = Emo_eval.Obj (Emo_runtime.new_obj %S __methods_%s) in\n\
        \  %s\n\
        \  self\n"
        (mangle_class_ctor c) c.Emo_ir.cdisplay c.Emo_ir.cname init_call)
    program.Emo_ir.pclasses;
  ignore env;
  (* the program *)
  put env
    "\n\
     let () =\n\
    \  let exit_code =\n\
    \    Emo_runtime.run (fun () ->\n\
     %s\n\
     )\n\
    \  in\n\
    \  if exit_code <> 0 then exit exit_code\n"
    (indented (emit_stmts env program.Emo_ir.pinit ~tail:false));
  Buffer.contents env.buf
