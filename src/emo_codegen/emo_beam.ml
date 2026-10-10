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
  mutable classes : Emo_ir.class_ list;
  mutable iface_classes : (string * string list) list;
  mutable class_field : (string * (string * int) list) list;
  mutable current_class : string option;
}

(* The class-member name behind a mangled method fname: the mangled
   form is `cname "__" member`. *)
let member_name (c : Emo_ir.class_) (m : Emo_ir.func) : string =
  let prefix = c.Emo_ir.cname ^ "__" in
  let n = m.Emo_ir.fname in
  if String.starts_with ~prefix n then
    String.sub n (String.length prefix) (String.length n - String.length prefix)
  else n

(* The checker's ClassType carries the display name; every emitted
   table keys on the mangled one. *)
let mangled_of_display (classes : Emo_ir.class_ list) (display : string) :
    string option =
  List.find_opt
    (fun (c : Emo_ir.class_) -> String.equal c.Emo_ir.cdisplay display)
    classes
  |> Option.map (fun c -> c.Emo_ir.cname)

(* A class's content fields, in init-assignment order (the IR's only
   field order). *)
let class_fields (c : Emo_ir.class_) : string list =
  match c.Emo_ir.cinit with
  | None -> []
  | Some init ->
      List.filter_map
        (fun (st : Emo_ir.stmt) ->
          match st with Emo_ir.Set_field { name; _ } -> Some name | _ -> None)
        init.Emo_ir.fbody

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

let atom s = "'" ^ s ^ "'"

(* A float literal, normalized: `%F` writes 65535.0 as `65535.`, which
   Core Erlang reads as an integer followed by a stray dot, and `%.17g`
   writes 3.14159 as 3.1415899999999999. The shortest decimal that reads
   back as the same double always carries a fraction and an exponent the
   grammar accepts. *)
let float_lit (f : float) : string =
  let rec shortest p =
    if p >= 17 then Printf.sprintf "%.17g" f
    else
      let s = Printf.sprintf "%.*g" p f in
      if float_of_string s = f then s else shortest (p + 1)
  in
  let s = shortest 1 in
  let n = String.length s in
  let rec find i =
    if i >= n then None
    else match s.[i] with 'e' | 'E' -> Some i | _ -> find (i + 1)
  in
  let mantissa, exponent =
    match find 0 with
    | Some i -> (String.sub s 0 i, Some (String.sub s (i + 1) (n - i - 1)))
    | None -> (s, None)
  in
  let mantissa =
    if String.contains mantissa '.' then mantissa else mantissa ^ ".0"
  in
  match exponent with None -> mantissa | Some e -> mantissa ^ "E" ^ e

(* the instance pattern for a class: the tag, the class atom, then one
   wildcard per field (fields live inline in the tuple) *)
let instance_pattern (classes : Emo_ir.class_ list) (cname : string) : string =
  let n =
    match
      List.find_opt
        (fun (c : Emo_ir.class_) -> String.equal c.Emo_ir.cname cname)
        classes
    with
    | Some c -> List.length (class_fields c)
    | None -> 0
  in
  let wilds =
    String.concat ", " (List.init n (fun i -> "_f" ^ string_of_int i))
  in
  match n with
  | 0 -> Printf.sprintf "{'emo_inst', %s}" (atom cname)
  | _ -> Printf.sprintf "{'emo_inst', %s, %s}" (atom cname) wilds

let put env s = Buffer.add_string env.buf s

(* ---- Expressions ---- *)

let rec expr env (x : Emo_ir.expr) : unit =
  match x.Emo_ir.desc with
  | Const (L_int n) -> put env (Int64.to_string n)
  | Const (L_byte n) -> put env (string_of_int n)
  | Const (L_float f) -> put env (float_lit f)
  | Const (L_bool b) -> put env (if b then "'true'" else "'false'")
  | Const (L_char c) -> put env (one_byte_lit (Char.code c))
  | Const (L_string s) -> put env (binary_lit s)
  | Type_ref a -> put env ("'" ^ a ^ "'")
  | Emo_ir.Global_var _ -> failwith "beam: module-level `var` is not supported"
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
      (* every part renders through to_str, then the binaries concat *)
      let rec chain = function
        | [] -> put env "#{}#"
        | [ one ] ->
            put env "apply 'emo_to_str'/1 (";
            expr env one;
            put env ")"
        | first :: rest ->
            put env "apply 'emo_strcat'/2 (apply 'emo_to_str'/1 (";
            expr env first;
            put env "), ";
            chain rest;
            put env ")"
      in
      chain items
  | Cond { c; t; e = else_ } ->
      (* Emo conditions are Bool values: the atoms 'true'/'false' *)
      put env "case ";
      expr env c;
      put env " of\n  <'true'> when 'true' ->\n";
      expr env t;
      put env "\n  <'false'> when 'true' ->\n";
      expr env else_;
      put env "\nend"
  | Binary (((Emo_ast.And | Emo_ast.Or) as op), l, r) ->
      (* the other targets short-circuit these, so beam does too —
         Core Erlang has no `andalso` call, only the operator, and the
         operator is not a Core form; a case gives the same shape *)
      let lcode = expr_block env l in
      let rcode = expr_block env r in
      if op = Emo_ast.And then
        put env
          (Printf.sprintf
             "case %s of\n\
              \t  <'true'> when 'true' ->\n\
             \    %s\n\
              \t  <_other> when 'true' ->\n\
             \    'false'\n\
              \tend"
             lcode rcode)
      else
        put env
          (Printf.sprintf
             "case %s of\n\
              \t  <'true'> when 'true' ->\n\
             \    'true'\n\
              \t  <_other> when 'true' ->\n\
             \    %s\n\
              \tend"
             lcode rcode)
  | Binary (op, l, r) ->
      (* Int64 is the target's own 64-bit wrapping integer — every
         integer operator already masks at 64 bits — so only Byte needs
         its own path, wrapping at 256. *)
      let name =
        match (op, x.Emo_ir.ety) with
        | Emo_ast.Add, Emo_check.Byte -> "byte_add"
        | Emo_ast.Sub, Emo_check.Byte -> "byte_sub"
        | Emo_ast.Mul, Emo_check.Byte -> "byte_mul"
        | Emo_ast.Shl, Emo_check.Byte -> "byte_shl"
        | _ -> (
            match op with
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
            | Emo_ast.Bit_and -> "band"
            | Emo_ast.Bit_or -> "bor"
            | Emo_ast.Bit_xor -> "bxor"
            | Emo_ast.Shl -> "shl"
            | Emo_ast.Shr -> "shr"
            (* the logical operators lower through the case above *)
            | Emo_ast.And | Emo_ast.Or -> assert false)
      in
      put env (Printf.sprintf "apply 'emo_%s'/2 " name);
      args_list env [ l; r ]
  | Unary (Emo_ast.Neg, x) ->
      put env "apply 'emo_neg'/1 ";
      args_list env [ x ]
  | Unary (Emo_ast.Not, x) ->
      put env "apply 'emo_not'/1 ";
      args_list env [ x ]
  | Unary (Emo_ast.Bit_not, x) ->
      put env
        (if x.Emo_ir.ety = Emo_check.Byte then "apply 'emo_byte_bnot'/1 "
         else "apply 'emo_bnot'/1 ");
      args_list env [ x ]
  | Tuple es ->
      put env "{";
      List.iteri
        (fun i e ->
          if i > 0 then put env ", ";
          expr env e)
        es;
      put env "}"
  | Array_lit es ->
      put env "[";
      List.iteri
        (fun i e ->
          if i > 0 then put env ", ";
          expr env e)
        es;
      put env "]"
  | Map_lit _ ->
      raise (Emo_ir.Lower_error "the beam target does not support Map yet")
  | Index (b, i) ->
      (* a tuple is an Erlang tuple and answers element/2; a list (an
         array literal) is 1-based and answers lists:nth *)
      if match b.Emo_ir.ety with Emo_check.TupleType _ -> true | _ -> false
      then (
        put env "call 'erlang':'element'(call 'erlang':'+'(1, ";
        expr env i;
        put env "), ";
        expr env b;
        put env ")")
      else (
        put env "call 'lists':'nth'(call 'erlang':'+'(1, ";
        expr env i;
        put env "), ";
        expr env b;
        put env ")")
  | Field_read { obj; name } -> (
      (* a module reference: the alias's runtime value is never used —
         qualified calls resolve statically — so the qualified path as
         a binary stands in (the TypeScript target's inert value) *)
      match obj.Emo_ir.desc with
      | Emo_ir.Type_ref m -> put env (binary_lit (m ^ "__" ^ name))
      | _ -> (
          let class_name =
            match obj.Emo_ir.ety with
            | Emo_check.ClassType c -> (
                match mangled_of_display env.classes c with
                | Some cname -> cname
                | None -> (
                    match env.current_class with
                    | Some c -> c
                    | None -> failwith "beam: field read without a known class")
                )
            | _ -> (
                match env.current_class with
                | Some c -> c
                | None -> failwith "beam: field read without a known class")
          in
          match List.assoc_opt class_name env.class_field with
          | Some fields -> (
              match List.assoc_opt name fields with
              | Some fidx ->
                  put env
                    (Printf.sprintf "call 'erlang':'element'(%d, " (fidx + 3));
                  expr env obj;
                  put env ")"
              | None ->
                  failwith ("beam: unknown field " ^ class_name ^ "." ^ name))
          | None -> failwith ("beam: unknown class " ^ class_name)))
  | Make_enum { enum_name; member } ->
      put env
        (Printf.sprintf "{'emo_enum', %s, %s}" (atom enum_name) (atom member))
  | Box_new v ->
      (* a Box is a process-dictionary key (T17.4 upgrades to a
         holding process for cross-process boxes) *)
      put env "let <_boxref> = call 'erlang':'make_ref'() in ";
      put env "do call 'erlang':'put'(_boxref, ";
      expr env v;
      put env ") _boxref"
  | Bytes_new v ->
      put env "apply 'emo_bytes_new'/1 ";
      args_list env [ v ]
  | List_new v ->
      put env "apply 'emo_list_new'/1 ";
      args_list env [ v ]
  | Method { self_; name; args } -> method_call env self_ name args
  | Do_spawn { func; args } -> (
      (* the arguments evaluate in the spawner; the fun closes over
         them lexically. The wrapper turns a `halt` into a clean
         process end. *)
      match List.assoc_opt func env.funcs with
      | Some a ->
          let arg_locals = List.map (fun _ -> fresh_var env "_spawnarg") args in
          List.iter2
            (fun arg l ->
              put env ("let <" ^ l ^ "> =\n");
              expr env arg;
              put env "\nin ")
            args arg_locals;
          put env "call 'erlang':'spawn'(fun () -> ";
          let saved = env.local_map in
          env.local_map <- [];
          put env
            (body_wrapper ~halt:true
               (Printf.sprintf "apply '%s'/%d (%s)"
                  (Emo_ir.sanitize_ident func)
                  a
                  (String.concat ", " arg_locals)));
          env.local_map <- saved;
          put env ")"
      | None -> failwith ("beam: unbound spawn " ^ func))
  | Spawn_value { f; args } ->
      let arg_locals = List.map (fun _ -> fresh_var env "_spawnarg") args in
      List.iter2
        (fun arg l ->
          put env ("let <" ^ l ^ "> =\n");
          expr env arg;
          put env "\nin ")
        args arg_locals;
      let f_code = expr_block env f in
      put env "call 'erlang':'spawn'(fun () -> ";
      let saved = env.local_map in
      env.local_map <- [];
      put env
        (body_wrapper ~halt:true
           (Printf.sprintf "apply %s (%s)" f_code
              (String.concat ", " arg_locals)));
      env.local_map <- saved;
      put env ")"
  | Builtin { name; args } -> builtin env name args
  | Make_exception { message } ->
      (* Exception.new's object is its message, and the construction
         never returns — the throw happens right here, so a Raise
         wrapping this never reaches its own wrapper. *)
      put env "call 'erlang':'throw'({'emo_raise', ";
      expr env message;
      put env "})"

and method_call env self_ name args =
  let mangled = Emo_ir.sanitize_ident name in
  (* the Bytes method names are unambiguous, so dispatch goes by name;
     length and to_string serve several types and split at runtime on
     the {'emo_bytes', Key} tag *)
  let bytes_only arity fname =
    put env (Printf.sprintf "apply '%s'/%d " fname arity);
    args_list env (self_ :: args)
  in
  match (name, args) with
  | "get", [ _ ] -> bytes_only 2 "emo_bytes_get"
  | "set", [ _; _ ] -> bytes_only 3 "emo_bytes_set"
  | "get_u16_le", [ _ ] -> bytes_only 2 "emo_bytes_u16_get"
  | "get_u32_le", [ _ ] -> bytes_only 2 "emo_bytes_u32_get"
  | "get_u64_le", [ _ ] -> bytes_only 2 "emo_bytes_u64_get"
  | "set_u16_le", [ _; _ ] -> bytes_only 3 "emo_bytes_u16_set"
  | "set_u32_le", [ _; _ ] -> bytes_only 3 "emo_bytes_u32_set"
  | "set_u64_le", [ _; _ ] -> bytes_only 3 "emo_bytes_u64_set"
  | "to_bytes", [] -> bytes_only 1 "emo_str_to_bytes"
  | "push_front", [ _ ] -> bytes_only 2 "emo_list_push_front"
  | "push_back", [ _ ] -> bytes_only 2 "emo_list_push_back"
  | "pop_front", [] -> bytes_only 1 "emo_list_pop_front"
  | "pop_back", [] -> bytes_only 1 "emo_list_pop_back"
  | "length", [] ->
      put env "case ";
      expr env self_;
      put env
        " of\n\
        \  <{'emo_bytes', _k}> when 'true' ->\n\
        \    apply 'emo_bytes_len'/1 ";
      args_list env [ self_ ];
      put env
        "\n  <{'emo_list', _k}> when 'true' ->\n    apply 'emo_list_len'/1 ";
      args_list env [ self_ ];
      put env "\n  <_> when 'true' ->\n    call 'erlang':'length'(";
      expr env self_;
      put env ")\nend"
  | "to_string", [] ->
      put env "case ";
      expr env self_;
      put env
        " of\n\
        \  <{'emo_bytes', _k}> when 'true' ->\n\
        \    apply 'emo_bytes_to_str'/1 ";
      args_list env [ self_ ];
      put env
        "\n  <{'emo_list', _k}> when 'true' ->\n    apply 'emo_list_to_str'/1 ";
      args_list env [ self_ ];
      put env "\n  <_> when 'true' ->\n    apply 'emo_to_str'/1 ";
      args_list env [ self_ ];
      put env "\nend"
  (* The fixed-width conversions. Int64 and Byte are both plain Erlang
     integers here, so `to_int64` is the identity and the static constructors
     differ only in Byte's range check. *)
  | "from_int64", [ v ] -> (
      match self_.Emo_ir.desc with
      | Emo_ir.Type_ref "Int64" -> expr env v
      | _ ->
          put env "apply 'emo_byte_from_int64'/1 ";
          args_list env [ v ])
  | "from_bits", [ v ] ->
      put env "apply 'emo_from_bits'/1 ";
      args_list env [ v ]
  | "to_int64", [] -> expr env self_
  | "to_byte", [] ->
      put env "apply 'emo_to_byte'/1 ";
      args_list env [ self_ ]
  | "to_bits", [] ->
      put env "apply 'emo_to_bits'/1 ";
      args_list env [ self_ ]
  | _ -> (
      match (name, args) with
      | "append", [ v ] ->
          put env "apply 'emo_array_append'/2 ";
          args_list env [ self_; v ]
      | "read", [] ->
          put env "call 'erlang':'get'(";
          expr env self_;
          put env ")"
      | "replace", [ v ] ->
          put env "apply 'emo_box_replace'/2 ";
          args_list env [ self_; v ]
      | "is", [ target ] -> (
          let tname =
            match target.Emo_ir.desc with
            | Emo_ir.Type_ref n -> n
            | _ -> failwith "beam: `is` expects a type name"
          in
          let impls =
            match List.assoc_opt tname env.iface_classes with
            | Some cs -> cs
            | None -> (
                match
                  List.find_opt
                    (fun c -> String.equal c.Emo_ir.cdisplay tname)
                    env.classes
                with
                | Some c -> [ c.Emo_ir.cname ]
                | None -> [])
          in
          match impls with
          | [] ->
              raise
                (Emo_ir.Lower_error ("beam: unknown type in `is`: " ^ tname))
          | _ ->
              put env "case ";
              expr env self_;
              put env " of\n";
              List.iter
                (fun cname ->
                  put env
                    (Printf.sprintf "  <%s> when 'true' ->\n    'true'\n"
                       (instance_pattern env.classes cname)))
                impls;
              put env "  <_> when 'true' ->\n    'false'\nend")
      | _ -> (
          (* dispatch: statically on a class-typed receiver, otherwise one
         arm per class defining the method (the runtime value is one of
         them — the checker admitted the call) *)
          let candidates =
            match self_.Emo_ir.ety with
            | Emo_check.ClassType c -> (
                match mangled_of_display env.classes c with
                | Some cname -> [ cname ]
                | None -> [])
            | _ ->
                List.filter_map
                  (fun (c : Emo_ir.class_) ->
                    if
                      List.exists
                        (fun (m : Emo_ir.func) ->
                          String.equal (member_name c m) mangled
                          && List.length m.Emo_ir.fparams - 1 = List.length args)
                        c.Emo_ir.cmethods
                    then Some c.Emo_ir.cname
                    else None)
                  env.classes
          in
          match candidates with
          | [] ->
              raise
                (Emo_ir.Lower_error
                   (Printf.sprintf "beam: method `%s` has no dispatch (in %s)"
                      name env.fname))
          | _ ->
              put env "case ";
              expr env self_;
              put env " of\n";
              List.iter
                (fun cname ->
                  let full = cname ^ "__" ^ mangled in
                  let arity = List.length args + 1 in
                  put env
                    (Printf.sprintf "  <%s> when 'true' ->\n    apply '%s'/%d ("
                       (instance_pattern env.classes cname)
                       (Emo_ir.sanitize_ident full)
                       arity);
                  expr env self_;
                  List.iter
                    (fun a ->
                      put env ", ";
                      expr env a)
                    args;
                  put env ")\n")
                candidates;
              put env
                "  <_> when 'true' ->\n\
                \    call 'erlang':'error'({'emo_no_method', ";
              put env (atom name);
              put env "})\nend"))

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
  | "println", [ v ] ->
      (* the interpreter's println appends a newline: the argument's
         bytes, then 10 *)
      put env "call 'io':'put_chars'(#{#<apply 'emo_to_str'/1 (";
      expr env v;
      put env ")>('all',8,'binary',['unsigned'|['big']]),";
      put env binary_lit_newline;
      put env "}#)"
  | "printf", [ fmt; data ] ->
      (* the emitted emo_printf walks the format bytes against the
         argument list and puts the rendering itself *)
      put env "apply 'emo_printf'/2 (";
      expr env fmt;
      put env ", ";
      expr env data;
      put env ")"
  | "self_pid", [] -> put env "call 'erlang':'self'()"
  | "halt", [] -> put env "call 'erlang':'throw'('emo_halt')"
  | _ ->
      raise
        (Emo_ir.Lower_error
           ("beam: builtin `" ^ name ^ "` is not available yet (T17.1)"))

and binary_lit_newline = "#<10>(8,1,'integer',['unsigned'|['big']])"

(* A Char value is a one-byte binary. *)
and one_byte_lit (code : int) : string =
  Printf.sprintf "#{#<%d>(8,1,'integer',['unsigned'|['big']])}#" code

(* an expression's code as a string, without disturbing the buffer *)
and expr_block env (x : Emo_ir.expr) : string =
  let before = Buffer.length env.buf in
  expr env x;
  let code = Buffer.sub env.buf before (Buffer.length env.buf - before) in
  Buffer.truncate env.buf before;
  code

(* Every function/closure body runs under this wrapper: a `return`
   anywhere in the body throws the tagged result and the wrapper
   unwraps it as the function's value. A process wrapper also swallows
   `halt`: the spawned fun returns and the process ends. *)
and body_wrapper ?(halt : bool = false) (body : string) : string =
  let halt_arm =
    if halt then "\n\t  <'emo_halt'> when 'true' -> 'ok'" else ""
  in
  Printf.sprintf
    {json|try
%s
of
    <_r> -> _r
catch
    <_C, _T, _S> ->
	case _T of
	  <{'emo_return', _rv}> when 'true' -> _rv%s
	  <_other> when 'true' -> call 'erlang':'throw'(_T)
	end|json}
    body halt_arm

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
  | Emo_ir.Assign_var { name; value } :: rest ->
      (* a var rebinding: a fresh Core variable shadows the old one
         over the rest of the block; the value is captured before the
         shadow exists *)
      let value_code = expr_block env value in
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      put env value_code;
      put env "\nin ";
      env.local_map <- (name, v) :: env.local_map;
      stmts env rest
  | Emo_ir.Set_field { self_; name; value } :: rest ->
      (* the instance tuple is rebuilt with setelement; self rebinds
         over the rest of the block *)
      let class_name =
        match self_.Emo_ir.ety with
        | Emo_check.ClassType c -> (
            match mangled_of_display env.classes c with
            | Some cname -> cname
            | None -> (
                match env.current_class with
                | Some c -> c
                | None -> failwith "beam: field set without a known class"))
        | _ -> (
            match env.current_class with
            | Some c -> c
            | None -> failwith "beam: field set without a known class")
      in
      let fidx =
        match List.assoc_opt class_name env.class_field with
        | Some fields -> (
            match List.assoc_opt name fields with
            | Some i -> i
            | None -> failwith ("beam: unknown field " ^ class_name ^ "." ^ name)
            )
        | None -> failwith ("beam: unknown class " ^ class_name)
      in
      let self_code = expr_block env self_ in
      let value_code = expr_block env value in
      let v = fresh_var env "self" in
      put env ("let <" ^ v ^ "> =\n");
      put env (Printf.sprintf "call 'erlang':'setelement'(%d, " (fidx + 3));
      put env self_code;
      put env ", ";
      put env value_code;
      put env ")\nin ";
      env.local_map <- ("self", v) :: env.local_map;
      stmts env rest
  | s :: rest ->
      put env "do\n";
      stmt env s;
      put env "\n";
      stmts env rest

and stmt env (s : Emo_ir.stmt) : unit =
  match s with
  | Emo_ir.Effect x -> expr env x
  | Emo_ir.Let { name; init; _ } ->
      (* a single-statement body: bind and produce the value *)
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      expr env init;
      put env "\nin ";
      put env v
  | Emo_ir.Assign_var { name; value } ->
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      expr env value;
      put env "\nin ";
      put env v
  | Emo_ir.Set_global_var _ ->
      failwith "beam: module-level `var` is not supported"
  | Emo_ir.Set_field { self_; name; value } ->
      let class_name =
        match self_.Emo_ir.ety with
        | Emo_check.ClassType c -> (
            match mangled_of_display env.classes c with
            | Some cname -> cname
            | None -> (
                match env.current_class with
                | Some c -> c
                | None -> failwith "beam: field set without a known class"))
        | _ -> (
            match env.current_class with
            | Some c -> c
            | None -> failwith "beam: field set without a known class")
      in
      let fidx =
        match List.assoc_opt class_name env.class_field with
        | Some fields -> (
            match List.assoc_opt name fields with
            | Some i -> i
            | None -> failwith ("beam: unknown field " ^ class_name ^ "." ^ name)
            )
        | None -> failwith ("beam: unknown class " ^ class_name)
      in
      let self_code = expr_block env self_ in
      let value_code = expr_block env value in
      let v = fresh_var env "self" in
      put env ("let <" ^ v ^ "> =\n");
      put env (Printf.sprintf "call 'erlang':'setelement'(%d, " (fidx + 3));
      put env self_code;
      put env ", ";
      put env value_code;
      put env ")\nin ";
      put env v
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
  | Emo_ir.Case { scrutinee; branches } ->
      let scratch = fresh_var env "case" in
      put env ("let <" ^ scratch ^ "> =\n");
      expr env scrutinee;
      put env "\nin case ";
      put env scratch;
      put env " of\n";
      (* a trailing wildcard or binding already covers every value, so
         the catch-all after it would be a clause erlc rejects *)
      let exhaustive =
        match List.rev branches with
        | last :: _ -> (
            last.Emo_ir.guard = None
            &&
            match last.Emo_ir.pattern.Emo_ast.pattern_desc with
            | Emo_ast.Wildcard | Emo_ast.Pattern_binding _ -> true
            | _ -> false)
        | [] -> false
      in
      let rec emit_branches bs =
        match bs with
        | [] ->
            if not exhaustive then (
              put env "  <_> when 'true' ->\n";
              put env "    call 'erlang':'error'({'emo_no_match', ";
              put env scratch;
              put env "})\n")
        | b :: rest ->
            let saved = env.local_map in
            put env "  <";
            emit_pattern env b.Emo_ir.pattern;
            put env "> ";
            (match b.Emo_ir.guard with
            | Some g ->
                put env "when ";
                guard_expr env g;
                put env " ->\n"
            | None -> put env "when 'true' ->\n");
            stmts env b.Emo_ir.body;
            put env "\n";
            env.local_map <- saved;
            emit_branches rest
      in
      emit_branches branches;
      put env "end"
  | Emo_ir.Send { target; message } ->
      put env "call 'erlang':'!'(";
      expr env target;
      put env ", ";
      expr env message;
      put env ")"
  | Emo_ir.Receive { branches } ->
      (* BEAM's selective receive IS the semantics: non-matching
         messages stay in the mailbox. The text grammar requires an
         after-clause; infinity with a blocking body never fires. *)
      put env "receive\n";
      let saved = env.local_map in
      List.iter
        (fun b ->
          put env "  <";
          emit_pattern env b.Emo_ir.pattern;
          put env "> ";
          (match b.Emo_ir.guard with
          | Some g ->
              put env "when ";
              guard_expr env g;
              put env " ->\n"
          | None -> put env "when 'true' ->\n");
          stmts env b.Emo_ir.body;
          put env "\n")
        branches;
      env.local_map <- saved;
      put env "after 'infinity' ->\n    primop 'recv_wait'()"
  | Emo_ir.Raise x -> (
      (* an ordinary Emo exception: a throw the entry reports. The
         raised value is the exception object; Exception.new's object
         is its message, so the wrapping is the throw itself. *)
      match x.Emo_ir.desc with
      | Emo_ir.Make_exception { message } ->
          put env "call 'erlang':'throw'({'emo_raise', ";
          expr env message;
          put env "})"
      | _ ->
          put env "call 'erlang':'throw'({'emo_raise', ";
          expr env x;
          put env "})")

(* ---- Guard expressions ----

   Core guards admit calls only (no apply/let/case), so a guard lowers
   through a restricted emitter: raw comparisons and boolean operators
   over variables and constants. Comparisons use the BEAM term order —
   for the numeric/string guards the checker admits, that is exactly
   the interpreter's result. *)

(* ---- Patterns ----

   Every Emo pattern maps directly onto a Core pattern: enum members
   become their tagged tuples, literals become literal patterns
   (strings as per-byte binary patterns), bindings become fresh
   variables. *)

and emit_pattern env (p : Emo_ast.pattern) : unit =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Wildcard -> put env "_"
  | Emo_ast.Pattern_binding name ->
      let v = fresh_var env name in
      put env v
  | Emo_ast.Pattern_literal (L_int n) -> put env (Int64.to_string n)
  | Emo_ast.Pattern_literal (L_byte n) -> put env (string_of_int n)
  | Emo_ast.Pattern_literal (L_bool b) ->
      put env (if b then "'true'" else "'false'")
  | Emo_ast.Pattern_literal (L_char c) -> put env (one_byte_lit (Char.code c))
  | Emo_ast.Pattern_literal (L_string str) -> put env (binary_lit str)
  | Emo_ast.Pattern_literal (L_float f) -> put env (float_lit f)
  | Emo_ast.Enum_member (t, m) ->
      put env (Printf.sprintf "{'emo_enum', %s, %s}" (atom t) (atom m))
  | Emo_ast.Tuple_pattern ps ->
      put env "{";
      List.iteri
        (fun i sub ->
          if i > 0 then put env ", ";
          emit_pattern env sub)
        ps;
      put env "}"

(* ---- The runtime ----

   Fixed Core Erlang defs prepended to every module: arithmetic with
   the interpreter's masked i64 wrap-around, numeric/string add,
   comparisons via structural equality on tagged values, and to_str/
   strcat for println and interpolation. Raw text — this code never
   varies per program. *)

and guard_expr env (x : Emo_ir.expr) : unit =
  match x.Emo_ir.desc with
  | Var name -> (
      match List.assoc_opt name env.local_map with
      | Some v -> put env v
      | None -> failwith ("beam: unbound guard local " ^ name))
  | Const (L_int n) -> put env (Int64.to_string n)
  | Const (L_float f) -> put env (float_lit f)
  | Const (L_bool b) -> put env (if b then "'true'" else "'false'")
  | Const (L_char c) -> put env (one_byte_lit (Char.code c))
  | Const (L_string s) -> put env (binary_lit s)
  | Binary (op, l, r) ->
      let raw =
        match op with
        | Emo_ast.Lt -> "'<'"
        | Emo_ast.Le -> "'=<'"
        | Emo_ast.Gt -> "'>'"
        | Emo_ast.Ge -> "'>='"
        | Emo_ast.Eq -> "'=:='"
        | Emo_ast.Ne -> "'=/='"
        | Emo_ast.And -> "'andalso'"
        | Emo_ast.Or -> "'orelse'"
        | Emo_ast.Add -> "'+'"
        | Emo_ast.Sub -> "'-'"
        | Emo_ast.Mul -> "'*'"
        | Emo_ast.Div -> "'div'"
        | Emo_ast.Mod -> "'rem'"
        | Emo_ast.Bit_and -> "'band'"
        | Emo_ast.Bit_or -> "'bor'"
        | Emo_ast.Bit_xor -> "'bxor'"
        | Emo_ast.Shl -> "'bsl'"
        | Emo_ast.Shr -> "'bsr'"
      in
      put env ("call 'erlang':" ^ raw ^ "(");
      guard_expr env l;
      put env ", ";
      guard_expr env r;
      put env ")"
  | Unary (Emo_ast.Not, x) ->
      put env "call 'erlang':'not'(";
      guard_expr env x;
      put env ")"
  | Unary (Emo_ast.Neg, x) ->
      put env "call 'erlang':'-'(";
      guard_expr env x;
      put env ")"
  | Unary (Emo_ast.Bit_not, x) ->
      put env "call 'erlang':'bnot'(";
      guard_expr env x;
      put env ")"
  | _ ->
      raise
        (Emo_ir.Lower_error
           "beam: guard expressions are limited to comparisons, \
            boolean             operators, and constants on this target")

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
	      apply 'emo_float_to_str'/1 (_f)
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
	  <{'emo_bytes', _k}> when 'true' ->
	      apply 'emo_bytes_label'/1 ({'emo_bytes', _k})
	  <{'emo_list', _k}> when 'true' ->
	      apply 'emo_list_to_str'/1 ({'emo_list', _k})
	  <_s> when call 'erlang':'is_binary'(_s) -> _s
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_to_str', _other})
	end

%% Emo prints a float the way OCaml's `%g` does — six significant digits,
%% exponent form below 1e-4 and at 1e6 and above — except that an integral
%% float within 1e16 keeps one decimal. `float_to_binary/2` decides the
%% exponent itself, so the rounded scientific form is what picks the branch.
'emo_float_to_str'/1 =
    fun (_f) ->
	case call 'erlang':'=='(call 'erlang':'trunc'(_f), _f) of
	  <'true'> when 'true' ->
	      case call 'erlang':'<'(call 'erlang':'abs'(_f), 10000000000000000.0) of
		<'true'> when 'true' ->
		    call 'erlang':'float_to_binary'(_f, [{'decimals',1}, 'compact'])
		<'false'> when 'true' -> apply 'emo_g6'/1 (_f)
	      end
	  <'false'> when 'true' -> apply 'emo_g6'/1 (_f)
	end

'emo_g6'/1 =
    fun (_x) ->
	let <_s> = call 'erlang':'float_to_binary'(_x, [{'scientific',5}])
	in let <_parts> = call 'binary':'split'(_s, #{#<101>(8,1,'integer',['unsigned'|['big']])}#)
	   in let <_m> = call 'erlang':'hd'(_parts)
	      in let <_e> = call 'erlang':'binary_to_integer'(call 'erlang':'hd'(call 'erlang':'tl'(_parts)))
		 in case call 'erlang':'<'(_e, -4) of
		      <'true'> when 'true' -> apply 'emo_g6_sci'/2 (_m, _e)
		      <'false'> when 'true' ->
			  case call 'erlang':'<'(_e, 6) of
			    <'true'> when 'true' ->
				call 'erlang':'float_to_binary'(_x, [{'decimals', call 'erlang':'-'(5, _e)}, 'compact'])
			    <'false'> when 'true' -> apply 'emo_g6_sci'/2 (_m, _e)
			  end
		    end

'emo_g6_sci'/2 =
    fun (_m, _e) ->
	let <_t> = call 'string':'trim'(_m, 'trailing', #{#<48>(8,1,'integer',['unsigned'|['big']])}#)
	in let <_mt> =
	       case call 'binary':'last'(_t) of
		 <_c> when call 'erlang':'=='(_c, 46) ->
		     call 'binary':'part'(_t, 0, call 'erlang':'-'(call 'erlang':'byte_size'(_t), 1))
		 <_c> when 'true' -> _t
	       end
	   in let <_sign> =
		  case call 'erlang':'<'(_e, 0) of
		    <'true'> when 'true' -> #{#<45>(8,1,'integer',['unsigned'|['big']])}#
		    <'false'> when 'true' -> #{#<43>(8,1,'integer',['unsigned'|['big']])}#
		  end
	      in #{#<_mt>('all',8,'binary',['unsigned'|['big']]),
		   #<101>(8,1,'integer',['unsigned'|['big']]),
		   #<_sign>('all',8,'binary',['unsigned'|['big']]),
		   #<apply 'emo_g6_exp'/1 (call 'erlang':'abs'(_e))>('all',8,'binary',['unsigned'|['big']])}#

'emo_g6_exp'/1 =
    fun (_e) ->
	let <_d> = call 'erlang':'integer_to_binary'(_e)
	in case call 'erlang':'<'(call 'erlang':'byte_size'(_d), 2) of
	     <'true'> when 'true' ->
		 #{#<48>(8,1,'integer',['unsigned'|['big']]),
		   #<_d>('all',8,'binary',['unsigned'|['big']])}#
	     <'false'> when 'true' -> _d
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

'emo_band'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'band'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_bor'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'bor'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_bxor'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'bxor'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_shl'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'bsl'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_shr'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    apply 'emo_mask'/1 (call 'erlang':'bsr'(_x, _y))
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_bnot'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      apply 'emo_mask'/1 (call 'erlang':'bnot'(_x))
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
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

'emo_byte_add'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'band'(call 'erlang':'+'(_x, _y), 255)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_byte_sub'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'band'(call 'erlang':'-'(_x, _y), 255)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_byte_mul'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'band'(call 'erlang':'*'(_x, _y), 255)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_byte_shl'/2 =
    fun (_a, _b) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_integer'(_y) ->
		    call 'erlang':'band'(call 'erlang':'bsl'(_x, _y), 255)
		<_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _b)
	end

'emo_byte_bnot'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      call 'erlang':'band'(call 'erlang':'bnot'(_x), 255)
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
	end

'emo_i64_from_int64'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      apply 'emo_mask'/1 (_x)
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
	end

'emo_byte_from_int64'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      case call 'erlang':'<'(_x, 0) of
		<'true'> when 'true' -> call 'erlang':'error'({'emo_bad_byte', _x})
		<'false'> when 'true' ->
		    case call 'erlang':'>'(_x, 255) of
		      <'true'> when 'true' -> call 'erlang':'error'({'emo_bad_byte', _x})
		      <'false'> when 'true' -> _x
		    end
	      end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
	end

'emo_to_byte'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      call 'erlang':'band'(_x, 255)
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
	end

'emo_to_bits'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_float'(_x) ->
	      let <_u> =
		  call 'binary':'decode_unsigned'(#{#<_x>(64,1,'float',['big'])}#, 'big')
	      in case call 'erlang':'<'(_u, 9223372036854775808) of
		   <'true'> when 'true' -> _u
		   <'false'> when 'true' -> call 'erlang':'-'(_u, 18446744073709551616)
		 end
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
	end

%% erlc miscompiles a float bit-string *pattern* written as Core Erlang
%% text (OTP 29 aborts with an internal consistency check), so the bits go
%% back to a float through the external term format instead.
'emo_from_bits'/1 =
    fun (_a) ->
	case _a of
	  <_x> when call 'erlang':'is_integer'(_x) ->
	      let <_u> = call 'erlang':'band'(_x, 18446744073709551615)
	      in call 'erlang':'binary_to_term'(
		   #{#<131>(8,1,'integer',['unsigned'|['big']]),
		     #<70>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 56), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 48), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 40), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 32), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 24), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 16), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(call 'erlang':'bsr'(_u, 8), 255)>(8,1,'integer',['unsigned'|['big']]),
		     #<call 'erlang':'band'(_u, 255)>(8,1,'integer',['unsigned'|['big']])}#)
	  <_other> when 'true' -> apply 'emo_type_error'/2 (_a, _a)
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

'emo_array_append'/2 =
    fun (_xs, _x) -> call 'lists':'reverse'(call 'lists':'reverse'([_x | _xs]))

'emo_box_replace'/2 =
    fun (_k, _v) ->
	do
	    call 'erlang':'put'(_k, _v)
	    _v

'emo_bytes_new'/1 =
    fun (_n) ->
	let <_k> = call 'erlang':'make_ref'()
	in do call 'erlang':'put'(_k, call 'binary':'copy'(#{#<0>(8,1,'integer',['unsigned'|['big']])}#, _n))
	   {'emo_bytes', _k}

'emo_bytes_len'/1 =
    fun (_a) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'erlang':'byte_size'(call 'erlang':'get'(_k))
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_get'/2 =
    fun (_a, _i) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'binary':'at'(call 'erlang':'get'(_k), _i)
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_set'/3 =
    fun (_a, _i, _v) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      let <_b> = call 'erlang':'get'(_k)
	      in do call 'erlang':'put'(_k, #{#<call 'binary':'part'(_b, 0, _i)>('all',8,'binary',['unsigned'|['big']]),
		#<apply 'emo_mask'/1 (_v)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'binary':'part'(_b, call 'erlang':'+'(_i, 1), call 'erlang':'-'(call 'erlang':'byte_size'(_b), call 'erlang':'+'(_i, 1)))>('all',8,'binary',['unsigned'|['big']])}#)
		 _v
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u16_get'/2 =
    fun (_a, _i) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'binary':'decode_unsigned'(call 'binary':'part'(call 'erlang':'get'(_k), _i, 2), 'little')
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u32_get'/2 =
    fun (_a, _i) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'binary':'decode_unsigned'(call 'binary':'part'(call 'erlang':'get'(_k), _i, 4), 'little')
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u64_get'/2 =
    fun (_a, _i) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      apply 'emo_mask'/1 (call 'binary':'decode_unsigned'(call 'binary':'part'(call 'erlang':'get'(_k), _i, 8), 'little'))
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u16_set'/3 =
    fun (_a, _i, _v) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      let <_b> = call 'erlang':'get'(_k)
	      in do call 'erlang':'put'(_k, #{#<call 'binary':'part'(_b, 0, _i)>('all',8,'binary',['unsigned'|['big']]),
		#<call 'erlang':'band'(_v, 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 8), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'binary':'part'(_b, call 'erlang':'+'(_i, 2), call 'erlang':'-'(call 'erlang':'byte_size'(_b), call 'erlang':'+'(_i, 2)))>('all',8,'binary',['unsigned'|['big']])}#)
		 apply 'emo_mask'/1 (_v)
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u32_set'/3 =
    fun (_a, _i, _v) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      let <_b> = call 'erlang':'get'(_k)
	      in do call 'erlang':'put'(_k, #{#<call 'binary':'part'(_b, 0, _i)>('all',8,'binary',['unsigned'|['big']]),
		#<call 'erlang':'band'(_v, 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 8), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 16), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 24), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'binary':'part'(_b, call 'erlang':'+'(_i, 4), call 'erlang':'-'(call 'erlang':'byte_size'(_b), call 'erlang':'+'(_i, 4)))>('all',8,'binary',['unsigned'|['big']])}#)
		 apply 'emo_mask'/1 (_v)
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_u64_set'/3 =
    fun (_a, _i, _v) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      let <_b> = call 'erlang':'get'(_k)
	      in do call 'erlang':'put'(_k, #{#<call 'binary':'part'(_b, 0, _i)>('all',8,'binary',['unsigned'|['big']]),
		#<call 'erlang':'band'(_v, 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 8), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 16), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 24), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 32), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 40), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 48), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'erlang':'band'(call 'erlang':'bsr'(_v, 56), 255)>(8,1,'integer',['unsigned'|['big']]),
		#<call 'binary':'part'(_b, call 'erlang':'+'(_i, 8), call 'erlang':'-'(call 'erlang':'byte_size'(_b), call 'erlang':'+'(_i, 8)))>('all',8,'binary',['unsigned'|['big']])}#)
		 apply 'emo_mask'/1 (_v)
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_str_to_bytes'/1 =
    fun (_s) ->
	let <_k> = call 'erlang':'make_ref'()
	in do call 'erlang':'put'(_k, _s)
	   {'emo_bytes', _k}

'emo_bytes_to_str'/1 =
    fun (_a) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'erlang':'get'(_k)
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_bytes_label'/1 =
    fun (_a) ->
	case _a of
	  <{'emo_bytes', _k}> when 'true' ->
	      call 'erlang':'iolist_to_binary'([66, 121, 116, 101, 115, 91, call 'erlang':'integer_to_list'(call 'erlang':'byte_size'(call 'erlang':'get'(_k))), 93])
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_bytes', _other})
	end

'emo_list_new'/1 =
    fun (_arr) ->
	let <_k> = call 'erlang':'make_ref'()
	in do call 'erlang':'put'(_k, {_arr, []})
	   {'emo_list', _k}

'emo_list_elems'/1 =
    fun (_l) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    call 'erlang':'++'(_f, call 'lists':'reverse'(_r))
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_push_front'/2 =
    fun (_l, _v) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    do call 'erlang':'put'(_k, {[_v | _f], _r})
		       _l
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_push_back'/2 =
    fun (_l, _v) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    do call 'erlang':'put'(_k, {_f, [_v | _r]})
		       _l
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_pop_front'/1 =
    fun (_l) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    case _f of
		      <[_h | _t]> when 'true' ->
			  do call 'erlang':'put'(_k, {_t, _r})
			     _h
		      <[]> when 'true' ->
			  case call 'lists':'reverse'(_r) of
			    <[_h | _t]> when 'true' ->
				do call 'erlang':'put'(_k, {_t, []})
				   _h
			    <[]> when 'true' ->
				call 'erlang':'error'({'emo_empty_list',
						       'pop_front', _l})
			  end
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_pop_back'/1 =
    fun (_l) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    case _r of
		      <[_h | _t]> when 'true' ->
			  do call 'erlang':'put'(_k, {_f, _t})
			     _h
		      <[]> when 'true' ->
			  case call 'lists':'reverse'(_f) of
			    <[_h | _t]> when 'true' ->
				do call 'erlang':'put'(_k, {[], _t})
				   _h
			    <[]> when 'true' ->
				call 'erlang':'error'({'emo_empty_list',
						       'pop_back', _l})
			  end
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_len'/1 =
    fun (_l) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_f, _r}> when 'true' ->
		    call 'erlang':'+'(call 'erlang':'length'(_f),
				      call 'erlang':'length'(_r))
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_to_str'/1 =
    fun (_l) ->
	case _l of
	  <{'emo_list', _k}> when 'true' ->
	      call 'erlang':'iolist_to_binary'
		(apply 'emo_list_join'/2 (apply 'emo_list_elems'/1 (_l), 1))
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_list', _other})
	end

'emo_list_join'/2 =
    fun (_elems, _first) ->
	case _elems of
	  <[_e | _rest]> when 'true' ->
	      let <_piece> = apply 'emo_to_str'/1 (_e)
	      in case _first of
		   <1> when 'true' ->
		       [[76, 105, 115, 116, 91], _piece
			| apply 'emo_list_join'/2 (_rest, 0)]
		   <_> when 'true' ->
		       [[44, 32], _piece | apply 'emo_list_join'/2 (_rest, 0)]
		 end
	  <[]> when 'true' ->
	      case _first of
		<1> when 'true' -> [76, 105, 115, 116, 91, 93]
		<_> when 'true' -> [93]
	      end
	end

'emo_eq'/2 =
    fun (_a, _b) ->
	case _a of
	  <{'emo_bytes', _ka}> when 'true' ->
	      case _b of
		<{'emo_bytes', _kb}> when 'true' ->
		    call 'erlang':'=:='(call 'erlang':'get'(_ka), call 'erlang':'get'(_kb))
		<_other> when 'true' -> 'false'
	      end
	  <{'emo_list', _ka}> when 'true' ->
	      case _b of
		<{'emo_list', _kb}> when 'true' ->
		    call 'erlang':'=:='(apply 'emo_list_elems'/1 (_a), apply 'emo_list_elems'/1 (_b))
		<_other> when 'true' -> 'false'
	      end
	  <_other> when 'true' -> call 'erlang':'=:='(_a, _b)
	end

'emo_ne'/2 =
    fun (_a, _b) -> call 'erlang':'=/='(_a, _b)

%% ---- printf ----
%% 
%%   The beam's own formatter: the format walks as a byte list, integers
%%   render through the bignum-native integer_to_binary (two's
%%   complement via a 2^64 band for the unsigned forms), and floats
%%   destructure into their IEEE-754 words for a BigInt-exact decimal
%%   expansion — correctly rounded, half to even, matching the C
%%   targets' snprintf.

'emo_printf'/2 =
    fun (_fmt, _args) ->
	call 'io':'put_chars'(apply 'emo_printf_walk'/3 (call 'binary':'bin_to_list'(_fmt), _args, []))

'emo_printf_walk'/3 =
    fun (_b, _a, _acc) ->
	case _b of
	  <[]> when 'true' ->
	      case _a of
		<[]> when 'true' -> call 'lists':'reverse'(_acc)
		<_other> when 'true' ->
		    call 'erlang':'error'({'emo_printf_count', call 'erlang':'length'(_other)})
	      end
	  <[37 | _rest]> when 'true' ->
	      apply 'emo_printf_conv'/3 (_rest, _a, _acc)
	  <[_c | _rest]> when 'true' ->
	      apply 'emo_printf_walk'/3 (_rest, _a, [_c | _acc])
	end

'emo_printf_conv'/3 =
    fun (_b0, _a0, _acc) ->
	case _b0 of
	  <[]> when 'true' ->
	      call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<109>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<119>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']])}#})
	  <[37 | _rest]> when 'true' ->
	      apply 'emo_printf_walk'/3 (_rest, _a0, [37 | _acc])
	  <_other> when 'true' ->
	      case apply 'emo_flags'/3 (_other, _a0, {'false', 'false', 'false', 'false', 'false'}) of
		<{_f, _b1, _a1}> when 'true' ->
		    case apply 'emo_width'/2 (_b1, _a1) of
		      <{_w, _b2, _a2}> when 'true' ->
			  case apply 'emo_prec'/2 (_b2, _a2) of
			    <{_p, _b3, _a3}> when 'true' ->
				case _b3 of
		   <[]> when 'true' ->
		       call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<109>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<119>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<98>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']])}#})
			   <[37 | _ignore]> when 'true' ->
			       call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<99>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<99>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<121>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<103>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<44>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<119>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<44>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<99>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']])}#})
			   <[_c | _b4]> when 'true' ->
			       apply 'emo_emit'/7 (_c, _f, _w, _p, _b4, _a3, _acc)
			 end
		      end
		  end
	    end
	end

'emo_flags'/3 =
    fun (_b, _a, _f) ->
	case _b of
	  <[45 | _t]> when 'true' ->
	      apply 'emo_flags'/3 (_t, _a, call 'erlang':'setelement'(1, _f, 'true'))
	  <[43 | _t]> when 'true' ->
	      apply 'emo_flags'/3 (_t, _a, call 'erlang':'setelement'(2, _f, 'true'))
	  <[32 | _t]> when 'true' ->
	      apply 'emo_flags'/3 (_t, _a, call 'erlang':'setelement'(3, _f, 'true'))
	  <[35 | _t]> when 'true' ->
	      apply 'emo_flags'/3 (_t, _a, call 'erlang':'setelement'(4, _f, 'true'))
	  <[48 | _t]> when 'true' ->
	      apply 'emo_flags'/3 (_t, _a, call 'erlang':'setelement'(5, _f, 'true'))
	  <_other> when 'true' -> {_f, _other, _a}
	end

'emo_width'/2 =
    fun (_b, _a) ->
	case _b of
	  <[42 | _t]> when 'true' ->
	      case apply 'emo_pop_int'/2 (_a, 42) of
		<{_v, _a2}> when 'true' -> {{'value', _v}, _t, _a2}
	      end
	  <[_c | _t]> when call 'erlang':'=<'(48, _c) ->
	      case call 'erlang':'=<'(_c, 57) of
		<'true'> when 'true' ->
		    case apply 'emo_digits'/2 (_b, 0) of
		      <{_n, _rest}> when 'true' -> {{'value', _n}, _rest, _a}
		    end
		<'false'> when 'true' -> {{'none'}, _b, _a}
	      end
	  <_other> when 'true' -> {{'none'}, _b, _a}
	end

'emo_prec'/2 =
    fun (_b, _a) ->
	case _b of
	  <[46 | _t]> when 'true' ->
	      case _t of
		<[42 | _t2]> when 'true' ->
		    case apply 'emo_pop_int'/2 (_a, 42) of
		      <{_v, _a2}> when 'true' ->
			  case call 'erlang':'<'(_v, 0) of
			    <'true'> when 'true' -> {{'omit'}, _t2, _a2}
			    <'false'> when 'true' -> {{'value', _v}, _t2, _a2}
			  end
		    end
		<_other> when 'true' ->
		    case apply 'emo_digits'/2 (_t, 0) of
		      <{_n, _rest}> when 'true' -> {{'value', _n}, _rest, _a}
		    end
	      end
	  <_other> when 'true' -> {{'none'}, _b, _a}
	end

'emo_digits'/2 =
    fun (_b, _n) ->
	case _b of
	  <[_c | _t]> when call 'erlang':'=<'(48, _c) ->
	      case call 'erlang':'=<'(_c, 57) of
		<'true'> when 'true' ->
		    apply 'emo_digits'/2 (_t, call 'erlang':'min'(call 'erlang':'+'(call 'erlang':'*'(_n, 10), call 'erlang':'-'(_c, 48)), 999999999))
		<'false'> when 'true' -> {_n, _b}
	      end
	  <_other> when 'true' -> {_n, _b}
	end

'emo_pop_int'/2 =
    fun (_a, _c) ->
	case _a of
	  <[_v | _t]> when call 'erlang':'is_integer'(_v) -> {_v, _t}
	  <[_v | _t]> when 'true' ->
	      call 'erlang':'error'({'emo_printf_wrong', _c, apply 'emo_printf_kind'/1 (_v)})
	  <[]> when 'true' ->
	      call 'erlang':'error'({'emo_printf_count', 0})
	end

'emo_printf_kind'/1 =
    fun (_v) ->
	case _v of
	  <_x> when call 'erlang':'is_atom'(_x) -> #{#<66>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']])}#
	  <_x> when call 'erlang':'is_integer'(_x) -> #{#<73>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<54>(8,1,'integer',['unsigned'|['big']]),#<52>(8,1,'integer',['unsigned'|['big']])}#
	  <_x> when call 'erlang':'is_float'(_x) -> #{#<70>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<54>(8,1,'integer',['unsigned'|['big']]),#<52>(8,1,'integer',['unsigned'|['big']])}#
	  <_x> when call 'erlang':'is_binary'(_x) ->
	      case call 'erlang':'=:='(call 'erlang':'byte_size'(_x), 1) of
		<'true'> when 'true' -> #{#<67>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']])}#
		<'false'> when 'true' -> #{#<83>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<103>(8,1,'integer',['unsigned'|['big']])}#
	      end
	  <_x> when call 'erlang':'is_list'(_x) -> #{#<65>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<121>(8,1,'integer',['unsigned'|['big']])}#
	  <_other> when 'true' -> #{#<118>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']])}#
	end

'emo_emit'/7 =
    fun (_c, _f, _w, _p, _rest, _args, _acc) ->
	case _c of
	  <100> when 'true' -> apply 'emo_emit_int'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <105> when 'true' -> apply 'emo_emit_int'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <117> when 'true' -> apply 'emo_emit_uint'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <111> when 'true' -> apply 'emo_emit_uint'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <120> when 'true' -> apply 'emo_emit_uint'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <88> when 'true' -> apply 'emo_emit_uint'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <99> when 'true' -> apply 'emo_emit_char'/6 (_f, _w, _p, _rest, _args, _acc)
	  <115> when 'true' -> apply 'emo_emit_str'/6 (_f, _w, _p, _rest, _args, _acc)
	  <102> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <70> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <101> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <69> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <103> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <71> when 'true' -> apply 'emo_emit_float'/7 (_c, _f, _w, _p, _rest, _args, _acc)
	  <97> when 'true' ->
	      call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<120>(8,1,'integer',['unsigned'|['big']]),#<45>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<99>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<118>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']])}#})
	  <65> when 'true' ->
	      call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<120>(8,1,'integer',['unsigned'|['big']]),#<45>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<108>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<99>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<118>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<65>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']])}#})
	  <110> when 'true' ->
	      call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<40>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<119>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<103>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<41>(8,1,'integer',['unsigned'|['big']])}#})
	  <112> when 'true' ->
	      call 'erlang':'error'({'emo_printf', #{#<112>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']]),#<58>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<37>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<96>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<117>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<100>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<40>(8,1,'integer',['unsigned'|['big']]),#<69>(8,1,'integer',['unsigned'|['big']]),#<109>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<104>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<32>(8,1,'integer',['unsigned'|['big']]),#<112>(8,1,'integer',['unsigned'|['big']]),#<111>(8,1,'integer',['unsigned'|['big']]),#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<116>(8,1,'integer',['unsigned'|['big']]),#<101>(8,1,'integer',['unsigned'|['big']]),#<114>(8,1,'integer',['unsigned'|['big']]),#<115>(8,1,'integer',['unsigned'|['big']]),#<41>(8,1,'integer',['unsigned'|['big']])}#})
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_printf_bad_conversion', _other})
	end

%% The signed decimal forms: %d and %i.
'emo_emit_int'/7 =
    fun (_c, _f, _w, _p, _rest, _args, _acc) ->
	case apply 'emo_pop_int'/2 (_args, _c) of
	  <{_v, _a2}> when 'true' ->
	      case apply 'emo_int_parts'/3 (_v, _f, 'true') of
		<{_body, _sign}> when 'true' ->
		    let <_out> = apply 'emo_pad'/4 (_f, _w, _sign, _body)
		    in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
	      end
	end

%% The unsigned forms: %u, %o, %x, %X read the 64-bit pattern.
'emo_emit_uint'/7 =
    fun (_c, _f, _w, _p, _rest, _args, _acc) ->
	case apply 'emo_pop_int'/2 (_args, _c) of
	  <{_v, _a2}> when 'true' ->
	      let <_u> = call 'erlang':'band'(_v, 18446744073709551615)
	      in let <_body> =
	       case _c of
		 <117> when 'true' -> call 'erlang':'integer_to_binary'(_u)
		 <111> when 'true' ->
		     let <_o> = call 'erlang':'integer_to_binary'(_u, 8)
		     in case call 'erlang':'and'(call 'erlang':'element'(4, _f), call 'erlang':'/='(_u, 0)) of
			  <'true'> when 'true' ->
			      call 'erlang':'iolist_to_binary'([48, _o])
			  <'false'> when 'true' -> _o
			end
		 <120> when 'true' ->
		     let <_h> = call 'erlang':'integer_to_binary'(_u, 16)
		     in case call 'erlang':'and'(call 'erlang':'element'(4, _f), call 'erlang':'/='(_u, 0)) of
			  <'true'> when 'true' ->
			      call 'erlang':'iolist_to_binary'([#{#<48>(8,1,'integer',['unsigned'|['big']]),#<120>(8,1,'integer',['unsigned'|['big']])}#, call 'string':'lowercase'(_h)])
			  <'false'> when 'true' -> call 'string':'lowercase'(_h)
			end
		 <88> when 'true' ->
		     let <_h> = call 'erlang':'integer_to_binary'(_u, 16)
		     in case call 'erlang':'and'(call 'erlang':'element'(4, _f), call 'erlang':'/='(_u, 0)) of
			  <'true'> when 'true' ->
			      call 'erlang':'iolist_to_binary'([#{#<48>(8,1,'integer',['unsigned'|['big']]),#<88>(8,1,'integer',['unsigned'|['big']])}#, _h])
			  <'false'> when 'true' -> _h
			end
	       end
	      in let <_out> = apply 'emo_pad'/4 (_f, _w, #{}#, _body)
	      in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
	end

%% %d/%i sign split: the value carries '-', '+' and ' ' come from the
%%   flags.
'emo_int_parts'/3 =
    fun (_v, _f, _signed) ->
	case call 'erlang':'<'(_v, 0) of
	  <'true'> when 'true' ->
	      {call 'erlang':'integer_to_binary'(call 'erlang':'abs'(_v)), #{#<45>(8,1,'integer',['unsigned'|['big']])}#}
	  <'false'> when 'true' ->
	      case _signed of
		<'true'> when 'true' ->
		    case call 'erlang':'element'(2, _f) of
		      <'true'> when 'true' -> {call 'erlang':'integer_to_binary'(_v), #{#<43>(8,1,'integer',['unsigned'|['big']])}#}
		      <'false'> when 'true' ->
			  case call 'erlang':'element'(3, _f) of
			    <'true'> when 'true' -> {call 'erlang':'integer_to_binary'(_v), #{#<32>(8,1,'integer',['unsigned'|['big']])}#}
			    <'false'> when 'true' -> {call 'erlang':'integer_to_binary'(_v), #{}#}
			  end
		    end
		<'false'> when 'true' -> {call 'erlang':'integer_to_binary'(_v), #{}#}
	      end
	end

%% One conversion's padding: '-' wins over '0', the sign stays ahead of
%%   a zero fill, and inf/nan never zero-fill (ZeroOk).
'emo_pad'/4 =
    fun (_f, _w, _sign, _body) ->
	let <_minus> =
		case _w of
		  <{'value', _n}> when 'true' ->
		      call 'erlang':'or'(call 'erlang':'element'(1, _f), call 'erlang':'<'(_n, 0))
		  <{'none'}> when 'true' -> call 'erlang':'element'(1, _f)
		end
	   in let <_zero> =
		  call 'erlang':'and'(call 'erlang':'element'(5, _f), call 'erlang':'not'(_minus))
	   in let <_width> =
	       case _w of
		 <{'value', _n}> when 'true' -> call 'erlang':'abs'(_n)
		 <{'none'}> when 'true' -> 0
	       end
	   in let <_total> = call 'erlang':'+'(call 'erlang':'byte_size'(_sign), call 'erlang':'byte_size'(_body))
	   in case call 'erlang':'<'(_width, _total) of
		<'true'> when 'true' ->
		    call 'erlang':'iolist_to_binary'([_sign, _body])
		<'false'> when 'true' ->
		    let <_fill> = call 'erlang':'-'(_width, _total)
		    in case _minus of
			 <'true'> when 'true' ->
			     call 'erlang':'iolist_to_binary'([_sign, _body, call 'binary':'copy'(#{#<32>(8,1,'integer',['unsigned'|['big']])}#, _fill)])
			 <'false'> when 'true' ->
			     case call 'erlang':'and'(_zero, call 'erlang':'not'(_minus)) of
			       <'true'> when 'true' ->
				   call 'erlang':'iolist_to_binary'([_sign, call 'binary':'copy'(#{#<48>(8,1,'integer',['unsigned'|['big']])}#, _fill), _body])
			       <'false'> when 'true' ->
				   call 'erlang':'iolist_to_binary'([call 'binary':'copy'(#{#<32>(8,1,'integer',['unsigned'|['big']])}#, _fill), _sign, _body])
			     end
		       end
	      end

%% %c: a one-byte binary rides as-is; an integer truncates to a byte,
%%   exactly C's unsigned-char conversion. Space padding only.
'emo_emit_char'/6 =
    fun (_f, _w, _p, _rest, _args, _acc) ->
	case _args of
	  <[_v | _a2]> when call 'erlang':'is_binary'(_v) ->
	      let <_out> = apply 'emo_pad'/4 (call 'erlang':'setelement'(5, _f, 'false'), _w, #{}#, _v)
	      in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
	  <[_v | _a2]> when call 'erlang':'is_integer'(_v) ->
	      let <_byte> = call 'erlang':'band'(_v, 255)
	      in case _byte of
		   <_b> when 'true' ->
		       let <_lit> = #{#<_b>(8,1,'integer',['unsigned'|['big']])}#
		       in let <_out> = apply 'emo_pad'/4 (call 'erlang':'setelement'(5, _f, 'false'), _w, #{}#, _lit)
		       in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
		 end
	  <[_v | _a2]> when 'true' ->
	      call 'erlang':'error'({'emo_printf_wrong', 99, apply 'emo_printf_kind'/1 (_v)})
	end

%% %s: bytes only, precision truncates, width pads with spaces — the
%%   `0` flag is undefined for strings in C and ignored here.
'emo_emit_str'/6 =
    fun (_f, _w, _p, _rest, _args, _acc) ->
	case _args of
	  <[_v | _a2]> when call 'erlang':'is_binary'(_v) ->
	      let <_body> =
		      case _p of
			<{'value', _n}> when 'true' ->
			    case call 'erlang':'<'(_n, call 'erlang':'byte_size'(_v)) of
			      <'true'> when 'true' ->
				  call 'binary':'part'(_v, 0, _n)
			      <'false'> when 'true' -> _v
			    end
			<{'omit'}> when 'true' -> _v
			<{'none'}> when 'true' -> _v
		      end
	      in let <_out> = apply 'emo_pad'/4 (call 'erlang':'setelement'(5, _f, 'false'), _w, #{}#, _body)
	      in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
	  <[_v | _a2]> when 'true' ->
	      call 'erlang':'error'({'emo_printf_wrong', 115, apply 'emo_printf_kind'/1 (_v)})
	end

%% The float family: the IEEE words decide the sign, inf and nan; the
%%   digits come from an exact expansion, rounded half to even.
'emo_emit_float'/7 =
    fun (_c, _f, _w, _p, _rest, _args, _acc) ->
	case _args of
	  <[_v | _a2]> when call 'erlang':'is_float'(_v) ->
	      case apply 'emo_float_parts'/1 (_v) of
		<{_s, _e11, _m}> when 'true' ->
	      let <_sign> =
		     case _s of
		       <1> when 'true' -> #{#<45>(8,1,'integer',['unsigned'|['big']])}#
		       <0> when 'true' ->
			   case call 'erlang':'element'(2, _f) of
			     <'true'> when 'true' -> #{#<43>(8,1,'integer',['unsigned'|['big']])}#
			     <'false'> when 'true' ->
				 case call 'erlang':'element'(3, _f) of
				   <'true'> when 'true' -> #{#<32>(8,1,'integer',['unsigned'|['big']])}#
				   <'false'> when 'true' -> #{}#
				 end
			   end
		     end
	      in let <_upper> = call 'erlang':'or'(call 'erlang':'=:='(_c, 70), call 'erlang':'or'(call 'erlang':'=:='(_c, 69), call 'erlang':'=:='(_c, 71)))
	      in let <_body> =
		     case _e11 of
		       <2047> when 'true' ->
			   let <_word> = case _m of
					  <0> when 'true' -> #{#<105>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']]),#<102>(8,1,'integer',['unsigned'|['big']])}#
					  <_other> when 'true' -> #{#<110>(8,1,'integer',['unsigned'|['big']]),#<97>(8,1,'integer',['unsigned'|['big']]),#<110>(8,1,'integer',['unsigned'|['big']])}#
					end
			   in case _upper of
				<'true'> when 'true' -> call 'string':'uppercase'(_word)
				<'false'> when 'true' -> _word
			      end
		       <_e> when 'true' ->
			   let <_pe> = case _e of
					<0> when 'true' -> 1074
					<_other> when 'true' -> call 'erlang':'-'(1075, _e)
				      end
			   in apply 'emo_float_conv'/5 (_c, _f, _m, _pe, _p)
		     end
	      in let <_out> = apply 'emo_pad'/4 (_f, _w, _sign, _body)
	      in apply 'emo_printf_walk'/3 (_rest, _a2, [_out | _acc])
		end
	  <[_v | _a2]> when 'true' ->
	      call 'erlang':'error'({'emo_printf_wrong', _c, apply 'emo_printf_kind'/1 (_v)})
	end

%% %f and %g keep six digits as C's defaults do; %e keeps six after the
%%   point. A negative `*` precision reads as omitted.
'emo_float_conv'/5 =
    fun (_c, _f, _m, _pe, _p) ->
	let <_prec> =
		case _p of
		  <{'value', _n}> when 'true' -> _n
		  <{'omit'}> when 'true' -> 'default'
		  <{'none'}> when 'true' -> 'default'
		end
	in case _c of
	     <102> when 'true' ->
		 apply 'emo_float_fixed'/4 (_m, _pe, apply 'emo_f_prec'/1 (_prec), call 'erlang':'element'(4, _f))
	     <70> when 'true' ->
		 apply 'emo_float_fixed'/4 (_m, _pe, apply 'emo_f_prec'/1 (_prec), call 'erlang':'element'(4, _f))
	     <101> when 'true' ->
		 let <_d> = apply 'emo_e_digits'/1 (_prec)
		 in case apply 'emo_float_sig'/3 (_m, _pe, _d) of
		      <{_q, _x}> when 'true' ->
			  apply 'emo_float_sci'/6 (_q, call 'erlang':'-'(_d, 1), _x, 'false', call 'erlang':'element'(4, _f), 'false')
		    end
	     <69> when 'true' ->
		 let <_d> = apply 'emo_e_digits'/1 (_prec)
		 in case apply 'emo_float_sig'/3 (_m, _pe, _d) of
		      <{_q, _x}> when 'true' ->
			  apply 'emo_float_sci'/6 (_q, call 'erlang':'-'(_d, 1), _x, 'true', call 'erlang':'element'(4, _f), 'false')
		    end
	     <103> when 'true' ->
		 apply 'emo_float_g'/5 (_m, _pe, apply 'emo_g_prec'/1 (_prec), 'false', call 'erlang':'element'(4, _f))
	     <71> when 'true' ->
		 apply 'emo_float_g'/5 (_m, _pe, apply 'emo_g_prec'/1 (_prec), 'true', call 'erlang':'element'(4, _f))
	   end

'emo_f_prec'/1 =
    fun (_prec) ->
	case _prec of
	  <'default'> when 'true' -> 6
	  <_n> when 'true' -> _n
	end

'emo_e_digits'/1 =
    fun (_prec) ->
	case _prec of
	  <'default'> when 'true' -> 7
	  <_n> when 'true' -> call 'erlang':'+'(_n, 1)
	end

'emo_g_prec'/1 =
    fun (_prec) ->
	case _prec of
	  <'default'> when 'true' -> 6
	  <0> when 'true' -> 1
	  <_n> when 'true' -> _n
	end

%% %f: value × 10^prec rounded to an integer, then the point goes back
%%   in `prec` digits from the right.
'emo_float_fixed'/4 =
    fun (_m, _pe, _prec, _hash) ->
	let <_num> = call 'erlang':'*'(_m, apply 'emo_pow10'/1 (_prec))
	in let <_den> = apply 'emo_pow2'/1 (_pe)
	in let <_q> = case _pe of
			<0> when 'true' -> _num
			<_other> when 'true' ->
			    apply 'emo_round'/3 (call 'erlang':'div'(_num, _den), call 'erlang':'rem'(_num, _den), _den)
		      end
	   in let <_s> = apply 'emo_zeropad'/2 (call 'erlang':'integer_to_binary'(_q), call 'erlang':'+'(_prec, 1))
	   in case call 'erlang':'<'(_prec, 1) of
		<'true'> when 'true' ->
		    case _hash of
		      <'true'> when 'true' -> call 'erlang':'iolist_to_binary'([_s, #{#<46>(8,1,'integer',['unsigned'|['big']])}#])
		      <'false'> when 'true' -> _s
		    end
		<'false'> when 'true' ->
		    let <_cut> = call 'erlang':'-'(call 'erlang':'byte_size'(_s), _prec)
		    in call 'erlang':'iolist_to_binary'([call 'binary':'part'(_s, 0, _cut), #{#<46>(8,1,'integer',['unsigned'|['big']])}#, call 'binary':'part'(_s, _cut, _prec)])
	      end

%% The (Q, X) significant-digit form: value ≈ Q × 10^(X − D + 1), Q
%%   carrying D digits, correctly rounded; the exponent adjusts up when
%%   the rounding bumps the leading digit.
'emo_float_sig'/3 =
    fun (_m, _pe, _d) ->
	case _m of
	  <0> when 'true' -> {0, 0}
	  <_other> when 'true' ->
	      let <_est> = call 'erlang':'trunc'(call 'erlang':'-'(call 'math':'log10'(call 'erlang':'float'(_m)), call 'erlang':'*'(0.3010299956639812, call 'erlang':'float'(_pe))))
	      in let <_x1> = apply 'emo_x_down'/3 (_m, _pe, _est)
	      in let <_x> = apply 'emo_x_up'/3 (_m, _pe, _x1)
	      in let <_shift> = call 'erlang':'-'(call 'erlang':'-'(_d, 1), _x)
	      in case call 'erlang':'=<'(0, _shift) of
		   <'true'> when 'true' ->
		       apply 'emo_sig_round'/4 (call 'erlang':'*'(_m, apply 'emo_pow10'/1 (_shift)), apply 'emo_pow2'/1 (_pe), _d, _x)
		   <'false'> when 'true' ->
		       apply 'emo_sig_round'/4 (_m, call 'erlang':'*' (apply 'emo_pow2'/1 (_pe), apply 'emo_pow10'/1 (call 'erlang':'abs'(_shift))), _d, _x)
		 end
	end

%% The rounding tail of 'emo_float_sig': Q from Num/Den, then the
%%   leading-digit bump.
'emo_sig_round'/4 =
    fun (_num, _den, _d, _x) ->
	let <_q> = apply 'emo_round'/3 (call 'erlang':'div'(_num, _den), call 'erlang':'rem'(_num, _den), _den)
	in case call 'erlang':'=<'(apply 'emo_pow10'/1 (_d), _q) of
	     <'true'> when 'true' -> {apply 'emo_pow10'/1 (call 'erlang':'-'(_d, 1)), call 'erlang':'+'(_x, 1)}
	     <'false'> when 'true' -> {_q, _x}
	   end

'emo_x_down'/3 =
    fun (_m, _pe, _x) ->
	case apply 'emo_cmp_pow10'/3 (_m, _pe, _x) of
	  <_r> when call 'erlang':'<'(_r, 0) -> apply 'emo_x_down'/3 (_m, _pe, call 'erlang':'-'(_x, 1))
	  <_r> when 'true' -> _x
	end

'emo_x_up'/3 =
    fun (_m, _pe, _x) ->
	case apply 'emo_cmp_pow10'/3 (_m, _pe, call 'erlang':'+'(_x, 1)) of
	  <_r> when call 'erlang':'=<'(0, _r) -> apply 'emo_x_up'/3 (_m, _pe, call 'erlang':'+'(_x, 1))
	  <_r> when 'true' -> _x
	end

%% sign(M / 2^pe − 10^x), exact: cross-multiplied into integers.
'emo_cmp_pow10'/3 =
    fun (_m, _pe, _x) ->
	let <_lnum> = _m
	in let <_lden> = apply 'emo_pow2'/1 (_pe)
	in case call 'erlang':'=<'(0, _x) of
	     <'true'> when 'true' ->
		 apply 'emo_cmp_tail'/4 (_lnum, _lden, apply 'emo_pow10'/1 (_x), 1)
	     <'false'> when 'true' ->
		 apply 'emo_cmp_tail'/4 (_lnum, _lden, 1, apply 'emo_pow10'/1 (call 'erlang':'abs'(_x)))
	   end

'emo_cmp_tail'/4 =
    fun (_lnum, _lden, _rnum, _rden) ->
	let <_l> = call 'erlang':'*'(_lnum, _rden)
	in let <_r> = call 'erlang':'*'(_rnum, _lden)
	in case call 'erlang':'<'(_l, _r) of
	     <'true'> when 'true' -> -1
	     <'false'> when 'true' ->
		 case call 'erlang':'=:='(_l, _r) of
		   <'true'> when 'true' -> 0
		   <'false'> when 'true' -> 1
		 end
	   end

%% %g: P significant digits, style f when the rounded exponent sits in
%%   [-4, P), style e otherwise; trailing zeros go unless '#'.
'emo_float_g'/5 =
    fun (_m, _pe, _p, _upper, _hash) ->
	case _m of
	  <0> when 'true' ->
	      case _hash of
		<'true'> when 'true' ->
		    case call 'erlang':'>'(_p, 1) of
		      <'true'> when 'true' ->
			  call 'erlang':'iolist_to_binary'([#{#<48>(8,1,'integer',['unsigned'|['big']]),#<46>(8,1,'integer',['unsigned'|['big']])}#, call 'binary':'copy'(#{#<48>(8,1,'integer',['unsigned'|['big']])}#, call 'erlang':'-'(_p, 1))])
		      <'false'> when 'true' -> #{#<48>(8,1,'integer',['unsigned'|['big']]),#<46>(8,1,'integer',['unsigned'|['big']])}#
		    end
		<'false'> when 'true' -> #{#<48>(8,1,'integer',['unsigned'|['big']])}#
	      end
	  <_other> when 'true' ->
	      case apply 'emo_float_sig'/3 (_m, _pe, _p) of
		<{_q, _x}> when 'true' ->
		    case call 'erlang':'and'(call 'erlang':'=<'(-4, _x), call 'erlang':'<'(_x, _p)) of
		      <'true'> when 'true' ->
			  apply 'emo_g_fixed'/4 (_q, _p, _x, _hash)
		      <'false'> when 'true' ->
			  apply 'emo_float_sci'/6 (_q, call 'erlang':'-'(_p, 1), _x, _upper, _hash, call 'erlang':'not'(_hash))
		    end
	      end
	end

%% The f style of %g, built straight from the (Q, X) digits.
'emo_g_fixed'/4 =
    fun (_q, _p, _x, _hash) ->
	let <_s> = apply 'emo_zeropad'/2 (call 'erlang':'integer_to_binary'(_q), _p)
	in let <_body> =
	       case call 'erlang':'<'(_x, 0) of
		 <'true'> when 'true' ->
		     call 'erlang':'iolist_to_binary'([#{#<48>(8,1,'integer',['unsigned'|['big']]),#<46>(8,1,'integer',['unsigned'|['big']])}#, call 'binary':'copy'(#{#<48>(8,1,'integer',['unsigned'|['big']])}#, call 'erlang':'abs'(call 'erlang':'+'(_x, 1))), _s])
		 <'false'> when 'true' ->
		     case call 'erlang':'=<'(_p, call 'erlang':'+'(_x, 1)) of
		       <'true'> when 'true' ->
			   call 'erlang':'iolist_to_binary'([_s, call 'binary':'copy'(#{#<48>(8,1,'integer',['unsigned'|['big']])}#, call 'erlang':'-'(call 'erlang':'+'(_x, 1), _p))])
		       <'false'> when 'true' ->
			   let <_cut> = call 'erlang':'+'(_x, 1)
			   in call 'erlang':'iolist_to_binary'([call 'binary':'part'(_s, 0, _cut), #{#<46>(8,1,'integer',['unsigned'|['big']])}#, call 'binary':'part'(_s, _cut, call 'erlang':'-'(_p, _cut))])
		     end
	       end
	in case _hash of
	     <'true'> when 'true' -> _body
	     <'false'> when 'true' ->
		 let <_t> = call 'string':'trim'(_body, 'trailing', [48])
		 in case call 'binary':'last'(_t) of
		      <46> when 'true' ->
			  call 'binary':'part'(_t, 0, call 'erlang':'-'(call 'erlang':'byte_size'(_t), 1))
		      <_c> when 'true' -> _t
		    end
	   end

%% d.ddd…e±XX from a (Q, X) rendering with Frac fraction digits;
%%   Strip removes trailing zeros (the %g rule), '#' keeps a bare point
%%   when no fraction digits remain.
'emo_float_sci'/6 =
    fun (_q, _frac, _x, _upper, _hash, _strip) ->
	let <_s> = apply 'emo_zeropad'/2 (call 'erlang':'integer_to_binary'(_q), call 'erlang':'+'(_frac, 1))
	in let <_raw> = case call 'erlang':'<'(0, _frac) of
			  <'true'> when 'true' ->
			      call 'binary':'part'(_s, 1, _frac)
			  <'false'> when 'true' -> #{}#
			end
	in let <_t> = case _strip of
			<'true'> when 'true' -> call 'string':'trim'(_raw, 'trailing', [48])
			<'false'> when 'true' -> _raw
		      end
	in let <_fracb> =
	       case call 'erlang':'byte_size'(_t) of
		 <0> when 'true' ->
		     case _hash of
		       <'true'> when 'true' -> #{#<46>(8,1,'integer',['unsigned'|['big']])}#
		       <'false'> when 'true' -> #{}#
		     end
		 <_n> when 'true' -> call 'erlang':'iolist_to_binary'([#{#<46>(8,1,'integer',['unsigned'|['big']])}#, _t])
	       end
	in let <_e> = case _upper of
			<'true'> when 'true' -> #{#<69>(8,1,'integer',['unsigned'|['big']])}#
			<'false'> when 'true' -> #{#<101>(8,1,'integer',['unsigned'|['big']])}#
		      end
	in let <_esign> = case call 'erlang':'<'(_x, 0) of
			    <'true'> when 'true' -> #{#<45>(8,1,'integer',['unsigned'|['big']])}#
			    <'false'> when 'true' -> #{#<43>(8,1,'integer',['unsigned'|['big']])}#
			  end
	in let <_abs> = call 'erlang':'abs'(_x)
	in let <_expb> =
	       case call 'erlang':'<'(_abs, 10) of
		 <'true'> when 'true' ->
		     call 'erlang':'iolist_to_binary'([_esign, 48, call 'erlang':'integer_to_binary'(_abs)])
		 <'false'> when 'true' ->
		     call 'erlang':'iolist_to_binary'([_esign, call 'erlang':'integer_to_binary'(_abs)])
	       end
	in call 'erlang':'iolist_to_binary'([call 'binary':'part'(_s, 0, 1), _fracb, _e, _expb])

%% The IEEE words: (S, E11, M52) of one double, big-endian bytes folded
%%   into an integer — no binary pattern matching in the emitted core.
'emo_float_parts'/1 =
    fun (_f) ->
	let <_b> = #{#<_f>(64,1,'float',['unsigned'|['big']])}#
	in apply 'emo_float_bits'/3 (_b, 0, 0)

'emo_float_bits'/3 =
    fun (_b, _i, _acc) ->
	case _i of
	  <8> when 'true' ->
	      let <_s> = call 'erlang':'div'(_acc, 9223372036854775808)
	      in let <_e> = call 'erlang':'band'(call 'erlang':'div'(_acc, 4503599627370496), 2047)
	      in case _e of
		   <0> when 'true' -> {_s, 0, call 'erlang':'band'(_acc, 4503599627370495)}
		   <_e> when 'true' ->
		       {_s, _e, call 'erlang':'+'(call 'erlang':'band'(_acc, 4503599627370495), 4503599627370496)}
		 end
	  <_i> when 'true' ->
	      apply 'emo_float_bits'/3 (_b, call 'erlang':'+'(_i, 1), call 'erlang':'+'(call 'erlang':'*'(_acc, 256), call 'binary':'at'(_b, _i)))
	end

%% Round Q + R/Den to nearest, ties to even.
'emo_round'/3 =
    fun (_q, _r, _den) ->
	let <_t> = call 'erlang':'*'(_r, 2)
	in case call 'erlang':'<'(_den, _t) of
	     <'true'> when 'true' -> call 'erlang':'+'(_q, 1)
	     <'false'> when 'true' ->
		 case call 'erlang':'=:='(_t, _den) of
		   <'true'> when 'true' -> call 'erlang':'+'(_q, call 'erlang':'band'(_q, 1))
		   <'false'> when 'true' -> _q
		 end
	   end

'emo_pow10'/1 =
    fun (_n) ->
	case _n of
	  <0> when 'true' -> 1
	  <_n> when 'true' -> call 'erlang':'*' (10, apply 'emo_pow10'/1 (call 'erlang':'-'(_n, 1)))
	end

'emo_pow2'/1 =
    fun (_n) ->
	case _n of
	  <0> when 'true' -> 1
	  <_n> when 'true' -> call 'erlang':'*' (2, apply 'emo_pow2'/1 (call 'erlang':'-'(_n, 1)))
	end

%% Left-pad a digit binary to at least Len digits with zeros.
'emo_zeropad'/2 =
    fun (_s, _len) ->
	case call 'erlang':'=<'(_len, call 'erlang':'byte_size'(_s)) of
	  <'true'> when 'true' -> _s
	  <'false'> when 'true' ->
	      call 'erlang':'iolist_to_binary'([call 'binary':'copy'(#{#<48>(8,1,'integer',['unsigned'|['big']])}#, call 'erlang':'-'(_len, call 'erlang':'byte_size'(_s))), _s])
	end

|}

(* ---- Module assembly ----

   One BEAM module per program (the wasm target's single-artifact
   design): every def lands in 'emo_main' under its mangled name, and
   'main'/0 runs the entry statements. *)

let emit (program : Emo_ir.program) : string =
  let buf = Buffer.create (16 * 1024) in
  let env =
    {
      buf;
      fresh = 0;
      local_map = [];
      funcs = [];
      fname = "";
      classes = [];
      class_field = [];
      iface_classes = [];
      current_class = None;
    }
  in
  let class_fields_assoc =
    List.map
      (fun (c : Emo_ir.class_) ->
        (c.Emo_ir.cname, List.mapi (fun i n -> (n, i)) (class_fields c)))
      program.Emo_ir.pclasses
  in
  env.class_field <- class_fields_assoc;
  (* interface -> the classes that structurally satisfy it *)
  let sanitize = Emo_ir.sanitize_ident in
  env.iface_classes <-
    List.map
      (fun (iname, meths) ->
        ( iname,
          List.filter_map
            (fun (c : Emo_ir.class_) ->
              let conforms =
                List.for_all
                  (fun (mname, arity) ->
                    List.exists
                      (fun (m : Emo_ir.func) ->
                        String.equal (member_name c m) (sanitize mname)
                        && List.length m.Emo_ir.fparams - 1 = arity)
                      c.Emo_ir.cmethods)
                  meths
              in
              if conforms then Some c.Emo_ir.cname else None)
            program.Emo_ir.pclasses ))
      program.Emo_ir.pinterfaces;
  env.classes <- program.Emo_ir.pclasses;
  env.funcs <-
    List.map
      (fun (f : Emo_ir.func) -> (f.Emo_ir.fname, List.length f.Emo_ir.fparams))
      program.Emo_ir.pfuncs
    @ List.concat_map
        (fun (c : Emo_ir.class_) ->
          List.map
            (fun (m : Emo_ir.func) ->
              (m.Emo_ir.fname, List.length m.Emo_ir.fparams))
            c.Emo_ir.cmethods
          @ [ (c.Emo_ir.cname ^ "__new", List.length (class_fields c)) ])
        program.Emo_ir.pclasses;
  put env "module 'emo_main' ['main'/0]\n";
  put env "    attributes []\n";
  put env rt_source;
  (* a def emitter shared by program functions and class methods *)
  let emit_def ~(cc : string option) ~(params : (string * string) list)
      ~(fname : string) ~(body : Emo_ir.stmt list) : unit =
    let name = Emo_ir.sanitize_ident fname in
    put env (Printf.sprintf "'%s'/%d =\n" name (List.length params));
    put env "    fun (";
    put env (String.concat ", " (List.map snd params));
    put env ") ->\n";
    env.local_map <- params;
    env.fname <- fname;
    env.current_class <- cc;
    let before = Buffer.length buf in
    stmts env body;
    let body_text = Buffer.sub buf before (Buffer.length buf - before) in
    Buffer.truncate buf before;
    put env (body_wrapper body_text);
    put env "\n\n";
    env.local_map <- [];
    env.current_class <- None
  in
  List.iter
    (fun (c : Emo_ir.class_) ->
      let fields = class_fields c in
      let init_params =
        match c.Emo_ir.cinit with
        | Some init -> (
            match init.Emo_ir.fparams with _ :: rest -> rest | [] -> [])
        | None -> []
      in
      let factory_params =
        List.mapi
          (fun i (pname, _) -> (pname, Printf.sprintf "_p%d" i))
          init_params
      in
      let undefineds =
        match fields with
        | [] -> ""
        | _ ->
            ", " ^ String.concat ", " (List.map (fun _ -> "'undefined'") fields)
      in
      (* the factory: fresh instance tuple, init's body with self
         bound, then the instance *)
      let name = Emo_ir.sanitize_ident (c.Emo_ir.cname ^ "__new") in
      put env (Printf.sprintf "'%s'/%d =\n" name (List.length factory_params));
      put env "    fun (";
      put env (String.concat ", " (List.map snd factory_params));
      put env ") ->\n";
      env.local_map <- factory_params;
      env.fname <- c.Emo_ir.cname ^ "__new";
      env.current_class <- Some c.Emo_ir.cname;
      let self_v = fresh_var env "self" in
      put env ("let <" ^ self_v ^ "> =\n");
      put env
        (Printf.sprintf "    {'emo_inst', %s%s}\nin " (atom c.Emo_ir.cname)
           undefineds);
      env.local_map <- ("self", self_v) :: env.local_map;
      let before = Buffer.length buf in
      (match c.Emo_ir.cinit with
      | Some init -> stmts env init.Emo_ir.fbody
      | None -> put env self_v);
      let body_text = Buffer.sub buf before (Buffer.length buf - before) in
      Buffer.truncate buf before;
      put env (body_wrapper body_text);
      put env "\n\n";
      env.local_map <- [];
      env.current_class <- None;
      List.iter
        (fun (m : Emo_ir.func) ->
          emit_def ~cc:(Some c.Emo_ir.cname)
            ~params:
              (List.mapi
                 (fun i (pname, _) -> (pname, Printf.sprintf "_p%d" i))
                 m.Emo_ir.fparams)
            ~fname:m.Emo_ir.fname ~body:m.Emo_ir.fbody)
        c.Emo_ir.cmethods)
    program.Emo_ir.pclasses;
  List.iter
    (fun (f : Emo_ir.func) ->
      emit_def ~cc:None
        ~params:
          (List.mapi
             (fun i (pname, _) -> (pname, Printf.sprintf "_p%d" i))
             f.Emo_ir.fparams)
        ~fname:f.Emo_ir.fname ~body:f.Emo_ir.fbody)
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
