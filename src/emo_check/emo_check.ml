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
  | FuncType of t list * t

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
      "(" ^ String.concat ", " (List.map to_string ps) ^ ") -> " ^ to_string r

type method_info = { mparams : t list; mret : t; mdef : Ast.fun_def }

type class_info = {
  cname : string;
  cmethods : (string * method_info) list;
  cfields : string list;
}

type ctx = {
  file : string;
  classes : (string, class_info) Hashtbl.t;
  interfaces : (string, (string * t list * t) list) Hashtbl.t;
  enums : (string, string list) Hashtbl.t;
  funcs : (string, Ast.fun_def) Hashtbl.t;
  diagnostics : Emo_support.Diagnostic.t list ref;
  mutable ret_sink : t list ref;
      (* while checking an arrow block, its return types land here *)
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
                        (fun p -> ann_to_type ctx p.Ast.param_type)
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
              cmethods = methods;
              cfields = List.map (fun f -> f.Ast.field_name) c.Ast.class_fields;
            }
      | Ast.Item_interface i ->
          let sigs =
            List.map
              (fun s ->
                ( s.Ast.sig_name,
                  List.map
                    (fun p -> ann_to_type ctx p.Ast.param_type)
                    s.Ast.sig_params,
                  ann_to_type ctx s.Ast.sig_return ))
              i.Ast.interface_methods
          in
          Hashtbl.replace ctx.interfaces i.Ast.interface_name sigs
      | Ast.Item_enum e ->
          Hashtbl.replace ctx.enums e.Ast.enum_name
            (List.map (fun m -> m.Ast.member_name) e.Ast.enum_members)
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
type env = { bindings : (string * var_info) list; depth : int; ret : t option }

(* The built-in surface every program sees. *)
let empty_env =
  {
    bindings =
      [
        ( "print",
          { vtype = FuncType ([ Unknown ], Unknown); is_var = false; depth = 0 }
        );
        ("Box", { vtype = Unknown; is_var = false; depth = 0 });
        ( "Exception",
          { vtype = ClassType "Exception"; is_var = false; depth = 0 } );
      ];
    depth = 0;
    ret = None;
  }

let lookup_env env name = List.assoc_opt name env.bindings
let bind env name info = { env with bindings = (name, info) :: env.bindings }

let child_scope env =
  { env with bindings = env.bindings; depth = env.depth + 1 }

(* [conforms actual expected] — the gradual conformance relation. Unknown on
   either side silences the check; a known mismatch is provable. *)
let rec conforms actual expected =
  match (actual, expected) with
  | _, Unknown | Unknown, _ -> true
  | Int, Float -> true
  | ClassType a, ClassType b -> String.equal a b
  | EnumType a, EnumType b -> String.equal a b
  | ArrayType a, ArrayType b -> conforms a b
  | BoxType a, BoxType b -> conforms a b
  | TupleType as_, TupleType bs ->
      List.length as_ = List.length bs && List.for_all2 conforms as_ bs
  | FuncType (pa, ra), FuncType (pb, rb) ->
      List.length pa = List.length pb
      && List.for_all2 (fun b a -> conforms a b) pb pa
      && conforms ra rb
  | InterfaceType _, _ | _, InterfaceType _ -> true (* structural check: T8.5 *)
  | a, b -> a = b

let known_nonovoid = ignore

(* Type-name resolution for `is()` targets; unknown names narrow to nothing. *)
let resolve_type_name ctx span name =
  if Hashtbl.mem ctx.classes name then ClassType name
  else if Hashtbl.mem ctx.interfaces name then InterfaceType name
  else if Hashtbl.mem ctx.enums name then EnumType name
  else (
    ignore span;
    Unknown)

(* True when a value of [rt] can provably never satisfy a check for [target]. *)
let provably_excluded rt target =
  match (rt, target) with
  | Unknown, _ | _, Unknown -> false
  | Int, _ | Float, _ | Bool, _ | Char, _ | String, _ -> true
  | ClassType a, ClassType b -> not (String.equal a b)
  | ClassType _, InterfaceType _ -> false (* structural check: T8.5 *)
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
      | Some info -> info.vtype
      | None ->
          report ctx span "E4003" (Printf.sprintf "`%s` is not defined" name);
          Unknown)
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
            if List.for_all (conforms first) rest then first else Unknown
      in
      ArrayType unified
  | Ast.Arrow_block (params, body) ->
      let param_types =
        List.map (fun p -> ann_to_type ctx p.Ast.param_type) params
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
          (child_scope env) params
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
            if List.for_all (conforms first) rest then first else Unknown
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
  | Ast.Call (callee, args) -> (
      List.iter (fun a -> ignore (check_expr ctx env a.Ast.arg_value)) args;
      match callee.Ast.desc with
      | Ast.Member _ -> Unknown (* method calls: T8.7 *)
      | _ ->
          let ft = check_expr ctx env callee in
          ignore ft;
          Unknown (* call-site checks: T8.7 *))
  | Ast.Do operand ->
      ignore (check_expr ctx env operand);
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
  let result_number = if lt = Float || rt = Float then Float else Int in
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
          if (not (conforms t existing.vtype)) && existing.vtype <> Unknown then
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
              if not (conforms vt info.vtype) then
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
          if not (conforms t expected) then
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
              when provably_excluded rt target_type ->
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
      List.iter (fun s -> ignore (check_stmt ctx then_env s)) then_body;
      Option.iter
        (fun body ->
          let else_env = child_scope env in
          List.iter (fun s -> ignore (check_stmt ctx else_env s)) body)
        else_body;
      env
  | Ast.Case { scrutinee; branches } ->
      ignore (check_expr ctx env scrutinee);
      (* Pattern checks and exhaustiveness: T8.8. *)
      List.iter
        (fun b ->
          let inner = child_scope env in
          ignore (check_pattern ctx inner b.Ast.pattern);
          Option.iter (fun g -> ignore (check_expr ctx inner g)) b.Ast.guard;
          List.iter (fun s -> ignore (check_stmt ctx inner s)) b.Ast.body)
        branches;
      env
  | Ast.Receive _ | Ast.Send _ -> env (* processes: step 11 *)
  | Ast.Raise e ->
      ignore (check_expr ctx env e);
      env

and check_pattern ctx env (_p : Ast.pattern) : unit = ()

let signature_of_def ctx (d : Ast.fun_def) : t =
  FuncType
    ( List.map (fun p -> ann_to_type ctx p.Ast.param_type) d.Ast.def_params,
      match d.Ast.def_return with
      | Some r -> ann_to_type ctx r
      | None -> Unknown )

(* Signature checks: the body runs under the declared parameter types with
   the declared return type as the target; `init` is exempt (it returns the
   class it constructs). *)
let check_fun_def ctx env ?self (d : Ast.fun_def) : unit =
  let frame =
    {
      (child_scope env) with
      ret = Option.map (ann_to_type ctx) d.Ast.def_return;
    }
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
  List.iter (fun s -> ignore (check_stmt ctx frame s)) d.Ast.def_body

let check_class ctx env (c : Ast.class_def) : unit =
  let self = ("self", ClassType c.Ast.class_name) in
  Option.iter (fun init -> check_fun_def ctx env ~self init) c.Ast.class_init;
  List.iter (fun m -> check_fun_def ctx env ~self m) c.Ast.class_methods

(* Checks the statement items of a program; declarations register into the
   environment in source order. *)
let check_items ctx (items : Ast.item list) : unit =
  ignore
    (List.fold_left
       (fun env item ->
         match item.Ast.item_desc with
         | Ast.Item_stmt s -> check_stmt ctx env s
         | Ast.Item_def d ->
             check_fun_def ctx env d;
             bind env d.Ast.def_name
               {
                 vtype = signature_of_def ctx d;
                 is_var = false;
                 depth = env.depth;
               }
         | Ast.Item_class c ->
             check_class ctx env c;
             env
         | _ -> env)
       empty_env items)

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
