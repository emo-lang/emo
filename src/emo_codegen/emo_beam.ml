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
  | Call_value { f; args } ->
      (* a closure value is a BEAM fun: apply the expression itself *)
      put env "apply ";
      expr env f;
      args_list env args
  | Closure { cparams; cbody } -> (
      match cparams with
      | [ (pname, _) ] ->
          let v = fresh_var env pname in
          put env ("fun (" ^ v ^ ") ->\n");
          let saved = env.local_map in
          env.local_map <- (pname, v) :: env.local_map;
          let before = Buffer.length env.buf in
          stmts env cbody;
          let body =
            Buffer.sub env.buf before (Buffer.length env.buf - before)
          in
          Buffer.truncate env.buf before;
          put env (body_wrapper body);
          env.local_map <- saved
      | _ ->
          raise
            (Emo_ir.Lower_error
               "beam: only one-parameter closures are supported yet"))
  | Interpolate items ->
      (* to_str the first part, then left-fold the concatenation *)
      let rec chain = function
        | [] -> put env "#{}#"
        | [ one ] -> expr env one
        | first :: rest ->
            put env "apply 'emo_strcat'/2 (";
            expr env first;
            put env ", ";
            chain rest;
            put env ")"
      in
      put env "apply 'emo_to_str'/1 (";
      chain items;
      put env ")"
  | Binary (op, l, r) ->
      put env
        (Printf.sprintf "apply 'emo_%s'/2 "
           (match op with
           | Emo_ast.Add -> "add"
           | Emo_ast.Sub -> "sub"
           | Emo_ast.Mul -> "mul"
           | Emo_ast.Div -> "div"
           | Emo_ast.Mod -> "mod"
           | Emo_ast.Lt -> "lt"
           | Emo_ast.Le -> "le"
           | Emo_ast.Gt -> "gt"
           | Emo_ast.Ge -> "ge"
           | Emo_ast.Eq -> "eq"
           | Emo_ast.Ne -> "ne"
           | Emo_ast.And | Emo_ast.Or -> "add"));
      args_list env [ l; r ]
  | Unary (Emo_ast.Neg, x) ->
      put env "apply 'emo_neg'/1 ";
      args_list env [ x ]
  | Unary (Emo_ast.Not, x) ->
      put env "apply 'emo_not'/1 ";
      args_list env [ x ]
  | Builtin { name; args } -> builtin env name args
  | _ ->
      raise
        (Emo_ir.Lower_error "beam: this construct is not available yet (T17.2)")

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
      put env "call 'io':'put_chars'(#{#<apply 'emo_to_str'/1 (";
      expr env v;
      put env ")>('all',8,'binary',['unsigned'|['big']]),";
      put env binary_lit_newline;
      put env "}#)"
  | "self_pid", [] -> put env "call 'erlang':'self'()"
  | "halt", [] -> put env "call 'erlang':'halt'(0)"
  | _ ->
      raise
        (Emo_ir.Lower_error
           ("beam: builtin `" ^ name ^ "` is not available yet (T17.1)"))

and binary_lit_newline = "#<10>(8,1,'integer',['unsigned'|['big']])"

(* Every function/closure body runs under this wrapper: a `return`
   anywhere in the body throws the tagged result and the wrapper
   unwraps it as the function's value. *)
and body_wrapper (body : string) : string =
  Printf.sprintf
    {json|try
%s
of
    <_r> -> _r
catch
    <_C, _T, _S> ->
	case _T of
	  <{'emo_return', _rv}> when 'true' -> _rv
	  <_other> when 'true' -> call 'erlang':'throw'(_T)
	end|json}
    body

(* ---- Statements ----

   A statement list becomes a left-nested `do` chain: `do E1 do E2 E3`.
   Core discards intermediate values naturally — no drops. *)

and stmts env (xs : Emo_ir.stmt list) : unit =
  match xs with
  | [] -> put env "'ok'"
  | [ s ] -> stmt env s
  | Emo_ir.Let { name; init; _ } :: rest ->
      (* a let scopes over everything after it *)
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      expr env init;
      put env "\nin ";
      stmts env rest
  | s :: rest ->
      put env "do\n";
      stmt env s;
      put env "\n";
      stmts env rest

and stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Emo_ir.Effect x -> expr env x
  | Emo_ir.Let _ -> failwith "beam: let handled by stmts"
  | Emo_ir.Assign_var { name; value } -> (
      (* BEAM variables are single-assignment; a `var` rebinding needs
         a fresh Core variable with later reads redirected — T17.2. *)
      match List.assoc_opt name env.local_map with
      | Some _ ->
          ignore value;
          raise
            (Emo_ir.Lower_error "beam: `var` reassignment arrives with T17.2")
      | None -> failwith ("beam: assignment to unbound " ^ name))
  | Emo_ir.Return_stmt x ->
      (* the function-body try wrapper turns this into the result *)
      put env "call 'erlang':'throw'({'emo_return', ";
      expr env x;
      put env "})"
  | Emo_ir.If { cond; then_; else_ } ->
      (* Emo conditions are Bool values: the atoms 'true'/'false' *)
      put env "case ";
      expr env cond;
      put env " of\n";
      put env "  <'true'> when 'true' ->\n";
      stmts env then_;
      put env "\n  <'false'> when 'true' ->\n";
      stmts env else_;
      put env "\nend"
  | Emo_ir.Case _ ->
      raise (Emo_ir.Lower_error "beam: case patterns arrive with T17.3")
  | Emo_ir.Receive _ | Emo_ir.Send _ ->
      raise (Emo_ir.Lower_error "beam: processes arrive with T17.4")
  | Emo_ir.Set_field _ ->
      raise (Emo_ir.Lower_error "beam: classes arrive with T17.3")
  | Emo_ir.Raise x ->
      (* an ordinary Emo exception: a throw the entry reports *)
      put env "call 'erlang':'throw'({emo_raise, ";
      expr env x;
      put env "})"

(* ---- The runtime ----

   Fixed Core Erlang defs prepended to every module: arithmetic with
   the interpreter's masked i64 wrap-around, numeric/string add,
   comparisons via structural equality on tagged values, and to_str/
   strcat for print and interpolation. Raw text — this code never
   varies per program. *)

let rt_source =
  {|
'emo_mask'/1 =
    fun (_v) ->
	call 'erlang':'-'
	    (call 'erlang':'rem'
		 (call 'erlang':'+'(_v, 9223372036854775808), 18446744073709551616),
	     9223372036854775808)

'emo_strcat'/2 =
    fun (_a, _b) ->
	#{#<_a>('all',8,'binary',['unsigned'|['big']]),
	  #<_b>('all',8,'binary',['unsigned'|['big']])}#

'emo_type_error'/2 =
    fun (_a, _b) ->
	call 'erlang':'error'({'emo_bad_type', _a, _b})

'emo_to_str'/1 =
    fun (_v) ->
	case _v of
	  <_i> when call 'erlang':'is_integer'(_i) ->
	      call 'erlang':'integer_to_binary'(_i)
	  <_f> when call 'erlang':'is_float'(_f) ->
	      call 'erlang':'float_to_binary'(_f, ['short'])
	  <'true'> when 'true' ->
	      #{#<116>(8,1,'integer',['unsigned'|['big']]),
		#<114>(8,1,'integer',['unsigned'|['big']]),
		#<117>(8,1,'integer',['unsigned'|['big']]),
		#<101>(8,1,'integer',['unsigned'|['big']])}#
	  <'false'> when 'true' ->
	      #{#<102>(8,1,'integer',['unsigned'|['big']]),
		#<97>(8,1,'integer',['unsigned'|['big']]),
		#<108>(8,1,'integer',['unsigned'|['big']]),
		#<115>(8,1,'integer',['unsigned'|['big']]),
		#<101>(8,1,'integer',['unsigned'|['big']])}#
	  <_s> when call 'erlang':'is_binary'(_s) -> _s
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_to_str', _other})
	end

'emo_add'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'+'(_x, _y))
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'+'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_x> when call 'erlang':'is_binary'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_binary'(_y) ->
		    apply 'emo_strcat'/2 (_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'+'(_x, _y)
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'+'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_sub'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'-'(_x, _y))
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'-'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'-'(_x, _y)
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'-'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_mul'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'*'(_x, _y))
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'*'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'*'(_x, _y)
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'*'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_div'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'div'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_mod'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'rem'(_x, _y)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_neg'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      apply 'emo_mask'/1 (call 'erlang':'-'(0, _x))
	  <_x> when call 'erlang':'is_float'(_x) ->
	      call 'erlang':'-'(_x)
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_other, _other)
	end

'emo_not'/1 =
    fun (_a) ->
	case _a of
	  <'true'> when 'true' -> 'false'
	  <'false'> when 'true' -> 'true'
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_other, _other)
	end

'emo_cmp'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) -> {_x, _y}
		<_y> when call 'erlang':'is_float'(_y) -> {_x, _y}
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) -> {_x, _y}
		<_y> when call 'erlang':'is_float'(_y) -> {_x, _y}
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_lt'/2 =
    fun (_a, _b) ->
	case apply 'emo_cmp'/2 (_a, _b) of
	  <{_x, _y}> when 'true' -> call 'erlang':'<'(_x, _y)
	end

'emo_le'/2 =
    fun (_a, _b) ->
	case apply 'emo_cmp'/2 (_a, _b) of
	  <{_x, _y}> when 'true' -> call 'erlang':'=<'(_x, _y)
	end

'emo_gt'/2 =
    fun (_a, _b) ->
	case apply 'emo_cmp'/2 (_a, _b) of
	  <{_x, _y}> when 'true' -> call 'erlang':'>'(_x, _y)
	end

'emo_ge'/2 =
    fun (_a, _b) ->
	case apply 'emo_cmp'/2 (_a, _b) of
	  <{_x, _y}> when 'true' -> call 'erlang':'>='(_x, _y)
	end

'emo_eq'/2 =
    fun (_a, _b) -> call 'erlang':'=:='(_a, _b)

'emo_ne'/2 =
    fun (_a, _b) -> call 'erlang':'=/='(_a, _b)

|}

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
  put env rt_source;
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
      let before = Buffer.length buf in
      stmts env f.Emo_ir.fbody;
      let body = Buffer.sub buf before (Buffer.length buf - before) in
      Buffer.truncate buf before;
      put env (body_wrapper body);
      put env "\n\n";
      env.local_map <- [])
    program.Emo_ir.pfuncs;
  put env "'main'/0 =\n";
  put env "    fun () ->\n";
  env.fname <- "main";
  env.local_map <- [];
  let before = Buffer.length buf in
  stmts env program.Emo_ir.pinit;
  let body = Buffer.sub buf before (Buffer.length buf - before) in
  Buffer.truncate buf before;
  put env (body_wrapper body);
  put env "\nend\n";
  Buffer.contents buf
