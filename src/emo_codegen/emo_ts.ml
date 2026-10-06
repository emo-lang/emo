(* The TypeScript backend: lowers the IR to a single self-contained
   TypeScript file — the runtime prelude followed by the program's
   classes, functions, and entry. Values keep the interpreter's tagged
   dynamic shape (primitives for Int/Bool/String, small wrappers for
   Float/Char/compounds), every function is async, and every call is
   awaited: the Emo surface stays direct-style while the event loop
   lives in the emitted code and the runtime. *)

module Ast = Emo_ast

type env = {
  buf : Buffer.t;
  mutable refs : string list; (* mutable local bindings, innermost first *)
  mutable fresh : int; (* unique scrutinee names *)
  mutable in_receive : bool; (* lowering a receive's branch bodies *)
  mutable fname : string; (* the function being emitted, for trampolining *)
  mutable fparams : string list; (* its parameters, in order *)
}

let put env fmt = Printf.ksprintf (Buffer.add_string env.buf) fmt

let fresh env =
  env.fresh <- env.fresh + 1;
  Printf.sprintf "__s%d" env.fresh

(* A tail `return f(args)` to the enclosing function becomes a
   parameter re-assignment and `continue` inside the driver loop — JS
   has no tail calls, and a deep await chain would blow the stack.
   Non-tail self-calls and cross-function tail calls keep the await
   shape (recorded limitation). *)
let trampoline env (f : Emo_ir.func) : bool =
  let rec in_body (xs : Emo_ir.stmt list) =
    List.exists
      (fun s ->
        match s with
        | Emo_ir.Return_stmt Emo_ir.{ desc = Call { func = g; _ }; _ }
          when g = f.Emo_ir.fname ->
            true
        | Emo_ir.Case { branches; _ } ->
            List.exists
              (fun (b : Emo_ir.branch) -> in_body b.Emo_ir.body)
              branches
        | Emo_ir.If { then_; else_; _ } -> in_body then_ || in_body else_
        | _ -> false)
      xs
  in
  in_body f.Emo_ir.fbody

(* ---- Patterns ---- *)

(* One branch's pattern as a predicate over the scrutinee [s]. *)
let rec pattern_test s (p : Emo_ast.pattern) : string =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> "true"
  | Ast.Pattern_literal (L_int n) -> Printf.sprintf "(%s === %d)" s n
  | Ast.Pattern_literal (L_float f) ->
      Printf.sprintf "(%s instanceof EFloat && %s.v === %s)" s s
        (string_of_float f)
  | Ast.Pattern_literal (L_string str) -> Printf.sprintf "(%s === %S)" s str
  | Ast.Pattern_literal (L_bool b) -> Printf.sprintf "(%s === %b)" s b
  | Ast.Pattern_literal (L_char c) ->
      Printf.sprintf "(%s instanceof EChar && %s.c === %C)" s s c
  | Ast.Enum_member (t, m) ->
      Printf.sprintf
        "(%s instanceof EEnum && %s.type === %S && %s.member === %S)" s s t s m
  | Ast.Tuple_pattern ps ->
      let tests =
        List.mapi
          (fun i sub -> pattern_test (Printf.sprintf "%s.items[%d]" s i) sub)
          ps
      in
      Printf.sprintf "(%s instanceof ETuple && %s.items.length === %d && %s)" s
        s (List.length ps)
        (String.concat " && " tests)

(* The binding statements that recover a pattern's variables. *)
let rec pattern_bindings s (p : Emo_ast.pattern) : string list =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_literal _ | Ast.Enum_member _ -> []
  | Ast.Pattern_binding name -> [ Printf.sprintf "const %s = %s;" name s ]
  | Ast.Tuple_pattern ps ->
      List.concat
        (List.mapi
           (fun i sub ->
             pattern_bindings (Printf.sprintf "%s.items[%d]" s i) sub)
           ps)

let branch_binding_names (b : Emo_ir.branch) : string list =
  let rec go s (p : Emo_ast.pattern) : string list =
    match p.Ast.pattern_desc with
    | Ast.Wildcard | Ast.Pattern_literal _ | Ast.Enum_member _ -> []
    | Ast.Pattern_binding name -> [ name ]
    | Ast.Tuple_pattern ps ->
        List.concat
          (List.mapi
             (fun i sub -> go (Printf.sprintf "%s.items[%d]" s i) sub)
             ps)
  in
  go "__s" b.Emo_ir.pattern

(* ---- Expressions ---- *)

(* OCaml's %S escapes non-ASCII bytes as decimal byte escapes, which
   JavaScript reads as legacy octal — corrupting every multi-byte
   character. Emit ASCII directly and non-ASCII codepoints as
   unicode escapes. *)
let js_string (s : string) : string =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  let n = String.length s in
  let push_ascii c =
    match c with
    | '"' -> Buffer.add_string buf "\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\n"
    | c -> Buffer.add_char buf c
  in
  let rec go i =
    if i >= n then ()
    else
      let b = Char.code s.[i] in
      if b < 0x80 then (
        push_ascii (Char.chr b);
        go (i + 1))
      else
        let cp =
          if b land 0xE0 = 0xC0 then
            ((b land 0x1F) lsl 6) lor (Char.code s.[i + 1] land 0x3F)
          else if b land 0xF0 = 0xE0 then
            ((b land 0x0F) lsl 12)
            lor ((Char.code s.[i + 1] land 0x3F) lsl 6)
            lor (Char.code s.[i + 2] land 0x3F)
          else
            ((b land 0x07) lsl 18)
            lor ((Char.code s.[i + 1] land 0x3F) lsl 12)
            lor ((Char.code s.[i + 2] land 0x3F) lsl 6)
            lor (Char.code s.[i + 3] land 0x3F)
        in
        Buffer.add_string buf (Printf.sprintf "\\u{%x}" cp);
        go
          (i
          +
          if b land 0xE0 = 0xC0 then 2 else if b land 0xF0 = 0xE0 then 3 else 4
          )
  in
  go 0;
  Buffer.add_char buf '"';
  Buffer.contents buf

let rec expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Const (L_int n) -> string_of_int n
  | Const (L_float f) -> Printf.sprintf "E.float(%s)" (string_of_float f)
  | Const (L_string s) -> js_string s
  | Const (L_bool b) -> if b then "true" else "false"
  | Const (L_char c) -> Printf.sprintf "E.char(%C)" c
  | Type_ref name -> Printf.sprintf "%S" name
  | Var name ->
      if List.mem name env.refs then Printf.sprintf "%s.v" name else name
  | Global name -> name
  | Tuple es ->
      Printf.sprintf "E.tuple(%s)" (String.concat ", " (List.map (expr env) es))
  | Array_lit es ->
      Printf.sprintf "E.array([%s])"
        (String.concat ", " (List.map (expr env) es))
  | Make_enum { enum_name; member } ->
      Printf.sprintf "E.enum_(%S, %S)" enum_name member
  | Interpolate es ->
      Printf.sprintf "E.interpolate([%s])"
        (String.concat ", " (List.map (expr env) es))
  | Unary (Ast.Neg, x) -> Printf.sprintf "E.neg(%s)" (expr env x)
  | Unary (Ast.Not, x) -> Printf.sprintf "(!E.truthy(%s))" (expr env x)
  | Cond { c; t; e = else_ } ->
      Printf.sprintf "(E.truthy(%s) ? (%s) : (%s))"
        (expr env c) (expr env t) (expr env else_)
  | Binary (op, l, r) -> (
      let lcode = expr env l in
      let rcode = expr env r in
      let call fn = Printf.sprintf "E.%s(%s, %s)" fn lcode rcode in
      match op with
      | Ast.And -> Printf.sprintf "(E.truthy(%s) && E.truthy(%s))" lcode rcode
      | Ast.Or -> Printf.sprintf "(E.truthy(%s) || E.truthy(%s))" lcode rcode
      | Ast.Eq -> call "eq"
      | Ast.Ne -> call "ne"
      | Ast.Lt -> call "lt"
      | Ast.Le -> call "le"
      | Ast.Gt -> call "gt"
      | Ast.Ge -> call "ge"
      | Ast.Add -> call "add"
      | Ast.Sub -> call "sub"
      | Ast.Mul -> call "mul"
      | Ast.Div -> call "div"
      | Ast.Mod -> call "mod")
  | Index (b, i) -> Printf.sprintf "E.index(%s, %s)" (expr env b) (expr env i)
  | Field_read { obj; name } -> Printf.sprintf "(%s).%s" (expr env obj) name
  | Call { func; args } ->
      Printf.sprintf "(await %s(%s))" func
        (String.concat ", " (List.map (expr env) args))
  | Call_value { f; args } ->
      Printf.sprintf "(await E.callValue(%s, [%s]))" (expr env f)
        (String.concat ", " (List.map (expr env) args))
  | Method { self_; name; args } ->
      Printf.sprintf "(await E.method(%s, %S, [%s]))" (expr env self_)
        (Emo_ir.sanitize_ident name)
        (String.concat ", " (List.map (expr env) args))
  | Builtin { name; args } ->
      let args_code = String.concat ", " (List.map (expr env) args) in
      if name = "println" then Printf.sprintf "E.println(%s)" args_code
      else if name = "self_pid" then "E.self()"
      else if name = "halt" then "E.halt()"
      else Printf.sprintf "E.builtin(%S, [%s])" name args_code
  | Box_new e -> Printf.sprintf "E.box(%s)" (expr env e)
  | Make_exception { message } ->
      Printf.sprintf "E.throwException(%s)" (expr env message)
  | Do_spawn { func; args } ->
      (* the arguments evaluate in the spawner (matching the other
         targets), so they are hoisted above the E.spawn call *)
      let arg_locals = List.map (fun _ -> fresh env) args in
      let pre =
        String.concat "\n"
          (List.mapi
             (fun i arg ->
               Printf.sprintf "const %s = await %s;" (List.nth arg_locals i)
                 (expr env arg))
             args)
      in
      Printf.sprintf
        "(await (async () => {\n\
         %s\n\
        \  return E.spawn(async () => {\n\
        \    return await %s(%s);\n\
        \  });\n\
         })())"
        pre
        (Emo_ir.sanitize_ident func)
        (String.concat ", " arg_locals)
  | Spawn_value { f; args } ->
      let arg_locals = List.map (fun _ -> fresh env) args in
      let pre =
        String.concat "\n"
          (List.mapi
             (fun i arg ->
               Printf.sprintf "const %s = await %s;" (List.nth arg_locals i)
                 (expr env arg))
             args)
      in
      let f_code = expr env f in
      Printf.sprintf
        "(await (async () => {\n\
         %s\n\
        \  return E.spawn(async () => {\n\
        \    return await (%s)(%s);\n\
        \  });\n\
         })())"
        pre f_code
        (String.concat ", " arg_locals)
  | Closure { cparams; cbody } ->
      let params = String.concat ", " (List.map fst cparams) in
      let saved = env.refs in
      let saved_name = env.fname in
      env.fname <- "";
      let body = stmts env cbody ~tail:true in
      env.fname <- saved_name;
      env.refs <- saved;
      Printf.sprintf "(async (%s) => {\n%s\n})" params body

(* Sequenced statements: every line ends with `;`; a tail position
   returns. *)
and stmts env (xs : Emo_ir.stmt list) ~(tail : bool) : string =
  match xs with
  | [] -> if tail then "return undefined;" else ""
  | [ s ] -> stmt env s ~tail
  | s :: rest ->
      Printf.sprintf "%s\n%s" (stmt env s ~tail:false) (stmts env rest ~tail)

and stmt env (s : Emo_ir.stmt) ~(tail : bool) : string =
  match s with
  | Effect e ->
      let code = expr env e in
      if tail then Printf.sprintf "return %s;" code
      else Printf.sprintf "%s;" code
  | Let { mutable_ = false; name; init } ->
      let init_code = expr env init in
      if tail then
        Printf.sprintf "const %s = %s;\nreturn %s;" name init_code name
      else Printf.sprintf "const %s = %s;" name init_code
  | Let { mutable_ = true; name; init } ->
      (* The init reads outer bindings; the box registers afterwards. *)
      let init_code = expr env init in
      env.refs <- name :: env.refs;
      if tail then
        Printf.sprintf "let %s = { v: %s };\nreturn %s.v;" name init_code name
      else Printf.sprintf "let %s = { v: %s };" name init_code
  | Assign_var { name; value } ->
      if List.mem name env.refs then
        Printf.sprintf "%s.v = %s;" name (expr env value)
      else Printf.sprintf "const %s = %s;" name (expr env value)
  | Set_field { self_; name; value } ->
      Printf.sprintf "(%s).%s = %s;" (expr env self_) name (expr env value)
  | If { cond; then_; else_ } ->
      Printf.sprintf "if (E.truthy(%s)) {\n%s\n} else {\n%s\n}" (expr env cond)
        (block env then_) (block env else_)
  | Case { scrutinee; branches } -> case env scrutinee branches ~tail
  | Send { target; message } ->
      Printf.sprintf "E.send(%s, %s)" (expr env target) (expr env message)
  | Receive { branches } ->
      let saved = env.in_receive in
      env.in_receive <- true;
      let scratch = fresh env in
      (* Same shape as `case`: guards nest inside the bindings' scope. *)
      let rec chain bs =
        match bs with
        | [] -> "return false;"
        | b :: rest -> (
            let test = pattern_test scratch b.Emo_ir.pattern in
            let bindings =
              String.concat "\n" (pattern_bindings scratch b.Emo_ir.pattern)
            in
            let body = stmts env b.Emo_ir.body ~tail:false in
            let next = chain rest in
            match b.Emo_ir.guard with
            | Some g ->
                Printf.sprintf
                  "if (%s) {\n\
                   %s\n\
                   if (E.truthy(%s)) {\n\
                   %s\n\
                   return true;\n\
                   } else {\n\
                   %s\n\
                   }\n\
                   } else {\n\
                   %s\n\
                   }"
                  test bindings (expr env g) body next next
            | None ->
                Printf.sprintf
                  "if (%s) {\n%s\n%s\nreturn true;\n} else {\n%s\n}" test
                  bindings body next)
      in
      let dispatch = chain branches in
      env.in_receive <- saved;
      Printf.sprintf "await E.receive(async (%s) => {\n%s\n})" scratch dispatch
  | Raise e -> Printf.sprintf "E.throwException(%s);" (expr env e)
  | Return_stmt e -> (
      if env.in_receive then
        match e.Emo_ir.desc with
        | Emo_ir.Call { func = g; args } when g = env.fname ->
            (* a receive branch's tail call continues the loop as a
               plain await-recursion *)
            let args_code = String.concat ", " (List.map (expr env) args) in
            Printf.sprintf "return await %s(%s);" (Emo_ir.sanitize_ident g)
              args_code
        | _ -> Printf.sprintf "throw new EReturn(%s);" (expr env e)
      else
        match e.Emo_ir.desc with
        | Emo_ir.Call { func = g; args } when g = env.fname ->
            (* Self tail call: reassign the parameters and continue the
               driver loop. *)
            let assigns =
              String.concat ""
                (List.map2
                   (fun p a -> Printf.sprintf "%s = %s; " p (expr env a))
                   env.fparams args)
            in
            Printf.sprintf "{ %scontinue; }" assigns
        | _ -> Printf.sprintf "return %s;" (expr env e))

and block env (xs : Emo_ir.stmt list) : string =
  match xs with [] -> "" | xs -> stmts env xs ~tail:false

and case env scrutinee (branches : Emo_ir.branch list) ~(tail : bool) : string =
  let s = fresh env in
  (* Guards may reference pattern bindings, so a guarded arm nests its
     guard inside the bindings' scope; the fall-through is duplicated
     into both escapes (arm chains are short). *)
  let rec chain bs =
    match bs with
    | [] -> Printf.sprintf "E.caseError(%s);" s
    | b :: rest -> (
        let test = pattern_test s b.Emo_ir.pattern in
        let bindings =
          String.concat "\n" (pattern_bindings s b.Emo_ir.pattern)
        in
        let body = stmts env b.Emo_ir.body ~tail in
        let next = chain rest in
        match b.Emo_ir.guard with
        | Some g ->
            Printf.sprintf
              "if (%s) {\n\
               %s\n\
               if (E.truthy(%s)) {\n\
               %s\n\
               } else {\n\
               %s\n\
               }\n\
               } else {\n\
               %s\n\
               }"
              test bindings (expr env g) body next next
        | None ->
            Printf.sprintf "if (%s) {\n%s\n%s\n} else {\n%s\n}" test bindings
              body next)
  in
  Printf.sprintf "{\n  const %s = %s;\n  %s\n}" s (expr env scrutinee)
    (chain branches)

(* ---- Declarations ---- *)

let emit_func env (f : Emo_ir.func) : string =
  env.refs <- [];
  let params = String.concat ", " (List.map fst f.fparams) in
  let saved_name = env.fname in
  let saved_params = env.fparams in
  env.fname <- f.Emo_ir.fname;
  env.fparams <- List.map fst f.Emo_ir.fparams;
  let tramp = trampoline env f in
  let body = stmts env f.Emo_ir.fbody ~tail:true in
  env.fname <- saved_name;
  env.fparams <- saved_params;
  if tramp then
    Printf.sprintf "async function %s(%s) {\n  for (;;) {\n%s\n  }\n}"
      f.Emo_ir.fname params body
  else
    Printf.sprintf "async function %s(%s) {\n%s\n}" f.Emo_ir.fname params body

(* The `X.new(...)` entry points: the IR lowers constructor calls to
   the mangled factory name; the factory builds the class instance
   (the constructor runs init). *)
let emit_ctor_factory env (c : Emo_ir.class_) : string =
  let params =
    match c.Emo_ir.cinit with
    | Some init -> (
        match init.Emo_ir.fparams with
        | _ :: rest -> List.map fst rest
        | [] -> [])
    | None -> []
  in
  Printf.sprintf "async function %s(%s) {\n  return new %s(%s);\n}"
    (c.Emo_ir.cname ^ "__new")
    (String.concat ", " params)
    c.Emo_ir.cname
    (String.concat ", " params)

(* A class's content fields, in init-assignment order — the equality
   surface (__eq) reads them. *)
let class_fields (c : Emo_ir.class_) : string list =
  match c.Emo_ir.cinit with
  | None -> []
  | Some init ->
      List.filter_map
        (fun (s : Emo_ir.stmt) ->
          match s with Emo_ir.Set_field { name; _ } -> Some name | _ -> None)
        init.Emo_ir.fbody

(* The class-member name behind a mangled method fname: the mangled
   form is `cname "__" member`; call sites dispatch on the member. *)
let member_name (c : Emo_ir.class_) (m : Emo_ir.func) : string =
  let prefix = c.Emo_ir.cname ^ "__" in
  let n = m.Emo_ir.fname in
  if String.starts_with ~prefix n then
    String.sub n (String.length prefix) (String.length n - String.length prefix)
  else n

let emit_class env (c : Emo_ir.class_) : string =
  env.refs <- [];
  let fields = class_fields c in
  let eq_method =
    let field_eqs =
      List.map
        (fun name -> Printf.sprintf "E.eq(this.%s, o.%s)" name name)
        fields
    in
    let conj =
      match field_eqs with [] -> "true" | xs -> String.concat " && " xs
    in
    Printf.sprintf
      "  __eq(o: any): boolean {\n    return o instanceof %s && %s;\n  }\n"
      c.Emo_ir.cname conj
  in
  let ctor =
    match c.Emo_ir.cinit with
    | None -> "  constructor() {}\n"
    | Some init ->
        let self_param, real_params =
          match init.Emo_ir.fparams with
          | self_ :: rest -> (fst self_, List.map fst rest)
          | [] -> ("self", [])
        in
        let saved = env.refs in
        let params_code = String.concat ", " real_params in
        let body = stmts env init.Emo_ir.fbody ~tail:false in
        env.refs <- saved;
        Printf.sprintf "  constructor(%s) {\n    const %s = this;\n%s\n  }\n"
          params_code self_param body
  in
  let methods =
    String.concat "\n"
      (List.map
         (fun (m : Emo_ir.func) ->
           env.refs <- [];
           let self_param, real_params =
             match m.Emo_ir.fparams with
             | self_ :: rest -> (fst self_, List.map fst rest)
             | [] -> ("self", [])
           in
           let params_code = String.concat ", " real_params in
           let body = stmts env m.Emo_ir.fbody ~tail:true in
           Printf.sprintf "  async %s(%s) {\n    const %s = this;\n%s\n  }"
             (Emo_ir.sanitize_ident (member_name c m))
             params_code self_param body)
         c.Emo_ir.cmethods)
  in
  Printf.sprintf "class %s {\n  static __emo = %S;\n%s%s%s\n}\n" c.Emo_ir.cname
    c.Emo_ir.cdisplay ctor eq_method methods

(* ---- The program ---- *)

let emit_ts ~(runtime : string) (program : Emo_ir.program) : string =
  if List.exists (fun f -> f.Emo_ir.fforeign <> None) program.Emo_ir.pfuncs then
    raise
      (Emo_ir.Lower_error
         "foreign definitions are not supported on the typescript target yet");
  let buf = Buffer.create (16 * 1024) in
  let env =
    { buf; refs = []; fresh = 0; fname = ""; fparams = []; in_receive = false }
  in
  Buffer.add_string buf runtime;
  Buffer.add_string buf "\n// ---- program ----\n";
  List.iter
    (fun (name, sigs) ->
      let entries =
        String.concat "; "
          (List.map (fun (m, a) -> Printf.sprintf "[%S, %d]" m a) sigs)
      in
      put env "E.interfaces[%S] = [%s];\n" name entries)
    program.Emo_ir.pinterfaces;
  List.iter
    (fun (c : Emo_ir.class_) ->
      put env "%s\n" (emit_class env c);
      put env "%s\n" (emit_ctor_factory env c))
    program.Emo_ir.pclasses;
  List.iter (fun f -> put env "%s\n" (emit_func env f)) program.Emo_ir.pfuncs;
  put env
    "\n\
     E.runMain(async () => {\n\
     %s\n\
     }).catch((e: any) => {\n\
     if (e instanceof EHalt || e instanceof EReturn) return;\n\
    \      console.error(E.renderError(e));\n\
    \  process.exitCode = 70;\n\
     });\n"
    (stmts env program.Emo_ir.pinit ~tail:false);
  Buffer.contents buf
