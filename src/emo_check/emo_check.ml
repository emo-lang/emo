(* The gradual type checker. Annotations are optional except on signatures;
   unannotated code stays [Unknown] and only certain errors are reported —
   every diagnostic must be provable from known types. Codes are E4xxx. *)

module Ast = Emo_ast

(* The checker's type language. *)
type t =
  | Unknown
  | Int
  | Float
  | Bool
  | Char
  | String
  | ClassType of string
  | InterfaceType of string
  | EnumType of string
  | ArrayType of t
  | TupleType of t list
  | BoxType of t
  | FuncType of (string * t) list * t

let rec to_string = function
  | Unknown -> "Unknown"
  | Int -> "Int"
  | Float -> "Float"
  | Bool -> "Bool"
  | Char -> "Char"
  | String -> "String"
  | ClassType c -> c
  | InterfaceType i -> i
  | EnumType e -> e
  | ArrayType e -> "Array[" ^ to_string e ^ "]"
  | BoxType e -> "Box[" ^ to_string e ^ "]"
  | TupleType ts -> "(" ^ String.concat ", " (List.map to_string ts) ^ ")"
  | FuncType (ps, r) ->
      "("
      ^ String.concat ", " (List.map (fun (n, t) -> n ^ ": " ^ to_string t) ps)
      ^ ") -> " ^ to_string r

type method_info = { mparams : (string * t) list; mret : t; mdef : Ast.fun_def }

type class_info = {
  cname : string;
  cinit_params : (string * t) list option;
  cmethods : (string * method_info) list;
  cfields : string list;
}

type ctx = {
  file : string;
  classes : (string, class_info) Hashtbl.t;
  interfaces : (string, (string * (string * t) list * t) list) Hashtbl.t;
  enums : (string, string list) Hashtbl.t;
  funcs : (string, Ast.fun_def) Hashtbl.t;
  diagnostics : Emo_support.Diagnostic.t list ref;
  mutable ret_sink : t list ref;
      (* while checking an arrow block, its return types land here *)
  modules : string list list; (* every known module path in the project *)
  current : string list; (* the module being checked *)
  refs : string list list ref; (* module paths referenced by this module *)
}

let report ctx span code message =
  ctx.diagnostics :=
    Emo_support.Diagnostic.
      { severity = Error; code = Some code; message; span; hint = None }
    :: !(ctx.diagnostics)

(* Annotations resolve names through the collected declarations; an unknown
   name is a certain error (the annotation can never hold). *)
let rec ann_to_type ctx ({ Ast.type_span = span; type_desc; _ } : Ast.type_ann)
    =
  match type_desc with
  | Ast.Named_type "Int" -> Int
  | Ast.Named_type "Float" -> Float
  | Ast.Named_type "Bool" -> Bool
  | Ast.Named_type "Char" -> Char
  | Ast.Named_type "String" -> String
  | Ast.Named_type "Box" -> BoxType Unknown
  | Ast.Named_type name ->
      if Hashtbl.mem ctx.classes name then ClassType name
      else if Hashtbl.mem ctx.interfaces name then InterfaceType name
      else if Hashtbl.mem ctx.enums name then EnumType name
      else (
        report ctx span "E4005" (Printf.sprintf "unknown type `%s`" name);
        Unknown)
  | Ast.Applied_type ("Array", [ elem ]) -> ArrayType (ann_to_type ctx elem)
  | Ast.Applied_type ("Box", [ elem ]) -> BoxType (ann_to_type ctx elem)
  | Ast.Applied_type (name, _) ->
      report ctx span "E4005" (Printf.sprintf "unknown type `%s`" name);
      Unknown
  | Ast.Tuple_type ts -> TupleType (List.map (ann_to_type ctx) ts)

(* Pass one: gather every declaration the checker reasons about. *)
let collect ctx (items : Ast.item list) : unit =
  List.iter
    (fun item ->
      match item.Ast.item_desc with
      | Ast.Item_def d ->
          List.iter
            (fun p -> ignore (ann_to_type ctx p.Ast.param_type))
            d.Ast.def_params;
          Option.iter (fun r -> ignore (ann_to_type ctx r)) d.Ast.def_return;
          Hashtbl.replace ctx.funcs d.Ast.def_name d
      | Ast.Item_class c ->
          Option.iter
            (fun init ->
              List.iter
                (fun p -> ignore (ann_to_type ctx p.Ast.param_type))
                init.Ast.def_params)
            c.Ast.class_init;
          let methods =
            List.map
              (fun d ->
                ( d.Ast.def_name,
                  {
                    mparams =
                      List.map
                        (fun p ->
                          (p.Ast.param_name, ann_to_type ctx p.Ast.param_type))
                        d.Ast.def_params;
                    mret =
                      (match d.Ast.def_return with
                      | Some r -> ann_to_type ctx r
                      | None -> Unknown (* init *));
                    mdef = d;
                  } ))
              c.Ast.class_methods
          in
          Hashtbl.replace ctx.classes c.Ast.class_name
            {
              cname = c.Ast.class_name;
              cinit_params =
                Option.map
                  (fun init ->
                    List.map
                      (fun p ->
                        (p.Ast.param_name, ann_to_type ctx p.Ast.param_type))
                      init.Ast.def_params)
                  c.Ast.class_init;
              cmethods = methods;
              cfields = List.map (fun f -> f.Ast.field_name) c.Ast.class_fields;
            }
      | Ast.Item_interface i ->
          let sigs =
            List.map
              (fun s ->
                ( s.Ast.sig_name,
                  List.map
                    (fun p ->
                      (p.Ast.param_name, ann_to_type ctx p.Ast.param_type))
                    s.Ast.sig_params,
                  ann_to_type ctx s.Ast.sig_return ))
              i.Ast.interface_methods
          in
          Hashtbl.replace ctx.interfaces i.Ast.interface_name sigs
      | Ast.Item_enum e ->
          Hashtbl.replace ctx.enums e.Ast.enum_name
            (List.map (fun m -> m.Ast.member_name) e.Ast.enum_members)
      | Ast.Item_require _ -> () (* pairing is the driver's job *)
      | Ast.Item_stmt _ -> ())
    items

(* Parses and collects declarations. Parse diagnostics land in
   [ctx.diagnostics] and the item list comes back empty. *)
let analyze ~file ~(source : string) : ctx * Ast.item list =
  let ctx =
    {
      file;
      classes = Hashtbl.create 8;
      interfaces = Hashtbl.create 8;
      enums = Hashtbl.create 8;
      funcs = Hashtbl.create 8;
      diagnostics = ref [];
      ret_sink = ref [];
      modules = [];
      current = [];
      refs = ref [];
    }
  in
  let parsed = Emo_parser.parse_program_with_diagnostics ~file ~source in
  match parsed with
  | exception Emo_lexer.Error diagnostic ->
      ctx.diagnostics := [ diagnostic ];
      (ctx, [])
  | (_, _ :: _) as failed ->
      let _, diagnostics = failed in
      ctx.diagnostics := diagnostics;
      (ctx, [])
  | items, [] ->
      collect ctx items;
      (ctx, items)

(* Flow environment: an ordered binding list; the depth marks the scope that
   introduced a binding (used by the var-escape check). *)
type var_info = { vtype : t; is_var : bool; depth : int }

type env = {
  bindings : (string * var_info) list;
  depth : int;
  ret : t option;
  block_depth : int;
      (* definition depth of the innermost enclosing arrow block, -1 when
         none; a `var` from a shallower scope cannot be captured *)
}

(* The built-in surface every program sees. *)
let empty_env =
  {
    bindings =
      [
        ( "print",
          {
            vtype = FuncType ([ ("value", Unknown) ], Unknown);
            is_var = false;
            depth = 0;
          } );
        ("Box", { vtype = Unknown; is_var = false; depth = 0 });
        ( "Exception",
          { vtype = ClassType "Exception"; is_var = false; depth = 0 } );
      ];
    depth = 0;
    ret = None;
    block_depth = -1;
  }

let lookup_env env name = List.assoc_opt name env.bindings
let bind env name info = { env with bindings = (name, info) :: env.bindings }

let child_scope env =
  { env with bindings = env.bindings; depth = env.depth + 1 }

(* A class conforms to an interface when it provides every declared method
   with a compatible shape — no declaration, exactly the README rule. *)
let rec structurally_conforms ctx cname iname =
  match
    (Hashtbl.find_opt ctx.classes cname, Hashtbl.find_opt ctx.interfaces iname)
  with
  | Some cls, Some sigs ->
      List.for_all
        (fun (m, iptypes, iret) ->
          match List.assoc_opt m cls.cmethods with
          | Some minfo ->
              List.length minfo.mparams = List.length iptypes
              && List.for_all2
                   (fun (_, it) (_, mt) -> conforms ctx mt it)
                   iptypes minfo.mparams
              && conforms ctx minfo.mret iret
          | None -> false)
        sigs
  | _ -> false

(* [conforms ctx actual expected] — the gradual conformance relation. Unknown
   on either side silences the check; a known mismatch is provable. *)
and conforms ctx actual expected =
  match (actual, expected) with
  | _, Unknown | Unknown, _ -> true
  | Int, Float -> true
  | ClassType a, ClassType b -> String.equal a b
  | EnumType a, EnumType b -> String.equal a b
  | ArrayType a, ArrayType b -> conforms ctx a b
  | BoxType a, BoxType b -> conforms ctx a b
  | TupleType as_, TupleType bs ->
      List.length as_ = List.length bs && List.for_all2 (conforms ctx) as_ bs
  | FuncType (pa, ra), FuncType (pb, rb) ->
      List.length pa = List.length pb
      && List.for_all2 (fun (_, b) (_, a) -> conforms ctx a b) pb pa
      && conforms ctx ra rb
  | ClassType c, InterfaceType i -> structurally_conforms ctx c i
  | InterfaceType a, InterfaceType b -> String.equal a b
  | _, InterfaceType _ -> false
  | InterfaceType _, _ -> false
  | a, b -> a = b

let known_nonovoid = ignore

(* The dotted path of a member chain rooted at an identifier, if any:
   `shop.order.total` → ["shop"; "order"; "total"]. *)
let dotted_path (e : Ast.expr) : string list option =
  let rec go e =
    match e.Ast.desc with
    | Ast.Ident n -> Some [ n ]
    | Ast.Member (inner, name) -> Option.map (fun p -> p @ [ name ]) (go inner)
    | _ -> None
  in
  go e

(* A module path is known when some declared module lives at or below it. *)
let module_prefix_known ctx path =
  List.exists
    (fun m ->
      List.length path <= List.length m
      && List.for_all2 String.equal path (List.take (List.length path) m))
    ctx.modules

(* The longest known module prefix of a dotted path. *)
let longest_module_prefix ctx (path : string list) : string list =
  let rec prefixes path =
    match path with [] -> [] | _ :: rest -> path :: prefixes rest
  in
  let candidates = List.rev (prefixes path) in
  let rec longest known = function
    | [] -> known
    | candidate :: rest ->
        longest
          (if module_prefix_known ctx candidate then candidate else known)
          rest
  in
  longest [] candidates

(* Type-name resolution for `is()` targets; unknown names narrow to nothing. *)
let resolve_type_name ctx span name =
  if Hashtbl.mem ctx.classes name then ClassType name
  else if Hashtbl.mem ctx.interfaces name then InterfaceType name
  else if Hashtbl.mem ctx.enums name then EnumType name
  else (
    ignore span;
    Unknown)

(* What a pattern covers of an enum scrutinee. *)
type coverage = All | Members of string list

let literal_type = function
  | Ast.L_int _ -> Int
  | Ast.L_float _ -> Float
  | Ast.L_char _ -> Char
  | Ast.L_string _ -> String
  | Ast.L_bool _ -> Bool

(* True when a value of [rt] can provably never satisfy a check for [target]. *)
let provably_excluded ctx rt target =
  match (rt, target) with
  | Unknown, _ | _, Unknown -> false
  | Int, _ | Float, _ | Bool, _ | Char, _ | String, _ -> true
  | ClassType a, ClassType b -> not (String.equal a b)
  | ClassType c, InterfaceType i -> not (structurally_conforms ctx c i)
  | ClassType _, EnumType _ -> true
  | EnumType a, EnumType b -> not (String.equal a b)
  | EnumType _, _ -> true
  | _ -> false

let rec check_expr ctx env (e : Ast.expr) : t =
  let span = e.Ast.span in
  match e.Ast.desc with
  | Ast.Int _ -> Int
  | Ast.Float _ -> Float
  | Ast.Bool _ -> Bool
  | Ast.Char _ -> Char
  | Ast.String _ -> String
  | Ast.Ident name -> (
      match lookup_env env name with
      | Some info ->
          (* The var-escape rule: a `var` from an outer block referenced
             inside an arrow block can outlive its block. *)
          if info.is_var && info.depth < env.block_depth then
            report ctx span "E4012"
              (Printf.sprintf
                 "the var `%s` cannot be captured by a block that can outlive \
                  its own; use a const or a Box"
                 name);
          info.vtype
      | None ->
          if module_prefix_known ctx [ name ] then (
            (* A root-level module reference. *)
            ctx.refs := [ name ] :: !(ctx.refs);
            Unknown)
          else (
            report ctx span "E4003" (Printf.sprintf "`%s` is not defined" name);
            Unknown))
  | Ast.Type_ident name ->
      if
        (* A declared type in value position: classes, enums, interfaces. *)
        Hashtbl.mem ctx.classes name
      then ClassType name
      else if Hashtbl.mem ctx.enums name then EnumType name
      else if Hashtbl.mem ctx.interfaces name then InterfaceType name
      else if name = "Box" || name = "Exception" then Unknown
      else Unknown
  | Ast.Interpolated parts ->
      List.iter (fun p -> check_part ctx env p) parts;
      String
  | Ast.Self -> (
      match lookup_env env "self" with
      | Some info -> info.vtype
      | None ->
          report ctx span "E4003" "`self` is not defined here";
          Unknown)
  | Ast.Member (recv, name) -> (
      if module_prefix_known ctx (Option.value (dotted_path e) ~default:[]) then (
        (* A qualified module reference: record the longest known module
           prefix; cross-module types stay unchecked this step. *)
        let path = Option.value (dotted_path e) ~default:[] in
        ctx.refs := longest_module_prefix ctx path :: !(ctx.refs);
        Unknown)
      else
        let rt = check_expr ctx env recv in
        match rt with
        | ClassType c -> (
            match Hashtbl.find_opt ctx.classes c with
            | Some info when List.mem name info.cfields -> Unknown
            | Some info ->
                report ctx span "E4001"
                  (Printf.sprintf "`%s` has no field `%s`" c name);
                Unknown
            | None -> Unknown)
        | EnumType e -> (
            match Hashtbl.find_opt ctx.enums e with
            | Some members when List.mem name members -> EnumType e
            | Some members ->
                report ctx span "E4001"
                  (Printf.sprintf "enum `%s` has no member `%s`" e name);
                Unknown
            | None -> Unknown)
        | Unknown -> Unknown
        | other ->
            report ctx span "E4001"
              (Printf.sprintf "%s has no field `%s`" (to_string other) name);
            Unknown)
  | Ast.Index (base, index) -> (
      let bt = check_expr ctx env base in
      let it = check_expr ctx env index in
      match bt with
      | ArrayType elem ->
          if it = Unknown || it = Int then elem
          else (
            report ctx span "E4004"
              (Printf.sprintf "the index must be an Int, got %s" (to_string it));
            elem)
      | TupleType ts -> (
          match (index.Ast.desc, it) with
          | Ast.Int n, _ when n >= 0 && n < List.length ts -> (
              match List.nth_opt ts n with Some t -> t | None -> Unknown)
          | Ast.Int n, _ ->
              report ctx span "E4006"
                (Printf.sprintf "tuple index %d is out of bounds for %s" n
                   (to_string bt));
              Unknown
          | _, Int -> Unknown
          | _, other ->
              report ctx span "E4004"
                (Printf.sprintf "the index must be an Int, got %s"
                   (to_string other));
              Unknown)
      | Unknown -> Unknown
      | other ->
          report ctx span "E4004"
            (Printf.sprintf "%s does not support indexing" (to_string other));
          Unknown)
  | Ast.Tuple es -> TupleType (List.map (check_expr ctx env) es)
  | Ast.Array_literal es ->
      let elem_types = List.map (check_expr ctx env) es in
      let unified =
        match elem_types with
        | [] -> Unknown
        | first :: rest ->
            if List.for_all (conforms ctx first) rest then first else Unknown
      in
      ArrayType unified
  | Ast.Arrow_block (params, body) ->
      let param_types =
        List.map
          (fun p -> (p.Ast.param_name, ann_to_type ctx p.Ast.param_type))
          params
      in
      let inner =
        List.fold_left
          (fun env p ->
            bind env p.Ast.param_name
              {
                vtype = ann_to_type ctx p.Ast.param_type;
                is_var = false;
                depth = env.depth;
              })
          { (child_scope env) with block_depth = env.depth }
          params
      in
      let sink = ref [] in
      let saved = ctx.ret_sink in
      ctx.ret_sink <- sink;
      let (_ : env) =
        List.fold_left (fun env s -> check_stmt ctx env s) inner body
      in
      ctx.ret_sink <- saved;
      let rets = List.rev !sink in
      let inferred =
        match rets with
        | [] -> Unknown
        | first :: rest ->
            if List.for_all (conforms ctx first) rest then first else Unknown
      in
      FuncType (param_types, inferred)
  | Ast.Unary (op, x) -> (
      let xt = check_expr ctx env x in
      match (op, xt) with
      | Ast.Not, Bool -> Bool
      | Ast.Not, Unknown -> Bool
      | Ast.Not, other ->
          report ctx span "E4004"
            (Printf.sprintf "operator `!` expects a Bool, got %s"
               (to_string other));
          Bool
      | Ast.Neg, (Int | Unknown) -> Int
      | Ast.Neg, Float -> Float
      | Ast.Neg, other ->
          report ctx span "E4004"
            (Printf.sprintf "operator `-` expects a number, got %s"
               (to_string other));
          Unknown)
  | Ast.Binary (op, l, r) -> check_binary ctx env span op l r
  | Ast.Do operand ->
      ignore (check_expr ctx env operand);
      Unknown
  | Ast.Call (callee, args) -> (
      match callee.Ast.desc with
      | Ast.Member (recv, mname) ->
          check_method_call ctx env span recv mname args
      | _ ->
          let ft = check_expr ctx env callee in
          check_apply ctx env span "this call" ft args)

(* Validates the arguments of a call against a known signature: arity,
   unknown or duplicate named arguments, and provable type mismatches.
   Returns the result type. *)
and check_apply ctx env span what ft args : t =
  let arg_values =
    List.map
      (fun a -> (a.Ast.arg_name, check_expr ctx env a.Ast.arg_value))
      args
  in
  match ft with
  | FuncType (params, ret) ->
      let positionals = List.filter_map (fun a -> a) in
      ignore positionals;
      let seen = Hashtbl.create 4 in
      List.iter
        (fun (n, _) ->
          match n with
          | Some name ->
              if Hashtbl.mem seen name then
                report ctx span "E4009"
                  (Printf.sprintf "the argument `%s` is passed twice" name);
              Hashtbl.replace seen name ()
          | None -> ())
        arg_values;
      if List.length arg_values <> List.length params then
        report ctx span "E4009"
          (Printf.sprintf "%s expects %d argument(s), got %d" what
             (List.length params) (List.length arg_values));
      List.iter
        (fun (n, _) ->
          match n with
          | Some name ->
              if not (List.exists (fun (pn, _) -> pn = name) params) then
                report ctx span "E4009"
                  (Printf.sprintf "%s has no parameter named `%s`" what name)
          | None -> ())
        arg_values;
      (* Type conformance: positionals fill the first free slots in order,
         named arguments address their parameter. *)
      let used = Array.make (List.length params) false in
      let params = Array.of_list params in
      let free_slot () =
        let rec go i =
          if i >= Array.length params then -1
          else if used.(i) then go (i + 1)
          else i
        in
        let i = go 0 in
        if i >= 0 then used.(i) <- true;
        i
      in
      List.iter
        (fun (n, vt) ->
          let slot =
            match n with
            | Some name ->
                let rec go i =
                  if i >= Array.length params then -1
                  else if fst params.(i) = name then i
                  else go (i + 1)
                in
                let i = go 0 in
                if i >= 0 then used.(i) <- true;
                i
            | None -> free_slot ()
          in
          if slot >= 0 then
            let _, pt = params.(slot) in
            if not (conforms ctx vt pt) then
              report ctx span "E4004"
                (Printf.sprintf "argument `%s` expects %s, got %s"
                   (fst params.(slot))
                   (to_string pt) (to_string vt)))
        arg_values;
      ret
  | Unknown -> Unknown
  | ClassType c ->
      report ctx span "E4009"
        (Printf.sprintf "a class is not callable; use `%s.new`" c);
      Unknown
  | other ->
      report ctx span "E4009"
        (Printf.sprintf "%s is not callable" (to_string other));
      Unknown

(* Method calls: dispatch on the receiver's known type against the collected
   declarations; the builtin method set is typed inline. Unknown receivers
   stay unchecked. *)
and check_method_call ctx env span recv mname args : t =
  let base = check_expr ctx env recv in
  let arg_values =
    List.map
      (fun a -> (a.Ast.arg_name, check_expr ctx env a.Ast.arg_value))
      args
  in
  let none_expected result =
    if List.length args = 0 then result
    else (
      report ctx span "E4009"
        (Printf.sprintf "`%s` expects no arguments, got %d" mname
           (List.length args));
      result)
  in
  let builtin0 = none_expected in
  let one_expected result =
    if List.length args = 1 then result
    else (
      report ctx span "E4009"
        (Printf.sprintf "`%s` expects 1 argument, got %d" mname
           (List.length args));
      result)
  in
  match (base, mname) with
  | ClassType c, "new" when String.equal c "Exception" -> (
      match arg_values with
      | [ (Some "message", _) ] | [ (None, _) ] -> ClassType "Exception"
      | _ ->
          report ctx span "E4009" "`Exception.new` expects `message`";
          ClassType "Exception")
  | ClassType c, "new" -> (
      match Hashtbl.find_opt ctx.classes c with
      | Some info -> (
          match info.cinit_params with
          | Some params ->
              check_apply ctx env span (c ^ ".new")
                (FuncType (params, ClassType c))
                args
          | None ->
              if List.length args > 0 then
                report ctx span "E4009"
                  (Printf.sprintf
                     "class `%s` declares no `init`; `new` takes no arguments" c);
              ClassType c)
      | None -> Unknown)
  | ClassType _, "to_string" -> builtin0 String
  | ClassType _, "is" -> one_expected Bool
  | ClassType c, _ -> (
      match Hashtbl.find_opt ctx.classes c with
      | Some info -> (
          match List.assoc_opt mname info.cmethods with
          | Some mi ->
              check_apply ctx env span
                (c ^ "." ^ mname)
                (FuncType (mi.mparams, mi.mret))
                args
          | None ->
              report ctx span "E4001"
                (Printf.sprintf "NoMethodError: `%s` has no method `%s`" c mname);
              Unknown)
      | None -> Unknown)
  | InterfaceType _, "to_string" -> builtin0 String
  | InterfaceType _, "is" -> one_expected Bool
  | InterfaceType i, _ -> (
      match Hashtbl.find_opt ctx.interfaces i with
      | Some sigs -> (
          match List.find_opt (fun (n, _, _) -> String.equal n mname) sigs with
          | Some (_, iptypes, iret) ->
              check_apply ctx env span
                (i ^ "." ^ mname)
                (FuncType (iptypes, iret))
                args
          | None ->
              report ctx span "E4001"
                (Printf.sprintf "NoMethodError: `%s` has no method `%s`" i mname);
              Unknown)
      | None -> Unknown)
  | v, "to_string" -> builtin0 String
  | ArrayType elem, "length" ->
      builtin0
        (ignore elem;
         Int)
  | TupleType _, "length" -> builtin0 Int
  | BoxType elem, "read" -> builtin0 elem
  | BoxType elem, "replace" -> (
      let args = List.map snd arg_values in
      match args with
      | [ v ] ->
          if not (conforms ctx v elem) then
            report ctx span "E4004"
              (Printf.sprintf "`replace` expects %s, got %s" (to_string elem)
                 (to_string v));
          elem
      | _ ->
          report ctx span "E4009"
            (Printf.sprintf "`replace` expects 1 argument, got %d"
               (List.length args));
          elem)
  | _, "is" ->
      let (_ : t list) = List.map snd arg_values in
      one_expected Bool
  | Unknown, _ -> Unknown
  | v, m ->
      report ctx span "E4001"
        (Printf.sprintf "NoMethodError: `%s` has no method `%s`" (to_string v) m);
      Unknown

and check_part ctx env = function
  | Ast.Literal_text _ -> ()
  | Ast.Part_expr e -> ignore (check_expr ctx env e)

and check_binary ctx env span op l r =
  let lt = check_expr ctx env l in
  let rt = check_expr ctx env r in
  let numeric_pair_ok () =
    let is_num = function Int | Float | Unknown -> true | _ -> false in
    is_num lt && is_num rt
  in
  let result_number =
    if lt = Float || rt = Float then Float
    else if lt = Unknown || rt = Unknown then Unknown
    else Int
  in
  let mismatch expects =
    report ctx span "E4004"
      (Printf.sprintf "operator expects %s, got %s and %s" expects
         (to_string lt) (to_string rt))
  in
  match op with
  | Ast.Add ->
      (* Numbers add as numbers, strings concatenate, and an Unknown side
         stays silent unless the known side could never work. *)
      let strings = lt = String && rt = String in
      let stringish v = v = String || v = Unknown in
      if
        not
          (strings
          || (numeric_pair_ok () && not (lt = String || rt = String))
          || (stringish lt && stringish rt))
      then mismatch "two numbers or two strings";
      if strings then String else result_number
  | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
      if not (numeric_pair_ok ()) then mismatch "two numbers";
      result_number
  | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge ->
      if not (numeric_pair_ok ()) then mismatch "two numbers";
      Bool
  | Ast.Eq | Ast.Ne -> Bool
  | Ast.And | Ast.Or ->
      let check_bool_side t =
        match t with
        | Bool | Unknown -> ()
        | other ->
            report ctx span "E4004"
              (Printf.sprintf "`&&`/`||` expect Bools, got %s" (to_string other))
      in
      check_bool_side lt;
      check_bool_side rt;
      Bool

and check_stmt ctx env (s : Ast.stmt) : env =
  let span = s.Ast.stmt_span in
  match s.Ast.stmt_desc with
  | Ast.Expr_stmt e ->
      ignore (check_expr ctx env e);
      env
  | Ast.Binding { mutable_; name; init } -> (
      let t = check_expr ctx env init in
      match lookup_env env name with
      | Some existing when existing.depth = env.depth ->
          (* Rebinding in the same scope: drift is an error only when the
             earlier type is known and the new one provably breaks it. *)
          if (not (conforms ctx t existing.vtype)) && existing.vtype <> Unknown
          then
            report ctx span "E4004"
              (Printf.sprintf "`%s` was bound as %s, this rebinds it as %s" name
                 (to_string existing.vtype) (to_string t));
          bind env name { existing with vtype = t }
      | _ -> bind env name { vtype = t; is_var = mutable_; depth = env.depth })
  | Ast.Assign { target; value } -> (
      let vt = check_expr ctx env value in
      match target.Ast.desc with
      | Ast.Ident name -> (
          match lookup_env env name with
          | Some info when info.is_var ->
              if not (conforms ctx vt info.vtype) then
                report ctx span "E4004"
                  (Printf.sprintf "cannot assign %s to the %s variable `%s`"
                     (to_string vt) (to_string info.vtype) name);
              env
          | Some info ->
              report ctx span "E4007"
                (Printf.sprintf "cannot assign to `%s`; it is a const" name);
              env
          | None ->
              report ctx span "E4003"
                (Printf.sprintf "`%s` is not defined" name);
              env)
      | _ -> env (* field assignment: constructor-only, parser-checked *))
  | Ast.Return None -> env
  | Ast.Return (Some e) ->
      let t = check_expr ctx env e in
      ctx.ret_sink := t :: !(ctx.ret_sink);
      (match env.ret with
      | Some expected when t <> Unknown && expected <> Unknown ->
          if not (conforms ctx t expected) then
            report ctx e.Ast.span "E4008"
              (Printf.sprintf "return type mismatch: expected %s, got %s"
                 (to_string expected) (to_string t))
      | _ -> ());
      env
  | Ast.If { cond; then_body; else_body } ->
      let ct = check_expr ctx env cond in
      (match ct with
      | Bool | Unknown -> ()
      | other ->
          report ctx cond.Ast.span "E4004"
            (Printf.sprintf "the `if` condition must be a Bool, got %s"
               (to_string other)));
      (* Flow narrowing: `if x.is(T)` gives x the type T inside the then
         branch; the else branch keeps the pre-test type, and neither leaks
         past the if. *)
      let narrowed =
        match cond.Ast.desc with
        | Ast.Call
            ( { Ast.desc = Ast.Member (recv, "is"); _ },
              [ { Ast.arg_value = { Ast.desc = Ast.Type_ident tname; _ }; _ } ]
            )
          when match recv.Ast.desc with Ast.Ident _ -> true | _ -> false ->
            let target_type = resolve_type_name ctx recv.Ast.span tname in
            let rt = check_expr ctx env recv in
            (match rt with
            | (ClassType _ | EnumType _ | Int | Float | Bool | Char | String)
              when provably_excluded ctx rt target_type ->
                report ctx recv.Ast.span "E4011"
                  (Printf.sprintf "`%s` can never narrow to %s" (to_string rt)
                     (to_string target_type))
            | _ -> ());
            Some
              ( (match recv.Ast.desc with Ast.Ident n -> n | _ -> ""),
                target_type )
        | Ast.Call ({ Ast.desc = Ast.Member (recv, "is"); _ }, target :: _) ->
            ignore (check_expr ctx env target.Ast.arg_value);
            None
        | _ -> None
      in
      let then_env =
        match narrowed with
        | Some (name, t) ->
            let is_var =
              match lookup_env env name with
              | Some info -> info.is_var
              | None -> false
            in
            bind (child_scope env) name
              { vtype = t; is_var; depth = env.depth + 1 }
        | None -> child_scope env
      in
      let (_ : env) =
        List.fold_left (fun env s -> check_stmt ctx env s) then_env then_body
      in
      Option.iter
        (fun body ->
          let else_env = child_scope env in
          let (_ : env) =
            List.fold_left (fun env s -> check_stmt ctx env s) else_env body
          in
          ())
        else_body;
      env
  | Ast.Case { scrutinee; branches } ->
      let st = check_expr ctx env scrutinee in
      List.iter
        (fun b ->
          let inner = child_scope env in
          let inner =
            check_pattern ctx inner scrutinee.Ast.span st b.Ast.pattern
          in
          Option.iter
            (fun g ->
              let gt = check_expr ctx inner g in
              match gt with
              | Bool | Unknown -> ()
              | other ->
                  report ctx g.Ast.span "E4004"
                    (Printf.sprintf "a `when` guard must be a Bool, got %s"
                       (to_string other)))
            b.Ast.guard;
          let (_ : env) =
            List.fold_left (fun env s -> check_stmt ctx env s) inner b.Ast.body
          in
          ())
        branches;
      check_exhaustive ctx scrutinee.Ast.span st branches;
      env
  | Ast.Receive _ | Ast.Send _ -> env (* processes: step 11 *)
  | Ast.Raise e ->
      ignore (check_expr ctx env e);
      env

(* Checks one pattern against the scrutinee's type when decidable, binding
   pattern variables. Returns the environment for the branch body. *)
and check_pattern ctx env span scrutinee_t (p : Ast.pattern) : env =
  let mismatch what =
    report ctx p.Ast.pattern_span "E4013"
      (Printf.sprintf "a %s pattern cannot match %s" what
         (to_string scrutinee_t))
  in
  match p.Ast.pattern_desc with
  | Ast.Wildcard -> env
  | Ast.Pattern_binding name ->
      bind env name { vtype = scrutinee_t; is_var = false; depth = env.depth }
  | Ast.Pattern_literal l -> (
      let lt = literal_type l in
      match scrutinee_t with
      | Unknown -> env
      | t when conforms ctx lt t -> env
      | _ ->
          mismatch (String.lowercase_ascii (to_string lt));
          env)
  | Ast.Enum_member (t, m) -> (
      match scrutinee_t with
      | EnumType e ->
          (if not (String.equal t e) then
             report ctx p.Ast.pattern_span "E4013"
               (Printf.sprintf "`%s.%s` cannot match %s" t m
                  (to_string scrutinee_t))
           else
             match Hashtbl.find_opt ctx.enums t with
             | Some members when not (List.mem m members) ->
                 report ctx p.Ast.pattern_span "E4013"
                   (Printf.sprintf "enum `%s` has no member `%s`" t m)
             | _ -> ());
          env
      | Unknown -> env
      | _ ->
          mismatch "qualified enum member";
          env)
  | Ast.Tuple_pattern ps -> (
      match scrutinee_t with
      | TupleType ts ->
          if List.length ps <> List.length ts then
            report ctx p.Ast.pattern_span "E4013"
              (Printf.sprintf "a %d-element tuple pattern cannot match %s"
                 (List.length ps) (to_string scrutinee_t));
          let env =
            List.fold_left2
              (fun env pat t -> check_pattern ctx env span t pat)
              env ps ts
          in
          env
      | Unknown ->
          List.iter
            (fun pat -> ignore (check_pattern ctx env span Unknown pat))
            ps;
          env
      | _ ->
          mismatch "tuple";
          env)

(* What a pattern covers of an enum scrutinee: everything, or specific
   members; tuple patterns contribute their first element's coverage. *)
and pattern_coverage scrutinee_t (p : Ast.pattern) : coverage =
  let first_members d =
    match d with
    | Ast.Enum_member (t, m) -> (
        match scrutinee_t with
        | EnumType e when String.equal t e -> Members [ m ]
        | _ -> Members [])
    | Ast.Wildcard | Ast.Pattern_binding _ -> All
    | _ -> Members []
  in
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> All
  | Ast.Tuple_pattern (first :: _) -> first_members first.Ast.pattern_desc
  | _ -> Members []

(* Exhaustiveness: a decidable enum scrutinee needs every member covered by
   an unguarded branch (or `_`); a decidable `(SomeEnum, ...)` tuple is
   checked through its first-element patterns. Guarded branches never
   count — their `when` may be false. *)
and check_exhaustive ctx span scrutinee_t (branches : Ast.branch list) : unit =
  let unguarded = List.filter (fun b -> b.Ast.guard = None) branches in
  let coverings =
    List.map (fun b -> pattern_coverage scrutinee_t b.Ast.pattern) unguarded
  in
  let covers_all = List.exists (fun c -> c = All) coverings in
  let covered =
    List.concat_map (function All -> [] | Members ms -> ms) coverings
  in
  let check_enum members =
    if not covers_all then
      match List.filter (fun m -> not (List.mem m covered)) members with
      | [] -> ()
      | missing ->
          report ctx span "E4014"
            (Printf.sprintf "this `case` is missing %s"
               (String.concat ", " missing))
  in
  match scrutinee_t with
  | EnumType e -> (
      match Hashtbl.find_opt ctx.enums e with
      | Some members -> check_enum members
      | None -> ())
  | TupleType (EnumType e :: _) -> (
      match Hashtbl.find_opt ctx.enums e with
      | Some members -> check_enum members
      | None -> ())
  | _ -> ()

let signature_of_def ctx (d : Ast.fun_def) : t =
  FuncType
    ( List.map
        (fun p -> (p.Ast.param_name, ann_to_type ctx p.Ast.param_type))
        d.Ast.def_params,
      match d.Ast.def_return with
      | Some r -> ann_to_type ctx r
      | None -> Unknown )

(* Signature checks: the body runs under the declared parameter types with
   the declared return type as the target; `init` is exempt (it returns the
   class it constructs). *)
let check_fun_def ctx env ?self ?(prebound = []) (d : Ast.fun_def) : unit =
  let frame =
    {
      (child_scope env) with
      ret = Option.map (ann_to_type ctx) d.Ast.def_return;
      block_depth = -1;
    }
  in
  let frame =
    List.fold_left
      (fun env (n, t) ->
        bind env n { vtype = t; is_var = false; depth = env.depth })
      frame prebound
  in
  let frame =
    match self with
    | Some (name, t) ->
        bind frame name { vtype = t; is_var = false; depth = frame.depth }
    | None -> frame
  in
  let frame =
    List.fold_left
      (fun env p ->
        bind env p.Ast.param_name
          {
            vtype = ann_to_type ctx p.Ast.param_type;
            is_var = false;
            depth = frame.depth;
          })
      frame d.Ast.def_params
  in
  ignore
    (List.fold_left (fun env s -> check_stmt ctx env s) frame d.Ast.def_body)

(* Class bodies: every method is checked under its signature with self
   bound to the class. *)
let check_class ctx env (c : Ast.class_def) : unit =
  let info = Hashtbl.find ctx.classes c.Ast.class_name in
  let self = ("self", ClassType c.Ast.class_name) in
  (* Method signatures are pre-bound so methods can call each other. *)
  let prebound =
    List.map (fun (n, mi) -> (n, FuncType (mi.mparams, mi.mret))) info.cmethods
  in
  Option.iter
    (fun init -> check_fun_def ctx env ~self ~prebound init)
    c.Ast.class_init;
  List.iter
    (fun m -> check_fun_def ctx env ~self ~prebound m)
    c.Ast.class_methods

(* Checks the statement items of a program; declarations register into the
   environment in source order. *)
let check_items ctx (items : Ast.item list) : unit =
  ignore
    (List.fold_left
       (fun env item ->
         match item.Ast.item_desc with
         | Ast.Item_stmt s -> check_stmt ctx env s
         | Ast.Item_def d ->
             let ft = signature_of_def ctx d in
             (* The signature binds before the body: recursion works. *)
             let env =
               bind env d.Ast.def_name
                 { vtype = ft; is_var = false; depth = env.depth }
             in
             check_fun_def ctx env d;
             env
         | Ast.Item_class c ->
             check_class ctx env c;
             env
         | _ -> env)
       empty_env items)

let sort_diagnostics diagnostics =
  List.sort
    (fun a b ->
      let open Emo_support.Diagnostic in
      let open Emo_support.Span in
      compare
        (a.span.line, a.span.col, a.span.start)
        (b.span.line, b.span.col, b.span.start))
    diagnostics

(* Checks one module's items with the project's module table: unbound names
   that address modules resolve silently, qualified references are recorded.
   Returns the diagnostics and the referenced module paths. *)
let check_module ~(modules : string list list) ~(current : string list)
    (items : Ast.item list) : Emo_support.Diagnostic.t list * string list list =
  let ctx =
    {
      file = String.concat "." current;
      classes = Hashtbl.create 8;
      interfaces = Hashtbl.create 8;
      enums = Hashtbl.create 8;
      funcs = Hashtbl.create 8;
      diagnostics = ref [];
      ret_sink = ref [];
      modules;
      current;
      refs = ref [];
    }
  in
  collect ctx items;
  if List.length !(ctx.diagnostics) = 0 then check_items ctx items;
  (sort_diagnostics (List.rev !(ctx.diagnostics)), List.rev !(ctx.refs))

(* Checks pre-parsed items without module context. Every diagnostic found,
   sorted by position. *)
let check_parsed (items : Ast.item list) : Emo_support.Diagnostic.t list =
  let diagnostics, _refs = check_module ~modules:[] ~current:[] items in
  diagnostics

let check_source ~file ~(source : string) : Emo_support.Diagnostic.t list =
  let ctx, items = analyze ~file ~source in
  if List.length !(ctx.diagnostics) = 0 then check_items ctx items;
  let diagnostics = List.rev !(ctx.diagnostics) in
  List.sort
    (fun a b ->
      let open Emo_support.Diagnostic in
      let open Emo_support.Span in
      compare
        (a.span.line, a.span.col, a.span.start)
        (b.span.line, b.span.col, b.span.start))
    diagnostics
