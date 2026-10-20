(* The BEAM target: emit Core Erlang text for `erlc` to assemble.

   The grammar facts this emitter relies on were probed against the
   pinned OTP 29 reader (plan/step-18-beam.md): every atom quoted, `do`
   sequences exactly two expressions with no comma and no end, fun
   bodies are one expression with no end, and binary literals are
   per-segment `#{...}#`. *)

type env = {
  buf : Buffer.t;
  module_name : string;
      (* The module atom, which erlc requires to equal the .core file's
         stem; the CLI derives it from the requested output *)
  loops_buf : Buffer.t;
      (* loop functions, emitted at module scope after main: a loop is
         a tail-recursive local function, discovered while bodies emit *)
  mutable fresh : int;
  mutable local_map : (string * string) list;
  mutable funcs : (string * int) list;
  mutable fname : string;
  mutable loops : (string * string list * Emo_ir.stmt option) list;
      (* each enclosing loop's (function atom, threaded Emo variable
         names — the header first on a `for` —, post clause), innermost
         first: break/continue call the function with the current
         values and a done flag *)
  mutable classes : Emo_ir.class_ list;
  mutable iface_classes : (string * string list) list;
  mutable class_field : (string * (string * int) list) list;
  mutable current_class : string option;
  mutable fforeigns : string list;
      (* `foreign def` names: the binding is skipped, a call refuses *)
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

(* The emitter's own statement-local scratch names. Their `let`s
   close within the statement that mints them, so they never thread
   through loop functions or continuations — only real source
   bindings do. *)
let beam_temps =
  [ "__recv"; "__thread"; "_spawnarg"; "_spawnpid"; "_spawnself"; "case" ]

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
  | Emo_ir.Global_var _ ->
      raise
        (Emo_ir.Lower_error
           "the beam target does not support module-level `var` yet")
  | Var name -> (
      match List.assoc_opt name env.local_map with
      | Some v -> put env v
      | None -> failwith ("beam: unbound local " ^ name ^ " in " ^ env.fname))
  | Global name -> (
      if List.mem name env.fforeigns then
        raise
          (Emo_ir.Lower_error
             (Printf.sprintf
                "the beam target does not support taking the value of the \
                 foreign definition `%s`"
                name));
      (* A first-class def: a local closure over its function. The whole
         program lowers into one BEAM module and a def is not exported,
         so `fun 'mod':'name'/a` names a function the module does not
         export — erlc accepts it, but loading leaves every function
         uncallable (`undef`), so a bare def passed as a `Block` ran
         nowhere on this target. A lambda that applies the plain local
         function is always callable. *)
      match List.assoc_opt name env.funcs with
      | Some a ->
          let vs =
            List.init a (fun _ ->
                env.fresh <- env.fresh + 1;
                Printf.sprintf "_blk%d" env.fresh)
          in
          let args = String.concat ", " vs in
          put env
            (Printf.sprintf "fun (%s) -> apply '%s'/%d (%s)" args
               (Emo_ir.sanitize_ident name)
               a args)
      | None -> failwith ("beam: unbound global " ^ name))
  | Call { func; args } -> (
      if List.mem func env.fforeigns then
        raise
          (Emo_ir.Lower_error
             (Printf.sprintf
                "the beam target does not support a call to the foreign \
                 definition `%s`"
                func));
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
  | Map_lit pairs ->
      (* the pairs lower as Erlang 2-tuples in the literal's order —
         the insertion order emo_map_new records *)
      put env "apply 'emo_map_new'/1 ([";
      List.iteri
        (fun i e ->
          if i > 0 then put env ", ";
          expr env e)
        pairs;
      put env "])"
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
      (* a Box is a process-dictionary key (T18.4 upgrades to a
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
  | Builder_new -> put env "apply 'emo_builder_new'/0 ()"
  | Method { self_; name; args } -> method_call env self_ name args
  | Do_spawn { func; args } -> (
      (* the arguments evaluate in the spawner; the fun closes over
         them lexically. The wrapper turns a `halt` into a clean
         process end. *)
      if List.mem func env.fforeigns then
        raise
          (Emo_ir.Lower_error
             (Printf.sprintf
                "the beam target does not support a call to the foreign \
                 definition `%s`"
                func));
      match List.assoc_opt func env.funcs with
      | Some a ->
          let arg_locals = List.map (fun _ -> fresh_var env "_spawnarg") args in
          List.iter2
            (fun arg l ->
              put env ("let <" ^ l ^ "> =\n");
              expr env arg;
              put env "\nin ")
            args arg_locals;
          spawn_registered env
            (Printf.sprintf "apply '%s'/%d (%s)"
               (Emo_ir.sanitize_ident func)
               a
               (String.concat ", " arg_locals))
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
      spawn_registered env
        (Printf.sprintf "apply %s (%s)" f_code (String.concat ", " arg_locals))
  | Builtin { name; args } -> builtin env name args
  | Runtime_impl { name; _ } ->
      raise
        (Emo_ir.Lower_error
           ("beam: the runtime implementation `" ^ name
          ^ "` is not available yet (T18.1)"))
  | Make_exception { message; data } ->
      (* Exception.new's object is its message, and the construction
         never returns — the throw happens right here, so a Raise
         wrapping this never reaches its own wrapper. The data, when
         present, lowers like any expression — a Map literal goes
         through emo_map_new — and rides the throw tuple. *)
      put env "call 'erlang':'throw'({'emo_raise', ";
      expr env message;
      Option.iter
        (fun d ->
          put env ", ";
          expr env d)
        data;
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
  | "get", [ i ] ->
      (* `get` names the Bytes accessor, the Builder accessor, Map's
         lookup, and a class method (the format packages' object types,
         say). The interpreter checks the receiver's class first, so
         dispatch at runtime: a Bytes, Builder, or Map receiver takes
         its builtin and every instance takes its class's method. When
         no class defines `get`, the builtins are the whole call. *)
      let candidates =
        List.filter_map
          (fun (c : Emo_ir.class_) ->
            if
              List.exists
                (fun (m : Emo_ir.func) ->
                  String.equal (member_name c m) mangled
                  && List.length m.Emo_ir.fparams - 1 = 1)
                c.Emo_ir.cmethods
            then Some c.Emo_ir.cname
            else None)
          env.classes
      in
      let recv = fresh_var env "__recv" in
      put env ("let <" ^ recv ^ "> =\n");
      expr env self_;
      put env ("\nin case " ^ recv ^ " of\n");
      List.iter
        (fun cname ->
          put env
            (Printf.sprintf "  <%s> when 'true' ->\n    apply '%s'/2 ("
               (instance_pattern env.classes cname)
               (Emo_ir.sanitize_ident (cname ^ "__" ^ mangled)));
          put env recv;
          put env ", ";
          expr env i;
          put env ")\n")
        candidates;
      put env
        (Printf.sprintf
           "  <{'emo_builder', _k}> when 'true' ->\n\
           \    apply 'emo_builder_get'/2 (%s, "
           recv);
      expr env i;
      put env ")\n";
      put env
        (Printf.sprintf
           "  <{'emo_map', _k}> when 'true' ->\n    apply 'emo_map_get'/2 (%s, "
           recv);
      expr env i;
      put env ")\n";
      put env "  <_> when 'true' ->\n    apply 'emo_bytes_get'/2 (";
      put env recv;
      put env ", ";
      expr env i;
      put env ")\nend"
  | "set", [ k; v ] ->
      (* `set` names both the Bytes writer and Map's insert; the tag
         picks at run time *)
      let recv = fresh_var env "__recv" in
      put env ("let <" ^ recv ^ "> =\n");
      expr env self_;
      put env ("\nin case " ^ recv ^ " of\n");
      put env
        "  <{'emo_bytes', _k}> when 'true' ->\n    apply 'emo_bytes_set'/3 (";
      put env recv;
      put env ", ";
      expr env k;
      put env ", ";
      expr env v;
      put env ")\n";
      put env "  <{'emo_map', _k}> when 'true' ->\n    apply 'emo_map_set'/3 (";
      put env recv;
      put env ", ";
      expr env k;
      put env ", ";
      expr env v;
      put env ")\nend"
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
  | "has", [ _ ] -> bytes_only 2 "emo_map_has"
  | "remove", [ _ ] -> bytes_only 2 "emo_map_remove"
  | "keys", [] -> bytes_only 1 "emo_map_keys"
  | "values", [] -> bytes_only 1 "emo_map_values"
  | "push", [ _ ] -> bytes_only 2 "emo_builder_push"
  | "to_array", [] -> bytes_only 1 "emo_builder_to_array"
  | "length", [] ->
      (* Instances answer their own `length` first — the interpreter's
         rule; the builtin length answers only when no class carries the
         name. The receiver is bound once, so a chained, side-effecting
         receiver is not re-evaluated. *)
      let recv = fresh_var env "__recv" in
      put env ("let <" ^ recv ^ "> =\n");
      expr env self_;
      put env ("\nin case " ^ recv ^ " of\n");
      let method_arms =
        List.filter_map
          (fun (c : Emo_ir.class_) ->
            if
              List.exists
                (fun (m : Emo_ir.func) ->
                  String.equal (member_name c m) "length"
                  && List.length m.Emo_ir.fparams - 1 = 0)
                c.Emo_ir.cmethods
            then
              Some
                (Printf.sprintf "  <%s> when 'true' ->\n    apply '%s'/1 (%s)\n"
                   (instance_pattern env.classes c.Emo_ir.cname)
                   (Emo_ir.sanitize_ident (c.Emo_ir.cname ^ "__length"))
                   recv)
            else None)
          env.classes
      in
      put env (String.concat "" method_arms);
      put env
        (Printf.sprintf
           "  <{'emo_bytes', _k}> when 'true' ->\n\
           \    apply 'emo_bytes_len'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <{'emo_list', _k}> when 'true' ->\n\
           \    apply 'emo_list_len'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <{'emo_map', _k}> when 'true' ->\n\
           \    apply 'emo_map_length'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <{'emo_builder', _k}> when 'true' ->\n\
           \    apply 'emo_builder_len'/1 (%s)\n"
           recv);
      put env
        "  <_str> when call 'erlang':'is_binary'(_str) ->\n\
        \    call 'erlang':'byte_size'(_str)\n";
      put env
        (Printf.sprintf
           "  <_> when 'true' ->\n    call 'erlang':'length'(%s)\nend" recv)
  | "to_string", [] ->
      (* Instances answer their own `to_string` first — the interpreter's
         rule; the builtin conversion answers only when no class carries
         the name. The receiver is bound once, so a chained,
         side-effecting receiver is not re-evaluated. *)
      let recv = fresh_var env "__recv" in
      put env ("let <" ^ recv ^ "> =\n");
      expr env self_;
      put env ("\nin case " ^ recv ^ " of\n");
      let method_arms =
        List.filter_map
          (fun (c : Emo_ir.class_) ->
            if
              List.exists
                (fun (m : Emo_ir.func) ->
                  String.equal (member_name c m) "to_string"
                  && List.length m.Emo_ir.fparams - 1 = 0)
                c.Emo_ir.cmethods
            then
              Some
                (Printf.sprintf "  <%s> when 'true' ->\n    apply '%s'/1 (%s)\n"
                   (instance_pattern env.classes c.Emo_ir.cname)
                   (Emo_ir.sanitize_ident (c.Emo_ir.cname ^ "__to_string"))
                   recv)
            else None)
          env.classes
      in
      put env (String.concat "" method_arms);
      put env
        (Printf.sprintf
           "  <{'emo_bytes', _k}> when 'true' ->\n\
           \    apply 'emo_bytes_to_str'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <{'emo_list', _k}> when 'true' ->\n\
           \    apply 'emo_list_to_str'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <{'emo_map', _k}> when 'true' ->\n\
           \    apply 'emo_map_str'/1 (%s)\n"
           recv);
      put env
        (Printf.sprintf
           "  <_> when 'true' ->\n    apply 'emo_to_str'/1 (%s)\nend" recv)
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
  | (("sqrt" | "floor" | "ceil") as mname), [] ->
      put env (Printf.sprintf "call 'math':'%s'(" mname);
      expr env self_;
      put env ")"
  | "trunc", [] ->
      (* the BIF answers an integer; the method answers a Float64 *)
      put env "call 'erlang':'float'(call 'erlang':'trunc'(";
      expr env self_;
      put env "))"
  | "to_float64", [] ->
      put env "call 'erlang':'float'(";
      expr env self_;
      put env ")"
  | "to_int64", [] when self_.Emo_ir.ety = Emo_check.Float64 ->
      put env "call 'erlang':'trunc'(";
      expr env self_;
      put env ")"
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
      | "substring", [ start; len ] ->
          put env "apply 'emo_str_substring'/3 ";
          args_list env [ self_; start; len ]
      | "starts_with", [ prefix ] ->
          put env "apply 'emo_str_starts_with'/2 ";
          args_list env [ self_; prefix ]
      | "split", [ sep ] ->
          put env "apply 'emo_str_split'/2 ";
          args_list env [ self_; sep ]
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
              (* Bind the receiver once: the arms below pass it, and
                 re-emitting it would run a side-effecting receiver (a
                 chained call, say) twice. *)
              let recv = fresh_var env "__recv" in
              put env ("let <" ^ recv ^ "> =\n");
              expr env self_;
              put env ("\nin case " ^ recv ^ " of\n");
              List.iter
                (fun cname ->
                  let full = cname ^ "__" ^ mangled in
                  let arity = List.length args + 1 in
                  put env
                    (Printf.sprintf "  <%s> when 'true' ->\n    apply '%s'/%d ("
                       (instance_pattern env.classes cname)
                       (Emo_ir.sanitize_ident full)
                       arity);
                  put env recv;
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
           ("beam: builtin `" ^ name ^ "` is not available yet (T18.1)"))

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

(* A `do` spawns [call_text] and the child records itself in the root's
   table, so 'main'/0 can kill whatever is still alive when it ends. The
   child removes itself on the way out, so the table holds exactly the
   children still running. The expression's value is the pid. *)
and spawn_registered env (call_text : string) : unit =
  let pid = fresh_var env "_spawnpid" in
  let self = fresh_var env "_spawnself" in
  put env (Printf.sprintf "let <%s> =\n" pid);
  put env "call 'erlang':'spawn'(fun () -> ";
  let saved = env.local_map in
  env.local_map <- [];
  put env (Printf.sprintf "let <%s> = call 'erlang':'self'()\nin " self);
  put env (Printf.sprintf "do apply 'emo_spawn_reg'/1 (%s) " self);
  put env
    (body_wrapper ~halt:true
       ~on_exit:(Printf.sprintf "apply 'emo_unreg'/1 (%s)" self)
       call_text);
  env.local_map <- saved;
  put env ")";
  put env (Printf.sprintf "\nin %s" pid)

(* Every function/closure body runs under this wrapper: a `return`
   anywhere in the body throws the tagged result and the wrapper
   unwraps it as the function's value. A process wrapper also swallows
   `halt`: the spawned fun returns and the process ends. [on_exit] is
   the entry's: Core Erlang has no `after`, so the root process ending —
   by return, `halt`, or an uncaught raise — runs it on both ways out,
   killing every child that is still alive. *)
and body_wrapper ?(halt : bool = false) ?(on_exit : string = "") (body : string)
    : string =
  let halt_arm =
    if halt then "\n\t  <'emo_halt'> when 'true' -> 'ok'" else ""
  in
  let exit_run = if on_exit = "" then "" else "do " ^ on_exit ^ " " in
  Printf.sprintf
    {json|try
%s
of
    <_r> -> %s_r
catch
    <_C, _T, _S> ->
	%scase _T of
	  <{'emo_return', _rv}> when 'true' -> _rv%s
	  <_other> when 'true' -> call 'erlang':'throw'(_T)
	end|json}
    body exit_run exit_run halt_arm

(* ---- Statements ----

   A statement list becomes a left-nested `do` chain: `do E1 do E2 E3`.
   Core discards intermediate values naturally — no drops. *)

and unique_names (names : string list) : string list =
  let rec go seen acc = function
    | [] -> List.rev acc
    | n :: rest ->
        if List.mem n seen then go seen acc rest
        else go (n :: seen) (n :: acc) rest
  in
  go [] [] names

(* The outer bindings a statement rebinds: an `Assign_var` target, or
   `self` through a field set. A `Let` is a fresh binding and never
   escapes, and a loop's own threading already carries its
   reassignments out. *)
and assigned_names (s : Emo_ir.stmt) : string list =
  match s with
  | Emo_ir.Assign_var { name; _ } -> [ name ]
  | Emo_ir.Set_field _ -> [ "self" ]
  | Emo_ir.If { then_; else_; _ } ->
      assigned_names_list then_ @ assigned_names_list else_
  | Emo_ir.While { body; _ } | Emo_ir.For { body; _ } ->
      assigned_names_list body
  | Emo_ir.Case { branches; _ } | Emo_ir.Receive { branches } ->
      List.concat_map
        (fun (b : Emo_ir.branch) -> assigned_names_list b.Emo_ir.body)
        branches
  | _ -> []

and assigned_names_list (xs : Emo_ir.stmt list) : string list =
  List.concat_map assigned_names xs

and stmts env (xs : Emo_ir.stmt list) : unit =
  match xs with
  | [] -> put env "'ok'"
  | ((Emo_ir.While _ | Emo_ir.For _) as loop) :: rest ->
      (* a loop rebinds its threaded bindings over the rest of the
         chain, so it consumes the rest like a let *)
      emit_loop env ~tail:false loop rest ~leaf:(fun () -> put env "'ok'")
  | [ s ] -> emit_scoped_stmt env s (fun () -> stmt env s)
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
      let call = set_field_call env self_ name value in
      let v = fresh_var env "self" in
      put env ("let <" ^ v ^ "> =\n");
      put env call;
      put env "\nin ";
      stmts env rest
  | ((Emo_ir.If _ | Emo_ir.Case _) as s) :: rest
    when List.exists
           (fun n -> List.mem_assoc n env.local_map)
           (assigned_names s) ->
      (* A branch that rebinds an outer `var` threads the new bindings
         out of the `case`, exactly like a loop: the branches answer a
         tuple of the bindings' final values, and the names rebind from
         it over the rest of the block. *)
      let assigned =
        unique_names
          (List.filter
             (fun n -> List.mem_assoc n env.local_map)
             (assigned_names s))
      in
      let slot = fresh_var env "__thread" in
      put env ("let <" ^ slot ^ "> =\n");
      emit_threaded_control env assigned s;
      put env "\nin ";
      List.iteri
        (fun i name ->
          let v = fresh_var env name in
          put env
            (Printf.sprintf "let <%s> =\n  call 'erlang':'element'(%d, %s)\nin "
               v (i + 1) slot);
          env.local_map <- (name, v) :: env.local_map)
        assigned;
      stmts env rest
  | s :: rest ->
      put env "do\n";
      emit_scoped_stmt env s (fun () -> stmt env s);
      put env "\n";
      stmts env rest

(* An `if`/`case` statement's branch bindings die with their arms: the
   arms' Core lets close inside the `case`, so the names must leave the
   map with them — a later loop lifts with every map entry as a
   threaded parameter, and a dead name would be read at its call site
   after its let has closed. Names that existed before the statement
   stay (a rebinding `if` never reaches here; it threads through the
   assigned-names path above). *)
and emit_scoped_stmt env s k =
  match s with
  | Emo_ir.If _ | Emo_ir.Case _ ->
      let pre = List.map fst env.local_map in
      k ();
      env.local_map <- List.filter (fun (n, _) -> List.mem n pre) env.local_map
  | _ -> k ()

(* A branch body of a threaded `if`/`case`: run it, then answer the
   tuple of the threaded bindings' final values. The branch's own
   bindings are dropped; the caller rebinds the outer names. *)
and emit_threaded_body env (assigned : string list) (body : Emo_ir.stmt list) :
    unit =
  (* The branch body as a tail chain whose fall-through leaf is the
     tuple of final bindings — the same continuation trick the loop
     body uses, so the tuple lands inside the last binding's scope. *)
  let saved = env.local_map in
  emit_loop_body env ~tail:true body ~leaf:(fun () ->
      put env "{";
      put env
        (String.concat ", "
           (List.map (fun n -> List.assoc n env.local_map) assigned));
      put env "}");
  env.local_map <- saved

and emit_threaded_control env (assigned : string list) (s : Emo_ir.stmt) : unit
    =
  match s with
  | Emo_ir.If { cond; then_; else_ } ->
      put env "case ";
      expr env cond;
      put env " of\n";
      put env "  <'true'> when 'true' ->\n";
      emit_threaded_body env assigned then_;
      put env "\n  <'false'> when 'true' ->\n";
      emit_threaded_body env assigned else_;
      put env "\nend"
  | Emo_ir.Case { scrutinee; branches } ->
      let scratch = fresh_var env "case" in
      put env ("let <" ^ scratch ^ "> =\n");
      expr env scrutinee;
      put env "\nin case ";
      put env scratch;
      put env " of\n";
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
            put env "  <";
            emit_pattern env b.Emo_ir.pattern;
            put env "> ";
            (match b.Emo_ir.guard with
            | Some g ->
                put env "when ";
                guard_expr env g;
                put env " ->\n"
            | None -> put env "when 'true' ->\n");
            emit_threaded_body env assigned b.Emo_ir.body;
            put env "\n";
            emit_branches rest
      in
      emit_branches branches;
      put env "end"
  | _ -> assert false

(* The instance tuple a field set rebuilds: `setelement(index, self,
   value)`. The class and the field index resolve from the receiver's
   type, falling back to the class whose body is being emitted. *)
and set_field_call env (self_ : Emo_ir.expr) name (value : Emo_ir.expr) :
    string =
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
        | None -> failwith ("beam: unknown field " ^ class_name ^ "." ^ name))
    | None -> failwith ("beam: unknown class " ^ class_name)
  in
  let self_code = expr_block env self_ in
  let value_code = expr_block env value in
  Printf.sprintf "call 'erlang':'setelement'(%d, %s, %s)" (fidx + 3) self_code
    value_code

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
      (* the value reads the old binding — the shadow registers after,
         or a self-referencing assignment (`n = n + 1`) would read the
         variable it is defining *)
      let value_code = expr_block env value in
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      put env value_code;
      put env "\nin ";
      put env v
  | Emo_ir.Set_global_var _ ->
      raise
        (Emo_ir.Lower_error
           "the beam target does not support module-level `var` yet")
  | Emo_ir.Set_field { self_; name; value } ->
      let call = set_field_call env self_ name value in
      let v = fresh_var env "self" in
      put env ("let <" ^ v ^ "> =\n");
      put env call;
      put env "\nin ";
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
      | Emo_ir.Make_exception { message; data } ->
          put env "call 'erlang':'throw'({'emo_raise', ";
          expr env message;
          Option.iter
            (fun d ->
              put env ", ";
              expr env d)
            data;
          put env "})"
      | _ ->
          put env "call 'erlang':'throw'({'emo_raise', ";
          expr env x;
          put env "})")
  | Emo_ir.While _ | Emo_ir.For _ ->
      failwith "beam: a loop outside a statement chain"
  | Emo_ir.Break -> (
      match env.loops with
      | (lname, var_names, _) :: _ ->
          emit_loop_jump env lname var_names "'true'"
      | [] -> failwith "beam: `break` outside a loop")
  | Emo_ir.Continue -> (
      match env.loops with
      | (lname, var_names, post) :: _ -> (
          (* the post clause runs before the next test; the rebinding it
             creates lives only in the jump — the local map restores, or
             later body statements would read a variable bound inside
             this let *)
          match post with
          | Some (Emo_ir.Assign_var { name; value; _ }) ->
              let saved = env.local_map in
              let value_code = expr_block env value in
              let v = fresh_var env name in
              put env ("let <" ^ v ^ "> =\n");
              put env value_code;
              put env "\nin ";
              emit_loop_jump env lname var_names "'false'";
              env.local_map <- saved
          | Some _ -> failwith "beam: this `for` post clause"
          | None -> emit_loop_jump env lname var_names "'false'")
      | [] -> failwith "beam: `continue` outside a loop")

(* The free variables of a loop body: every outer binding it reads or
   assigns threads through the loop function's parameters — a module
   level function sees nothing of the enclosing scope, so a read of an
   outer variable (a nested loop's `col > row`) rides a parameter just
   like an assignment does. Over-collection is harmless: the value
   round-trips unchanged, and a shadowing binding only widens the set. *)
and free_expr env (e : Emo_ir.expr) (acc : string list) : string list =
  let add name acc = if List.mem name acc then acc else acc @ [ name ] in
  let xs es acc = List.fold_left (fun acc x -> free_expr env x acc) acc es in
  match e.Emo_ir.desc with
  | Emo_ir.Var name -> add name acc
  | Emo_ir.Unary (_, x)
  | Emo_ir.Box_new x
  | Emo_ir.Bytes_new x
  | Emo_ir.List_new x ->
      free_expr env x acc
  | Emo_ir.Builder_new -> acc
  | Emo_ir.Binary (_, l, r) -> free_expr env l (free_expr env r acc)
  | Emo_ir.Cond { c; t; e } ->
      free_expr env c (free_expr env t (free_expr env e acc))
  | Emo_ir.Index (b, i) -> free_expr env b (free_expr env i acc)
  | Emo_ir.Field_read { obj; _ } -> free_expr env obj acc
  | Emo_ir.Call { args; _ }
  | Emo_ir.Builtin { args; _ }
  | Emo_ir.Runtime_impl { args; _ }
  | Emo_ir.Do_spawn { args; _ } ->
      xs args acc
  | Emo_ir.Call_value { f; args } | Emo_ir.Spawn_value { f; args } ->
      xs (f :: args) acc
  | Emo_ir.Method { self_; args; _ } -> xs (self_ :: args) acc
  | Emo_ir.Interpolate es | Emo_ir.Tuple es | Emo_ir.Array_lit es -> xs es acc
  | Emo_ir.Map_lit es -> xs es acc
  | Emo_ir.Make_exception { message; data } ->
      free_expr env message
        (match data with Some d -> free_expr env d acc | None -> acc)
  | Emo_ir.Closure { cparams; cbody } ->
      let names = List.map fst cparams in
      List.fold_left
        (fun acc name -> List.filter (fun n -> n <> name) acc)
        (free_stmts env cbody acc) names
  | Emo_ir.Const _ | Emo_ir.Type_ref _ | Emo_ir.Global _ | Emo_ir.Global_var _
  | Emo_ir.Make_enum _ ->
      acc

and free_stmt env (s : Emo_ir.stmt) (acc : string list) : string list =
  match s with
  | Emo_ir.Effect e -> free_expr env e acc
  | Emo_ir.Let { init; _ } -> free_expr env init acc
  | Emo_ir.Assign_var { name; value } ->
      free_expr env value (if List.mem name acc then acc else acc @ [ name ])
  | Emo_ir.Set_global_var { value; _ } -> free_expr env value acc
  | Emo_ir.Set_field { self_; name = _; value } ->
      free_expr env self_ (free_expr env value acc)
  | Emo_ir.If { cond; then_; else_ } ->
      free_expr env cond (free_stmts env then_ (free_stmts env else_ acc))
  | Emo_ir.While { cond; body; _ } ->
      free_expr env cond (free_stmts env body acc)
  | Emo_ir.For { init = Emo_ir.Let { init; _ }; cond; post; body; _ } ->
      free_expr env init
        (free_expr env cond (free_stmt env post (free_stmts env body acc)))
  | Emo_ir.For { init = _; _ } ->
      failwith "beam: the `for` header binds a `var`"
  | Emo_ir.Case { scrutinee; branches } ->
      List.fold_left
        (fun acc (b : Emo_ir.branch) ->
          let acc =
            match b.Emo_ir.guard with
            | Some g -> free_expr env g acc
            | None -> acc
          in
          free_stmts env b.Emo_ir.body acc)
        (free_expr env scrutinee acc)
        branches
  | Emo_ir.Receive { branches } ->
      List.fold_left
        (fun acc (b : Emo_ir.branch) ->
          let acc =
            match b.Emo_ir.guard with
            | Some g -> free_expr env g acc
            | None -> acc
          in
          free_stmts env b.Emo_ir.body acc)
        acc branches
  | Emo_ir.Send { target; message } ->
      free_expr env target (free_expr env message acc)
  | Emo_ir.Return_stmt e | Emo_ir.Raise e -> free_expr env e acc
  | Emo_ir.Break | Emo_ir.Continue -> acc

and free_stmts env (xs : Emo_ir.stmt list) (acc : string list) : string list =
  List.fold_left (fun acc s -> free_stmt env s acc) acc xs

(* The recursive jump a break or continue emits: the loop function
   called with the current values of its threaded bindings — the
   do-chain's shadowing means the local map holds the latest — and the
   done flag. *)
and emit_loop_jump env lname var_names done_atom =
  let args =
    List.map
      (fun name ->
        match List.assoc_opt name env.local_map with
        | Some v -> v
        | None -> failwith ("beam: unbound loop var " ^ name))
      var_names
  in
  emit_loop_jump_args env lname args done_atom

and emit_loop_jump_args env lname (args : string list) done_atom =
  put env
    (Printf.sprintf "apply %s/%d (%s)" lname
       (List.length args + 1)
       (String.concat ", " (args @ [ done_atom ])))

(* Whether a statement holds a break/continue of the enclosing loop:
   nested loops' jumps bind to themselves and stop the walk. A `case`
   whose branches jump cannot weave into the tail chain (its arms emit
   through the plain statement path), so the body weaver refuses it
   rather than lower a jump that would return. *)
and has_direct_jump env (s : Emo_ir.stmt) : bool =
  match s with
  | Emo_ir.Break | Emo_ir.Continue -> true
  | Emo_ir.If { then_; else_; _ } ->
      List.exists (has_direct_jump env) then_
      || List.exists (has_direct_jump env) else_
  | Emo_ir.Case { branches; _ } ->
      List.exists
        (fun (b : Emo_ir.branch) ->
          List.exists
            (fun bs ->
              List.exists
                (fun inner ->
                  match inner with
                  | Emo_ir.While _ | Emo_ir.For _ -> false
                  | x -> has_direct_jump env x)
                bs)
            [ b.Emo_ir.body ])
        branches
  | _ -> false

(* The loop body as a tail chain: an if weaves the rest of the body
   into both arms (its fall-through continues there), a break or
   continue is the tail itself and truncates the dead rest, and plain
   statements sequence through `do`. Every fall-through path ends in
   [leaf] — the threaded jump, a genuine tail call — so a jump never
   sits in a scrutinee or a `do` head where it could return. *)
and emit_loop_body env ~(tail : bool) ~(leaf : unit -> unit)
    (xs : Emo_ir.stmt list) : unit =
  match xs with
  | [] -> leaf ()
  | Emo_ir.Break :: _ -> stmt env Emo_ir.Break
  | Emo_ir.Continue :: _ -> stmt env Emo_ir.Continue
  | [ ((Emo_ir.While _ | Emo_ir.For _) as loop) ] when not tail ->
      (* The loop is the last statement of a value chain: its value is
         the list's value, so no jump follows it. *)
      emit_loop env ~tail ~leaf:(fun () -> put env "'ok'") loop []
  | [ s ] when not tail ->
      (* Outside a loop body the last statement's own value is the
         list's value; the tail chain's leaf does not follow it. *)
      stmt env s
  | Emo_ir.If { cond; then_; else_ } :: rest when rest <> [] ->
      (* The branches join before the rest: the rest becomes a shared
         continuation that each branch tail-calls with every binding
         live at the join — nested joins and the enclosing loop's
         fall-through all read current values through the parameters,
         and the enclosing loop threads them (see `emit_loop`). One
         copy of the rest instead of one per branch, which a chain of
         ifs would otherwise multiply 2^ifs times. Emitter temporaries
         never thread: their lets close within their statement. *)
      let rec live_uniq acc = function
        | [] -> List.rev acc
        | name :: tl ->
            if
              List.mem name acc
              || List.mem name beam_temps
              || List.mem name tl
            then live_uniq acc tl
            else live_uniq (name :: acc) tl
      in
      let live = live_uniq [] (List.map fst env.local_map) in
      let n2 = env.fresh + 1 in
      env.fresh <- n2;
      let cname = Printf.sprintf "'__cont_%d'" n2 in
      let saved_map = env.local_map in
      let saved_loops = env.loops in
      let before = Buffer.length env.buf in
      let param_of =
        List.map (fun name -> (name, fresh_var env name)) live
      in
      put env
        (Printf.sprintf "%s/%d =\n    fun (%s) ->\n" cname
           (List.length param_of)
           (String.concat ", " (List.map snd param_of)));
      env.local_map <- param_of;
      emit_loop_body env ~tail rest ~leaf;
      env.local_map <- saved_map;
      env.loops <- saved_loops;
      let slice = Buffer.sub env.buf before (Buffer.length env.buf - before) in
      Buffer.truncate env.buf before;
      Buffer.add_string env.loops_buf slice;
      Buffer.add_string env.loops_buf "\n\n";
      let emit_branch (branch_body : Emo_ir.stmt list) =
        let saved = env.local_map in
        emit_loop_body env ~tail:true branch_body ~leaf:(fun () ->
            put env
              (Printf.sprintf "apply %s/%d (%s)" cname
                 (List.length param_of)
                 (String.concat ", "
                    (List.map
                       (fun (name, _) ->
                         match List.assoc_opt name env.local_map with
                         | Some v -> v
                         | None ->
                             failwith ("beam: unbound cont var " ^ name))
                       param_of))));
        env.local_map <- saved
      in
      put env "\t\tcase ";
      expr env cond;
      put env " of\n\t\t  <'true'> when 'true' ->\n\t\t";
      emit_branch then_;
      put env "\n\t\t  <'false'> when 'true' ->\n\t\t";
      emit_branch else_;
      put env "\n\t\tend"
  | Emo_ir.If { cond; then_; else_ } :: rest ->
      put env "\t\tcase ";
      expr env cond;
      put env " of\n\t\t  <'true'> when 'true' ->\n\t\t";
      let saved = env.local_map in
      emit_loop_body env ~tail (then_ @ []) ~leaf;
      env.local_map <- saved;
      put env "\n\t\t  <'false'> when 'true' ->\n\t\t";
      emit_loop_body env ~tail (else_ @ []) ~leaf;
      env.local_map <- saved;
      put env "\n\t\tend"
  | ((Emo_ir.While _ | Emo_ir.For _) as loop) :: rest ->
      emit_loop env ~tail loop rest ~leaf
  | (Emo_ir.Case { branches; _ } as s) :: rest ->
      if
        List.exists
          (fun (b : Emo_ir.branch) ->
            List.exists (has_direct_jump env) b.Emo_ir.body)
          branches
      then
        failwith "beam: a `case` branch jumps out of a loop — not supported yet"
      else if
        List.exists (fun n -> List.mem_assoc n env.local_map) (assigned_names s)
      then (
        (* A branch that rebinds an outer `var` threads the new bindings
           out of the `case`, exactly like one at statement level: without
           this a `while` whose exit a branch sets never sees it, because
           the branch's `let` shadows only inside the branch. *)
        let assigned =
          unique_names
            (List.filter
               (fun n -> List.mem_assoc n env.local_map)
               (assigned_names s))
        in
        let slot = fresh_var env "__thread" in
        put env ("let <" ^ slot ^ "> =\n");
        emit_threaded_control env assigned s;
        put env "\nin ";
        List.iteri
          (fun i name ->
            let v = fresh_var env name in
            put env
              (Printf.sprintf
                 "let <%s> =\n  call 'erlang':'element'(%d, %s)\nin " v (i + 1)
                 slot);
            env.local_map <- (name, v) :: env.local_map)
          assigned;
        emit_loop_body env ~tail rest ~leaf)
      else (
        put env "do\n";
        stmt env s;
        put env "\n";
        emit_loop_body env ~tail rest ~leaf)
  | Emo_ir.Let { name; init; _ } :: rest ->
      (* the binding scopes over the rest of the body *)
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      expr env init;
      put env "\nin ";
      emit_loop_body env ~tail rest ~leaf
  | Emo_ir.Assign_var { name; value } :: rest ->
      (* the rebinding scopes over the rest: an accumulation
         (`line = line + ...`) must reach the later reads *)
      let value_code = expr_block env value in
      let v = fresh_var env name in
      put env ("let <" ^ v ^ "> =\n");
      put env value_code;
      put env "\nin ";
      emit_loop_body env ~tail rest ~leaf
  | Emo_ir.Set_field { self_; name; value } :: rest ->
      (* A field set rebinds `self` over the rest, exactly like a
         `var` rebinding: the rest rides the let's body. A `do` would
         not scope it, so the rebound `self` read unbound after the
         loop (the class-init shape). *)
      let call = set_field_call env self_ name value in
      let v = fresh_var env "self" in
      put env ("let <" ^ v ^ "> =\n");
      put env call;
      put env "\nin ";
      emit_loop_body env ~tail rest ~leaf
  | s :: rest ->
      put env "do\n";
      stmt env s;
      put env "\n";
      emit_loop_body env ~tail rest ~leaf

(* One loop statement: a tail-recursive module function. The site calls
   it with the header's init and the current threaded bindings; every
   exit returns them (the header included), and the site rebinds them
   over the rest of the chain. *)
and emit_loop env ~(tail : bool) ~(leaf : unit -> unit) (loop : Emo_ir.stmt)
    (rest : Emo_ir.stmt list) : unit =
  let header, init, cond, post, body =
    match loop with
    | Emo_ir.While { cond; body; _ } -> (None, None, cond, None, body)
    | Emo_ir.For
        {
          init = Emo_ir.Let { mutable_ = true; name; init };
          cond;
          post;
          body;
          _;
        } ->
        (Some name, Some (name, init), cond, Some post, body)
    | Emo_ir.For { init = _; _ } ->
        failwith "beam: the `for` header binds a `var`"
    | _ -> assert false
  in
  let frees =
    free_expr env cond
      (free_stmts env body
         (match post with Some p -> free_stmt env p [] | None -> []))
  in
  let frees =
    List.filter
      (fun n ->
        List.mem_assoc n env.local_map
        && match header with Some h -> n <> h | None -> true)
      frees
  in
  (* Every live binding threads, not just the loop's own reads: a join
     inside the body may need a binding the loop never reads (one that
     only the code after the loop uses), and the loop function's def is
     self-contained — whatever the body's continuations reference must
     ride the parameters. *)
  let rec live_uniq acc = function
    | [] -> List.rev acc
    | name :: tl ->
        if
          List.mem name acc
          || List.mem name beam_temps
          || List.mem name frees
          || (match header with Some h -> name = h | None -> false)
        then live_uniq acc tl
        else live_uniq (name :: acc) tl
  in
  let live_names = live_uniq [] (List.map fst env.local_map) in
  let var_names = (match header with Some h -> [ h ] | None -> []) @ frees @ live_names in
  let n = env.fresh + 1 in
  env.fresh <- n;
  let lname = Printf.sprintf "'__loop_%d'" n in
  let arity = List.length var_names + 1 in
  let saved_map = env.local_map in
  let saved_loops = env.loops in
  let before = Buffer.length env.buf in
  let param_of = List.map (fun name -> (name, fresh_var env name)) var_names in
  let done_param =
    env.fresh <- env.fresh + 1;
    Printf.sprintf "_done%d" env.fresh
  in
  env.loops <- (lname, var_names, post) :: env.loops;
  let exit_value =
    match var_names with
    | [] -> "'ok'"
    | ws ->
        "{"
        ^ String.concat "," (List.map (fun name -> List.assoc name param_of) ws)
        ^ "}"
  in
  put env
    (Printf.sprintf "%s/%d =\n    fun (%s) ->\n" lname arity
       (String.concat ", " (List.map snd param_of @ [ done_param ])));
  put env (Printf.sprintf "\tcase %s of\n" done_param);
  put env (Printf.sprintf "\t  <'true'> when 'true' -> %s\n" exit_value);
  put env "\t  <'false'> when 'true' ->\n\t    case ";
  expr env cond;
  put env " of\n";
  put env "\t      <'true'> when 'true' ->\n\t";
  let emit_thread_case () =
    (* the fall-through leaf: this iteration's final bindings ride the
       recursive call; its bindings scope to this case, so the map
       restores after *)
    let saved_leaf = env.local_map in
    put env "\t\tcase {";
    put env
      (String.concat ","
         (List.map
            (fun name ->
              match List.assoc_opt name env.local_map with
              | Some v -> v
              | None -> failwith ("beam: unbound loop var " ^ name))
            var_names));
    put env "} of\n\t          <{";
    let rebound =
      List.map
        (fun _ ->
          env.fresh <- env.fresh + 1;
          Printf.sprintf "_t%d" env.fresh)
        var_names
    in
    put env (String.concat "," rebound);
    put env "}> when 'true' ->\n\t\t    ";
    (* the post reads the rebound header, not the parameter *)
    List.iter2
      (fun name r -> env.local_map <- (name, r) :: env.local_map)
      var_names rebound;
    let rebound_written = match rebound with _ :: ws -> ws | [] -> [] in
    (match post with
    | Some (Emo_ir.Assign_var { name; value; _ }) ->
        let value_code = expr_block env value in
        let v = fresh_var env name in
        put env (Printf.sprintf "let <%s> =\n" v);
        put env value_code;
        put env "\nin ";
        emit_loop_jump_args env lname (v :: rebound_written) "'false'"
    | Some _ -> failwith "beam: this `for` post clause"
    | None -> emit_loop_jump_args env lname rebound "'false'");
    put env "\n\t        end";
    env.local_map <- saved_leaf
  in
  emit_loop_body env ~tail:true body ~leaf:emit_thread_case;
  put env "\n";
  put env (Printf.sprintf "\t      <'false'> when 'true' -> %s\n" exit_value);
  put env "\t    end\n";
  put env "\tend";
  let slice = Buffer.sub env.buf before (Buffer.length env.buf - before) in
  Buffer.truncate env.buf before;
  Buffer.add_string env.loops_buf slice;
  Buffer.add_string env.loops_buf "\n\n";
  env.local_map <- saved_map;
  env.loops <- saved_loops;
  (* the site: the initial call, its exit value rebound over the rest *)
  let emit_initial_call () =
    put env (Printf.sprintf "apply %s/%d (" lname arity);
    let sep = ref false in
    let comma () = if !sep then put env ", " else sep := true in
    (match init with
    | Some (_, e) ->
        comma ();
        expr env e
    | None -> ());
    List.iter
      (fun name ->
        comma ();
        match List.assoc_opt name env.local_map with
        | Some v -> put env v
        | None -> failwith ("beam: unbound loop var " ^ name))
      (match header with Some _ -> List.tl var_names | None -> var_names);
    comma ();
    put env "'false')"
  in
  if var_names = [] then (
    put env "do\n";
    emit_initial_call ();
    put env "\n";
    if rest = [] then leaf () else emit_loop_body env ~tail rest ~leaf)
  else (
    put env "case ";
    emit_initial_call ();
    put env " of\n\t  <{";
    let saved_site = env.local_map in
    let rebound = List.map (fun name -> fresh_var env name) var_names in
    put env (String.concat "," rebound);
    put env "}> when 'true' ->\n";
    if rest = [] then leaf () else emit_loop_body env ~tail rest ~leaf;
    (* the pattern bindings scope to this arm *)
    env.local_map <- saved_site;
    put env "\nend")

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
	  <{'emo_builder', _k}> when 'true' ->
	      apply 'emo_builder_to_str'/1 ({'emo_builder', _k})
	  <{'emo_map', _k}> when 'true' ->
	      apply 'emo_map_str'/1 ({'emo_map', _k})
	  <{'emo_enum', _n, _m}> when 'true' ->
	      call 'erlang':'atom_to_binary'(_m, 'utf8')
	  <_t> when call 'erlang':'is_tuple'(_t) ->
	      apply 'emo_tuple_to_str'/1 (_t)
	  <_a> when call 'erlang':'is_list'(_a) ->
	      apply 'emo_array_to_str'/1 (_a)
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
			    <'true'> when 'true' -> apply 'emo_g6_dec'/2 (_x, _e)
			    <'false'> when 'true' -> apply 'emo_g6_sci'/2 (_m, _e)
			  end
		    end

%% The %g decimal tail: 'compact' keeps one decimal digit, so a value
%%   rounding to an integer at six significant digits answers "204.0"
%%   where %g says "204" — strip that pair.
'emo_g6_dec'/2 =
    fun (_x, _e) ->
	let <_s> = call 'erlang':'float_to_binary'(_x, [{'decimals', call 'erlang':'-'(5, _e)}, 'compact'])
	in case call 'erlang':'=<'(2, call 'erlang':'byte_size'(_s)) of
	     <'true'> when 'true' ->
		 case call 'erlang':'=='(call 'binary':'part'(_s, call 'erlang':'-'(call 'erlang':'byte_size'(_s), 2), 2), #{#<46>(8,1,'integer',['unsigned'|['big']]),#<48>(8,1,'integer',['unsigned'|['big']])}#) of
		   <'true'> when 'true' -> call 'binary':'part'(_s, 0, call 'erlang':'-'(call 'erlang':'byte_size'(_s), 2))
		   <'false'> when 'true' -> _s
		 end
	     <'false'> when 'true' -> _s
	   end

'emo_g6_sci'/2 =
    fun (_m, _e) ->
	let <_t> = call 'string':'trim'(_m, 'trailing', [48])
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
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'erlang':'/'(_x, _y)
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
	  <_x> when call 'erlang':'is_float'(_x) ->
	      case _b of
		<_y> when call 'erlang':'is_float'(_y) ->
		    call 'math':'fmod'(_x, _y)
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
    fun (_xs, _x) -> call 'lists':'append'(_xs, [_x])

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

%% String.substring(start, length): in-bounds only, the same range
%% check the interpreter enforces before binary:part/3 would badarg.
'emo_str_substring'/3 =
    fun (_s, _start, _len) ->
	case call 'erlang':'<'(_start, 0) of
	  <'true'> when 'true' ->
	      call 'erlang':'error'({'emo_bad_substring', _start, _len})
	  <'false'> when 'true' ->
	      case call 'erlang':'<'(_len, 0) of
		<'true'> when 'true' ->
		    call 'erlang':'error'({'emo_bad_substring', _start, _len})
		<'false'> when 'true' ->
		    case call 'erlang':'=<'(call 'erlang':'+'(_start, _len), call 'erlang':'byte_size'(_s)) of
		      <'true'> when 'true' -> call 'binary':'part'(_s, _start, _len)
		      <'false'> when 'true' ->
			  call 'erlang':'error'({'emo_bad_substring', _start, _len})
		    end
	      end
	end

'emo_str_starts_with'/2 =
    fun (_s, _p) ->
	case call 'erlang':'>='(call 'erlang':'byte_size'(_s), call 'erlang':'byte_size'(_p)) of
	  <'false'> when 'true' -> 'false'
	  <'true'> when 'true' ->
	      call 'erlang':'=:='(call 'binary':'part'(_s, 0, call 'erlang':'byte_size'(_p)), _p)
	end

'emo_str_split'/2 =
    fun (_s, _sep) ->
	case _sep of
	  <_e> when call 'erlang':'=='(call 'erlang':'byte_size'(_e), 0) ->
	      call 'erlang':'error'
		({'emo_empty_sep',
		  call 'erlang':'iolist_to_binary'([116, 104, 101, 32, 115, 101, 112, 97, 114, 97, 116, 111, 114, 32, 109, 117, 115, 116, 32, 110, 111, 116, 32, 98, 101, 32, 101, 109, 112, 116, 121])})
	  <_other> when 'true' ->
	      call 'binary':'split'(_s, _sep, ['global'])
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

%% The ArrayBuilder: BEAM's terms are immutable, so the builder is a
%% {emo_builder, Key} tag over a per-process {Count, Reversed} pair in the
%% process dictionary — the same mechanism emo_list_new uses. Push
%% conses onto the reversed list, so it is O(1); get is O(n) (it walks to
%% the index), which only push is required to avoid.
'emo_builder_new'/0 =
    fun () ->
	let <_k> = call 'erlang':'make_ref'()
	in do call 'erlang':'put'(_k, {0, []})
	   {'emo_builder', _k}

'emo_builder_push'/2 =
    fun (_b, _v) ->
	case _b of
	  <{'emo_builder', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_n, _r}> when 'true' ->
		    do call 'erlang':'put'(_k, {call 'erlang':'+'(_n, 1), [_v | _r]})
		       _b
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_builder', _other})
	end

'emo_builder_elems'/1 =
    fun (_b) ->
	case _b of
	  <{'emo_builder', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_n, _r}> when 'true' -> call 'lists':'reverse'(_r)
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_builder', _other})
	end

'emo_builder_len'/1 =
    fun (_b) ->
	case _b of
	  <{'emo_builder', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_n, _r}> when 'true' -> _n
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_builder', _other})
	end

'emo_builder_get'/2 =
    fun (_b, _i) ->
	case _b of
	  <{'emo_builder', _k}> when 'true' ->
	      case call 'erlang':'get'(_k) of
		<{_n, _r}> when 'true' ->
		    case call 'erlang':'is_integer'(_i) of
		      <'true'> when 'true' ->
			  case call 'erlang':'>='(_i, 0) of
			    <'true'> when 'true' ->
				case call 'erlang':'<'(_i, _n) of
				  <'true'> when 'true' ->
				      call 'lists':'nth'(call 'erlang':'-'(_n, _i), _r)
				  <'false'> when 'true' ->
				      call 'erlang':'error'({'emo_builder_index', _i, _n})
				end
			    <'false'> when 'true' ->
				call 'erlang':'error'({'emo_builder_index', _i, _n})
			  end
		      <'false'> when 'true' ->
			  call 'erlang':'error'({'emo_builder_index', _i, _n})
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_builder', _other})
	end

%% to_array hands out a fresh list — a copy, so the builder stays free to
%% grow without touching the array it already returned.
'emo_builder_to_array'/1 = fun (_b) -> apply 'emo_builder_elems'/1 (_b)

'emo_builder_to_str'/1 =
    fun (_b) ->
	call 'erlang':'iolist_to_binary'
	    (apply 'emo_builder_join'/2 (apply 'emo_builder_elems'/1 (_b), 1))

'emo_builder_join'/2 =
    fun (_elems, _first) ->
	case _elems of
	  <[_e | _rest]> when 'true' ->
	      let <_piece> = apply 'emo_to_str'/1 (_e)
	      in case _first of
		   <1> when 'true' ->
		       [[65, 114, 114, 97, 121, 66, 117, 105, 108, 100, 101, 114, 91], _piece
			| apply 'emo_builder_join'/2 (_rest, 0)]
		   <_> when 'true' ->
		       [[44, 32], _piece | apply 'emo_builder_join'/2 (_rest, 0)]
		 end
	  <[]> when 'true' ->
	      case _first of
		<1> when 'true' ->
		    [65, 114, 114, 97, 121, 66, 117, 105, 108, 100, 101, 114, 91, 93]
		<_> when 'true' -> [93]
	      end
	end

'emo_tuple_to_str'/1 =
    fun (_t) ->
	call 'erlang':'iolist_to_binary'
	    (apply 'emo_tuple_join'/2 (call 'erlang':'tuple_to_list'(_t), 1))

'emo_tuple_join'/2 =
    fun (_elems, _first) ->
	case _elems of
	  <[_e | _rest]> when 'true' ->
	      let <_piece> = apply 'emo_to_str'/1 (_e)
	      in case _first of
		   <1> when 'true' ->
		       [[40], _piece | apply 'emo_tuple_join'/2 (_rest, 0)]
		   <_> when 'true' ->
		       [[44, 32], _piece | apply 'emo_tuple_join'/2 (_rest, 0)]
		 end
	  <[]> when 'true' ->
	      case _first of
		<1> when 'true' -> [40, 41]
		<_> when 'true' -> [41]
	      end
	end

'emo_array_to_str'/1 =
    fun (_a) ->
	call 'erlang':'iolist_to_binary'
	    (apply 'emo_array_join'/2 (_a, 1))

'emo_array_join'/2 =
    fun (_elems, _first) ->
	case _elems of
	  <[_e | _rest]> when 'true' ->
	      let <_piece> = apply 'emo_to_str'/1 (_e)
	      in case _first of
		   <1> when 'true' ->
		       [[91], _piece | apply 'emo_array_join'/2 (_rest, 0)]
		   <_> when 'true' ->
		       [[44, 32], _piece | apply 'emo_array_join'/2 (_rest, 0)]
		 end
	  <[]> when 'true' ->
	      case _first of
		<1> when 'true' -> [91, 93]
		<_> when 'true' -> [93]
	      end
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
	  <{'emo_builder', _ka}> when 'true' ->
	      case _b of
		<{'emo_builder', _kb}> when 'true' ->
		    call 'erlang':'=:='(apply 'emo_builder_elems'/1 (_a), apply 'emo_builder_elems'/1 (_b))
		<_other> when 'true' -> 'false'
	      end
	  <{'emo_map', _ka}> when 'true' ->
	      case _b of
		<{'emo_map', _kb}> when 'true' ->
		    apply 'emo_map_equal'/2 (_a, _b)
		<_other> when 'true' -> 'false'
	      end
	  <_other> when 'true' -> call 'erlang':'=:='(_a, _b)
	end

'emo_ne'/2 =
    fun (_a, _b) -> apply 'emo_not'/1 (apply 'emo_eq'/2 (_a, _b))

%% ---- Map ----
%%
%%   The Map is a {'emo_map', Key} tag over a per-process {Order, Pairs}
%%   pair in the process dictionary — the same mechanism emo_list_new
%%   uses. Order is the insertion-order key list; Pairs an Erlang map
%%   key→value. An existing key replaces in place and keeps its first
%%   position. Keys are the six hashable primitives, compared with =:=,
%%   so 1 and 1.0 stay distinct.

'emo_map_new'/1 =
    fun (_pairs) ->
	apply 'emo_map_new_walk'/3 (_pairs, call 'maps':'from_list'([]), [])

'emo_map_new_walk'/3 =
    fun (_pairs, _m, _order) ->
	case _pairs of
	  <[{_k, _v} | _rest]> when 'true' ->
	      case call 'maps':'is_key'(_k, _m) of
		<'true'> when 'true' ->
		    apply 'emo_map_new_walk'/3 (_rest, call 'maps':'put'(_k, _v, _m), _order)
		<'false'> when 'true' ->
		    apply 'emo_map_new_walk'/3 (_rest, call 'maps':'put'(_k, _v, _m), call 'erlang':'++'(_order, [_k]))
	      end
	  <[]> when 'true' ->
	      let <_k> = call 'erlang':'make_ref'()
	      in do call 'erlang':'put'(_k, {_order, _m})
		 {'emo_map', _k}
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_map_pairs', _other})
	end

'emo_map_get'/2 =
    fun (_m, _k) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    case call 'maps':'find'(_k, _pairs) of
		      <{'ok', _v}> when 'true' -> _v
		      <'error'> when 'true' ->
			  call 'erlang':'error'
			    ({'emo_no_key',
			      call 'erlang':'iolist_to_binary'
				([110, 111, 32, 107, 101, 121, 32,
				  apply 'emo_map_dbg'/1 (_k),
				  32, 105, 110, 32, 116, 104, 105, 115, 32, 77, 97, 112])})
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_set'/3 =
    fun (_m, _k, _v) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    case call 'maps':'is_key'(_k, _pairs) of
		      <'true'> when 'true' ->
			  do call 'erlang':'put'(_mk, {_order, call 'maps':'put'(_k, _v, _pairs)})
			     _m
		      <'false'> when 'true' ->
			  do call 'erlang':'put'(_mk, {call 'erlang':'++'(_order, [_k]), call 'maps':'put'(_k, _v, _pairs)})
			     _m
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_has'/2 =
    fun (_m, _k) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    call 'maps':'is_key'(_k, _pairs)
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_remove'/2 =
    fun (_m, _k) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    case call 'maps':'is_key'(_k, _pairs) of
		      <'true'> when 'true' ->
			  do call 'erlang':'put'(_mk, {apply 'emo_map_order_drop'/2 (_order, _k), call 'maps':'remove'(_k, _pairs)})
			     _m
		      <'false'> when 'true' -> _m
		    end
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_order_drop'/2 =
    fun (_keys, _k) ->
	case _keys of
	  <[_h | _t]> when 'true' ->
	      case call 'erlang':'=:='(_h, _k) of
		<'true'> when 'true' -> _t
		<'false'> when 'true' ->
		    [_h | apply 'emo_map_order_drop'/2 (_t, _k)]
	      end
	  <[]> when 'true' -> []
	end

'emo_map_length'/1 =
    fun (_m) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    call 'maps':'size'(_pairs)
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_keys'/1 =
    fun (_m) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' -> _order
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_values'/1 =
    fun (_m) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    apply 'emo_map_values_walk'/2 (_order, _pairs)
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_values_walk'/2 =
    fun (_keys, _pairs) ->
	case _keys of
	  <[_k | _rest]> when 'true' ->
	      [call 'maps':'get'(_k, _pairs)
	       | apply 'emo_map_values_walk'/2 (_rest, _pairs)]
	  <[]> when 'true' -> []
	end

'emo_map_str'/1 =
    fun (_m) ->
	case _m of
	  <{'emo_map', _mk}> when 'true' ->
	      case call 'erlang':'get'(_mk) of
		<{_order, _pairs}> when 'true' ->
		    call 'erlang':'iolist_to_binary'
		      (apply 'emo_map_str_walk'/3 (_order, _pairs, 1))
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _other})
	end

'emo_map_str_walk'/3 =
    fun (_keys, _pairs, _first) ->
	case _keys of
	  <[_k | _rest]> when 'true' ->
	      let <_kd> = apply 'emo_map_dbg'/1 (_k)
	      in let <_vd> = apply 'emo_map_dbg'/1 (call 'maps':'get'(_k, _pairs))
		 in case _first of
		      <1> when 'true' ->
			  [123, _kd, 58, 32, _vd
			   | apply 'emo_map_str_walk'/3 (_rest, _pairs, 0)]
		      <_> when 'true' ->
			  [44, 32, _kd, 58, 32, _vd
			   | apply 'emo_map_str_walk'/3 (_rest, _pairs, 0)]
		    end
	  <[]> when 'true' ->
	      case _first of
		<1> when 'true' -> [123, 125]
		<_> when 'true' -> [125]
	      end
	end

'emo_map_equal'/2 =
    fun (_a, _b) ->
	case _a of
	  <{'emo_map', _ka}> when 'true' ->
	      case _b of
		<{'emo_map', _kb}> when 'true' ->
		    case call 'erlang':'get'(_ka) of
		      <{_oa, _pa}> when 'true' ->
			  case call 'erlang':'get'(_kb) of
			    <{_ob, _pb}> when 'true' ->
				case call 'erlang':'=:='(call 'maps':'size'(_pa), call 'maps':'size'(_pb)) of
				  <'false'> when 'true' -> 'false'
				  <'true'> when 'true' ->
				      apply 'emo_map_equal_walk'/3 (_oa, _pa, _pb)
				end
			  end
		    end
		<_other> when 'true' -> 'false'
	      end
	  <_other> when 'true' ->
	      call 'erlang':'error'({'emo_no_map', _a})
	end

'emo_map_equal_walk'/3 =
    fun (_keys, _pa, _pb) ->
	case _keys of
	  <[_k | _rest]> when 'true' ->
	      case call 'maps':'is_key'(_k, _pb) of
		<'false'> when 'true' -> 'false'
		<'true'> when 'true' ->
		    case apply 'emo_eq'/2 (call 'maps':'get'(_k, _pa), call 'maps':'get'(_k, _pb)) of
		      <'false'> when 'true' -> 'false'
		      <'true'> when 'true' ->
			  apply 'emo_map_equal_walk'/3 (_rest, _pa, _pb)
		    end
	      end
	  <[]> when 'true' -> 'true'
	end

%% Inside a Map's rendering and its get-miss message, a string shows
%% quoted — the interpreter's debug form; everything else goes through
%% the shared to_str. On this target a string is a raw binary (a Char
%% is a one-byte one), so the quote walk is what draws the line.

'emo_map_dbg'/1 =
    fun (_v) ->
	case call 'erlang':'is_binary'(_v) of
	  <'true'> when 'true' ->
	      call 'erlang':'iolist_to_binary'
		(apply 'emo_map_quote'/1 (_v))
	  <'false'> when 'true' ->
	      apply 'emo_to_str'/1 (_v)
	end

'emo_map_quote'/1 =
    fun (_s) -> [34 | apply 'emo_map_quote_walk'/2 (_s, 0)]

'emo_map_quote_walk'/2 =
    fun (_s, _i) ->
	case call 'erlang':'>='(_i, call 'erlang':'byte_size'(_s)) of
	  <'true'> when 'true' -> [34]
	  <'false'> when 'true' ->
	      case call 'binary':'at'(_s, _i) of
		<34> when 'true' ->
		    [92, 34 | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
		<92> when 'true' ->
		    [92, 92 | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
		<10> when 'true' ->
		    [92, 110 | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
		<9> when 'true' ->
		    [92, 116 | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
		<13> when 'true' ->
		    [92, 114 | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
		<_c> when 'true' ->
		    [_c | apply 'emo_map_quote_walk'/2 (_s, call 'erlang':'+'(_i, 1))]
	      end
	end

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

%% The root process is the program. 'main'/0 owns this table, registers
%% every process it spawns in it, and kills the survivors on its way
%% out — a child never outlives the root, whatever the root did.
'emo_root_table'/0 =
    fun () ->
	case call 'ets':'whereis'('emo_procs') of
	  <'undefined'> when 'true' ->
	      call 'ets':'new'('emo_procs', ['named_table', 'public', 'set'])
	  <_t> when 'true' -> _t
	end

'emo_spawn_reg'/1 =
    fun (_pid) ->
	do call 'ets':'insert'('emo_procs', {_pid}) _pid

'emo_unreg'/1 =
    fun (_pid) ->
	do call 'ets':'delete'('emo_procs', _pid) _pid

'emo_kill_spawned'/0 =
    fun () ->
	case call 'ets':'whereis'('emo_procs') of
	  <'undefined'> when 'true' -> 'ok'
	  <_t> when 'true' ->
	      call 'lists':'foreach'
		  (fun (_o) -> call 'erlang':'exit'(call 'erlang':'element'(1, _o), 'kill'),
		   call 'ets':'tab2list'('emo_procs'))
	end

|}

(* ---- Module assembly ----

   One BEAM module per program (the wasm target's single-artifact
   design): every def lands in the module named by [module_name] under
   its mangled name, and 'main'/0 runs the entry statements.

   The name is a required argument rather than a constant because erlc
   requires the module atom to equal the .core file's stem
   (plan/step-18-beam.md), and the file is the caller's `-o` to choose. *)

(* Whether [name] can be a module atom. Quoted atoms would admit any
   string, but the stem has to be a file name too, and erlc loads a
   module by matching the two — so a name outside this set is refused
   where it can still be explained, not assembled into a .core that
   cannot be loaded. *)
let valid_module_name (name : string) : bool =
  let start c = c >= 'a' && c <= 'z' in
  let rest c =
    start c
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '_' || c = '@'
  in
  String.length name > 0 && start name.[0] && String.for_all rest name

let emit ~(module_name : string) (program : Emo_ir.program) : string =
  if not (valid_module_name module_name) then
    invalid_arg
      (Printf.sprintf
         "beam: `%s` is not a BEAM module name — a lower-case letter followed \
          by letters, digits, `_` or `@`"
         module_name);
  let buf = Buffer.create (16 * 1024) in
  let env =
    {
      buf;
      module_name;
      loops_buf = Buffer.create 1024;
      fresh = 0;
      local_map = [];
      loops = [];
      funcs = [];
      fname = "";
      classes = [];
      class_field = [];
      iface_classes = [];
      current_class = None;
      fforeigns =
        List.filter_map
          (fun (f : Emo_ir.func) ->
            if f.Emo_ir.fforeign <> None then Some f.Emo_ir.fname else None)
          program.Emo_ir.pfuncs;
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
          @ [
              ( c.Emo_ir.cname ^ "__new",
                match c.Emo_ir.cinit with
                | Some init -> List.length init.Emo_ir.fparams - 1
                | None -> 0 );
            ])
        program.Emo_ir.pclasses;
  put env (Printf.sprintf "module '%s' ['main'/0]\n" module_name);
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
    let inner = body_wrapper body_text in
    (* A const thunk memoizes in persistent_term: the initializer runs
       once per node, and every later read returns the same value — the
       identity an allocating initializer hands out survives, as in the
       interpreter. 'undefined' is the sentinel: no Emo value is ever
       the bare undefined atom (bools are 'true'/'false', instances are
       tagged tuples). The key carries the module name, so two programs
       on one node keep separate slots. *)
    let memo name text =
      let key = Printf.sprintf "{%s, %s}" (atom module_name) (atom name) in
      Printf.sprintf
        "case call 'persistent_term':'get'(%s, 'undefined') of\n\
        \  <'undefined'> when 'true' ->\n\
        \      let <_emo_const_v> = %s\n\
        \      in case call 'persistent_term':'put'(%s, _emo_const_v) of\n\
        \           <_emo_ignored> when 'true' -> _emo_const_v\n\
        \         end\n\
        \  <_emo_cached> when 'true' -> _emo_cached\nend"
        key text key
    in
    let inner =
      if params = [] && List.mem fname program.Emo_ir.pconsts then
        memo name inner
      else inner
    in
    put env inner;
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
      | Some init ->
          (* init's value is the instance, not whatever its last
             statement produced: a trailing method call must not become
             the constructor's result. *)
          stmts env
            (init.Emo_ir.fbody
            @ [
                Emo_ir.Effect
                  {
                    ety = Emo_check.ClassType c.Emo_ir.cname;
                    desc = Emo_ir.Var "self";
                  };
              ])
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
      if f.Emo_ir.fforeign = None then
        emit_def ~cc:None
          ~params:
            (List.mapi
               (fun i (pname, _) -> (pname, Printf.sprintf "_p%d" i))
               f.Emo_ir.fparams)
          ~fname:f.Emo_ir.fname ~body:f.Emo_ir.fbody)
    program.Emo_ir.pfuncs;
  env.fname <- "main";
  env.local_map <- [];
  let before = Buffer.length buf in
  stmts env program.Emo_ir.pinit;
  let body = Buffer.sub buf before (Buffer.length buf - before) in
  Buffer.truncate buf before;
  (* the loop functions discovered in any body join the definitions
     ahead of main *)
  Buffer.add_buffer buf env.loops_buf;
  put env "'main'/0 =\n";
  put env "    fun () ->\n";
  put env "        do apply 'emo_root_table'/0 ()\n";
  put env (body_wrapper ~on_exit:"apply 'emo_kill_spawned'/0 ()" body);
  put env "\nend\n";
  Buffer.contents buf
