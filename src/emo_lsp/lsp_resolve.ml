(* Name resolution for completion and hover: which declarations are in
   scope, what a dotted receiver refers to, and which symbol sits under
   the cursor. The checker's full flow analysis is deliberately not
   reused here — the server needs fast, best-effort answers even while
   the buffer is incomplete. *)

module Ast = Emo_ast
module Ix = Lsp_index

let is_container_kind k =
  k = Ix.Kind.class_ || k = Ix.Kind.namespace || k = Ix.Kind.enum
  || k = Ix.Kind.interface

let span_contains (s : Emo_support.Span.t) (offset : int) : bool =
  s.Emo_support.Span.start <= offset && offset <= s.Emo_support.Span.stop

(* The innermost class enclosing [offset], for `self.` completion. *)
let enclosing_class (items : Ast.item list) (offset : int) : string option =
  let best = ref None in
  let consider name span =
    if span_contains span offset then
      match !best with
      | Some (_, prev) when prev >= span.Emo_support.Span.start -> ()
      | _ -> best := Some (name, span.Emo_support.Span.start)
  in
  List.iter
    (fun (item : Ast.item) ->
      match item.Ast.item_desc with
      | Ast.Item_class c -> consider c.Ast.class_name c.Ast.class_span
      | _ -> ())
    items;
  Option.map fst !best

(* ---- Finding a binding's initializer -------------------------------- *)

let rec find_binding (items : Ast.item list) (name : string) : Ast.expr option =
  let found = ref None in
  let rec stmts (ss : Ast.stmt list) =
    List.iter
      (fun (s : Ast.stmt) ->
        if !found = None then
          match s.Ast.stmt_desc with
          | Ast.Binding { name = n; init; _ } when n = name ->
              found := Some init
          | Ast.If { then_body; else_body; _ } ->
              stmts then_body;
              Option.iter stmts else_body
          | Ast.Case { branches; _ } ->
              List.iter (fun b -> stmts b.Ast.body) branches
          | Ast.Receive branches ->
              List.iter (fun b -> stmts b.Ast.body) branches
          | Ast.Expr_stmt { Ast.desc = Ast.Arrow_block (_, body); _ } ->
              stmts body
          | _ -> ())
      ss
  in
  List.iter
    (fun (item : Ast.item) ->
      if !found = None then
        match item.Ast.item_desc with
        | Ast.Item_def d -> stmts d.Ast.def_body
        | Ast.Item_class c ->
            Option.iter (fun i -> stmts i.Ast.def_body) c.Ast.class_init;
            List.iter (fun m -> stmts m.Ast.def_body) c.Ast.class_methods
        | Ast.Item_emo_group g ->
            List.iter (fun d -> stmts d.Ast.def_body) g.Ast.group_defs
        | Ast.Item_stmt s -> stmts [ s ]
        | _ -> ())
    items;
  !found

let find_param_type (items : Ast.item list) (name : string) :
    Ast.type_decl option =
  let found = ref None in
  let params (ps : Ast.param list) =
    List.iter
      (fun (p : Ast.param) ->
        if !found = None && p.Ast.param_name = name then
          found := Some p.Ast.param_type)
      ps
  in
  let rec stmts (ss : Ast.stmt list) =
    List.iter
      (fun (s : Ast.stmt) ->
        if !found = None then
          match s.Ast.stmt_desc with
          | Ast.Expr_stmt { Ast.desc = Ast.Arrow_block (ps, _); _ } -> params ps
          | _ -> ())
      ss
  in
  List.iter
    (fun (item : Ast.item) ->
      if !found = None then
        match item.Ast.item_desc with
        | Ast.Item_def d ->
            params d.Ast.def_params;
            stmts d.Ast.def_body
        | Ast.Item_class c ->
            Option.iter (fun i -> params i.Ast.def_params) c.Ast.class_init;
            List.iter (fun m -> params m.Ast.def_params) c.Ast.class_methods
        | Ast.Item_emo_group g ->
            List.iter (fun d -> params d.Ast.def_params) g.Ast.group_defs
        | _ -> ())
    items;
  !found

let base_type_name (t : Ast.type_decl) : string option =
  match t.Ast.type_desc with
  | Ast.Named_type n -> Some n
  | Ast.Applied_type (n, _) -> Some n
  | Ast.Tuple_type _ -> None

let return_type_of_def (items : Ast.item list) (fname : string) : string option
    =
  let found = ref None in
  List.iter
    (fun (item : Ast.item) ->
      if !found = None then
        match item.Ast.item_desc with
        | Ast.Item_def d when d.Ast.def_name = fname ->
            found := Option.bind d.Ast.def_return base_type_name
        | _ -> ())
    items;
  !found

let rec infer_container (ix : Ix.t) (items : Ast.item list) ~(depth : int)
    (name : string) : string option =
  if depth > 6 then None
  else
    match find_binding items name with
    | Some
        {
          Ast.desc =
            Ast.Call
              ( {
                  Ast.desc =
                    Ast.Member ({ Ast.desc = Ast.Type_ident c; _ }, "new");
                  _;
                },
                _ );
          _;
        } ->
        Some c
    | Some { Ast.desc = Ast.Member ({ Ast.desc = Ast.Type_ident e; _ }, _); _ }
      ->
        Some e
    | Some { Ast.desc = Ast.Call ({ Ast.desc = Ast.Ident f; _ }, _); _ } -> (
        match return_type_of_def items f with Some c -> Some c | None -> None)
    | Some { Ast.desc = Ast.Ident other; _ } -> (
        match infer_container ix items ~depth:(depth + 1) other with
        | Some _ as c -> c
        | None -> local_or_project_container ix items other)
    | _ -> local_or_project_container ix items name

and local_or_project_container (ix : Ix.t) (items : Ast.item list)
    (name : string) : string option =
  match find_param_type items name with
  | Some t -> base_type_name t
  | None -> (
      match Ix.symbols_named ix name with
      | s :: _ when is_container_kind s.Ix.kind -> Some s.Ix.name
      | _ -> None)

(* ---- Dotted receiver extraction ------------------------------------- *)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_' || c = '?'

(* The identifier chain immediately before [offset], when the character
   just before it is a `.` (i.e. we are completing a member). *)
let receiver_segments (text : string) (offset : int) : string list option =
  let n = String.length text in
  let i = offset - 1 in
  if i < 0 || i >= n || text.[i] <> '.' then None
  else
    let j = ref (i - 1) in
    while !j >= 0 && (is_ident_char text.[!j] || text.[!j] = '.') do
      decr j
    done;
    let start = !j + 1 in
    let chain = String.sub text start (i - start) in
    if chain = "" then None else Some (String.split_on_char '.' chain)

(* ---- Member resolution ---------------------------------------------- *)

let top_level_in_file (ix : Ix.t) (file : string) : Ix.symbol list =
  List.filter
    (fun (s : Ix.symbol) -> s.Ix.container = None && not s.Ix.local)
    (Ix.symbols_in_file ix file)

(* Declarations collected from the in-memory buffer: unsaved edits must
   be completable and hoverable before the file reaches disk. *)
let current_symbols ~(file : string) (items : Ast.item list) : Ix.symbol list =
  Ix.collect_items ~file ~module_path:[] items
  @ Ix.collect_locals ~file ~module_path:[] items

(* The first container declaration with [name], preferring one in [file]
   so same-named classes in other modules do not leak in. The current
   buffer wins, then the on-disk index. *)
let container_symbol (ix : Ix.t) ~(file : string) ~(items : Ast.item list)
    (name : string) : Ix.symbol option =
  let containers syms =
    List.filter
      (fun (s : Ix.symbol) -> is_container_kind s.Ix.kind && s.Ix.name = name)
      syms
  in
  match containers (current_symbols ~file items) with
  | s :: _ -> Some s
  | [] -> (
      let candidates = containers (Ix.symbols_named ix name) in
      let file = Lsp_util.normalize_path file in
      match
        List.find_opt (fun (s : Ix.symbol) -> s.Ix.file = file) candidates
      with
      | Some s -> Some s
      | None -> ( match candidates with s :: _ -> Some s | [] -> None))

(* The container a dotted receiver names (a class, group, enum, or
   interface), or None when the receiver is not a container. *)
let resolve_container (ix : Ix.t) (items : Ast.item list) ~(file : string)
    (offset : int) (segments : string list) : Ix.symbol option =
  let named name = container_symbol ix ~file ~items name in
  match segments with
  | [] -> None
  | [ "self" ] -> (
      match enclosing_class items offset with Some c -> named c | None -> None)
  | [ single ] -> (
      match named single with
      | Some s -> Some s
      | None -> Option.bind (infer_container ix items ~depth:0 single) named)
  | _ -> (
      match named (String.concat "." segments) with
      | Some s -> Some s
      | None -> (
          match Ix.resolve_module_prefix ix segments with
          | Some (module_path, [ last ]) -> (
              match Ix.module_file ix module_path with
              | Some mfile ->
                  List.find_opt
                    (fun (s : Ix.symbol) ->
                      is_container_kind s.Ix.kind && s.Ix.name = last)
                    (Ix.symbols_in_file ix mfile)
              | None -> None)
          | _ -> (
              match segments with
              | [ recv; _ ] ->
                  Option.bind (infer_container ix items ~depth:0 recv) named
              | _ -> None)))

(* Resolve a receiver chain to the declarations that may follow a dot. *)
let resolve_receiver (ix : Ix.t) (items : Ast.item list) (file : string)
    (offset : int) (segments : string list) : Ix.symbol list =
  match resolve_container ix items ~file offset segments with
  | Some s -> Ix.members_of_in_file ix ~file:s.Ix.file s.Ix.name
  | None -> (
      match Ix.resolve_module_prefix ix segments with
      | Some (module_path, []) -> (
          match Ix.module_file ix module_path with
          | Some mfile -> top_level_in_file ix mfile
          | None -> [])
      | _ -> [])

(* ---- The identifier under the cursor --------------------------------- *)

let identifier_at (text : string) (offset : int) : (string * int * int) option =
  let n = String.length text in
  let is_word c = is_ident_char c || c = '.' in
  if n = 0 then None
  else
    let start = ref (min offset n) in
    while !start > 0 && is_word text.[!start - 1] do
      decr start
    done;
    let stop = ref (min offset n) in
    while !stop < n && is_word text.[!stop] do
      incr stop
    done;
    if !stop <= !start then None
    else
      let word = String.sub text !start (!stop - !start) in
      Some (word, !start, !stop)

(* Candidate definitions for a bare (possibly dotted) name. *)
let definitions_for_name (ix : Ix.t) (items : Ast.item list) (file : string)
    (name : string) : Ix.symbol list =
  let in_file =
    List.filter
      (fun (s : Ix.symbol) ->
        s.Ix.name = name || s.Ix.name = Filename.basename name)
      (current_symbols ~file items @ Ix.symbols_in_file ix file)
  in
  let local = List.filter (fun (s : Ix.symbol) -> s.Ix.local) in_file in
  let exact = Ix.symbols_named ix name in
  let candidates =
    local @ (if String.contains name '.' then [] else in_file) @ exact
  in
  let seen = Hashtbl.create 8 in
  List.filter
    (fun (s : Ix.symbol) ->
      let key = (s.Ix.file, s.Ix.span.Emo_support.Span.start) in
      if Hashtbl.mem seen key then false
      else (
        Hashtbl.replace seen key ();
        true))
    candidates
