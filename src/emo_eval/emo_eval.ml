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
  | ClassDef of class_def_value
  | Instance of instance_value
  | EnumType of enum_type_value
  | EnumMember of string * string (* type name, member name *)
  | TypeValue of string
  | Module of string (* path only — the real payload lands in step 09 *)

and class_def_value = {
  cname : string;
  cinit : closure option; (* at most one init, per the parser *)
  cmethods : (string * closure) list;
  builtin_exception : bool; (* the shipped `Exception` class *)
}

and instance_value = {
  iclass : class_def_value;
  mutable ifields : (string * value) list;
      (* appended/replaced only by `self.x = ...` inside init; frozen after *)
}

and enum_type_value = { ename : string; emembers : (string * value) list }

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
  | EnumType _ -> "an enum"
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
  | EnumType x, EnumType y -> String.equal x.ename y.ename
  | ClassDef x, ClassDef y -> x == y (* a declaration is an identity *)
  | Module x, Module y | TypeValue x, TypeValue y -> String.equal x y
  | Instance x, Instance y ->
      String.equal x.iclass.cname y.iclass.cname
      && List.length x.ifields = List.length y.ifields
      && List.for_all2
           (fun (nx, vx) (ny, vy) -> String.equal nx ny && equal_value vx vy)
           x.ifields y.ifields
  | ArrowBlock x, ArrowBlock y -> x == y (* closures are identities *)
  | BuiltinFn x, BuiltinFn y -> String.equal x y
  | _ -> false

let global_env () =
  let env = { frame = Hashtbl.create 16; parent = None } in
  Hashtbl.replace env.frame "print"
    { bound = BuiltinFn "print"; mutable_ = false };
  Hashtbl.replace env.frame "Box" { bound = TypeValue "Box"; mutable_ = false };
  (* The shipped exception class: `raise Exception.new(message: "boom")`. *)
  Hashtbl.replace env.frame "Exception"
    {
      bound =
        ClassDef
          {
            cname = "Exception";
            cinit = None;
            cmethods = [];
            builtin_exception = true;
          };
      mutable_ = false;
    };
  env

(* Program output goes to stdout; tests redirect it through [set_output]. *)
let output : (string -> unit) ref =
  ref (fun s ->
      print_string s;
      flush stdout)

let set_output f = output := f

(* The one stringification rule: interpolation and `.to_string()` share it. *)
let rec to_string = function
  | Int n -> string_of_int n
  | Float f ->
      if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.1f" f
      else Printf.sprintf "%g" f
  | Bool b -> string_of_bool b
  | Char c -> String.make 1 c
  | String s -> s
  | Tuple vs -> "(" ^ String.concat ", " (List.map to_string vs) ^ ")"
  | Array vs ->
      "[" ^ String.concat ", " (List.map to_string (Array.to_list vs)) ^ "]"
  | Box _ -> "<box>"
  | ArrowBlock _ -> "<arrow block>"
  | BuiltinFn name -> Printf.sprintf "<builtin %s>" name
  | ClassDef c -> c.cname
  | Instance _ -> "<instance>"
  | EnumType e -> e.ename
  | EnumMember (t, m) -> t ^ "." ^ m
  | TypeValue t -> t
  | Module n -> n

(* Interfaces have no runtime artifact beyond this registry: `x.is(T)`
   checks the receiver's class against the declared method shapes. *)
let interface_registry : (string, (string * int) list) Hashtbl.t =
  Hashtbl.create 8

(* `x.is(T)` — the runtime half of narrowing: exact class for classes, the
   declaring enum for members, and a structural method-shape check for
   interfaces. *)
let runtime_is span v t =
  match (v, t) with
  | Instance i, ClassDef c -> String.equal i.iclass.cname c.cname
  | EnumMember (et, _), EnumType e -> String.equal et e.ename
  | Instance i, TypeValue tname -> (
      match Hashtbl.find_opt interface_registry tname with
      | Some sigs ->
          List.for_all
            (fun (m, arity) ->
              match List.assoc_opt m i.iclass.cmethods with
              | Some closure -> List.length closure.params = arity
              | None -> false)
            sigs
      | None -> false)
  | EnumMember _, TypeValue _ -> false
  | _ ->
      error span "E3007"
        (Printf.sprintf "`is` checks instances and enum members, not %s"
           (type_name v))

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

let rec lookup_opt env name =
  match Hashtbl.find_opt env.frame name with
  | Some { bound; _ } -> Some bound
  | None -> (
      match env.parent with
      | Some parent -> lookup_opt parent name
      | None -> None)

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
   frame; a return whose expression is a call raises [Tail_call] instead,
   so the frame can rebind and iterate — tail calls never grow the OCaml
   stack. *)
exception Return_signal of value

exception
  Tail_call of closure * (string option * value) list * (string * value) list
(* callee, arguments, pre-bound extras (a method's `self`) *)

(* `raise <value>` unwinds as an exception; the driver turns an uncaught one
   into an E3010 diagnostic. *)
exception Emo_raise of value * Emo_support.Span.t

let literal_value = function
  | Ast.L_int n -> Int n
  | Ast.L_float f -> Float f
  | Ast.L_char c -> Char c
  | Ast.L_string s -> String s
  | Ast.L_bool b -> Bool b

(* Binds pattern variables into [frame] and reports whether the pattern
   matches. Bindings from a branch that ends up not matching do not leak:
   each branch attempts its match in a fresh child frame. *)
let rec match_pattern frame span pattern value =
  match pattern.Ast.pattern_desc with
  | Ast.Wildcard -> true
  | Ast.Pattern_binding name ->
      define frame name ~mutable_:false value;
      true
  | Ast.Pattern_literal l -> equal_value value (literal_value l)
  | Ast.Enum_member (t, m) -> (
      match value with
      | EnumMember (t', m') -> String.equal t t' && String.equal m m'
      | _ -> false)
  | Ast.Tuple_pattern ps -> (
      match value with
      | Tuple vs when List.length vs = List.length ps ->
          List.for_all2 (fun p v -> match_pattern frame span p v) ps vs
      | _ -> false)

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
  match callee.Ast.desc with
  | Ast.Member (recv, mname) -> eval_method env span recv mname arg_exprs
  | _ ->
      let f = eval_expr env callee in
      let args =
        List.map
          (fun { Ast.arg_name; arg_value } ->
            (arg_name, eval_expr env arg_value))
          arg_exprs
      in
      apply f span args

(* Methods are only callable directly: `x.to_string()`, `box.read()`,
   `Box.new(v)`. A bare `x.to_string` is not a value. *)
and eval_method env span recv mname arg_exprs =
  let argc = List.length arg_exprs in
  let eval_args () =
    List.map
      (fun { Ast.arg_name; arg_value } ->
        match arg_name with
        | Some n ->
            error span "E3007"
              (Printf.sprintf "methods take positional arguments only (`%s`)" n)
        | None -> eval_expr env arg_value)
      arg_exprs
  in
  (* Constructors and methods keep the argument names so they can bind by
     parameter name. *)
  let eval_args_named () =
    List.map
      (fun { Ast.arg_name; arg_value } -> (arg_name, eval_expr env arg_value))
      arg_exprs
  in
  let none_expected what =
    if argc = 0 then ()
    else
      error span "E3007"
        (Printf.sprintf "`%s` expects no arguments, got %d" what argc)
  in
  let base = eval_expr env recv in
  match (base, mname) with
  | Instance i, mname when List.mem_assoc mname i.iclass.cmethods ->
      let closure = List.assoc mname i.iclass.cmethods in
      let args = eval_args_named () in
      let frame = bind_params closure span args in
      define frame "self" ~mutable_:false (Instance i);
      eval_frame closure frame span
  | Instance i, "is" -> (
      let args = eval_args () in
      match args with
      | [ t ] -> Bool (runtime_is span (Instance i) t)
      | _ ->
          error span "E3007"
            (Printf.sprintf "`is` expects 1 argument, got %d" argc))
  | Instance i, mname ->
      error span "E3007"
        (Printf.sprintf "NoMethodError: `%s` has no method `%s`" i.iclass.cname
           mname)
  | ClassDef c, "new" -> (
      let args = eval_args_named () in
      match c.cinit with
      | Some init ->
          let instance = Instance { iclass = c; ifields = [] } in
          let frame = bind_params init span args in
          define frame "self" ~mutable_:false instance;
          (* init constructs; it does not return a value. An early `return`
             simply ends the window, and no implicit value exists. *)
          (try List.iter (eval_stmt frame) init.body with
          | Return_signal _ -> ()
          | Tail_call _ -> ());
          instance
      | None when c.builtin_exception -> (
          match args with
          | [ (Some "message", v) ] | [ (None, v) ] ->
              Instance { iclass = c; ifields = [ ("message", v) ] }
          | _ -> error span "E3007" "`Exception.new` expects `message`")
      | None ->
          if List.length args > 0 then
            error span "E3007"
              (Printf.sprintf
                 "class `%s` declares no `init`; `new` takes no arguments"
                 c.cname);
          Instance { iclass = c; ifields = [] })
  | ClassDef c, m ->
      error span "E3007"
        (Printf.sprintf "class `%s` has no member `%s`" c.cname m)
  | TypeValue "Box", "new" -> (
      let args = eval_args () in
      match args with
      | [ v ] -> Box (ref v)
      | _ ->
          error span "E3007"
            (Printf.sprintf "`Box.new` expects 1 argument, got %d" argc))
  | TypeValue t, m ->
      error span "E3009" (Printf.sprintf "type `%s` has no member `%s` yet" t m)
  | v, "to_string" ->
      none_expected "to_string";
      String (to_string v)
  | Array xs, "length" ->
      none_expected "length";
      Int (Array.length xs)
  | Tuple xs, "length" ->
      none_expected "length";
      Int (List.length xs)
  | Box r, "read" ->
      none_expected "read";
      !r
  | Box r, "replace" -> (
      let args = eval_args () in
      match args with
      | [ v ] ->
          r := v;
          v
      | _ ->
          error span "E3007"
            (Printf.sprintf "`replace` expects 1 argument, got %d" argc))
  | (EnumMember _ as v), "is" -> (
      let args = eval_args () in
      match args with
      | [ t ] -> Bool (runtime_is span v t)
      | _ ->
          error span "E3007"
            (Printf.sprintf "`is` expects 1 argument, got %d" argc))
  | v, m ->
      error span "E3007"
        (Printf.sprintf "%s has no method `%s`" (type_name v) m)

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
and bind_params closure span args =
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
  let frame = child closure.env in
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
      define frame param_name ~mutable_:false value)
    params;
  let leftover =
    Hashtbl.fold (fun k _ acc -> if acc = None then Some k else acc) named None
  in
  match leftover with
  | Some name ->
      error span "E3007"
        (Printf.sprintf "`%s` has no parameter named `%s`" closure.def_name name)
  | None -> frame

and apply_closure closure span args = eval_body closure span args

and apply_builtin span name args =
  match (name, args) with
  | "print", [ v ] ->
      !output (to_string v ^ "\n");
      v
  | "print", vs ->
      error span "E3007"
        (Printf.sprintf "`print` expects 1 argument, got %d" (List.length vs))
  | _ -> error span "E3007" (Printf.sprintf "unknown builtin `%s`" name)

(* The function frame. A [Tail_call] rebinds callee and arguments and
   iterates in place; the OCaml stack stays flat however long the Emo-level
   recursion runs. *)
and eval_body closure span args =
  eval_frame closure (bind_params closure span args) span

(* Runs a prepared frame. A [Tail_call] rebinds callee, arguments, and any
   extras (a method's `self`), and iterates in place — the OCaml stack stays
   flat however long the Emo-level recursion runs. *)
and eval_frame closure frame span =
  let rec loop closure frame =
    try
      let rec run = function
        | [] ->
            error span "E3008"
              (Printf.sprintf "reached the end of %s without `return`"
                 closure.def_name)
        | stmt :: rest ->
            let () = eval_stmt frame stmt in
            run rest
      in
      run closure.body
    with
    | Return_signal v -> v
    | Tail_call (c, args, extras) ->
        let frame = bind_params c span args in
        List.iter (fun (k, v) -> define frame k ~mutable_:false v) extras;
        loop c frame
  in
  loop closure frame

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
      | Ast.Member ({ Ast.desc = Ast.Self; _ }, name) -> (
          (* Only init bodies contain `self.x = ...` — the parser enforces
             the window; here `self` must be the instance under
             construction. *)
          match lookup env span "self" with
          | Instance i ->
              (* replace in place, or create the field on first assignment *)
              let rest = List.remove_assoc name i.ifields in
              i.ifields <- (name, v) :: rest
          | v ->
              error span "E3003"
                (Printf.sprintf
                   "`self.x = ...` needs an instance under construction, got %s"
                   (type_name v)))
      | _ -> error span "E3003" "invalid assignment target")
  | Ast.Return None -> not_yet span "a valueless `return`"
  | Ast.Return (Some e) -> (
      match e.Ast.desc with
      | Ast.Call ({ Ast.desc = Ast.Member (recv, mname); _ }, arg_exprs) -> (
          (* A method call in return position tail-calls with `self`. *)
          let base = eval_expr env recv in
          match base with
          | Instance i when List.mem_assoc mname i.iclass.cmethods ->
              let closure = List.assoc mname i.iclass.cmethods in
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    (arg_name, eval_expr env arg_value))
                  arg_exprs
              in
              raise (Tail_call (closure, args, [ ("self", Instance i) ]))
          | _ -> raise (Return_signal (eval_expr env e)))
      | Ast.Call (callee, arg_exprs) -> (
          let f = eval_expr env callee in
          match f with
          | ArrowBlock closure ->
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    (arg_name, eval_expr env arg_value))
                  arg_exprs
              in
              raise (Tail_call (closure, args, []))
          | not_a_closure ->
              let args =
                List.map
                  (fun { Ast.arg_name; arg_value } ->
                    match arg_name with
                    | Some n ->
                        error span "E3007"
                          (Printf.sprintf
                             "builtins take positional arguments only (`%s`)" n)
                    | None -> eval_expr env arg_value)
                  arg_exprs
              in
              raise
                (Return_signal
                   (apply not_a_closure span
                      (List.map (fun v -> (None, v)) args))))
      | _ -> raise (Return_signal (eval_expr env e)))
  | Ast.If { cond; then_body; else_body } -> (
      let c = eval_expr env cond in
      match c with
      | Bool true -> List.iter (eval_stmt env) then_body
      | Bool false -> (
          match else_body with
          | Some body -> List.iter (eval_stmt env) body
          | None -> ())
      | v ->
          error cond.Ast.span "E3001"
            (Printf.sprintf "the `if` condition must be a Bool, got %s"
               (type_name v)))
  | Ast.Case { scrutinee; branches } ->
      let v = eval_expr env scrutinee in
      let rec try_branches = function
        | [] ->
            error span "E3006"
              (Printf.sprintf "no `case` branch matched this %s value"
                 (type_name v))
        | branch :: rest ->
            let frame = child env in
            if not (match_pattern frame span branch.Ast.pattern v) then
              try_branches rest
            else
              let guard_holds =
                match branch.Ast.guard with
                | Some g -> (
                    match eval_expr frame g with
                    | Bool b -> b
                    | gv ->
                        error span "E3001"
                          (Printf.sprintf
                             "a `when` guard must be a Bool, got %s"
                             (type_name gv)))
                | None -> true
              in
              if guard_holds then List.iter (eval_stmt frame) branch.Ast.body
              else try_branches rest
      in
      try_branches branches
  | Ast.Receive _ -> not_yet span "`receive`"
  | Ast.Send _ -> not_yet span "processes"
  | Ast.Raise e ->
      let v = eval_expr env e in
      raise (Emo_raise (v, span))

and eval_expr env e =
  let span = e.Ast.span in
  match e.Ast.desc with
  | Ast.Int n -> Int n
  | Ast.Float f -> Float f
  | Ast.Bool b -> Bool b
  | Ast.Char c -> Char c
  | Ast.String s -> String s
  | Ast.Ident name -> lookup env span name
  | Ast.Type_ident t -> (
      (* A declared class, enum, or interface resolves to its value; an
         unknown upper name stays a bare type value. *)
      match lookup_opt env t with
      | Some v -> v
      | None -> TypeValue t)
  | Ast.Interpolated parts ->
      String
        (String.concat ""
           (List.map
              (function
                | Ast.Literal_text s -> s
                | Ast.Part_expr e -> to_string (eval_expr env e))
              parts))
  | Ast.Self -> lookup env span "self"
  | Ast.Member (inner, name) -> (
      let base = eval_expr env inner in
      match base with
      | Instance i -> (
          match List.assoc_opt name i.ifields with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "`%s` has no field `%s`" i.iclass.cname name))
      | EnumType e -> (
          match List.assoc_opt name e.emembers with
          | Some v -> v
          | None ->
              error span "E3007"
                (Printf.sprintf "enum `%s` has no member `%s`" e.ename name))
      | _ ->
          error span "E3007" "a member access must be a call, like `x.read()`")
  | Ast.Index (base, index) -> eval_index env span base index
  | Ast.Tuple es -> Tuple (List.map (eval_expr env) es)
  | Ast.Array_literal es -> Array (Array.of_list (List.map (eval_expr env) es))
  | Ast.Arrow_block (params, body) ->
      ArrowBlock { def_name = "`<arrow block>`"; params; body; env }
  | Ast.Unary (op, x) -> eval_unary env span op x
  | Ast.Binary (op, l, r) -> eval_binary env span op l r
  | Ast.Call (callee, args) -> eval_call env span callee args
  | Ast.Do _ -> not_yet span "processes"

(* Top-level items: defs register closures in the environment, statements
   run in order. Closures capture [env] by reference, so a def resolves
   names against the frame as it stands when the call happens — recursion
   and forward references among defs both work. *)
let method_closure class_name env d =
  {
    def_name = Printf.sprintf "`%s.%s`" class_name d.Ast.def_name;
    params = d.Ast.def_params;
    body = d.Ast.def_body;
    env;
  }

let eval_item env item =
  match item.Ast.item_desc with
  | Ast.Item_stmt s -> eval_stmt env s
  | Ast.Item_def d ->
      define env d.Ast.def_name ~mutable_:false
        (ArrowBlock
           {
             def_name = Printf.sprintf "`%s`" d.Ast.def_name;
             params = d.Ast.def_params;
             body = d.Ast.def_body;
             env;
           })
  | Ast.Item_class c ->
      define env c.Ast.class_name ~mutable_:false
        (ClassDef
           {
             cname = c.Ast.class_name;
             cinit =
               Option.map
                 (fun d -> method_closure c.Ast.class_name env d)
                 c.Ast.class_init;
             cmethods =
               List.map
                 (fun d ->
                   (d.Ast.def_name, method_closure c.Ast.class_name env d))
                 c.Ast.class_methods;
             builtin_exception = false;
           })
  | Ast.Item_interface i ->
      let sigs =
        List.map
          (fun s -> (s.Ast.sig_name, List.length s.Ast.sig_params))
          i.Ast.interface_methods
      in
      Hashtbl.replace interface_registry i.Ast.interface_name sigs;
      define env i.Ast.interface_name ~mutable_:false
        (TypeValue i.Ast.interface_name)
  | Ast.Item_enum e ->
      let members =
        List.map
          (fun m ->
            (m.Ast.member_name, EnumMember (e.Ast.enum_name, m.Ast.member_name)))
          e.Ast.enum_members
      in
      define env e.Ast.enum_name ~mutable_:false
        (EnumType { ename = e.Ast.enum_name; emembers = members })

(* Runs a whole file: declarations register, statements execute in order.
   An uncaught `raise` terminates the program with an E3010 diagnostic. *)
let run_program ~file ~source =
  Hashtbl.reset interface_registry;
  let items = Emo_parser.parse_program ~file ~source in
  let env = global_env () in
  try List.iter (eval_item env) items
  with Emo_raise (v, span) ->
    error span "E3010" (Printf.sprintf "uncaught exception: %s" (to_string v))
