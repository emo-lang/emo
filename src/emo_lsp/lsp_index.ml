(* The project index: every declaration under the project root, plus the
   module table that maps a qualified path to its `.emo` file.

   The directory tree is the module tree (README, Modules and Visibility),
   so a path like `shop.order` is just `shop/order.emo`. The index is
   rebuilt lazily and cached by a fingerprint of the tree's mtimes.

   The root is the directory the file's project stands in, and a project
   is a directory holding a package.emo — the compiler's root rule
   (E5010). A file under no such directory has no index: the editor
   answers from nothing rather than from a tree the compiler would
   refuse. *)

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

(* ---- Rendering type declarations and signatures --------------------- *)

let rec type_decl_to_string (t : Ast.type_decl) : string =
  match t.Ast.type_desc with
  | Ast.Named_type n -> n
  | Ast.Applied_type (n, args) ->
      n ^ "[" ^ String.concat ", " (List.map type_decl_to_string args) ^ "]"
  | Ast.Tuple_type ts ->
      "(" ^ String.concat ", " (List.map type_decl_to_string ts) ^ ")"

let params_to_string (ps : Ast.param list) : string =
  String.concat ", "
    (List.map
       (fun p -> p.Ast.param_name ^ " " ^ type_decl_to_string p.Ast.param_type)
       ps)

let def_signature (d : Ast.fun_def) : string =
  let ret =
    match d.Ast.def_return with
    | Some r -> " " ^ type_decl_to_string r
    | None -> ""
  in
  Printf.sprintf "def %s(%s)%s" d.Ast.def_name
    (params_to_string d.Ast.def_params)
    ret

let foreign_signature (f : Ast.foreign_def) : string =
  Printf.sprintf "foreign def %s(%s) %s = \"%s\"" f.Ast.foreign_name
    (params_to_string f.Ast.foreign_params)
    (type_decl_to_string f.Ast.foreign_return)
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
  | Ast.Map_literal _ -> "{...}"
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
                        (type_decl_to_string m.Ast.sig_return))
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
          {
            Ast.stmt_desc =
              Ast.Binding
                {
                  mutable_;
                  pattern = { pattern_desc = Ast.Pattern_binding name; _ };
                  init;
                  _;
                };
            stmt_span;
          } ->
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
              (p.Ast.param_name ^ " " ^ type_decl_to_string p.Ast.param_type)
            ~file ~span:p.Ast.param_type.Ast.type_span ~container:None
            ~module_path ~local:true
          :: !out)
      ps
  in
  let rec walk_stmts ~container:_ (stmts : Ast.stmt list) =
    List.iter
      (fun (s : Ast.stmt) ->
        match s.Ast.stmt_desc with
        | Ast.Binding
            {
              mutable_;
              pattern = { pattern_desc = Ast.Pattern_binding name; _ };
              _;
            } ->
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
  units : (string list * Ast.item list) list;
      (* module path -> parsed items: the pre-registration input, so a
         check sees every module's declarations, dependencies included *)
  symbols : symbol list;
  packages : string list list;
      (* the short-name prefix of every indexed package: the checker's
         visibility rule keys on these, exactly as a build's does *)
  package_deps : (string list * string list) list;
      (* package prefix -> the scoped names it declares in its manifest;
         the root project uses [] *)
  aliases : (string list * string list) list;
      (* module path -> the path it resolves to: a package's `main.emo`
         entry is reachable by both spellings and they are one module *)
  by_name : (string, symbol list) Hashtbl.t;
  by_container : (string, symbol list) Hashtbl.t;
  by_file : (string, symbol list) Hashtbl.t;
  built_at : float;
}

let index_of ?(units = []) ?(packages = []) ?(package_deps = []) ?(aliases = [])
    (root : string) ~(modules : (string list * string) list)
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
    units;
    symbols;
    packages;
    package_deps;
    aliases;
    by_name;
    by_container;
    by_file;
    built_at = Unix.gettimeofday ();
  }

(* The index for a file that stands outside any project: the editor still
   answers requests, it simply has no declarations to resolve against. *)
let empty : t = index_of "" ~modules:[] ~symbols:[]

(* The parsed items of every indexed module, with [items] substituted for
   the module [current]: a diagnostic check runs against the editor's own
   text for the file being checked while every other module — project or
   dependency — contributes its declarations, so cross-module members
   (`sync.done`, `json.decode`) resolve. *)
let units_for (ix : t) ~(current : string list) (items : Ast.item list) :
    (string list * Ast.item list) list =
  let replaced = ref false in
  let units =
    List.map
      (fun (path, existing) ->
        if path = current then (
          replaced := true;
          (path, items))
        else (path, existing))
      ix.units
  in
  if !replaced then units else (current, items) :: units

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
   root-relative path without the `.emo` extension. A child directory
   holding its own package.emo is a project of its own — the compiler's
   walk leaves it out, so the index does too: resolving a reference the
   compiler refuses is worse than resolving nothing. *)
let scan (root : string) : (string list * string) list =
  let acc = ref [] in
  let rec walk (rel : string list) (dir : string) =
    List.iter
      (fun entry ->
        if entry = "package.emo" || entry = "package.lock" then ()
        else
          let path = Filename.concat dir entry in
          if Lsp_util.is_directory path then
            if skip_dir entry then ()
            else if Lsp_util.file_exists (Filename.concat path "package.emo")
            then ()
            else walk (rel @ [ entry ]) path
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

(* Declaration symbols for every indexed module, from the parsed items so
   the tree is parsed once per index build. *)
let symbols_of (modules : (string list * string) list)
    (units : (string list * Ast.item list) list) : symbol list =
  List.concat
    (List.map2
       (fun (module_path, file) (_, items) ->
         collect_items ~file ~module_path items
         @ collect_locals ~file ~module_path items)
       modules units)

let cache : (string, string * t) Hashtbl.t = Hashtbl.create 4

(* ---- Dependency packages -------------------------------------------- *)

(* The dependency side of the index: every package the manifest pins —
   transitively, through each package's own manifest — with the module
   table and the three tables a check needs to resolve through them (the
   package prefixes, the declared deps behind the visibility rule, and
   the main-entry aliases), all mounted the way the compiler's
   `register_package` registers a package. *)
type dep_tree = {
  dep_modules : (string list * string) list;
  dep_packages : string list list;
  dep_package_deps : (string list * string list) list;
  dep_aliases : (string list * string list) list;
}

let empty_tree =
  {
    dep_modules = [];
    dep_packages = [];
    dep_package_deps = [];
    dep_aliases = [];
  }

let is_http_endpoint endpoint =
  String.starts_with ~prefix:"http://" endpoint
  || String.starts_with ~prefix:"https://" endpoint

(* The bundled standard library rides the compiler binary, so the editor
   resolves a stdlib package with nothing beside it — a build fetches it
   into the shared content-addressed cache, and the index reads it from
   there. Materializing writes exactly what a build would write, once
   per package; the embedded data cannot move for the process's
   lifetime, so the lookup is memoized. *)
let embedded_dirs : (string, string option) Hashtbl.t = Hashtbl.create 8

let embedded_package_dir ~(name : string) ~(version : Emo_pkg.Version.t) :
    string option =
  let cache_dir = Emo_pkg.Registry.default_cache_dir () in
  let key = name ^ "@" ^ Emo_pkg.Version.to_string version ^ "@" ^ cache_dir in
  match Hashtbl.find_opt embedded_dirs key with
  | Some dir -> dir
  | None ->
      let dir =
        match
          Emo_pkg.Registry.fetch Emo_pkg.Registry.Embedded ~name ~version
        with
        | Error _ -> None
        | Ok fetched -> (
            if Emo_pkg.Registry.is_cached ~cache_dir fetched then
              Some (Emo_pkg.Registry.cache_path ~cache_dir fetched)
            else
              match Emo_pkg.Registry.materialize ~cache_dir fetched with
              | Ok dir -> Some dir
              | Error _ -> None)
      in
      Hashtbl.replace embedded_dirs key dir;
      dir

(* Where a dependency's sources stand. A configured filesystem registry
   serves every name — its endpoint directories hold the layout. With
   none configured (or an HTTP endpoint, which the editor never waits
   on), an unscoped name comes from the bundled standard library; a
   scoped name appears only when a build already fetched it — the cache
   directory the lockfile's checksum names. [None] when nothing on disk
   serves the name: the editor resolves no reference the compiler would
   fetch over the network. *)
let package_dir ~(registry : string option) ~(name : string)
    ~(version : Emo_pkg.Version.t) ~(locked_checksum : string option) :
    string option =
  match registry with
  | Some endpoint when not (is_http_endpoint endpoint) ->
      let dir =
        Filename.concat endpoint
          (Filename.concat name (Emo_pkg.Version.to_string version))
      in
      if Lsp_util.is_directory dir then Some dir else None
  | _ ->
      if String.contains name '/' then
        match locked_checksum with
        | Some checksum ->
            let dir =
              Filename.concat
                (Emo_pkg.Registry.default_cache_dir ())
                (name ^ "-" ^ Emo_pkg.Version.to_string version ^ "-" ^ checksum)
            in
            if Lsp_util.is_directory dir then Some dir else None
        | None -> None
      else embedded_package_dir ~name ~version

(* A package's files under the compiler's keying: the entry file — the
   root's `main.emo` when it holds one, else the file named after the
   package — is the module a require binds, and a `main.emo` keeps its
   own name beside it (the two spellings are one module, an alias).
   Every other file becomes a child of the short name, so two packages'
   `internal` and `mark` do not collide. *)
let mount_package ~(short : string) ~(dir : string) :
    (string list * string) list * (string list * string list) list =
  let scanned = scan dir in
  let from_project = List.mem_assoc [ "main" ] scanned in
  let body = if from_project then "main" else short in
  let modules =
    List.concat_map
      (fun (rel, file) ->
        match rel with
        | [ name ] when name = body ->
            if from_project then
              [ ([ short ], file); ([ short; "main" ], file) ]
            else [ ([ short ], file) ]
        | _ -> [ (short :: rel, file) ])
      scanned
  in
  let aliases =
    if from_project then [ ([ short; "main" ], [ short ]) ] else []
  in
  (modules, aliases)

(* Module files contributed by the manifest's dependencies — the standard
   library's packages among them, pinned in `deps` like any other. Each
   package's directory tree is its public module tree, registered under
   the short name the require binds. Transitive dependencies are walked
   through each package's manifest. *)
let dependency_tree ~(root : string) ~(registry : string option) : dep_tree =
  let manifest_path = Filename.concat root "package.emo" in
  match Lsp_util.read_file manifest_path with
  | None -> empty_tree
  | Some source -> (
      match Emo_pkg.parse_manifest ~file:manifest_path ~source with
      | exception Emo_pkg.Manifest_error _ -> empty_tree
      | manifest ->
          let lock =
            match
              Emo_pkg.Lockfile.read
                (Filename.concat root Emo_pkg.Lockfile.filename)
            with
            | Ok entries -> entries
            | Error _ -> []
          in
          let lock_entry name =
            List.find_opt (fun e -> e.Emo_pkg.Lockfile.dep = name) lock
          in
          let visited : (string, unit) Hashtbl.t = Hashtbl.create 8 in
          let modules = ref [] in
          let packages = ref [] in
          let package_deps = ref [] in
          let aliases = ref [] in
          (* the root project's own deps, for the visibility rule *)
          package_deps :=
            ([], List.map fst manifest.Emo_pkg.deps) :: !package_deps;
          let rec go (name, pinned) depth =
            if depth > 6 || Hashtbl.mem visited name then ()
            else begin
              Hashtbl.replace visited name ();
              let version =
                match lock_entry name with
                | Some e -> e.Emo_pkg.Lockfile.version
                | None -> pinned
              in
              let locked_checksum =
                Option.map
                  (fun e -> e.Emo_pkg.Lockfile.checksum)
                  (lock_entry name)
              in
              match package_dir ~registry ~name ~version ~locked_checksum with
              | None -> ()
              | Some dir -> begin
                  let short = Emo_pkg.short_name name in
                  let pkg_modules, pkg_aliases = mount_package ~short ~dir in
                  modules := pkg_modules @ !modules;
                  packages := [ short ] :: !packages;
                  aliases := pkg_aliases @ !aliases;
                  let pkg_manifest = Filename.concat dir "package.emo" in
                  match Lsp_util.read_file pkg_manifest with
                  | Some psrc -> (
                      match
                        Emo_pkg.parse_manifest ~file:pkg_manifest ~source:psrc
                      with
                      | pm ->
                          package_deps :=
                            ([ short ], List.map fst pm.Emo_pkg.deps)
                            :: !package_deps;
                          List.iter
                            (fun (n, v) -> go (n, v) (depth + 1))
                            pm.Emo_pkg.deps
                      | exception Emo_pkg.Manifest_error _ -> ())
                  | None -> ()
                end
            end
          in
          List.iter (fun (n, v) -> go (n, v) 0) manifest.Emo_pkg.deps;
          {
            dep_modules = !modules;
            dep_packages = !packages;
            dep_package_deps = !package_deps;
            dep_aliases = !aliases;
          })

let dependency_modules ~(root : string) ~(registry : string option) :
    (string list * string) list =
  (dependency_tree ~root ~registry).dep_modules

let build (root : string) : t =
  let tree = dependency_tree ~root ~registry:None in
  let modules = scan root @ tree.dep_modules in
  let units =
    List.map (fun (path, file) -> (path, parse_tolerant file)) modules
  in
  let symbols = symbols_of modules units in
  index_of root ~modules ~units ~symbols ~packages:tree.dep_packages
    ~package_deps:tree.dep_package_deps ~aliases:tree.dep_aliases

(* The index for [root], rebuilt only when the tree's fingerprint moves.
   Dependency modules ride along so names like `http` and `net` resolve
   in diagnostics and completion. *)
let get ?registry (root : string) : t =
  let root = Lsp_util.normalize_path root in
  let project_modules = scan root in
  let tree = dependency_tree ~root ~registry in
  let modules = project_modules @ tree.dep_modules in
  let key = root ^ "|" ^ Option.value ~default:"" registry in
  let fp = fingerprint root modules in
  match Hashtbl.find_opt cache key with
  | Some (cached_fp, ix) when cached_fp = fp -> ix
  | _ ->
      let units =
        List.map (fun (path, file) -> (path, parse_tolerant file)) modules
      in
      let symbols = symbols_of modules units in
      let ix =
        index_of root ~modules ~units ~symbols ~packages:tree.dep_packages
          ~package_deps:tree.dep_package_deps ~aliases:tree.dep_aliases
      in
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

(* The directory the file's project is rooted at: the workspace root the
   client named, else the file's own directory — and only when that
   directory holds a package.emo. Nothing is looked up above it: the
   compiler's root rule reads the directory it runs in and no ancestor
   (E5010), so the editor makes the same single guess rather than
   indexing a tree the compiler would refuse. *)
let find_root ?(fallback : string option) (file : string) : string option =
  let candidate =
    match fallback with
    | Some dir -> dir
    | None -> Filename.dirname (Lsp_util.normalize_path file)
  in
  if Lsp_util.file_exists (Filename.concat candidate "package.emo") then
    Some candidate
  else None
