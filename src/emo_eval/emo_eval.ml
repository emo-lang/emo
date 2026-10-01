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
