(* Tree-walking evaluator. Values are dynamically tagged; environments form a
   lexical chain that closures capture by reference. Runtime errors are
   diagnostics with spans, in the E3xxx code range. *)

module Ast = Emo_ast

exception Error of Emo_support.Diagnostic.t

let error span ?hint code message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

type value =
  | Int of int
  | Float of float
  | Bool of bool
  | Char of char
  | String of string
  | Tuple of value list
  | Array of value array
  | Box of value ref
  | ArrowBlock of closure
  | BuiltinFn of string
  | ClassDef of string (* name only — the real payload lands in step 06 *)
  | Instance of string (* name only — the real payload lands in step 06 *)
  | EnumMember of string * string (* type name, member name *)
  | TypeValue of string
  | Module of string (* path only — the real payload lands in step 09 *)

and closure = {
  def_name : string; (* "`fib`" or "`<arrow block>`", for diagnostics *)
  params : Ast.param list;
  body : Ast.stmt list;
  env : env;
}

and env = { frame : (string, binding) Hashtbl.t; parent : env option }
and binding = { mutable bound : value; mutable_ : bool }

let type_name = function
  | Int _ -> "Int"
  | Float _ -> "Float"
  | Bool _ -> "Bool"
  | Char _ -> "Char"
  | String _ -> "String"
  | Tuple _ -> "Tuple"
  | Array _ -> "Array"
  | Box _ -> "Box"
  | ArrowBlock _ -> "an arrow block"
  | BuiltinFn _ -> "a builtin"
  | ClassDef _ -> "a class"
  | Instance _ -> "an instance"
  | EnumMember _ -> "an enum member"
  | TypeValue _ -> "a type"
  | Module _ -> "a module"

let rec equal_value a b =
  match (a, b) with
  | Int x, Int y -> Int.equal x y
  | Float x, Float y -> Float.equal x y
  | Bool x, Bool y -> Bool.equal x y
  | Char x, Char y -> Char.equal x y
  | String x, String y -> String.equal x y
  | Tuple xs, Tuple ys ->
      List.length xs = List.length ys && List.for_all2 equal_value xs ys
  | Array xs, Array ys ->
      Array.length xs = Array.length ys
      &&
      let ok = ref true in
      Array.iteri (fun i x -> if not (equal_value x ys.(i)) then ok := false) xs;
      !ok
  | Box x, Box y -> equal_value !x !y
  | EnumMember (t, m), EnumMember (t', m') ->
      String.equal t t' && String.equal m m'
  | ClassDef x, ClassDef y | Module x, Module y | TypeValue x, TypeValue y ->
      String.equal x y
  | ArrowBlock x, ArrowBlock y -> x == y (* closures are identities *)
  | BuiltinFn x, BuiltinFn y -> String.equal x y
  | _ -> false

let global_env () = { frame = Hashtbl.create 16; parent = None }
let child parent = { frame = Hashtbl.create 8; parent = Some parent }

(* Defines a name in exactly this frame; a later definition of the same name
   replaces the earlier one within the frame. *)
let define env name ~mutable_ value =
  Hashtbl.replace env.frame name { bound = value; mutable_ }

let rec lookup env span name =
  match Hashtbl.find_opt env.frame name with
  | Some { bound; _ } -> bound
  | None -> (
      match env.parent with
      | Some parent -> lookup parent span name
      | None -> error span "E3002" (Printf.sprintf "`%s` is not defined" name))

let rec assign env span name value =
  match Hashtbl.find_opt env.frame name with
  | Some { mutable_ = true; _ } ->
      Hashtbl.replace env.frame name { bound = value; mutable_ = true }
  | Some { mutable_ = false; _ } ->
      error span "E3003"
        (Printf.sprintf "cannot assign to `%s`; it is a const" name)
        ~hint:"use `var` for bindings that change"
  | None -> (
      match env.parent with
      | Some parent -> assign parent span name value
      | None ->
          error span "E3003"
            (Printf.sprintf "cannot assign to `%s`; it is not defined" name))

(* Explicit returns unwind through an exception to the nearest function
   frame; there is no implicit last-expression value anywhere. *)
exception Return_signal of value

let not_yet span what =
  error span "E3009" (Printf.sprintf "%s is not supported yet" what)

let rec eval_unary env span op x =
  let v = eval_expr env x in
  match (op, v) with
  | Ast.Not, Bool b -> Bool (not b)
  | Ast.Not, v ->
      error span "E3001"
        (Printf.sprintf "operator `!` expects a Bool, got %s" (type_name v))
  | Ast.Neg, Int n -> Int (-n)
  | Ast.Neg, Float f -> Float (-.f)
  | Ast.Neg, v ->
      error span "E3001"
        (Printf.sprintf "operator `-` expects a number, got %s" (type_name v))

and eval_binary env span op left_expr right_expr =
  let op_name = function
    | Ast.Eq -> "=="
    | Ast.Ne -> "!="
    | Ast.Lt -> "<"
    | Ast.Le -> "<="
    | Ast.Gt -> ">"
    | Ast.Ge -> ">="
    | Ast.Add -> "+"
    | Ast.Sub -> "-"
    | Ast.Mul -> "*"
    | Ast.Div -> "/"
    | Ast.Mod -> "%"
    | Ast.And -> "&&"
    | Ast.Or -> "||"
  in
  let left = eval_expr env left_expr in
  let right = eval_expr env right_expr in
  let type_mismatch expects =
    error span "E3001"
      (Printf.sprintf "operator `%s` expects %s, got %s and %s" (op_name op)
         expects (type_name left) (type_name right))
  in
  let as_float = function
    | Int x -> float_of_int x
    | Float f -> f
    | v -> type_mismatch "two numbers"
  in
  let check_bool v =
    match v with Bool b -> b | v -> type_mismatch "two Bools"
  in
  match op with
  | Ast.And -> Bool (if check_bool left then check_bool right else false)
  | Ast.Or -> Bool (if check_bool left then true else check_bool right)
  | Ast.Eq -> Bool (equal_value left right)
  | Ast.Ne -> Bool (not (equal_value left right))
  | Ast.Lt -> Bool (as_float left < as_float right)
  | Ast.Le -> Bool (as_float left <= as_float right)
  | Ast.Gt -> Bool (as_float left > as_float right)
  | Ast.Ge -> Bool (as_float left >= as_float right)
  | Ast.Add -> (
      match (left, right) with
      | Int x, Int y -> Int (x + y)
      | Float x, Float y -> Float (x +. y)
      | Int x, Float y -> Float (float_of_int x +. y)
      | Float x, Int y -> Float (x +. float_of_int y)
      | String x, String y -> String (x ^ y)
      | _ -> type_mismatch "two numbers or two strings")
  | Ast.Sub -> (
      match (left, right) with
      | Int x, Int y -> Int (x - y)
      | Float x, Float y -> Float (x -. y)
      | Int x, Float y -> Float (float_of_int x -. y)
      | Float x, Int y -> Float (x -. float_of_int y)
      | _ -> type_mismatch "two numbers")
  | Ast.Mul -> (
      match (left, right) with
      | Int x, Int y -> Int (x * y)
      | Float x, Float y -> Float (x *. y)
      | Int x, Float y -> Float (float_of_int x *. y)
      | Float x, Int y -> Float (x *. float_of_int y)
      | _ -> type_mismatch "two numbers")
  | Ast.Div | Ast.Mod -> (
      let zero_check d =
        match d with
        | Int 0 -> error span "E3005" "division by zero"
        | Float f when f = 0.0 -> error span "E3005" "division by zero"
        | _ -> ()
      in
      match (left, right) with
      | Int x, Int y ->
          zero_check right;
          if op = Ast.Div then Int (x / y) else Int (x mod y)
      | Float x, Float y ->
          zero_check right;
          if op = Ast.Div then Float (x /. y) else Float (Float.rem x y)
      | Int x, Float y ->
          zero_check right;
          if op = Ast.Div then Float (float_of_int x /. y)
          else Float (Float.rem (float_of_int x) y)
      | Float x, Int y ->
          zero_check right;
          if op = Ast.Div then Float (x /. float_of_int y)
          else Float (Float.rem x (float_of_int y))
      | _ -> type_mismatch "two numbers")

and eval_index env span base index =
  let b = eval_expr env base in
  let i = eval_expr env index in
  let at len =
    match i with
    | Int n when n >= 0 && n < len -> n
    | Int n ->
        error span "E3004"
          (Printf.sprintf "index %d is out of bounds for a length-%d %s" n len
             (match b with Array _ -> "Array" | _ -> "Tuple"))
    | v ->
        error span "E3001"
          (Printf.sprintf "the index must be an Int, got %s" (type_name v))
  in
  match (b, i) with
  | Array xs, _ -> xs.(at (Array.length xs))
  | Tuple xs, _ ->
      let xs = Array.of_list xs in
      xs.(at (Array.length xs))
  | v, _ ->
      error span "E3001"
        (Printf.sprintf "%s does not support indexing" (type_name v))

and eval_call env span callee arg_exprs =
  let f = eval_expr env callee in
  let args =
    List.map
      (fun { Ast.arg_name; arg_value } -> (arg_name, eval_expr env arg_value))
      arg_exprs
  in
  apply f span args

and apply f span args =
  match f with
  | ArrowBlock closure -> apply_closure closure span args
  | BuiltinFn name ->
      List.iter
        (fun (name_, _) ->
          match name_ with
          | Some n ->
              error span "E3007"
                (Printf.sprintf "builtin `%s` takes positional arguments only"
                   name)
          | None -> ())
        args;
      apply_builtin span name (List.map snd args)
  | v ->
      error span "E3007"
        (Printf.sprintf "%s is not callable"
           (String.capitalize_ascii (type_name v)))

(* Binds the arguments to the parameters: positionals fill the first free
   slot left to right, named arguments address their parameter directly. *)
and apply_closure closure span args =
  let params = Array.of_list closure.params in
  let positional = Queue.create () in
  let named = Hashtbl.create 4 in
  List.iter
    (fun (name, value) ->
      match name with
      | None -> Queue.push value positional
      | Some name ->
          if Hashtbl.mem named name then
            error span "E3007"
              (Printf.sprintf "the argument `%s` is passed twice" name);
          Hashtbl.replace named name value)
    args;
  let positional_count = Queue.length positional in
  let named_count = Hashtbl.length named in
  if positional_count + named_count <> Array.length params then
    error span "E3007"
      (Printf.sprintf "`%s` expects %d argument%s, got %d" closure.def_name
         (Array.length params)
         (if Array.length params = 1 then "" else "s")
         (positional_count + named_count));
  let call_env = child closure.env in
  Array.iter
    (fun { Ast.param_name; _ } ->
      let value =
        match Hashtbl.find_opt named param_name with
        | Some v ->
            Hashtbl.remove named param_name;
            v
        | None ->
            if Queue.is_empty positional then
              error span "E3007"
                (Printf.sprintf "`%s` is missing an argument for `%s`"
                   closure.def_name param_name)
            else Queue.pop positional
      in
      define call_env param_name ~mutable_:false value)
    params;
  let leftover =
    Hashtbl.fold (fun k _ acc -> if acc = None then Some k else acc) named None
  in
  match leftover with
  | Some name ->
      error span "E3007"
        (Printf.sprintf "`%s` has no parameter named `%s`" closure.def_name name)
  | None -> eval_body closure call_env span

and apply_builtin span name args =
  match (name, args) with
  | _ -> error span "E3007" (Printf.sprintf "unknown builtin `%s`" name)

and eval_body closure call_env span =
  let rec run = function
    | [] ->
        error span "E3008"
          (Printf.sprintf "reached the end of %s without `return`"
             closure.def_name)
    | stmt :: rest -> ( match eval_stmt call_env stmt with () -> run rest)
  in
  try run closure.body with
  | Return_signal v -> v
  | Error diagnostic -> raise (Error diagnostic)

and eval_stmt env s =
  let span = s.Ast.stmt_span in
  match s.Ast.stmt_desc with
  | Ast.Expr_stmt e -> ignore (eval_expr env e)
  | Ast.Binding { mutable_; name; init } ->
      define env name ~mutable_ (eval_expr env init)
  | Ast.Assign { target; value } -> (
      let v = eval_expr env value in
      match target.Ast.desc with
      | Ast.Ident name -> assign env span name v
      | Ast.Member ({ Ast.desc = Ast.Self; _ }, _) ->
          not_yet span "field assignment"
      | _ -> error span "E3003" "invalid assignment target")
  | Ast.Return None -> not_yet span "a valueless `return`"
  | Ast.Return (Some e) -> raise (Return_signal (eval_expr env e))
  | Ast.If _ -> not_yet span "`if`"
  | Ast.Case _ -> not_yet span "`case`"
  | Ast.Receive _ -> not_yet span "`receive`"
  | Ast.Send _ -> not_yet span "processes"
  | Ast.Raise _ -> not_yet span "exceptions"

and eval_expr env e =
  let span = e.Ast.span in
  match e.Ast.desc with
  | Ast.Int n -> Int n
  | Ast.Float f -> Float f
  | Ast.Bool b -> Bool b
  | Ast.Char c -> Char c
  | Ast.String s -> String s
  | Ast.Ident name -> lookup env span name
  | Ast.Type_ident t -> TypeValue t
  | Ast.Interpolated _ -> not_yet span "string interpolation"
  | Ast.Self -> not_yet span "`self`"
  | Ast.Member _ -> not_yet span "member access"
  | Ast.Index (base, index) -> eval_index env span base index
  | Ast.Tuple es -> Tuple (List.map (eval_expr env) es)
  | Ast.Array_literal es -> Array (Array.of_list (List.map (eval_expr env) es))
  | Ast.Arrow_block (params, body) ->
      ArrowBlock { def_name = "`<arrow block>`"; params; body; env }
  | Ast.Unary (op, x) -> eval_unary env span op x
  | Ast.Binary (op, l, r) -> eval_binary env span op l r
  | Ast.Call (callee, args) -> eval_call env span callee args
  | Ast.Do _ -> not_yet span "processes"
