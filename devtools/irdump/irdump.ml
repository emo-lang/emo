(* irdump — print the IR a program lowers to: one indented tree per
   function plus the entry's top-level statements. A backend debugging
   aid, in the spirit of the .wat sibling the wasm target emits: the
   input side of lowering, where index and operand bugs live.

   Usage: dune exec devtools/irdump/irdump.exe -- <dir containing
   main.emo>; the program is resolved and checked like `emo build`,
   always on the native target. *)

let ( @@@ ) indent text = Printf.printf "%s%s\n" (String.make indent ' ') text

let lit = function
  | Emo_ast.L_int n -> Printf.sprintf "int %d" n
  | Emo_ast.L_float f -> Printf.sprintf "float %g" f
  | Emo_ast.L_bool b -> Printf.sprintf "bool %b" b
  | Emo_ast.L_char c -> Printf.sprintf "char %C" c
  | Emo_ast.L_string s -> Printf.sprintf "string %S" s

let unop = function Emo_ast.Not -> "not" | Neg -> "neg"

let binop = function
  | Emo_ast.Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="
  | And -> "&&"
  | Or -> "||"

let rec dump_pattern indent pat =
  match pat.Emo_ast.pattern_desc with
  | Emo_ast.Enum_member (e, m) -> indent @@@ Printf.sprintf "pattern %s.%s" e m
  | Emo_ast.Pattern_literal l -> indent @@@ "pattern " ^ lit l
  | Emo_ast.Pattern_binding name -> indent @@@ "pattern bind " ^ name
  | Emo_ast.Wildcard -> indent @@@ "pattern _"
  | Emo_ast.Tuple_pattern ps ->
      indent @@@ "pattern tuple";
      List.iter (dump_pattern (indent + 2)) ps

let rec dump_e indent e =
  match e.Emo_ir.desc with
  | Const l -> indent @@@ Printf.sprintf "Const %s" (lit l)
  | Type_ref name -> indent @@@ "Type_ref " ^ name
  | Var v -> indent @@@ "Var " ^ v
  | Global g -> indent @@@ "Global " ^ g
  | Tuple es ->
      indent @@@ "Tuple";
      List.iter (dump_e (indent + 2)) es
  | Array_lit es ->
      indent @@@ "Array";
      List.iter (dump_e (indent + 2)) es
  | Make_enum { enum_name; member } ->
      indent @@@ Printf.sprintf "Enum %s.%s" enum_name member
  | Interpolate es ->
      indent @@@ "Interpolate";
      List.iter (dump_e (indent + 2)) es
  | Unary (op, x) ->
      indent @@@ "Unary";
      (indent + 2) @@@ unop op;
      dump_e (indent + 2) x
  | Binary (op, l, r) ->
      indent @@@ "Binary";
      (indent + 2) @@@ binop op;
      dump_e (indent + 2) l;
      dump_e (indent + 2) r
  | Index (b, i) ->
      indent @@@ "Index";
      dump_e (indent + 2) b;
      dump_e (indent + 2) i
  | Field_read { obj; name } ->
      indent @@@ "Field " ^ name;
      dump_e (indent + 2) obj
  | Call { func; args } ->
      indent @@@ "Call " ^ func;
      List.iter (dump_e (indent + 2)) args
  | Call_value { f; args } ->
      indent @@@ "Call_value";
      dump_e (indent + 2) f;
      List.iter (dump_e (indent + 2)) args
  | Method { self_; name; args } ->
      indent @@@ "Method " ^ name;
      dump_e (indent + 2) self_;
      List.iter (dump_e (indent + 2)) args
  | Builtin { name; args } ->
      indent @@@ "Builtin " ^ name;
      List.iter (dump_e (indent + 2)) args
  | Box_new v ->
      indent @@@ "Box_new";
      dump_e (indent + 2) v
  | Make_exception { message } ->
      indent @@@ "Raise_value";
      dump_e (indent + 2) message
  | Do_spawn { func; args } ->
      indent @@@ "Spawn " ^ func;
      List.iter (dump_e (indent + 2)) args
  | Spawn_value { f; args } ->
      indent @@@ "Spawn_value";
      dump_e (indent + 2) f;
      List.iter (dump_e (indent + 2)) args
  | Closure { cparams; _ } ->
      indent
      @@@ Printf.sprintf "Closure [%s]"
            (String.concat "," (List.map fst cparams))

and dump_branch indent b =
  dump_pattern indent b.Emo_ir.pattern;
  Option.iter
    (fun g ->
      indent @@@ "guard";
      dump_e (indent + 2) g)
    b.Emo_ir.guard;
  List.iter (dump_s (indent + 2)) b.Emo_ir.body

and dump_s indent s =
  match s with
  | Effect e ->
      indent @@@ "Effect";
      dump_e (indent + 2) e
  | Let { name; init; _ } ->
      indent @@@ "Let " ^ name;
      dump_e (indent + 2) init
  | Assign_var { name; value } ->
      indent @@@ "Assign " ^ name;
      dump_e (indent + 2) value
  | Set_field { self_; name; value } ->
      indent @@@ "Set_field " ^ name;
      dump_e (indent + 2) self_;
      dump_e (indent + 2) value
  | If { cond; then_; else_ } ->
      indent @@@ "If";
      dump_e (indent + 2) cond;
      List.iter (dump_s (indent + 2)) then_;
      List.iter (dump_s (indent + 2)) else_
  | Case { scrutinee; branches } ->
      indent @@@ "Case";
      dump_e (indent + 2) scrutinee;
      List.iter (dump_branch (indent + 2)) branches
  | Receive { branches } ->
      indent @@@ "Receive";
      List.iter (dump_branch (indent + 2)) branches
  | Send { target; message } ->
      indent @@@ "Send";
      dump_e (indent + 2) target;
      dump_e (indent + 2) message
  | Raise e ->
      indent @@@ "Raise";
      dump_e (indent + 2) e
  | Return_stmt e ->
      indent @@@ "Return";
      dump_e (indent + 2) e

let inputs, entry, _ =
  Emo_project.compile_inputs ~entry_file:"main.emo" ~target:"native"

let p = Emo_ir.lower { Emo_ir.modules = inputs; entry }

let () =
  List.iter
    (fun f ->
      Printf.printf "FUNC %s params=[%s]\n" f.Emo_ir.fname
        (String.concat "," (List.map fst f.Emo_ir.fparams));
      List.iter (dump_s 2) f.Emo_ir.fbody)
    p.Emo_ir.pfuncs;
  List.iter
    (fun c ->
      Printf.printf "CLASS %s\n" c.Emo_ir.cname;
      Option.iter
        (fun i -> Printf.printf "  init %s\n" i.Emo_ir.fname)
        c.Emo_ir.cinit;
      List.iter
        (fun m -> Printf.printf "  method %s\n" m.Emo_ir.fname)
        c.Emo_ir.cmethods)
    p.Emo_ir.pclasses;
  List.iter
    (fun (name, meths) ->
      Printf.printf "INTERFACE %s [%s]\n" name
        (String.concat ","
           (List.map (fun (m, a) -> m ^ "/" ^ string_of_int a) meths)))
    p.Emo_ir.pinterfaces;
  Printf.printf "PINIT\n";
  List.iter (dump_s 2) p.Emo_ir.pinit
