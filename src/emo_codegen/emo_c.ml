(* The C backend: the IR lowered to one C translation unit that the
   system cc compiles next to the Emo runtime sources into a single
   standalone binary — no OCaml runtime (plan/step-24-c-target.md;
   docs/native-backend.md records the emit-and-delegate precedent).

   The two-world structure starts at the signature: native types cross
   as C scalars, and the dynamic world's tagged word arrives with its
   task (T24.4). The skeleton emits the entry stub, hosted startup,
   and println over stdio; every construct beyond that support set
   refuses loudly rather than miscompiling, growing task by task
   (T24.2 fills the trampoline and the integer core). *)

module Ast = Emo_ast

(* The runtime sources, carried as generated data so the backend works
   wherever the compiler runs — no file lookup against the
   installation. *)
let runtime_c = Emo_c_runtime_data.runtime_c
let runtime_h = Emo_c_runtime_data.runtime_h

type env = { buf : Buffer.t }

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

(* Native Emo types cross as C scalars; everything dynamic waits for
   the tagged word (T24.4). [Void] is a result type only. *)
let c_type (t : Emo_check.t) : string option =
  match t with
  | Emo_check.Int64 -> Some "int64_t"
  | Emo_check.Float64 -> Some "double"
  | Emo_check.Bool -> Some "bool"
  | Emo_check.Void -> Some "void"
  | _ -> None

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

(* ---- Expressions ----

   T24.1 emits string literals only — println's argument. The integer
   core arrives in T24.2; every other form refuses. *)

let emit_expr env (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Const (Ast.L_string s) -> c_string s
  | Const _ -> refuse "non-string literals"
  | _ -> refuse "this expression form"

(* ---- Statements ----

   The one statement in the support set: println of a string literal
   over stdio. Everything else — bindings, control flow, returns — is
   T24.2 and later. *)

let emit_builtin env (name : string) (args : Emo_ir.expr list) : unit =
  match (name, args) with
  | "println", [ e ] ->
      let arg = emit_expr env e in
      put env "  emo_println_str(%s);\n" arg
  | "println", _ -> refuse "println with more than one argument"
  | _ -> refuse (Printf.sprintf "the builtin `%s`" name)

let rec emit_stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Effect { desc = Builtin { name; args }; _ } -> emit_builtin env name args
  | Effect _ -> refuse "this expression statement"
  | Let _ -> refuse "bindings"
  | Assign_var _ -> refuse "variable assignment"
  | Set_global_var _ -> refuse "module-level variable assignment"
  | Set_field _ -> refuse "field assignment"
  | If _ -> refuse "`if` statements"
  | Case _ -> refuse "`case` statements"
  | Receive _ -> refuse "`receive` statements"
  | Send _ -> refuse "message sends"
  | Raise _ -> refuse "`raise`"
  | Return_stmt _ -> refuse "`return`"

let emit_stmts env (stmts : Emo_ir.stmt list) : unit =
  List.iter (emit_stmt env) stmts

(* ---- Functions ----

   The tail-call lowering (parameter rebind + jump to the function
   head, `return` as a branch to the epilogue) shapes this emission in
   T24.2; today a function body only carries the statement support set
   above, and anything beyond it refuses. *)

let emit_func env (f : Emo_ir.func) : unit =
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
  put env "%s %s(%s) {\n" (result_type f)
    (Emo_ir.sanitize_ident f.Emo_ir.fname)
    params;
  emit_stmts env f.Emo_ir.fbody;
  (* Unreachable in practice — the checker requires a non-Void body to
     return, and `return` is not in the support set yet. *)
  if f.Emo_ir.fresult <> Emo_check.Void then put env "  return 0;\n";
  put env "}\n\n"

(* ---- The program ---- *)

let emit (program : Emo_ir.program) : string =
  if List.exists (fun f -> f.Emo_ir.fforeign <> None) program.pfuncs then
    raise
      (Emo_ir.Lower_error
         "foreign definitions are not supported on the c target yet");
  if program.pclasses <> [] then refuse "classes";
  if program.pinterfaces <> [] then refuse "interfaces";
  if program.pglobals <> [] then refuse "module-level variables";
  let buf = Buffer.create (16 * 1024) in
  let env = { buf } in
  put env "/* Generated by the Emo compiler (target: c) — do not edit. */\n\n";
  put env "#include \"emo_c_runtime.h\"\n\n";
  List.iter (fun f -> emit_func env f) program.pfuncs;
  put env "int main(void) {\n";
  put env "  emo_startup();\n";
  emit_stmts env program.pinit;
  put env "  return 0;\n}\n";
  Buffer.contents buf
