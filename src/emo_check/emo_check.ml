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

(* The full pass: every diagnostic found, sorted by position. *)
let check_source ~file ~(source : string) : Emo_support.Diagnostic.t list =
  let ctx, _items = analyze ~file ~source in
  let diagnostics = List.rev !(ctx.diagnostics) in
  List.sort
    (fun a b ->
      let open Emo_support.Diagnostic in
      let open Emo_support.Span in
      compare
        (a.span.line, a.span.col, a.span.start)
        (b.span.line, b.span.col, b.span.start))
    diagnostics
