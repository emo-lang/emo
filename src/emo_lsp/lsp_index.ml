(* The project index: every declaration under the project root, plus the
   module table that maps a qualified path to its `.emo` file.

   The directory tree is the module tree (README, Modules and Visibility),
   so a path like `shop.order` is just `shop/order.emo`. The index is
   rebuilt lazily and cached by a fingerprint of the tree's mtimes. *)

module Ast = Emo_ast
module Span = Emo_support.Span

(* LSP SymbolKind values (kept as ints so the server stays JSON-only). *)
module Kind = struct
  let file = 1
  let module_ = 2
  let namespace = 3
  let package = 4
  let class_ = 5
  let method_ = 6
  let property = 7
  let field = 8
  let constructor = 9
  let enum = 10
  let interface = 11
  let function_ = 12
  let variable = 13
  let constant = 14
  let struct_ = 23
  let enum_member = 22
  let type_parameter = 26
end

type symbol = {
  name : string;
  kind : int;
  detail : string;
  file : string;
  span : Span.t;
  container : string option; (* the class/group/interface/enum this holds *)
  module_path : string list;
  local : bool; (* a parameter or block binding, not a top-level decl *)
}

(* ---- Rendering type annotations and signatures ---------------------- *)

let rec type_ann_to_string (t : Ast.type_ann) : string =
  match t.Ast.type_desc with
  | Ast.Named_type n -> n
  | Ast.Applied_type (n, args) ->
      n ^ "[" ^ String.concat ", " (List.map type_ann_to_string args) ^ "]"
  | Ast.Tuple_type ts ->
      "(" ^ String.concat ", " (List.map type_ann_to_string ts) ^ ")"

let params_to_string (ps : Ast.param list) : string =
  String.concat ", "
    (List.map
       (fun p -> p.Ast.param_name ^ " " ^ type_ann_to_string p.Ast.param_type)
       ps)

let def_signature (d : Ast.fun_def) : string =
  let ret =
    match d.Ast.def_return with
    | Some r -> " " ^ type_ann_to_string r
    | None -> ""
  in
  Printf.sprintf "def %s(%s)%s" d.Ast.def_name
    (params_to_string d.Ast.def_params)
    ret

let foreign_signature (f : Ast.foreign_def) : string =
  Printf.sprintf "foreign def %s(%s) %s = \"%s\"" f.Ast.foreign_name
    (params_to_string f.Ast.foreign_params)
    (type_ann_to_string f.Ast.foreign_return)
    f.Ast.foreign_symbol

(* ---- Collecting declarations from one file -------------------------- *)

let mk ~name ~kind ~detail ~file ~span ~container ~module_path ~local =
  { name; kind; detail; file; span; container; module_path; local }

let class_fields (c : Ast.class_def) : Ast.field list = c.Ast.class_fields

let rec expr_to_text (e : Ast.expr) : string =
  match e.Ast.desc with
  | Ast.Ident s -> s
  | Ast.Type_ident s -> s
  | Ast.Self -> "self"
  | Ast.Int n -> string_of_int n
  | Ast.Int64 n -> Int64.to_string n
  | Ast.Byte n -> string_of_int n
  | Ast.Float f -> string_of_float f
  | Ast.Bool b -> string_of_bool b
  | Ast.Char c -> Printf.sprintf "'%c'" c
  | Ast.String _ -> "\"...\""
  | Ast.Interpolated _ -> "\"...\""
  | Ast.Member (r, f) -> expr_to_text r ^ "." ^ f
  | Ast.Index (r, _) -> expr_to_text r ^ "[...]"
  | Ast.Call (f, _) -> expr_to_text f ^ "(...)"
  | Ast.Arrow_block _ -> "-> (...) { ... }"
  | Ast.Tuple _ -> "(...)"
  | Ast.Array_literal _ -> "[...]"
  | Ast.Unary (_, r) -> expr_to_text r
  | Ast.Binary (_, l, _) -> expr_to_text l
  | Ast.If_expr _ -> "if ... { ... } else { ... }"
  | Ast.Do e -> "do " ^ expr_to_text e

let collect_items ~(file : string) ~(module_path : string list)
    (items : Ast.item list) : symbol list =
  let out = ref [] in
  let add s = out := s :: !out in
  let add_def ?container (d : Ast.fun_def) =
    add
      (mk ~name:d.Ast.def_name ~kind:Kind.function_ ~detail:(def_signature d)
         ~file ~span:d.Ast.def_span ~container ~module_path ~local:false)
  in
  List.iter
    (fun (item : Ast.item) ->
      match item.Ast.item_desc with
      | Ast.Item_def d -> add_def d
      | Ast.Item_foreign f ->
          add
            (mk ~name:f.Ast.foreign_name ~kind:Kind.function_
               ~detail:(foreign_signature f) ~file ~span:f.Ast.foreign_span
               ~container:None ~module_path ~local:false)
      | Ast.Item_class c ->
          add
            (mk ~name:c.Ast.class_name ~kind:Kind.class_
               ~detail:("class " ^ c.Ast.class_name)
               ~file ~span:c.Ast.class_span ~container:None ~module_path
               ~local:false);
          Option.iter
            (fun init ->
              add
                (mk ~name:"init" ~kind:Kind.constructor
                   ~detail:
                     ("def init(" ^ params_to_string init.Ast.def_params ^ ")")
                   ~file ~span:init.Ast.def_span
                   ~container:(Some c.Ast.class_name) ~module_path ~local:false))
            c.Ast.class_init;
          List.iter
            (fun m ->
              add
                (mk ~name:m.Ast.def_name ~kind:Kind.method_
                   ~detail:(def_signature m) ~file ~span:m.Ast.def_span
                   ~container:(Some c.Ast.class_name) ~module_path ~local:false))
            c.Ast.class_methods;
          List.iter
            (fun (f : Ast.field) ->
              add
                (mk ~name:f.Ast.field_name ~kind:Kind.field
                   ~detail:("field " ^ f.Ast.field_name)
                   ~file ~span:f.Ast.field_span
                   ~container:(Some c.Ast.class_name) ~module_path ~local:false))
            (class_fields c)
      | Ast.Item_interface i ->
          add
            (mk ~name:i.Ast.interface_name ~kind:Kind.interface
               ~detail:("interface " ^ i.Ast.interface_name)
               ~file ~span:i.Ast.interface_span ~container:None ~module_path
               ~local:false);
          List.iter
            (fun (m : Ast.method_sig) ->
              add
                (mk ~name:m.Ast.sig_name ~kind:Kind.method_
                   ~detail:
                     (Printf.sprintf "def %s(%s) %s" m.Ast.sig_name
                        (params_to_string m.Ast.sig_params)
                        (type_ann_to_string m.Ast.sig_return))
                   ~file ~span:m.Ast.sig_span
                   ~container:(Some i.Ast.interface_name) ~module_path
                   ~local:false))
            i.Ast.interface_methods
      | Ast.Item_enum e ->
          add
            (mk ~name:e.Ast.enum_name ~kind:Kind.enum
               ~detail:
                 (Printf.sprintf "enum %s { %s }" e.Ast.enum_name
                    (String.concat ", "
                       (List.map
                          (fun (m : Ast.member) -> m.Ast.member_name)
                          e.Ast.enum_members)))
               ~file ~span:e.Ast.enum_span ~container:None ~module_path
               ~local:false);
          List.iter
            (fun (m : Ast.member) ->
              add
                (mk
                   ~name:(e.Ast.enum_name ^ "." ^ m.Ast.member_name)
                   ~kind:Kind.enum_member
                   ~detail:(e.Ast.enum_name ^ "." ^ m.Ast.member_name)
                   ~file ~span:m.Ast.member_span
                   ~container:(Some e.Ast.enum_name) ~module_path ~local:false))
            e.Ast.enum_members
      | Ast.Item_emo_group g ->
          add
            (mk ~name:g.Ast.group_name ~kind:Kind.namespace
               ~detail:("emo " ^ g.Ast.group_name)
               ~file ~span:g.Ast.group_span ~container:None ~module_path
               ~local:false);
          List.iter
            (fun d -> add_def ~container:g.Ast.group_name d)
            g.Ast.group_defs;
          List.iter
            (fun (span, name, init) ->
              add
                (mk ~name ~kind:Kind.constant
                   ~detail:
                     (Printf.sprintf "const %s = %s" name (expr_to_text init))
                   ~file ~span ~container:(Some g.Ast.group_name) ~module_path
                   ~local:false))
            g.Ast.group_consts
      | Ast.Item_stmt
          { Ast.stmt_desc = Ast.Binding { mutable_; name; init }; stmt_span } ->
          add
            (mk ~name
               ~kind:(if mutable_ then Kind.variable else Kind.constant)
               ~detail:
                 (Printf.sprintf "%s %s = %s"
                    (if mutable_ then "var" else "const")
                    name (expr_to_text init))
               ~file ~span:stmt_span ~container:None ~module_path ~local:false)
      | Ast.Item_stmt _ | Ast.Item_require _ -> ())
    items;
  List.rev !out

(* Every parameter and block binding in the file, so completion offers
   names that are in scope. Precise lexical scoping is left to the
   checker; this is a file-wide superset. *)
let collect_locals ~(file : string) ~(module_path : string list)
    (items : Ast.item list) : symbol list =
  let out = ref [] in
  let bind_params ~container:_ (ps : Ast.param list) =
    List.iter
      (fun (p : Ast.param) ->
        out :=
          mk ~name:p.Ast.param_name ~kind:Kind.variable
            ~detail:
              (p.Ast.param_name ^ " " ^ type_ann_to_string p.Ast.param_type)
            ~file ~span:p.Ast.param_type.Ast.type_span ~container:None
            ~module_path ~local:true
          :: !out)
      ps
  in
  let rec walk_stmts ~container:_ (stmts : Ast.stmt list) =
    List.iter
      (fun (s : Ast.stmt) ->
        match s.Ast.stmt_desc with
        | Ast.Binding { mutable_; name; _ } ->
            out :=
              mk ~name
                ~kind:(if mutable_ then Kind.variable else Kind.constant)
                ~detail:((if mutable_ then "var " else "const ") ^ name)
                ~file ~span:s.Ast.stmt_span ~container:None ~module_path
                ~local:true
              :: !out
        | _ -> ())
      stmts
  in
  let walk_def ?container (d : Ast.fun_def) =
    bind_params ~container d.Ast.def_params;
    walk_stmts ~container d.Ast.def_body
  in
  List.iter
    (fun (item : Ast.item) ->
      match item.Ast.item_desc with
      | Ast.Item_def d -> walk_def d
      | Ast.Item_class c ->
          Option.iter
            (fun i -> walk_def ~container:c.Ast.class_name i)
            c.Ast.class_init;
          List.iter (walk_def ~container:c.Ast.class_name) c.Ast.class_methods
      | Ast.Item_emo_group g ->
          List.iter (walk_def ~container:g.Ast.group_name) g.Ast.group_defs
      | _ -> ())
    items;
  List.rev !out

(* ---- The project index ---------------------------------------------- *)

type t = {
  root : string;
  modules : (string list * string) list; (* module path -> backing file *)
  symbols : symbol list;
  by_name : (string, symbol list) Hashtbl.t;
  by_container : (string, symbol list) Hashtbl.t;
  by_file : (string, symbol list) Hashtbl.t;
  built_at : float;
}

let index_of (root : string) ~(modules : (string list * string) list)
    ~(symbols : symbol list) : t =
  let by_name = Hashtbl.create 256 in
  let by_container = Hashtbl.create 128 in
  let by_file = Hashtbl.create 128 in
  List.iter
    (fun s ->
      let add tbl key =
        Hashtbl.replace tbl key
          (s :: Option.value ~default:[] (Hashtbl.find_opt tbl key))
      in
      add by_name s.name;
      (match s.container with Some c -> add by_container c | None -> ());
      add by_file s.file)
    symbols;
  {
    root;
    modules;
    symbols;
    by_name;
    by_container;
    by_file;
    built_at = Unix.gettimeofday ();
  }

let symbols_named (ix : t) (name : string) : symbol list =
  Option.value ~default:[] (Hashtbl.find_opt ix.by_name name)

let members_of (ix : t) (container : string) : symbol list =
  Option.value ~default:[] (Hashtbl.find_opt ix.by_container container)

(* Members declared in a specific file — used to disambiguate same-named
   classes across modules. *)
let members_of_in_file (ix : t) ~(file : string) (container : string) :
    symbol list =
  let file = Lsp_util.normalize_path file in
  List.filter (fun (s : symbol) -> s.file = file) (members_of ix container)

let symbols_in_file (ix : t) (file : string) : symbol list =
  let file = Lsp_util.normalize_path file in
  Option.value ~default:[] (Hashtbl.find_opt ix.by_file file)

let module_file (ix : t) (path : string list) : string option =
  List.assoc_opt path ix.modules

(* Longest prefix of [segments] that names a module, and what is left. *)
let resolve_module_prefix (ix : t) (segments : string list) :
    (string list * string list) option =
  let rec go taken rest best =
    match rest with
    | [] -> best
    | seg :: tl ->
        let taken' = taken @ [ seg ] in
        let best' =
          match module_file ix taken' with
          | Some _ -> Some (taken', tl)
          | None -> best
        in
        go taken' tl best'
  in
  go [] segments None

(* ---- Directory walking and the fingerprint cache -------------------- *)

let skip_dir name =
  name = "_build" || name = ".emo-build" || name = ".git"
  || name = "node_modules" || name = ".emobuild"

(* Collects (module path, file) under [root]. The module path is the
   root-relative path without the `.emo` extension. *)
let scan (root : string) : (string list * string) list =
  let acc = ref [] in
  let rec walk (rel : string list) (dir : string) =
    List.iter
      (fun entry ->
        if entry = "package.emo" || entry = "package.lock" then ()
        else
          let path = Filename.concat dir entry in
          if Lsp_util.is_directory path then
            if skip_dir entry then () else walk (rel @ [ entry ]) path
          else if Filename.check_suffix entry ".emo" then
            let name = Filename.remove_extension entry in
            acc := (rel @ [ name ], Lsp_util.normalize_path path) :: !acc)
      (Lsp_util.readdir dir)
  in
  walk [] root;
  !acc

(* A cheap change detector: each file's size and mtime. *)
let fingerprint (root : string) (files : (string list * string) list) : string =
  let buf = Buffer.create 256 in
  List.iter
    (fun (_, file) ->
      match Unix.stat file with
      | stats ->
          Buffer.add_string buf
            (Printf.sprintf "%s:%d:%f;" file stats.Unix.st_size
               stats.Unix.st_mtime)
      | exception Unix.Unix_error _ -> ())
    (List.sort (fun (_, a) (_, b) -> String.compare a b) files);
  Digest.to_hex (Digest.string (Buffer.contents buf))

let parse_tolerant (file : string) : Ast.item list =
  match Lsp_util.read_file file with
  | None -> []
  | Some source -> (
      match Emo_parser.parse_program_with_diagnostics ~file ~source with
      | items, _ -> items
      | exception Emo_lexer.Error _ -> [])

let build (root : string) : t =
  let modules = scan root in
  let symbols =
    List.concat_map
      (fun (module_path, file) ->
        let items = parse_tolerant file in
        collect_items ~file ~module_path items
        @ collect_locals ~file ~module_path items)
      modules
  in
  index_of root ~modules ~symbols

let cache : (string, string * t) Hashtbl.t = Hashtbl.create 4

(* Module files contributed by the manifest's dependencies. A package's
   directory tree is its public module tree — `walk`-style — so a package
   registers its files relative to its own root (the file named after the
   package's short name becomes the module the `require` binds).
   Transitive dependencies are walked through each package's manifest. *)
let dependency_modules ~(root : string) ~(registry : string option) :
    (string list * string) list =
  match registry with
  | None | Some "" -> []
  | Some endpoint -> (
      let manifest_path = Filename.concat root "package.emo" in
      match Lsp_util.read_file manifest_path with
      | None -> []
      | Some source -> (
          match Emo_pkg.parse_manifest ~file:manifest_path ~source with
          | exception Emo_pkg.Manifest_error _ -> []
          | manifest ->
              let lock =
                match
                  Emo_pkg.Lockfile.read
                    (Filename.concat root Emo_pkg.Lockfile.filename)
                with
                | Ok entries -> entries
                | Error _ -> []
              in
              let lock_version name =
                match
                  List.find_opt (fun e -> e.Emo_pkg.Lockfile.dep = name) lock
                with
                | Some e -> Some e.Emo_pkg.Lockfile.version
                | None -> None
              in
              let visited : (string, unit) Hashtbl.t = Hashtbl.create 8 in
              let out = ref [] in
              let rec go (name, pinned) depth =
                if depth > 6 || Hashtbl.mem visited name then ()
                else begin
                  Hashtbl.replace visited name ();
                  let version =
                    match lock_version name with Some v -> v | None -> pinned
                  in
                  let dir =
                    Filename.concat endpoint
                      (Filename.concat name (Emo_pkg.Version.to_string version))
                  in
                  if Lsp_util.is_directory dir then begin
                    List.iter
                      (fun (rel, file) -> out := (rel, file) :: !out)
                      (scan dir);
                    let pkg_manifest = Filename.concat dir "package.emo" in
                    match Lsp_util.read_file pkg_manifest with
                    | Some psrc -> (
                        match
                          Emo_pkg.parse_manifest ~file:pkg_manifest ~source:psrc
                        with
                        | pm ->
                            List.iter
                              (fun (n, v) -> go (n, v) (depth + 1))
                              pm.Emo_pkg.deps
                        | exception Emo_pkg.Manifest_error _ -> ())
                    | None -> ()
                  end
                end
              in
              List.iter (fun (n, v) -> go (n, v) 0) manifest.Emo_pkg.deps;
              !out))

(* The index for [root], rebuilt only when the tree's fingerprint moves.
   Dependency modules ride along so names like `http` and `net` resolve
   in diagnostics and completion. *)
let get ?registry (root : string) : t =
  let root = Lsp_util.normalize_path root in
  let project_modules = scan root in
  let dep_modules = dependency_modules ~root ~registry in
  let modules = project_modules @ dep_modules in
  let key = root ^ "|" ^ Option.value ~default:"" registry in
  let fp = fingerprint root modules in
  match Hashtbl.find_opt cache key with
  | Some (cached_fp, ix) when cached_fp = fp -> ix
  | _ ->
      let symbols =
        List.concat_map
          (fun (module_path, file) ->
            let items = parse_tolerant file in
            collect_items ~file ~module_path items
            @ collect_locals ~file ~module_path items)
          modules
      in
      let ix = index_of root ~modules ~symbols in
      Hashtbl.replace cache key (fp, ix);
      ix

let invalidate ?root () : unit =
  match root with
  | Some r ->
      let prefix = Lsp_util.normalize_path r ^ "|" in
      Hashtbl.iter
        (fun key _ ->
          if Lsp_util.starts_with ~prefix key || key = Lsp_util.normalize_path r
          then Hashtbl.remove cache key)
        cache
  | None -> Hashtbl.reset cache

(* ---- Locating the project root for a file --------------------------- *)

(* The nearest ancestor (inclusive) holding a package.emo manifest, else
   the fallback supplied by the client (its workspace root), else the
   file's own directory. *)
let find_root ?(fallback : string option) (file : string) : string =
  let rec up dir =
    if Lsp_util.file_exists (Filename.concat dir "package.emo") then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then dir else up parent
  in
  let start = Filename.dirname (Lsp_util.normalize_path file) in
  match up start with
  | dir when Lsp_util.file_exists (Filename.concat dir "package.emo") -> dir
  | _ -> ( match fallback with Some d -> d | None -> start)
