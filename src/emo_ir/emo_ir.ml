module Ast = Emo_ast

(* The mid-level IR: modules of named functions over typed values, with
   tagged-dynamic fallbacks. Every backend lowers from this IR — never
   from the AST again.

   Types are the checker's own [Emo_check.t]: every expression carries the
   type step 09 gave it, and [Unknown] marks the dynamic regions. A
   function whose parameters, result, and body are entirely native
   ([fspecializable]) is Stage B's specialization target; everything else
   keeps dynamic semantics at its Unknown regions. *)

type expr = { ety : Emo_check.t; desc : expr_desc }

and expr_desc =
  | Const of Emo_ast.literal
  | Type_ref of string (* a type name in value position: `is` targets *)
  | Var of string (* a local binding, or `self` *)
  | Global of string (* a mangled program-wide def *)
  | Tuple of expr list
  | Array_lit of expr list
  | Map_lit of expr list (* (key, value) tuple pairs, in insertion order *)
  | Make_enum of { enum_name : string; member : string }
  | Interpolate of expr list
  | Unary of Emo_ast.unop * expr
  | Binary of Emo_ast.binop * expr * expr
  | Cond of { c : expr; t : expr; e : expr } (* the one-line if expression *)
  | Index of expr * expr
  | Field_read of { obj : expr; name : string }
  | Call of { func : string; args : expr list } (* resolved static call *)
  | Call_value of { f : expr; args : expr list } (* first-class blocks *)
  | Method of { self_ : expr; name : string; args : expr list }
  | Builtin of { name : string; args : expr list }
  | Box_new of expr
  | Global_var of string (* a module-level `var`, read *)
  | Bytes_new of expr (* Bytes.new(n) — a zero-filled byte buffer *)
  | List_new of expr (* List.new(array) — a fresh deque over the elements *)
  | Builder_new (* ArrayBuilder.new() — a fresh empty growable array builder *)
  | Make_exception of { message : expr; data : expr option }
  | Do_spawn of { func : string; args : expr list }
  | Spawn_value of { f : expr; args : expr list }
  | Closure of { cparams : (string * Emo_check.t) list; cbody : stmt list }

and stmt =
  | Effect of expr (* an expression run for its effect *)
  | Let of { mutable_ : bool; name : string; init : expr }
  | Assign_var of { name : string; value : expr } (* a `var`, in scope *)
  | Set_global_var of { name : string; value : expr } (* a module-level `var` *)
  | Set_field of { self_ : expr; name : string; value : expr }
  | If of { cond : expr; then_ : stmt list; else_ : stmt list }
  | While of { cond : expr; body : stmt list }
  | For of {
      init : stmt; (* the header `var` — scoped to the loop *)
      cond : expr;
      post : stmt; (* the header assignment — the loop's one update step *)
      body : stmt list;
    }
  | Break
  | Continue
  | Case of { scrutinee : expr; branches : branch list }
  | Receive of { branches : branch list }
  | Send of { target : expr; message : expr }
  | Raise of expr
  | Return_stmt of expr

and branch = {
  pattern : Emo_ast.pattern;
  guard : expr option;
  body : stmt list;
}

type func = {
  fname : string; (* mangled, program-unique *)
  fmodule : string list;
  fparams : (string * Emo_check.t) list;
  fresult : Emo_check.t;
  fbody : stmt list;
  fspecializable : bool; (* Stage B: every value in the body is native *)
  fforeign : string option; (* the C symbol for `foreign def` bindings *)
}

type class_ = {
  cname : string; (* mangled *)
  cdisplay : string; (* the source name *)
  cinit : func option; (* constructs the object; [self] is its first param *)
  cmethods : func list; (* [self] is each method's first param *)
}

type program = {
  pfuncs : func list;
  pclasses : class_ list;
  pinterfaces : (string * (string * int) list) list;
      (* interface name → method name/arity, for the runtime's is() *)
  piface_sigs :
    (string * (string * (string * Emo_check.t) list * Emo_check.t) list) list;
      (* interface name → full method signatures — param names and types
         plus the return type — for the c target's callback trampolines
         (CHECK.md, 2026-10-11) *)
  pinit : stmt list; (* the entry module's top-level statements *)
  pglobals : (string * expr) list; (* module-level `var` ref cells *)
  pentry : string list; (* the entry module's path *)
}

(* Raised when the lowerer meets something the checker admitted but the
   IR does not model. *)
exception Lower_error of string

(* ---- Mangling: module path × name → one program-unique identifier. ---- *)

(* A module's file name may carry a hyphen (`instance-fixture`), which no
   backend identifier can; module-path components go through this. *)
let sanitize_component (s : string) : string =
  String.map (fun c -> if c = '-' then '_' else c) s

let mangle (module_path : string list) (name : string) : string =
  String.concat "__" (List.map sanitize_component module_path @ [ name ])

(* Predicate methods end in `?`, which backend identifiers cannot
   carry; the mangled function name normalizes it. *)
let sanitize_ident (name : string) : string =
  if String.contains name '?' then
    String.concat "_q" (String.split_on_char '?' name)
  else name

(* ---- The lowering ---- *)

type module_input = {
  mpath : string list;
  mitems : Emo_ast.item list;
  mtypes : (string * int * int, Emo_check.t) Hashtbl.t;
      (* span start/stop → checked type *)
}

(* One program-wide symbol: a def, a class, or an enum. *)
type symbol =
  | S_func of { mangled : string; params : string list }
  | S_class of { mangled : string; params : string list } (* init's params *)
  | S_interface (* a declared interface, a type reference *)
  | S_global of { gname : string } (* a module-level `var` *)
  | S_enum

type env = {
  symbols : (string list * string, symbol) Hashtbl.t; (* module path × name *)
  current : string list;
  mutable locals : string list; (* innermost first *)
  types : (string * int * int, Emo_check.t) Hashtbl.t;
  module_paths : string list list; (* every module in the program *)
  packages : string list list;
      (* the short-name prefix of every fetched package *)
  mutable aliases : (string * string list) list;
      (* `const order = shop.order` — a name bound to a module path *)
}

let is_builtin = function
  | "println" | "printf" | "self_pid" | "halt" -> true
  | name ->
      (String.length name >= 4 && String.sub name 0 4 = "net_")
      || (String.length name >= 5 && String.sub name 0 5 = "file_")
      || (String.length name >= 3 && String.sub name 0 3 = "os_")
      || (String.length name >= 7 && String.sub name 0 7 = "expect_")

let type_of env (span : Emo_support.Span.t) : Emo_check.t =
  match
    Hashtbl.find_opt env.types
      ( span.Emo_support.Span.file,
        span.Emo_support.Span.start,
        span.Emo_support.Span.stop )
  with
  | Some t -> t
  | None -> Emo_check.Unknown

let rec mk env span desc : expr = { ety = type_of env span; desc }

and lookup_symbol env (path : string list) (name : string) : symbol option =
  Hashtbl.find_opt env.symbols (path, name)

(* The dotted chain of an expression that addresses a module member, if
   any: [shop.order.total] → (["shop"; "order"], "total"). *)
and dotted_path (e : Ast.expr) : (string list * string) option =
  let rec go e =
    match e.Ast.desc with
    | Ast.Ident name -> Some ([ name ], true)
    | Ast.Type_ident name -> Some ([ name ], true)
    | Ast.Member (inner, name) -> (
        match go inner with
        | Some (path, _plain) -> Some (path @ [ name ], false)
        | None -> None)
    | _ -> None
  in
  match go e with
  | Some (path, false) ->
      let module_path = List.rev (List.tl (List.rev path)) in
      let name = List.hd (List.rev path) in
      if module_path = [] then None else Some (module_path, name)
  | _ -> None

(* The full segment chain of a dotted expression: [shop.order.total] →
   ["shop"; "order"; "total"]. *)
and full_chain (e : Ast.expr) : string list option =
  let rec go e =
    match e.Ast.desc with
    | Ast.Ident name -> Some [ name ]
    | Ast.Type_ident name -> Some [ name ]
    | Ast.Member (inner, name) ->
        Option.map (fun path -> path @ [ name ]) (go inner)
    | _ -> None
  in
  go e

(* ---- Type references ---- *)
(* A type reference written at a use site: the last dotted segment names
   the type, every segment before it a module (bare means the current
   module). Resolves to (declaring module path, qualified display name,
   symbol). *)
and resolve_type_ref env (ref_ : string) :
    (string list * string * symbol) option =
  let mod_path, name =
    match List.rev (String.split_on_char '.' ref_) with
    | name :: rev_mod -> (List.rev rev_mod, name)
    | [] -> ([], ref_)
  in
  let abs =
    if mod_path = [] then env.current
    else relativize env (substitute_alias env mod_path)
  in
  match Hashtbl.find_opt env.symbols (abs, name) with
  | Some (S_class _ as s) -> Some (abs, qualify_name abs name, s)
  | Some (S_enum as s) -> Some (abs, qualify_name abs name, s)
  | Some (S_interface as s) -> Some (abs, qualify_name abs name, s)
  | _ -> (
      (* The built-in `R` enum (seeded with no module) and `Exception`
         keep their bare names. *)
      match Hashtbl.find_opt env.symbols ([], name) with
      | Some (S_enum as s) -> Some ([], name, s)
      | _ -> if name = "Exception" then Some ([], name, S_interface) else None)

and qualify_name (abs : string list) (name : string) : string =
  String.concat "." (abs @ [ name ])

(* The qualified display name a type reference resolves to; the written
   reference when nothing declares it. *)
and type_display env (ref_ : string) : string =
  match resolve_type_ref env ref_ with Some (_, q, _) -> q | None -> ref_

(* The class a `.new` receiver names, bare or module-qualified. *)
and resolve_class env (recv : Ast.expr) : (string * string list) option =
  match full_chain recv with
  | Some chain -> (
      let name = List.hd (List.rev chain) in
      match resolve_type_ref env (String.concat "." chain) with
      | Some (abs, _, _) -> (
          match Hashtbl.find_opt env.symbols (abs, name) with
          | Some (S_class { mangled; params }) -> Some (mangled, params)
          | _ -> None)
      | None -> None)
  | None -> None

(* Substitutes a leading module alias: [order.total] with [order ↔
   shop.order] becomes (["shop"; "order"], "total"). *)
and is_module_path env (path : string list) : bool =
  List.exists (fun m -> m = path) env.module_paths

and substitute_alias env (path : string list) : string list =
  match path with
  | head :: rest -> (
      match List.assoc_opt head env.aliases with
      | Some target -> target @ rest
      | None -> path)
  | [] -> []

(* A reference inside a package is written against the package root
   (`internal.float` in `json.emo`), so resolve it under the current
   package's prefix when the prefixed path is a known module. An already
   absolute path is left alone. *)
and relativize_in ~(current : string list) ~(packages : string list list)
    ~(module_paths : string list list) (path : string list) : string list =
  let rec pkg_of = function
    | [] -> []
    | pkg :: rest ->
        if
          List.length pkg <= List.length current
          && List.take (List.length pkg) current = pkg
        then pkg
        else pkg_of rest
  in
  match pkg_of packages with
  | [] -> path
  | pkg ->
      (* Prefix, not exact: the relative path may name a directory module
         (`internal`) whose defs live one segment deeper. *)
      let prefixed = pkg @ path in
      if
        List.exists
          (fun m ->
            List.length prefixed <= List.length m
            && List.take (List.length prefixed) m = prefixed)
          module_paths
      then prefixed
      else path

and relativize env (path : string list) : string list =
  relativize_in ~current:env.current ~packages:env.packages
    ~module_paths:env.module_paths path

(* Reorders named/positional arguments into the callee's parameter order —
   positionals fill the first free slots left to right, named arguments
   address their parameters (the evaluator's [bind_params] rule). The
   checker has already validated arity and names. *)
and order_args env params args =
  let named =
    List.filter_map
      (fun { Ast.arg_name; arg_value } ->
        match arg_name with Some n -> Some (n, arg_value) | None -> None)
      args
  in
  let positional = Queue.create () in
  List.iter
    (fun { Ast.arg_name; arg_value } ->
      match arg_name with
      | None -> Queue.push arg_value positional
      | Some _ -> ())
    args;
  List.map
    (fun param ->
      match List.assoc_opt param named with
      | Some arg -> lower_expr env arg
      | None ->
          if Queue.is_empty positional then
            failwith
              (Printf.sprintf
                 "order_args: no positional for parameter `%s` (params: %s)"
                 param
                 (String.concat ", " params));
          lower_expr env (Queue.pop positional))
    params

and lower_expr env (e : Ast.expr) : expr =
  let expr desc = mk env e.Ast.span desc in
  match e.Ast.desc with
  | Ast.Int64 n -> expr (Const (L_int n))
  | Ast.Byte n -> expr (Const (L_byte n))
  | Ast.Float f -> expr (Const (L_float f))
  | Ast.Bool b -> expr (Const (L_bool b))
  | Ast.Char c -> expr (Const (L_char c))
  | Ast.String s -> expr (Const (L_string s))
  | Ast.Interpolated parts ->
      expr
        (Interpolate
           (List.map
              (function
                | Ast.Literal_text s ->
                    { ety = Emo_check.String; desc = Const (L_string s) }
                | Ast.Part_expr part -> lower_expr env part)
              parts))
  | Ast.Ident name -> (
      if List.mem name env.locals then expr (Var name)
      else
        match lookup_symbol env env.current name with
        | Some (S_func { mangled; params }) when params = [] ->
            (* A const binding (e.g. `const order = shop.order`): calling
               the zero-arg function evaluates it. *)
            {
              ety = Emo_check.Unknown;
              desc = Call { func = mangled; args = [] };
            }
        | Some (S_func { mangled; _ }) | Some (S_class { mangled; _ }) ->
            expr (Global mangled)
        | Some (S_global { gname }) -> expr (Global_var gname)
        | Some S_interface ->
            { ety = Emo_check.Unknown; desc = Type_ref (type_display env name) }
        | Some S_enum ->
            let q = type_display env name in
            { ety = Emo_check.EnumType q; desc = Type_ref q }
        | None when is_builtin name -> expr (Builtin { name; args = [] })
        | None -> { ety = Emo_check.Unknown; desc = Type_ref name })
  | Ast.Type_ident name ->
      { ety = type_of env e.Ast.span; desc = Type_ref (type_display env name) }
  | Ast.Self -> expr (Var "self")
  | Ast.Member (inner, name) -> (
      (* A dotted path: a module member (def, class, enum member), or a
         field read on a value — the symbol table tells them apart. The
         lookup key is (everything before the member, the member): the
         prefix is a module path for defs and classes, and the type's own
         name for enum members. *)
      match dotted_path e with
      | None ->
          {
            ety = type_of env e.Ast.span;
            desc = Field_read { obj = lower_expr env inner; name };
          }
      | Some (path, member) -> (
          (* A def, class, or enum member: (module path, member name).
             An enum member's enum is the path before the member —
             `Color.red`, or `pkg.Color.red`. *)
          let path = relativize env path in
          match Hashtbl.find_opt env.symbols (path, member) with
          | Some (S_func { mangled; params }) when params = [] ->
              (* A const binding: calling the zero-arg function
                 evaluates it. *)
              expr (Call { func = mangled; args = [] })
          | Some (S_func { mangled; _ }) -> expr (Global mangled)
          | Some (S_class _) ->
              (* A class in value position — an `is()` target. *)
              expr (Type_ref (qualify_name path member))
          | _ -> (
              match resolve_type_ref env (String.concat "." path) with
              | Some (_, q, S_enum) ->
                  expr (Make_enum { enum_name = q; member })
              | _ ->
                  {
                    ety = type_of env e.Ast.span;
                    desc = Field_read { obj = lower_expr env inner; name };
                  })))
  | Ast.Index (base, index) ->
      expr (Index (lower_expr env base, lower_expr env index))
  | Ast.Call (callee, args) -> lower_call env e.Ast.span callee args
  | Ast.Arrow_block (params, body) ->
      {
        ety = Emo_check.Unknown;
        desc =
          Closure
            {
              cparams =
                List.map (fun p -> (p.Ast.param_name, Emo_check.Unknown)) params;
              cbody = lower_scoped env params body;
            };
      }
  | Ast.Unary (op, x) -> expr (Unary (op, lower_expr env x))
  | Ast.Binary (op, l, r) ->
      expr (Binary (op, lower_expr env l, lower_expr env r))
  | Ast.If_expr { cond; then_expr; else_expr } ->
      expr
        (Cond
           {
             c = lower_expr env cond;
             t = lower_expr env then_expr;
             e = lower_expr env else_expr;
           })
  | Ast.Tuple es -> expr (Tuple (List.map (lower_expr env) es))
  | Ast.Array_literal es -> expr (Array_lit (List.map (lower_expr env) es))
  | Ast.Map_literal entries ->
      expr (Map_lit (List.map (lower_pair env) entries))
  | Ast.Do operand -> (
      match operand.Ast.desc with
      | Ast.Call (callee, args) -> (
          match resolve_callee env callee with
          | Some (mangled, params) ->
              expr
                (Do_spawn { func = mangled; args = order_args env params args })
          | None ->
              let f, arg_exprs = lower_apply env operand in
              expr (Spawn_value { f; args = arg_exprs }))
      | _ -> raise (Lower_error "`do` lowers from a call only"))

(* One map entry lowers to a (key, value) pair. The parser's literal hands
   over the pair directly; `Map.new`'s argument is a two-element tuple the
   checker already admitted, and the lowering rebuilds it so both spellings
   share one shape. *)
and lower_pair env ((key, value) : Ast.expr * Ast.expr) : expr =
  {
    ety = Emo_check.Unknown;
    desc = Tuple [ lower_expr env key; lower_expr env value ];
  }

and lower_map_arg env (entry : Ast.expr) : expr =
  match entry.Ast.desc with
  | Ast.Tuple [ key; value ] ->
      {
        ety = Emo_check.Unknown;
        desc = Tuple [ lower_expr env key; lower_expr env value ];
      }
  | _ ->
      raise (Lower_error "`Map.new` takes (key, value) pairs of two elements")

and lower_call env span callee args =
  match callee.Ast.desc with
  | Ast.Ident name when is_builtin name ->
      {
        ety = type_of env span;
        desc =
          Builtin
            {
              name;
              args =
                List.map
                  (fun { Ast.arg_value; _ } -> lower_expr env arg_value)
                  args;
            };
      }
  | _ -> (
      match resolve_callee env callee with
      | Some (mangled, params) ->
          {
            ety = type_of env span;
            desc = Call { func = mangled; args = order_args env params args };
          }
      | None -> (
          match callee.Ast.desc with
          | Ast.Member (recv, name) -> (
              match recv.Ast.desc with
              | Ast.Type_ident "Box" when name = "new" -> (
                  match args with
                  | [ { Ast.arg_name = None; arg_value } ] ->
                      {
                        ety = Emo_check.Unknown;
                        desc = Box_new (lower_expr env arg_value);
                      }
                  | _ -> raise (Lower_error "`Box.new` takes one argument"))
              | Ast.Type_ident "Bytes" when name = "new" -> (
                  match args with
                  | [ { Ast.arg_name = None; arg_value } ] ->
                      {
                        ety = Emo_check.Bytes;
                        desc = Bytes_new (lower_expr env arg_value);
                      }
                  | _ -> raise (Lower_error "`Bytes.new` takes one argument"))
              | Ast.Type_ident "List" when name = "new" -> (
                  match args with
                  | [ { Ast.arg_name = None; arg_value } ] ->
                      {
                        ety = type_of env span;
                        desc = List_new (lower_expr env arg_value);
                      }
                  | _ -> raise (Lower_error "`List.new` takes one argument"))
              | Ast.Type_ident "ArrayBuilder" when name = "new" -> (
                  match args with
                  | [] -> { ety = type_of env span; desc = Builder_new }
                  | _ ->
                      raise
                        (Lower_error "`ArrayBuilder.new` takes no arguments"))
              | Ast.Type_ident "Map" when name = "new" ->
                  {
                    ety = type_of env span;
                    desc =
                      Map_lit
                        (List.map
                           (fun { Ast.arg_value; _ } ->
                             lower_map_arg env arg_value)
                           args);
                  }
              | _ when name = "new" -> (
                  (* A declared class, bare or module-qualified. *)
                  match resolve_class env recv with
                  | Some (mangled, params) ->
                      {
                        ety = type_of env span;
                        desc =
                          Call
                            {
                              func = mangled;
                              args = order_args env params args;
                            };
                      }
                  | None ->
                      (* The built-in exception, or an unsupported
                         constructor: the checker admitted only these. *)
                      let args =
                        List.map
                          (fun { Ast.arg_name; arg_value } ->
                            (arg_name, arg_value))
                          args
                      in
                      {
                        ety = type_of env span;
                        desc =
                          Make_exception
                            {
                              message =
                                (match args with
                                | (Some "message", v) :: _ | (None, v) :: _ ->
                                    lower_expr env v
                                | _ ->
                                    { ety = String; desc = Const (L_string "") });
                              data =
                                (match args with
                                | [ _; (_, dv) ] -> Some (lower_expr env dv)
                                | _ -> None);
                            };
                      })
              | _ ->
                  {
                    ety = type_of env span;
                    desc =
                      Method
                        {
                          self_ = lower_expr env recv;
                          name;
                          args =
                            List.map
                              (fun { Ast.arg_value; _ } ->
                                lower_expr env arg_value)
                              args;
                        };
                  })
          | _ ->
              {
                ety = type_of env span;
                desc =
                  Call_value
                    {
                      f = lower_expr env callee;
                      args =
                        List.map
                          (fun { Ast.arg_value; _ } -> lower_expr env arg_value)
                          args;
                    };
              }))

(* A call's callee resolves when its dotted chain addresses a def or
   class: plain names in the current module (unless shadowed by a
   local), and module-qualified chains. *)
and resolve_callee env (callee : Ast.expr) : (string * string list) option =
  match dotted_path callee with
  | Some (module_path, name) -> (
      let module_path = relativize env (substitute_alias env module_path) in
      match Hashtbl.find_opt env.symbols (module_path, name) with
      | Some (S_func { mangled; params }) -> Some (mangled, params)
      | Some (S_class { mangled; params }) -> Some (mangled, params)
      | Some S_enum | Some S_interface | Some (S_global _) | None -> None)
  | None -> (
      match callee.Ast.desc with
      | Ast.Ident name when not (List.mem name env.locals) -> (
          match lookup_symbol env env.current name with
          | Some (S_func { mangled; params }) -> Some (mangled, params)
          | _ -> None)
      | _ -> None)

and lower_apply env (call : Ast.expr) : expr * expr list =
  match call.Ast.desc with
  | Ast.Call (callee, args) ->
      ( lower_expr env callee,
        List.map (fun { Ast.arg_value; _ } -> lower_expr env arg_value) args )
  | _ -> raise (Lower_error "expected a call")

and lower_scoped env (params : Ast.param list) (body : Ast.stmt list) :
    stmt list =
  let saved = env.locals in
  env.locals <- List.map (fun p -> p.Ast.param_name) params @ env.locals;
  let lowered = lower_stmts env body in
  env.locals <- saved;
  lowered

and lower_stmts env (stmts : Ast.stmt list) : stmt list =
  match stmts with
  | s :: rest -> (
      (* The head lowers before the rest: a binding's name must sit in
         [env.locals] when its successors read it. The lets force that
         order — a constructor's arguments have no promised order, and
         ocamlopt happily lowers the tail first. *)
      match s.Ast.stmt_desc with
      | Ast.Binding { pattern; init; _ } -> (
          match pattern.Ast.pattern_desc with
          | Ast.Pattern_binding _ ->
              let head = lower_stmt env s in
              let tail = lower_stmts env rest in
              head :: tail
          | _ ->
              (* A destructured binding desugars to a one-arm `case`
                 wrapping the block remainder: the branch's own machinery
                 binds the pattern's names for everything after it, and a
                 value that matches nothing dies the case-no-match death.
                 No new IR nodes — the six backends see a Case. *)
              let scrutinee = lower_expr env init in
              let saved = env.locals in
              collect_pattern_locals pattern env;
              let body = lower_stmts env rest in
              env.locals <- saved;
              [
                Case
                  { scrutinee; branches = [ { pattern; guard = None; body } ] };
              ])
      | _ ->
          let head = lower_stmt env s in
          let tail = lower_stmts env rest in
          head :: tail)
  | [] -> []

and lower_stmt env (s : Ast.stmt) : stmt =
  match s.Ast.stmt_desc with
  | Ast.Expr_stmt e -> Effect (lower_expr env e)
  | Ast.Binding { mutable_; pattern; init } -> (
      match pattern.Ast.pattern_desc with
      | Ast.Pattern_binding name -> (
          (* `const order = shop.order` binds a module path: record the
             alias so later `order.total(x)` resolves through it. *)
          match
            ( mutable_,
              Option.bind (full_chain init) (fun chain ->
                  let chain = relativize env chain in
                  if is_module_path env chain then Some chain else None) )
          with
          | false, Some target ->
              env.aliases <- (name, target) :: env.aliases;
              (* The alias itself is a namespace, not a value: calls resolve
                 through it, nothing reads it. The dead local carries an
                 Int literal because a String literal would emit native
                 emo_str into a value-typed slot — invalid C. *)
              Let
                {
                  mutable_ = false;
                  name;
                  init = { ety = Unknown; desc = Const (L_int 0L) };
                }
          | _ ->
              env.locals <- name :: env.locals;
              Let { mutable_; name; init = lower_expr env init })
      | _ -> raise (Lower_error "a destructured binding has no lowering yet"))
  | Ast.Assign { target; value } -> (
      match target.Ast.desc with
      | Ast.Ident name -> (
          if
            (* The innermost binding wins, reads and assigns alike: a local
             shadows a same-named module-level `var` (the checker's own
             rule, and a `for` header's variable shadows one too). *)
            List.mem name env.locals
          then Assign_var { name; value = lower_expr env value }
          else
            match lookup_symbol env env.current name with
            | Some (S_global { gname }) ->
                Set_global_var { name = gname; value = lower_expr env value }
            | _ -> Assign_var { name; value = lower_expr env value })
      | Ast.Member ({ Ast.desc = Ast.Self; _ }, field) ->
          Set_field
            {
              self_ = { ety = Emo_check.Unknown; desc = Var "self" };
              name = field;
              value = lower_expr env value;
            }
      | _ -> raise (Lower_error "invalid assignment target"))
  | Ast.Return (Some e) -> Return_stmt (lower_expr env e)
  | Ast.Return None ->
      Return_stmt { ety = Emo_check.Unknown; desc = Const (L_bool false) }
  | Ast.Raise e -> Raise (lower_expr env e)
  | Ast.If { cond; then_body; else_body } ->
      If
        {
          cond = lower_expr env cond;
          then_ = lower_stmts env then_body;
          else_ = Option.value else_body ~default:[] |> lower_stmts env;
        }
  | Ast.Case { scrutinee; branches } ->
      Case
        {
          scrutinee = lower_expr env scrutinee;
          branches = List.map (lower_branch env) branches;
        }
  | Ast.Receive branches ->
      Receive { branches = List.map (lower_branch env) branches }
  | Ast.Send { target; message } ->
      Send { target = lower_expr env target; message = lower_expr env message }
  | Ast.While { cond; body } ->
      While { cond = lower_expr env cond; body = lower_stmts env body }
  | Ast.For { init; cond; post; body } -> (
      (* The parser admits one header shape: a `var` init, a condition,
         an assignment post. The header `var` lowers as a loop-scoped
         mutable binding the For node carries — nothing leaks past the
         loop, on any backend. *)
      match init.Ast.stmt_desc with
      | Ast.Binding { mutable_ = true; _ } ->
          let saved = env.locals in
          let lowered_init = lower_stmt env init in
          let node =
            For
              {
                init = lowered_init;
                cond = lower_expr env cond;
                post = lower_stmt env post;
                body = lower_stmts env body;
              }
          in
          env.locals <- saved;
          node
      | _ -> raise (Lower_error "the `for` header binds a `var`"))
  | Ast.Break -> Break
  | Ast.Continue -> Continue

and lower_branch env (b : Ast.branch) : branch =
  let saved = env.locals in
  let () = collect_pattern_locals b.Ast.pattern env in
  let lowered =
    {
      pattern = qualify_pattern env b.Ast.pattern;
      guard = Option.map (lower_expr env) b.Ast.guard;
      body = lower_stmts env b.Ast.body;
    }
  in
  env.locals <- saved;
  lowered

(* An enum-member pattern's enum carries the qualified identity the
   code enums are keyed by; the raw AST keeps the written reference. *)
and qualify_pattern env (p : Ast.pattern) : Ast.pattern =
  match p.Ast.pattern_desc with
  | Ast.Enum_member (t, m) ->
      { p with pattern_desc = Ast.Enum_member (type_display env t, m) }
  | Ast.Tuple_pattern ps ->
      {
        p with
        pattern_desc = Ast.Tuple_pattern (List.map (qualify_pattern env) ps);
      }
  | _ -> p

and collect_pattern_locals (p : Ast.pattern) env =
  match p.Ast.pattern_desc with
  | Ast.Pattern_binding name -> env.locals <- name :: env.locals
  | Ast.Tuple_pattern ps -> List.iter (fun p -> collect_pattern_locals p env) ps
  | _ -> ()

(* A def lowers with its signature's types. *)
and lower_func env ~(module_path : string list) ~(mangled : string)
    ~(self : bool) (d : Ast.fun_def) : func =
  let self_param = if self then [ ("self", Emo_check.Unknown) ] else [] in
  let saved = env.locals in
  env.locals <-
    List.map (fun p -> p.Ast.param_name) d.Ast.def_params
    @ (if self then [ "self" ] else [])
    @ env.locals;
  let param_types =
    self_param
    @ List.map
        (fun p -> (p.Ast.param_name, decl_type p.Ast.param_type))
        d.Ast.def_params
  in
  let fbody = lower_stmts env d.Ast.def_body in
  env.locals <- saved;
  {
    fname = mangled;
    fmodule = module_path;
    fparams = param_types;
    fresult =
      (match d.Ast.def_return with
      | Some r -> decl_type r
      | None -> Emo_check.Void);
    fbody;
    fspecializable = false;
    fforeign = None;
  }

and decl_type (a : Ast.type_decl) : Emo_check.t =
  match a.Ast.type_desc with
  | Ast.Named_type "Int64" -> Emo_check.Int64
  | Ast.Named_type "Float64" -> Emo_check.Float64
  | Ast.Named_type "Bool" -> Emo_check.Bool
  | Ast.Named_type "Char" -> Emo_check.Char
  | Ast.Named_type "String" -> Emo_check.String
  | Ast.Named_type "Pid" -> Emo_check.Pid
  | Ast.Named_type "Void" -> Emo_check.Void
  | _ -> Emo_check.Unknown

(* ---- Stage B completeness ----

   A function specializes when every value in it is native — parameters,
   result, and every expression in the body — and the only calls it makes
   are to other specialized functions. Native: Int64, Float64, Bool, Char,
   String. Everything dynamic (Unknown, objects, sockets, closures)
   disqualifies. Computed to a fixed point over the call graph. *)

let is_native = function
  | Emo_check.Int64 | Emo_check.Float64 | Emo_check.Bool | Emo_check.Char
  | Emo_check.String ->
      true
  | _ -> false

let rec expr_native (special : string list) (e : expr) : bool =
  match e.desc with
  | Const _ | Type_ref _ -> true
  | Var _ | Global _ -> true
  | Tuple es | Array_lit es | Interpolate es ->
      List.for_all (expr_native special) es
  | Map_lit _ -> false (* dynamic: the hash table is an identity *)
  | Make_enum _ -> true
  | Unary (_, x) -> expr_native special x
  | Binary (_, l, r) -> expr_native special l && expr_native special r
  | Cond { c; t; e } ->
      expr_native special c && expr_native special t && expr_native special e
  | Index (b, i) -> expr_native special b && expr_native special i
  | Field_read { obj; _ } -> expr_native special obj
  | Call { func; args } ->
      List.mem func special && List.for_all (expr_native special) args
  | Call_value _ | Method _ | Builtin _ | Box_new _ | Bytes_new _ | List_new _
  | Builder_new | Make_exception _ | Do_spawn _ | Spawn_value _ | Closure _
  | Global_var _ ->
      false (* dynamic operations keep the function dynamic *)

and stmts_native special (stmts : stmt list) : bool =
  List.for_all (stmt_native special) stmts

and stmt_native special (s : stmt) : bool =
  match s with
  | Effect e -> expr_native special e
  | Let { init; _ } -> expr_native special init
  | Assign_var { value; _ } -> expr_native special value
  | Set_global_var _ -> false
  | Set_field _ -> false
  | If { cond; then_; else_ } ->
      expr_native special cond && stmts_native special then_
      && stmts_native special else_
  | Case { scrutinee; branches } ->
      expr_native special scrutinee
      && List.for_all
           (fun b ->
             (match b.guard with
               | Some g -> expr_native special g
               | None -> true)
             && stmts_native special b.body)
           branches
  | Receive _ | Send _ | Raise _ -> false
  | While _ | For _ | Break | Continue ->
      false
      (* a loop keeps its function dynamic — the specialized
              emitters do not lower the loop statements yet *)
  | Return_stmt e -> expr_native special e

(* Iterates to a fixed point: a function qualifies when its shape is
   native and every function it calls already qualified. A foreign
   binding has no Emo body to specialize — the external is the whole
   implementation, reached through the dynamic wrapper. *)
let specialize (funcs : func list) : func list =
  let shape_ok f =
    is_native f.fresult
    && List.for_all (fun (_, t) -> is_native t) f.fparams
    && f.fforeign = None
  in
  let rec loop funcs =
    let special =
      List.filter_map
        (fun g -> if g.fspecializable then Some g.fname else None)
        funcs
    in
    let changed = ref false in
    let funcs =
      List.map
        (fun f ->
          if
            (not f.fspecializable) && shape_ok f
            (* Self-recursion is native when the shape is: seed the
               function's own name so direct recursion qualifies. *)
            && stmts_native (f.fname :: special) f.fbody
          then (
            changed := true;
            { f with fspecializable = true })
          else f)
        funcs
    in
    if !changed then loop funcs else funcs
  in
  loop funcs

(* ---- Program lowering ---- *)

type input = {
  modules : module_input list; (* every module in the dependency closure *)
  entry : string list; (* the entry module's path *)
  packages : string list list;
      (* the short-name prefix of every fetched package *)
}

(* Lowers a whole program: symbols from every module first (forward
   references work), then const bindings, functions, classes, and the
   entry's top-level statements. *)
let lower (input : input) : program =
  let symbols : (string list * string, symbol) Hashtbl.t = Hashtbl.create 16 in
  (* The built-in `R` enum: no module declares it, so its symbol is
     seeded — `R.ok` / `R.error` lower as the enum constructions they
     are, on every target. *)
  Hashtbl.replace symbols ([], "R") S_enum;
  (* pass 1: every program-wide symbol *)
  List.iter
    (fun (m : module_input) ->
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.item_desc with
          | Ast.Item_def d ->
              Hashtbl.replace symbols (m.mpath, d.Ast.def_name)
                (S_func
                   {
                     mangled = mangle m.mpath d.Ast.def_name;
                     params =
                       List.map (fun p -> p.Ast.param_name) d.Ast.def_params;
                   })
          | Ast.Item_class c ->
              (* The class symbol resolves `C.new` to the constructor
                 wrapper, whether or not the class has an init. *)
              let init_params =
                match c.Ast.class_init with
                | Some init ->
                    List.map (fun p -> p.Ast.param_name) init.Ast.def_params
                | None -> []
              in
              Hashtbl.replace symbols
                (m.mpath, c.Ast.class_name)
                (S_class
                   {
                     mangled = mangle m.mpath (c.Ast.class_name ^ "__new");
                     params = init_params;
                   })
          | Ast.Item_enum e ->
              Hashtbl.replace symbols (m.mpath, e.Ast.enum_name) S_enum
          | Ast.Item_interface i ->
              (* A declared interface is a type reference, resolvable in
                 any module's signatures. *)
              Hashtbl.replace symbols
                (m.mpath, i.Ast.interface_name)
                S_interface
          | Ast.Item_emo_group g ->
              (* a function group's members: registered under both the
                 group-qualified key (`Foo.hello` resolves here) and the
                 current module's key (bare refs inside the group) *)
              List.iter
                (fun d ->
                  let mangled =
                    mangle m.mpath (g.Ast.group_name ^ "__" ^ d.Ast.def_name)
                  in
                  let params =
                    List.map (fun p -> p.Ast.param_name) d.Ast.def_params
                  in
                  Hashtbl.replace symbols
                    ([ g.Ast.group_name ], d.Ast.def_name)
                    (S_func { mangled; params });
                  Hashtbl.replace symbols (m.mpath, d.Ast.def_name)
                    (S_func { mangled; params }))
                g.Ast.group_defs;
              List.iter
                (fun (_, cname, _) ->
                  let mangled =
                    mangle m.mpath (g.Ast.group_name ^ "__" ^ cname)
                  in
                  Hashtbl.replace symbols
                    ([ g.Ast.group_name ], cname)
                    (S_func { mangled; params = [] });
                  Hashtbl.replace symbols (m.mpath, cname)
                    (S_func { mangled; params = [] }))
                g.Ast.group_consts
          | Ast.Item_foreign f ->
              Hashtbl.replace symbols
                (m.mpath, f.Ast.foreign_name)
                (S_func
                   {
                     mangled = mangle m.mpath f.Ast.foreign_name;
                     params =
                       List.map (fun p -> p.Ast.param_name) f.Ast.foreign_params;
                   })
          | Ast.Item_stmt
              {
                stmt_desc =
                  Ast.Binding
                    {
                      mutable_ = true;
                      pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                      _;
                    };
                _;
              }
            when m.mpath <> input.entry ->
              Hashtbl.replace symbols (m.mpath, name)
                (S_global { gname = mangle m.mpath name })
          | Ast.Item_stmt
              {
                stmt_desc =
                  Ast.Binding
                    {
                      mutable_ = false;
                      pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                      _;
                    };
                _;
              }
            when m.mpath <> input.entry ->
              (* A const binding in a non-entry module becomes a zero-arg
                 function other modules can call. *)
              Hashtbl.replace symbols (m.mpath, name)
                (S_func { mangled = mangle m.mpath name; params = [] })
          | _ -> ())
        m.mitems)
    input.modules;
  (* Module aliases: `const order = shop.order` in any module. Scanned
     up front so every def body resolves through them regardless of
     lowering order. *)
  let all_module_paths =
    List.map (fun (m : module_input) -> m.mpath) input.modules
  in
  let pre_aliases =
    List.concat_map
      (fun (m : module_input) ->
        List.filter_map
          (fun (item : Ast.item) ->
            match item.Ast.item_desc with
            | Ast.Item_stmt
                {
                  stmt_desc =
                    Ast.Binding
                      {
                        mutable_ = false;
                        pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                        init;
                        _;
                      };
                  _;
                } -> (
                match full_chain init with
                | Some chain ->
                    let chain =
                      relativize_in ~current:m.mpath ~packages:input.packages
                        ~module_paths:all_module_paths chain
                    in
                    if List.exists (fun mp -> mp = chain) all_module_paths then
                      Some (name, chain)
                    else None
                | _ -> None)
            | _ -> None)
          m.mitems)
      input.modules
  in
  let funcs = ref [] in
  let classes = ref [] in
  let interfaces = ref [] in
  let iface_sigs = ref [] in
  let globals = ref [] in
  (* The entry module can be discovered twice (as the entry root and as
     a sibling file): two paths, one parsed item list. Dedupe by path
     and by the items' physical identity — path alone misses the pair,
     and lowering both copies mangles every symbol twice (the group
     tables' last-wins registration then leaves one copy's calls
     dangling). *)
  let seen_paths = Hashtbl.create 8 in
  let seen_items : Ast.item list list ref = ref [] in
  let input =
    {
      input with
      modules =
        List.filter
          (fun (m : module_input) ->
            if Hashtbl.mem seen_paths m.mpath then false
            else if List.exists (fun kept -> kept == m.mitems) !seen_items then
              false
            else (
              Hashtbl.replace seen_paths m.mpath ();
              seen_items := m.mitems :: !seen_items;
              true))
          input.modules;
    }
  in
  (* pass 2: non-entry const bindings lower to zero-arg functions *)
  List.iter
    (fun (m : module_input) ->
      let const_env =
        {
          symbols;
          current = m.mpath;
          locals = [];
          types = m.mtypes;
          module_paths = all_module_paths;
          packages = input.packages;
          aliases = pre_aliases;
        }
      in
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.item_desc with
          | Ast.Item_stmt
              {
                stmt_desc =
                  Ast.Binding
                    {
                      mutable_ = false;
                      pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                      init;
                      _;
                    };
                _;
              }
            when m.mpath <> input.entry ->
              (* A module alias (`const d = internal.discounts`) binds a
                 path, not a value: uses resolve through the alias, so
                 no thunk lowers (lowering would hit the Type_ref the
                 module reference is). *)
              if
                match
                  Option.bind (full_chain init) (fun chain ->
                      let chain = relativize const_env chain in
                      if is_module_path const_env chain then Some chain
                      else None)
                with
                | Some _ -> true
                | None -> false
              then ()
              else
                funcs :=
                  {
                    fname = mangle m.mpath name;
                    fmodule = m.mpath;
                    fparams = [];
                    fresult = Emo_check.Unknown;
                    fbody = [ Return_stmt (lower_expr const_env init) ];
                    fspecializable = false;
                    fforeign = None;
                  }
                  :: !funcs
          | Ast.Item_stmt
              {
                stmt_desc =
                  Ast.Binding
                    {
                      mutable_ = true;
                      pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                      init;
                      _;
                    };
                _;
              }
            when m.mpath <> input.entry ->
              globals :=
                (mangle m.mpath name, lower_expr const_env init) :: !globals
          | _ -> ())
        m.mitems)
    input.modules;
  (* pass 3: defs, classes, interfaces *)
  List.iter
    (fun (m : module_input) ->
      let env =
        {
          symbols;
          current = m.mpath;
          locals = [];
          types = m.mtypes;
          module_paths = all_module_paths;
          packages = input.packages;
          aliases = pre_aliases;
        }
      in
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.item_desc with
          | Ast.Item_def d ->
              funcs :=
                lower_func env ~module_path:m.mpath
                  ~mangled:(mangle m.mpath d.Ast.def_name)
                  ~self:false d
                :: !funcs
          | Ast.Item_class c ->
              let display = c.Ast.class_name in
              let init =
                Option.map
                  (fun d ->
                    lower_func env ~module_path:m.mpath
                      ~mangled:(mangle m.mpath (display ^ "__init"))
                      ~self:true d)
                  c.Ast.class_init
              in
              let methods =
                List.map
                  (fun d ->
                    lower_func env ~module_path:m.mpath
                      ~mangled:
                        (mangle m.mpath
                           (display ^ "__" ^ sanitize_ident d.Ast.def_name))
                      ~self:true d)
                  c.Ast.class_methods
              in
              classes :=
                {
                  cname = mangle m.mpath display;
                  cdisplay = qualify_name m.mpath display;
                  cinit = init;
                  cmethods = methods;
                }
                :: !classes
          | Ast.Item_emo_group g ->
              (* the group's defs and const thunks lower like any other
                 function; symbols were registered in pass 1 *)
              List.iter
                (fun d ->
                  funcs :=
                    lower_func env ~module_path:m.mpath
                      ~mangled:
                        (mangle m.mpath
                           (g.Ast.group_name ^ "__" ^ d.Ast.def_name))
                      ~self:false d
                    :: !funcs)
                g.Ast.group_defs;
              List.iter
                (fun (_, cname, cexpr) ->
                  let body : Ast.stmt =
                    {
                      stmt_span = item.Ast.item_span;
                      stmt_desc = Ast.Return (Some cexpr);
                    }
                  in
                  let thunk_def : Ast.fun_def =
                    {
                      def_span = item.Ast.item_span;
                      def_name = g.Ast.group_name ^ "__" ^ cname;
                      def_params = [];
                      def_return = None;
                      def_body = [ body ];
                    }
                  in
                  let mangled =
                    match
                      Hashtbl.find_opt symbols ([ g.Ast.group_name ], cname)
                    with
                    | Some (S_func { mangled; _ }) -> mangled
                    | _ -> mangle m.mpath (g.Ast.group_name ^ "__" ^ cname)
                  in
                  (* the thunk returns the const's value: Unknown, like
                     every other const binding (Void would lose it) *)
                  let thunk =
                    lower_func env ~module_path:m.mpath ~mangled ~self:false
                      thunk_def
                  in
                  funcs := { thunk with fresult = Emo_check.Unknown } :: !funcs)
                g.Ast.group_consts
          | Ast.Item_foreign f ->
              (* The FFI carrier types stay what they are — an interface
                 is the callback pair, a class or a tuple is a C struct
                 shape — instead of degrading to Unknown (decl_type has
                 no type tables). Tuple shapes recurse: a nested tuple
                 is a struct within the struct. *)
              let rec foreign_ffi_type (a : Ast.type_decl) : Emo_check.t =
                match a.Ast.type_desc with
                | Ast.Named_type name -> (
                    match resolve_type_ref env name with
                    | Some (_, q, S_interface) -> Emo_check.InterfaceType q
                    | Some (_, q, S_class _) -> Emo_check.ClassType q
                    | _ -> decl_type a)
                | Ast.Tuple_type ts ->
                    Emo_check.TupleType (List.map foreign_ffi_type ts)
                | _ -> decl_type a
              in
              let foreign_param_type (p : Ast.param) : Emo_check.t =
                foreign_ffi_type p.Ast.param_type
              in
              funcs :=
                {
                  fname = mangle m.mpath f.Ast.foreign_name;
                  fmodule = m.mpath;
                  fparams =
                    List.map
                      (fun p -> (p.Ast.param_name, foreign_param_type p))
                      f.Ast.foreign_params;
                  fresult = foreign_ffi_type f.Ast.foreign_return;
                  fbody = [];
                  fspecializable = false;
                  fforeign = Some f.Ast.foreign_symbol;
                }
                :: !funcs
          | Ast.Item_interface i ->
              interfaces :=
                ( qualify_name m.mpath i.Ast.interface_name,
                  List.map
                    (fun s -> (s.Ast.sig_name, List.length s.Ast.sig_params))
                    i.Ast.interface_methods )
                :: !interfaces;
              iface_sigs :=
                ( qualify_name m.mpath i.Ast.interface_name,
                  List.map
                    (fun s ->
                      ( s.Ast.sig_name,
                        List.map
                          (fun p ->
                            (p.Ast.param_name, decl_type p.Ast.param_type))
                          s.Ast.sig_params,
                        decl_type s.Ast.sig_return ))
                    i.Ast.interface_methods )
                :: !iface_sigs
          | _ -> ())
        m.mitems)
    input.modules;
  let entry_module =
    List.find (fun (m : module_input) -> m.mpath = input.entry) input.modules
  in
  let env =
    {
      symbols;
      current = input.entry;
      locals = [];
      types = entry_module.mtypes;
      module_paths = all_module_paths;
      packages = input.packages;
      aliases = pre_aliases;
    }
  in
  let pinit =
    entry_module.mitems
    |> List.filter_map (fun (item : Ast.item) ->
        match item.Ast.item_desc with
        | Ast.Item_stmt s -> (
            (* A module alias (`const ui = internal.vnode`) binds a
                path, not a value: the alias is recorded at scan time,
                uses resolve through it, so the entry lowers no binding
                for it — a value slot here would emit garbage C. *)
            match s.Ast.stmt_desc with
            | Ast.Binding
                {
                  mutable_ = false;
                  pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                  _;
                }
              when List.mem_assoc name pre_aliases ->
                None
            | _ -> Some s)
        | _ -> None)
    |> lower_stmts env
  in
  (* The entry module can be discovered under two paths, lowering its
     items twice; dedupe functions by name, keeping the first. *)
  let pfuncs =
    let seen = Hashtbl.create 16 in
    List.filter
      (fun (f : func) ->
        if Hashtbl.mem seen f.fname then false
        else (
          Hashtbl.replace seen f.fname ();
          true))
      (specialize !funcs)
  in
  {
    pfuncs;
    pclasses = !classes;
    pinterfaces = !interfaces;
    piface_sigs = !iface_sigs;
    pinit;
    pglobals = List.rev !globals;
    pentry = input.entry;
  }
