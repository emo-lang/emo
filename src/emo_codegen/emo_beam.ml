(* The BEAM target: emit Core Erlang text for `erlc` to assemble.

   The grammar facts this emitter relies on were probed against the
   pinned OTP 29 reader (plan/step-17-beam.md): every atom quoted, `do`
   sequences exactly two expressions with no comma and no end, fun
   bodies are one expression with no end, and binary literals are
   per-segment `#{...}#`. *)

type env = {
  buf : Buffer.t;
  mutable fresh : int;
  mutable local_map : (string * string) list;
  mutable funcs : (string * int) list;
  mutable fname : string;
}

let fresh_var env name =
  env.fresh <- env.fresh + 1;
  let v = Printf.sprintf "_%s%d" (Emo_ir.sanitize_ident name) env.fresh in
  env.local_map <- (name, v) :: env.local_map;
  v

(* A string constant as a per-byte binary literal: UTF-8 bytes in,
   UTF-8 bytes out. *)
let binary_lit (s : string) : string =
  let seg c =
    Printf.sprintf "#<%d>(8,1,'integer',['unsigned'|['big']])" (Char.code c)
  in
  let n = String.length s in
  if n = 0 then "#{}#"
  else "#{" ^ String.concat "," (List.init n (fun i -> seg s.[i])) ^ "}#"

let put env s = Buffer.add_string env.buf s

(* ---- Expressions ---- *)

let rec expr env (x : Emo_ir.expr) : unit =
  match x.Emo_ir.desc with
  | Const (L_int n) -> put env (string_of_int n)
  | Const (L_float f) -> put env (Printf.sprintf "%F" f)
  | Const (L_bool b) -> put env (if b then "'true'" else "'false'")
  | Const (L_char c) -> put env (Printf.sprintf "$\\x%02x" (Char.code c))
  | Const (L_string s) -> put env (binary_lit s)
  | Type_ref a -> put env ("'" ^ a ^ "'")
  | Var name -> (
      match List.assoc_opt name env.local_map with
      | Some v -> put env v
      | None -> failwith ("beam: unbound local " ^ name ^ " in " ^ env.fname))
  | Global name -> (
      (* a first-class def: its fun literal *)
      match List.assoc_opt name env.funcs with
      | Some a ->
          put env
            (Printf.sprintf "fun 'emo_main':'%s'/%d"
               (Emo_ir.sanitize_ident name)
               a)
      | None -> failwith ("beam: unbound global " ^ name))
  | Call { func; args } -> (
      match List.assoc_opt func env.funcs with
      | Some a ->
          put env
            (Printf.sprintf "apply '%s'/%d " (Emo_ir.sanitize_ident func) a);
          args_list env args
      | None -> failwith ("beam: unbound call " ^ func))
  | Builtin { name; args } -> builtin env name args
  | _ ->
      raise
        (Emo_ir.Lower_error "beam: this construct is not available yet (T17.1)")

and args_list env args =
  put env "(";
  List.iteri
    (fun i a ->
      if i > 0 then put env ", ";
      expr env a)
    args;
  put env ")"

and builtin env name args =
  match (name, args) with
  | "print", [ v ] ->
      (* the interpreter's print appends a newline: the argument's
         bytes, then 10 *)
      put env "call 'io':'put_chars'(#{#<";
      expr env v;
      put env ">('all',8,'binary',['unsigned'|['big']]),";
      put env binary_lit_newline;
      put env "}#)"
  | "self_pid", [] -> put env "call 'erlang':'self'()"
  | "halt", [] -> put env "call 'erlang':'halt'(0)"
  | _ ->
      raise
        (Emo_ir.Lower_error
           ("beam: builtin `" ^ name ^ "` is not available yet (T17.1)"))

and binary_lit_newline = "#<10>(8,1,'integer',['unsigned'|['big']])"

(* ---- Statements ----

   A statement list becomes a left-nested `do` chain: `do E1 do E2 E3`.
   Core discards intermediate values naturally — no drops. *)

let rec stmts env (xs : Emo_ir.stmt list) : unit =
  match xs with
  | [] -> put env "'ok'"
  | [ s ] -> stmt env s
  | s :: rest ->
      put env "do\n";
      stmt env s;
      put env "\n";
      stmts env rest

and stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Emo_ir.Effect x -> expr env x
  | Emo_ir.Let { name; init; _ } ->
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      expr env init;
      put env "\nin ";
      put env v
  | Emo_ir.Assign_var { name; value } -> (
      (* BEAM variables are single-assignment; a `var` rebinding needs
         a fresh Core variable with later reads redirected — T17.2. *)
      match List.assoc_opt name env.local_map with
      | Some _ ->
          ignore value;
          raise
            (Emo_ir.Lower_error "beam: `var` reassignment arrives with T17.2")
      | None -> failwith ("beam: assignment to unbound " ^ name))
  | Emo_ir.Return_stmt x -> expr env x
  | Emo_ir.If _ | Emo_ir.Case _ | Emo_ir.Receive _ | Emo_ir.Send _ ->
      raise (Emo_ir.Lower_error "beam: this statement arrives with T17.2/T17.4")
  | Emo_ir.Set_field _ ->
      raise (Emo_ir.Lower_error "beam: classes arrive with T17.3")
  | Emo_ir.Raise _ ->
      raise (Emo_ir.Lower_error "beam: exceptions arrive with T17.2")

(* ---- Module assembly ----

   One BEAM module per program (the wasm target's single-artifact
   design): every def lands in 'emo_main' under its mangled name, and
   'main'/0 runs the entry statements. *)

let emit (program : Emo_ir.program) : string =
  let buf = Buffer.create (16 * 1024) in
  let env = { buf; fresh = 0; local_map = []; funcs = []; fname = "" } in
  env.funcs <-
    List.map
      (fun (f : Emo_ir.func) -> (f.Emo_ir.fname, List.length f.Emo_ir.fparams))
      program.Emo_ir.pfuncs;
  put env "module 'emo_main' ['main'/0]\n";
  put env "    attributes []\n";
  List.iter
    (fun (f : Emo_ir.func) ->
      let name = Emo_ir.sanitize_ident f.Emo_ir.fname in
      put env (Printf.sprintf "'%s'/%d =\n" name (List.length f.Emo_ir.fparams));
      put env "    fun (";
      let param_vars =
        List.mapi
          (fun i (pname, _) -> (pname, Printf.sprintf "_p%d" i))
          f.Emo_ir.fparams
      in
      put env (String.concat ", " (List.map snd param_vars));
      put env ") ->\n";
      env.local_map <- param_vars;
      env.fname <- f.Emo_ir.fname;
      stmts env f.Emo_ir.fbody;
      put env "\nend\n\n";
      env.local_map <- [])
    program.Emo_ir.pfuncs;
  put env "'main'/0 =\n";
  put env "    fun () ->\n";
  env.fname <- "main";
  env.local_map <- [];
  stmts env program.Emo_ir.pinit;
  put env "\nend\n";
  Buffer.contents buf
