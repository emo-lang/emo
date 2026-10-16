module Ast = Emo_ast

(* The project layer: the directory tree is the module tree. Discovers the
   module table under the working directory and resolves qualified paths.
   Codes for this stage are E5xxx.

   The root rule: the project root is where the compiler stands. The
   working directory must hold a package.emo — that directory is the
   package, and every .emo file under it is a module at its path. The
   search never walks upward: a directory without a manifest is not a
   project (E5010), and an entry file that is not a module of the package
   is not part of one (E5011). *)

(* Raised when the static stages of any module found errors. *)
exception Static_errors of Emo_support.Diagnostic.t list

type module_kind =
  | File of string (* the .emo file backing the module *)
  | Dir of string (* the directory holding child modules *)

type project = {
  root : string; (* filesystem path of the project root (the working dir) *)
  files : (string list, string) Hashtbl.t; (* module path → .emo file *)
  dirs : (string list, string) Hashtbl.t; (* module path → directory *)
  mutable packages : string list list;
      (* the short-name prefix of every fetched package registered in
         [files] / [dirs]: a module under one of these is addressed by
         its full prefixed path from outside, and relative to the prefix
         from inside (a package's own references are written against its
         root, per the README's module tree) *)
  mutable package_deps : (string list * string list) list;
      (* a package prefix → the scoped names it declares in its manifest
         (the root project's deps use the prefix []): a module may
         reference only its own package's subtree and its own declared
         deps, and a `require` is paired against the owning package's
         manifest, so a package cannot reach a sibling or transitive
         dependency it never declared *)
  diagnostics : Emo_support.Diagnostic.t list ref;
  cache : (string, string * Ast.item list) Hashtbl.t;
      (* file → (content hash, parsed items): unchanged modules skip
         re-lex/parse within a run *)
  mutable parses : int; (* number of actual lex/parse operations *)
}

let report p code message =
  let span =
    Emo_support.Span.make ~file:p.root ~line:1 ~col:1 ~start:0 ~stop:0
  in
  p.diagnostics :=
    Emo_support.Diagnostic.
      { severity = Error; code = Some code; message; span; hint = None }
    :: !(p.diagnostics)

let entries dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | raw ->
      raw |> Array.to_list |> List.sort compare
      |> List.filter_map (fun entry ->
          if entry = "." || entry = ".." || entry = "_build" then None
          else if entry = "package.emo" then None
          (* A package.emo is a manifest, never a module — at any depth. *)
            else
            let path = Filename.concat dir entry in
            if Sys.file_exists path && Sys.is_directory path then
              Some (entry, `Dir path)
            else if Filename.check_suffix entry ".emo" then
              Some (Filename.remove_extension entry, `File path)
            else None)

(* Registers every .emo file and every directory under [fs_dir] as a module
   at [rel] ^ name. A file and a directory with the same stem are a
   collision — two modules claiming one path. A directory holding its own
   package.emo is a project of its own: the walk leaves it out entirely —
   a nested package never leaks its requires into the outer tree. *)
(* The entry's dirname can carry a trailing "/." (from resolution);
   the file keys must match the entry's own clean absolute form or the
   entry lookup misses and the module lowers twice. *)
let normalize_path (path : string) : string =
  let n = String.length path in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if
      !i + 2 < n
      && path.[!i] = '/'
      && path.[!i + 1] = '.'
      && path.[!i + 2] = '/'
    then i := !i + 2
    else (
      Buffer.add_char buf path.[!i];
      incr i)
  done;
  let s = Buffer.contents buf in
  let s =
    if String.length s > 2 && String.ends_with ~suffix:"/." s then
      String.sub s 0 (String.length s - 2)
    else s
  in
  s

(* [body] names the file that is the current module's own body rather
   than a child: registering a package [json] walks the package root with
   [body = Some "json"], so [json.emo] defines the module `json` while
   [internal/] and [mark.emo] become `json.internal` and `json.mark`. *)
let rec walk ?(body : string option) p rel fs_dir =
  List.iter
    (fun (name, kind) ->
      let path = rel @ [ name ] in
      match kind with
      | `Dir fs_path ->
          if Sys.file_exists (Filename.concat fs_path "package.emo") then ()
          else if Hashtbl.mem p.files path then
            report p "E5005"
              (Printf.sprintf "module path `%s` is claimed by both %s and %s"
                 (String.concat "." path)
                 (Hashtbl.find p.files path)
                 fs_path)
          else if Hashtbl.mem p.dirs path then ()
          else (
            Hashtbl.replace p.dirs path fs_path;
            walk p path fs_path)
      | `File fs_path -> (
          let fs_path = normalize_path fs_path in
          match body with
          | Some b when String.equal name b ->
              if Hashtbl.mem p.files rel then
                report p "E5005"
                  (Printf.sprintf
                     "module path `%s` is claimed by both %s and %s"
                     (String.concat "." rel) (Hashtbl.find p.files rel) fs_path)
              else Hashtbl.replace p.files rel fs_path
          | _ ->
              if Hashtbl.mem p.dirs path then
                report p "E5005"
                  (Printf.sprintf
                     "module path `%s` is claimed by both %s and %s"
                     (String.concat "." path) fs_path (Hashtbl.find p.dirs path))
              else if Hashtbl.mem p.files path then ()
              else Hashtbl.replace p.files path fs_path))
    (entries fs_dir)

(* Discovers the module tree under the working directory. *)
let discover () : project =
  let root = Sys.getcwd () in
  let p =
    {
      root;
      files = Hashtbl.create 8;
      dirs = Hashtbl.create 8;
      packages = [];
      package_deps = [];
      diagnostics = ref [];
      cache = Hashtbl.create 8;
      parses = 0;
    }
  in
  (* The root directory is itself a module (the empty path). *)
  Hashtbl.replace p.dirs [] p.root;
  walk p [] p.root;
  p

(* Resolves a (normalized) module path to its file or directory. *)
let resolve p (path : string list) : module_kind option =
  match Hashtbl.find_opt p.files path with
  | Some f -> Some (File f)
  | None -> Option.map (fun d -> Dir d) (Hashtbl.find_opt p.dirs path)

(* All known module file paths (segment lists), for the checker and graph. *)
let module_paths p : string list list =
  Hashtbl.fold (fun path _ acc -> path :: acc) p.files []

let diagnostics p : Emo_support.Diagnostic.t list = List.rev !(p.diagnostics)

(* Child modules of a module, from the registered tables rather than the
   filesystem: a package's public module `json` is a body file ([json.emo])
   that also has children ([json.internal], [json.mark]), so a module path
   may be both a body and a namespace. Scanning keys one segment deeper
   yields exactly the children and naturally excludes the body itself. *)
let children p (path : string list) : (string * string list) list =
  let n = List.length path in
  let collect tbl acc =
    Hashtbl.fold
      (fun key _ acc ->
        if List.length key = n + 1 && List.take n key = path then
          (List.nth key n, key) :: acc
        else acc)
      tbl acc
  in
  List.sort
    (fun (a, _) (b, _) -> compare a b)
    (collect p.dirs (collect p.files []))

(* The package a module path belongs to: the short-name prefix registered
   for a fetched dependency, or [] for the project's own tree. *)
let package_of p (path : string list) : string list =
  match
    List.find_opt
      (fun pkg ->
        List.length pkg <= List.length path
        && List.take (List.length pkg) path = pkg)
      p.packages
  with
  | Some pkg -> pkg
  | None -> []

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Parses a file through the content-hash cache: unchanged files reuse
   their parsed items across every stage of a run. *)
let parse_cached p (file : string) : Ast.item list =
  let source = read_file file in
  let hash = Digest.string source in
  match Hashtbl.find_opt p.cache file with
  | Some (cached_hash, items) when cached_hash = hash -> items
  | _ ->
      p.parses <- p.parses + 1;
      let items =
        match Emo_parser.parse_program_with_diagnostics ~file ~source with
        | exception Emo_lexer.Error d -> raise (Static_errors [ d ])
        | (_, first :: _) as parsed ->
            let _, diagnostics = parsed in
            ignore first;
            raise (Static_errors diagnostics)
        | items, [] -> items
      in
      Hashtbl.replace p.cache file (hash, items);
      items

(* Evaluates one module's items in a fresh environment (the module's
   namespace) and returns it. This is the whole load story: top-level items
   run once, on first load, in file order. A package's own submodule names
   are pre-bound in the environment, so a reference inside the package is
   written against the package root (`internal.float` in `json.emo` means
   `json.internal.float`) — and a def body's closure captures this env, so
   the binding holds when the def is called later. *)
let load_module p (handle_of : string list -> Emo_eval.module_handle option)
    (path : string list) : Emo_eval.env =
  match Hashtbl.find_opt p.files path with
  | None ->
      failwith
        (Printf.sprintf "module `%s` has no backing file"
           (String.concat "." path))
  | Some file ->
      let items = parse_cached p file in
      let env = Emo_eval.global_env () in
      (match package_of p path with
      | [] -> ()
      | pkg ->
          List.iter
            (fun (name, child) ->
              match handle_of child with
              | Some h ->
                  Emo_eval.define env name ~mutable_:false (Emo_eval.Module h)
              | None -> ())
            (children p pkg));
      List.iter (Emo_eval.eval_item ~module_path:path env) items;
      env

(* Installs the evaluator's module hooks for this project: discovery
   (normalized path → handle with children) and loading. *)
let install_hooks p =
  (* One run, one set of program-wide registries: stale entries from a
     previous run in the same process must not serve this one. *)
  Emo_eval.reset_program_registries ();
  (* Handles are memoized per module path: every reference to `shop.order`
     shares one namespace and one load. *)
  let handles : (string list, Emo_eval.module_handle) Hashtbl.t =
    Hashtbl.create 8
  in
  let handle_of path =
    match Hashtbl.find_opt handles path with
    | Some h -> Some h
    | None -> (
        match resolve p path with
        | None -> None
        | Some _ ->
            let h =
              {
                Emo_eval.mpath = path;
                mchildren = children p path;
                menv = None;
                loading = false;
              }
            in
            Hashtbl.replace handles path h;
            Some h)
  in
  Emo_eval.module_handle_of := handle_of;
  (Emo_eval.module_loader := fun path -> load_module p handle_of path);
  (* The program's bare-type owner index: type names are program-wide
     (CHECK.md, cross-module types), but a bare reference carries no
     module path to load through. Resolved on demand — the first lookup
     scans the project's files (through the parse cache), the declaring
     module loads like any module reference, and the answer memoizes,
     including the negative ones the builtins produce. *)
  let resolved_types : (string, Emo_eval.value option) Hashtbl.t =
    Hashtbl.create 16
  in
  Emo_eval.type_owner_of :=
    fun name ->
      match Hashtbl.find_opt resolved_types name with
      | Some v -> v
      | None ->
          let answer =
            Hashtbl.fold
              (fun path file acc ->
                match acc with
                | Some _ -> acc
                | None -> (
                    let items =
                      try Some (parse_cached p file) with _ -> None
                    in
                    match items with
                    | None -> None
                    | Some items -> (
                        let declares =
                          List.exists
                            (fun item ->
                              match item.Ast.item_desc with
                              | Ast.Item_class c ->
                                  String.equal c.Ast.class_name name
                              | Ast.Item_enum e ->
                                  String.equal e.Ast.enum_name name
                              | _ -> false)
                            items
                        in
                        if not declares then None
                        else
                          match handle_of path with
                          | None -> None
                          | Some h ->
                              Emo_eval.ensure_module_loaded h;
                              let menv = Option.get h.Emo_eval.menv in
                              Emo_eval.lookup_opt menv name)))
              p.files None
          in
          Hashtbl.replace resolved_types name answer;
          answer

(* `internal` is subtree-private: a module whose path contains an internal
   segment may only be referenced from modules under that segment's parent.
   Returns one diagnostic per violation, naming both modules. *)
let check_internal_privacy (graph : (string list, string list list) Hashtbl.t) :
    Emo_support.Diagnostic.t list =
  let dotted path = String.concat "." path in
  List.concat_map
    (fun (use_site, refs) ->
      List.filter_map
        (fun r ->
          let rec internal_parent before = function
            | "internal" :: _ -> Some (List.rev before)
            | seg :: rest -> internal_parent (seg :: before) rest
            | [] -> None
          in
          match internal_parent [] r with
          | Some parent ->
              let rec prefix n xs =
                if n <= 0 then []
                else
                  match xs with
                  | [] -> []
                  | x :: rest -> x :: prefix (n - 1) rest
              in
              let shares =
                List.length use_site >= List.length parent
                && prefix (List.length parent) use_site = parent
              in
              if shares then None
              else
                Some
                  {
                    Emo_support.Diagnostic.severity = Error;
                    code = Some "E5001";
                    message =
                      Printf.sprintf
                        "module `%s` cannot reference `%s`: `internal` is \
                         subtree-private"
                        (dotted use_site) (dotted r);
                    span =
                      Emo_support.Span.make ~file:(dotted use_site) ~line:1
                        ~col:1 ~start:0 ~stop:0;
                    hint = None;
                  }
          | None -> None)
        refs)
    (Hashtbl.fold (fun path refs acc -> (path, refs) :: acc) graph [])

(* Checks every module in the project, collecting the reference graph.
   Returns per-module references and every diagnostic found. *)
(* Detects a reference cycle between file modules and returns its chain
   (first module repeated at the end). Only file modules form edges — a
   directory reference is a namespace, not a load. *)
let find_cycle (graph : (string list, string list list) Hashtbl.t) :
    string list list option =
  let rec dfs visiting node =
    if List.mem node visiting then
      (* The cycle runs from [node] (where visiting re-enters) forward. *)
      let rec chain = function
        | [] -> [ node ]
        | x :: rest -> if x = node then [ x ] else x :: chain rest
      in
      Some (node :: chain visiting)
    else
      match Hashtbl.find_opt graph node with
      | None | Some [] -> None
      | Some refs ->
          let visiting = node :: visiting in
          List.find_map (dfs visiting) refs
  in
  let rec anywhere (nodes : string list list) : string list list option =
    match nodes with
    | [] -> None
    | node :: rest -> (
        match dfs [] node with Some c -> Some c | None -> anywhere rest)
  in
  anywhere (Hashtbl.fold (fun path _ acc -> path :: acc) graph [])

let check_project (p : project) :
    string list list
    * (string list * string list list * (string * Emo_support.Span.t) list) list
    * Emo_check.program_types
    * Emo_support.Diagnostic.t list =
  let module_paths = module_paths p in
  let graph : (string list, string list list) Hashtbl.t = Hashtbl.create 8 in
  let requires_table :
      (string list, (string * Emo_support.Span.t) list) Hashtbl.t =
    Hashtbl.create 8
  in
  (* Parse every module first: the program's type tables (CHECK.md,
     cross-module types) need every declaration before any module is
     checked. *)
  let units =
    Hashtbl.fold
      (fun path file acc ->
        let source = read_file file in
        let items =
          match Emo_parser.parse_program_with_diagnostics ~file ~source with
          | exception Emo_lexer.Error d -> raise (Static_errors [ d ])
          | (_, first :: _) as parsed ->
              let _, diagnostics = parsed in
              ignore first;
              raise (Static_errors diagnostics)
          | items, [] -> items
        in
        (path, items) :: acc)
      p.files []
  in
  let program, preregister_errors =
    Emo_check.preregister_types ~packages:p.packages
      ~package_deps:p.package_deps ~units
  in
  let errors, entries =
    List.fold_left
      (fun (errors, entries) (path, items) ->
        let diagnostics, refs, requires =
          Emo_check.check_module ~modules:module_paths ~packages:p.packages
            ~package_deps:p.package_deps ~current:path ~program items
        in
        Hashtbl.replace graph path refs;
        Hashtbl.replace requires_table path requires;
        match diagnostics with
        | [] -> (errors, entries)
        | ds -> (ds @ errors, (path, refs) :: entries))
      ([], []) units
  in
  let internal_errors = check_internal_privacy graph in
  let cycle_error =
    match find_cycle graph with
    | None -> []
    | Some chain ->
        let dotted path = String.concat "." path in
        let rec chain_string = function
          | [] -> ""
          | [ last ] -> dotted last
          | node :: rest -> dotted node ^ " -> " ^ chain_string rest
        in
        [
          Emo_support.Diagnostic.
            {
              severity = Error;
              code = Some "E5003";
              message = "module reference cycle: " ^ chain_string chain;
              span =
                Emo_support.Span.make ~file:p.root ~line:1 ~col:1 ~start:0
                  ~stop:0;
              hint = None;
            };
        ]
  in
  (* Strict pairing: every require must name a dependency its own
     package's manifest declares. The require is paired against the
     requiring module's package, not the project's: a package's internal
     `require` answers to that package's deps block. *)
  let pairing_errors =
    List.concat_map
      (fun (path, requires) ->
        let pkg = package_of p path in
        let declared =
          match List.assoc_opt pkg p.package_deps with
          | Some ds -> ds
          | None -> []
        in
        List.filter_map
          (fun (dep, span) ->
            if List.mem dep declared then None
            else
              Some
                {
                  Emo_support.Diagnostic.severity = Error;
                  code = Some "E5006";
                  message =
                    Printf.sprintf
                      "module `%s` requires `%s`, but its package's manifest \
                       (package.emo) does not list it in deps"
                      (String.concat "." path) dep;
                  span;
                  hint =
                    Some
                      "add the package to the manifest's deps block, or remove \
                       the require";
                })
          requires)
      (Hashtbl.fold (fun k v acc -> (k, v) :: acc) requires_table [])
  in
  let entries =
    List.map
      (fun (path, refs) ->
        let requires =
          match Hashtbl.find_opt requires_table path with
          | Some r -> r
          | None -> []
        in
        (path, refs, requires))
      entries
  in
  ( module_paths,
    entries,
    program,
    preregister_errors @ errors @ internal_errors @ cycle_error @ pairing_errors
  )

(* Runs the entry file: the graph is discovered up front (collisions report
   immediately), modules load lazily on first access with load-once
   semantics, and the entry's own items evaluate in file order. With
   ~check:true every module is checked first. *)
(* The manifest of the project at the working directory. The root rule
   reads only this directory: a project is where you stand, never where
   some ancestor's manifest happens to sit. *)
let manifest_here () : string option =
  let candidate = Filename.concat (Sys.getcwd ()) "package.emo" in
  if Sys.file_exists candidate then Some candidate else None

let no_manifest_error () =
  Static_errors
    [
      {
        Emo_support.Diagnostic.severity = Error;
        code = Some "E5010";
        message = "no package.emo in the current directory";
        span =
          Emo_support.Span.make ~file:(Sys.getcwd ()) ~line:1 ~col:1 ~start:0
            ~stop:0;
        hint = Some "run `emo new <name>` to scaffold a project here";
      };
    ]

(* Parses the manifest at [manifest_path] and re-roots the project's
   module tree at the manifest's directory — the package is the module
   tree's root, not whatever directory the compiler ran in. *)
let use_manifest (p : project) (manifest_path : string) :
    project * (Emo_pkg.manifest * string (* its directory *)) =
  let manifest =
    match
      Emo_pkg.parse_manifest ~file:manifest_path
        ~source:(read_file manifest_path)
    with
    | m -> m
    | exception Emo_pkg.Manifest_error d -> raise (Static_errors [ d ])
  in
  (* Re-root at an absolute manifest directory: every registered
     file path is then absolute, so the entry lookup (which
     absolutizes the entry file) matches what the walk registers —
     a relative entry used to slip past the match and get lowered
     twice, once as the root module and once under its own name. *)
  let dir =
    let d = Filename.dirname manifest_path in
    if Filename.is_relative d then Filename.concat (Sys.getcwd ()) d else d
  in
  Hashtbl.reset p.files;
  Hashtbl.reset p.dirs;
  Hashtbl.replace p.dirs [] dir;
  walk p [] dir;
  (* The project's own manifest is data, not a module. *)
  Hashtbl.remove p.files [ "package" ];
  (p, (manifest, dir))

(* Discovers the project and parses the manifest at the working directory.
   Without one there is no project: E5010 names the missing manifest
   rather than guessing at an ancestor's. *)
let prepare () : project * (Emo_pkg.manifest * string (* its directory *)) =
  let p = discover () in
  (match diagnostics p with [] -> () | ds -> raise (Static_errors ds));
  match manifest_here () with
  | None -> raise (no_manifest_error ())
  | Some manifest_path -> use_manifest p manifest_path

let dep_error ~(manifest_dir : string) (message : string) =
  Static_errors
    [
      {
        Emo_support.Diagnostic.severity = Error;
        code = Some "E5007";
        message;
        span =
          Emo_support.Span.make ~file:manifest_dir ~line:1 ~col:1 ~start:0
            ~stop:0;
        hint = None;
      };
    ]

(* ---- registry endpoints, credentials, and the HTTP transport ---- *)

(* With EMO_REGISTRY unset and no manifest `registry` field, the standard
   library rides the compiler binary itself (T24.2) — a lone emo binary
   resolves stdlib packages with nothing beside it. *)
let bundled_registry () : Emo_pkg.Registry.t = Emo_pkg.Registry.Embedded

(* Strips one trailing slash, so joining endpoint paths never doubles it. *)
let registry_base (registry : string) : string =
  let n = String.length registry in
  if n > 0 && registry.[n - 1] = '/' then String.sub registry 0 (n - 1)
  else registry

(* `emo emoji login` stores one block per registry — registry, token,
   username — in a key = "value" file under the user's config directory.
   Entries never cross registries: publish and HTTP pulls match the entry
   against the resolved endpoint, so a token minted for one host is never
   sent to another. The file holds API tokens in plaintext and is written
   0600. *)

type stored_login = {
  c_registry : string;
  c_token : string;
  c_username : string;
  c_expires_at : string; (* RFC 3339, or "" when the token never expires *)
}

(* Parses the credentials file: `key = "value"` lines with the keys
   registry, token, username and the optional expires_at; blank lines and #
   comments are layout only. A new block starts at each `registry` line.
   Strict — any malformed or unknown line is an error naming the line
   number, never a silent skip. *)
let parse_credentials (content : string) : (stored_login list, string) result =
  let error line message =
    Error (Printf.sprintf "credentials: line %d: %s" line message)
  in
  let unquote line key rest =
    let n = String.length rest in
    if
      n < 2
      || rest.[0] <> '"'
      || rest.[n - 1] <> '"'
      ||
        try String.index (String.sub rest 1 (n - 2)) '"' <> -1
        with Not_found -> false
    then
      error line
        (Printf.sprintf "`%s` must be a quoted value without quotes" key)
    else Ok (String.sub rest 1 (n - 2))
  in
  let complete line entry =
    match (entry.c_registry, entry.c_token, entry.c_username) with
    | r, t, u when r <> "" && t <> "" && u <> "" -> Ok entry
    | r, _, _ when r <> "" ->
        error line
          (Printf.sprintf "the `%s` block is missing a token or username" r)
    | _ -> error line "a block must start with `registry`"
  in
  let parse_line line text entry entries =
    let trimmed = String.trim text in
    if trimmed = "" || trimmed.[0] = '#' then Ok (entry, entries)
    else
      match String.index_opt trimmed '=' with
      | None -> error line "expected `key = \"value\"`"
      | Some i -> (
          let key = String.trim (String.sub trimmed 0 i) in
          let rest =
            String.trim
              (String.sub trimmed (i + 1) (String.length trimmed - i - 1))
          in
          match key with
          | "registry" -> (
              match entry.c_registry with
              | "" -> (
                  match unquote line key rest with
                  | Ok v -> Ok ({ entry with c_registry = v }, entries)
                  | Error e -> Error e)
              | _ -> (
                  (* A repeated `registry` opens the next block; the current
                     one must be complete before it is set aside. *)
                  match complete line entry with
                  | Ok full -> (
                      match unquote line key rest with
                      | Ok v ->
                          Ok
                            ( {
                                c_registry = v;
                                c_token = "";
                                c_username = "";
                                c_expires_at = "";
                              },
                              full :: entries )
                      | Error e -> Error e)
                  | Error e -> Error e))
          | "token" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_token = v }, entries)
              | Error e -> Error e)
          | "username" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_username = v }, entries)
              | Error e -> Error e)
          | "expires_at" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_expires_at = v }, entries)
              | Error e -> Error e)
          | other -> error line (Printf.sprintf "unknown key `%s`" other))
  in
  let rec go line entry entries lines =
    match lines with
    | [] -> (
        if entry.c_registry = "" && entry.c_token = "" && entry.c_username = ""
        then Ok (List.rev entries)
        else
          match complete line entry with
          | Ok full -> Ok (List.rev (full :: entries))
          | Error e -> Error e)
    | text :: rest -> (
        match parse_line line text entry entries with
        | Ok (entry, entries) -> go (line + 1) entry entries rest
        | Error e -> Error e)
  in
  (* A trailing empty element (the newline-terminated file's last line) is
     just a blank line to skip; the final block flushes at the end either
     way, and line numbers stay honest. *)
  go 1
    { c_registry = ""; c_token = ""; c_username = ""; c_expires_at = "" }
    []
    (String.split_on_char '\n' content)

let load_credentials ~(file : string) : (stored_login list, string) result =
  if not (Sys.file_exists file) then Ok []
  else
    let ic = open_in_bin file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        parse_credentials (really_input_string ic (in_channel_length ic)))

(* Replaces the block for [registry] in place, or appends one, and rewrites
   the file 0600. Values are checked before anything is written: the format
   has no escapes, so a quote or newline cannot be smuggled in. *)
let store_credentials ~(file : string) ~(registry : string) ~(token : string)
    ~(username : string) ~(expires_at : string) : (unit, string) result =
  let entry =
    {
      c_registry = registry_base registry;
      c_token = token;
      c_username = username;
      c_expires_at = expires_at;
    }
  in
  let plain (label : string) (v : string) =
    if v = "" then Error (label ^ " is empty")
    else if String.contains v '"' || String.contains v '\n' then
      Error (label ^ " must not contain quotes or newlines")
    else Ok ()
  in
  (* The expiry may be empty — a token that never expires. *)
  let expiry =
    if entry.c_expires_at = "" then Ok ()
    else if
      String.contains entry.c_expires_at '"'
      || String.contains entry.c_expires_at '\n'
    then Error "expires_at must not contain quotes or newlines"
    else Ok ()
  in
  match
    ( plain "registry" entry.c_registry,
      plain "token" entry.c_token,
      plain "username" entry.c_username,
      expiry )
  with
  | Error e, _, _, _ | _, Error e, _, _ | _, _, Error e, _ | _, _, _, Error e ->
      Error e
  | Ok (), Ok (), Ok (), Ok () -> (
      match load_credentials ~file with
      | Error e -> Error e
      | Ok stored -> (
          let entries =
            match
              List.partition (fun e -> e.c_registry = entry.c_registry) stored
            with
            | _, kept -> entry :: kept
          in
          let buf = Buffer.create 256 in
          Buffer.add_string buf
            "# Emo registry credentials, written by `emo emoji login`.\n\
             # One block per registry; publish only sends a token to its own \
             registry.\n\
             # Keep this file private — it holds API tokens in plaintext.\n";
          List.iter
            (fun e ->
              Buffer.add_char buf '\n';
              Buffer.add_string buf
                (Printf.sprintf "registry = \"%s\"\n" e.c_registry);
              Buffer.add_string buf
                (Printf.sprintf "token = \"%s\"\n" e.c_token);
              Buffer.add_string buf
                (Printf.sprintf "username = \"%s\"\n" e.c_username);
              Buffer.add_string buf
                (Printf.sprintf "expires_at = \"%s\"\n" e.c_expires_at))
            entries;
          let dir = Filename.dirname file in
          let rec ensure_dir d =
            if not (Sys.file_exists d) then begin
              ensure_dir (Filename.dirname d);
              try Unix.mkdir d 0o755 with Sys_error _ -> ()
            end
          in
          (try ensure_dir dir with Sys_error _ -> ());
          match open_out_bin file with
          | exception Sys_error m -> Error m
          | oc ->
              Fun.protect
                ~finally:(fun () -> close_out_noerr oc)
                (fun () ->
                  output_string oc (Buffer.contents buf);
                  close_out_noerr oc;
                  match Unix.chmod file 0o600 with
                  | () -> Ok ()
                  | exception Unix.Unix_error (e, _, _) ->
                      Error (Unix.error_message e))))

(* The credentials file: $EMO_CONFIG_DIR, then the XDG config home, then the
   user's .config — mirroring the cache directory's resolution. *)
let credentials_file () : string =
  let dir =
    match Sys.getenv_opt "EMO_CONFIG_DIR" with
    | Some d when d <> "" -> d
    | _ ->
        let config_home =
          match Sys.getenv_opt "XDG_CONFIG_HOME" with
          | Some d when d <> "" -> d
          | _ -> (
              match Sys.getenv_opt "HOME" with
              | Some home -> Filename.concat home ".config"
              | None -> Filename.get_temp_dir_name ())
        in
        Filename.concat config_home "emo"
  in
  Filename.concat dir "credentials"

(* An endpoint string: an http(s) URL selects the registry service over
   HTTP; anything else is a filesystem registry directory. *)
let endpoint_of_string (endpoint : string) : Emo_pkg.Registry.t =
  if
    String.starts_with ~prefix:"http://" endpoint
    || String.starts_with ~prefix:"https://" endpoint
  then Emo_pkg.Registry.Http endpoint
  else Emo_pkg.Registry.Fs_dir endpoint

(* The registry a project resolves against: EMO_REGISTRY wins, then the
   manifest's `registry` field, then the bundled standard library. *)
let registry ~(manifest : Emo_pkg.manifest) : Emo_pkg.Registry.t =
  match Sys.getenv_opt "EMO_REGISTRY" with
  | Some endpoint when endpoint <> "" -> endpoint_of_string endpoint
  | _ -> (
      match manifest.Emo_pkg.registry with
      | Some url -> Emo_pkg.Registry.Http url
      | None -> bundled_registry ())

(* With an HTTP registry configured, unscoped names — the top-level short
   names the official standard library owns, which the publish name rule
   can never host — resolve from the bundled standard library; scoped names
   go to the configured endpoint. A filesystem registry keeps serving both
   (test fixtures carry stdlib copies). *)
let registry_for_name ~(registry : Emo_pkg.Registry.t) (name : string) :
    Emo_pkg.Registry.t =
  match registry with
  | Emo_pkg.Registry.Http _ when not (String.contains name '/') ->
      bundled_registry ()
  | _ -> registry

(* The embedded HTTP transport runs fetch programs against the bundled
   standard library through [run_embedded] — which sits at the end of this
   file (it needs [run_entry]). The cell breaks the ordering; module
   initialization fills it, so by any call time it is set. *)
let embedded_runner_cell : Emo_pkg.Http_registry.runner option ref = ref None

let http_transport ~program ~globals =
  match !embedded_runner_cell with
  | Some run -> run ~program ~globals
  | None -> Error "the embedded HTTP transport is not initialized"

(* The token an HTTP registry call rides with: EMO_TOKEN wins, then the
   stored login minted for this endpoint — never another registry's. No
   token is fine: public packages read anonymously, and a private one
   answers 404 either way. A damaged credentials file surfaces rather than
   being silently ignored. *)
let token_for ~(manifest_dir : string) ~(endpoint : string) : string option =
  match Sys.getenv_opt "EMO_TOKEN" with
  | Some t when t <> "" -> Some t
  | _ -> (
      match load_credentials ~file:(credentials_file ()) with
      | Error m -> raise (dep_error ~manifest_dir m)
      | Ok stored -> (
          match
            List.find_opt
              (fun e ->
                String.equal
                  (registry_base e.c_registry)
                  (registry_base endpoint))
              stored
          with
          | Some e -> Some e.c_token
          | None -> None))

(* Fetch one package through its name's route, verifying the content digest
   against [expected_checksum] — the index's on a fresh resolve, the
   lockfile's on install/run. The lockfile's checksum is enforced, never
   just recorded: content that digests differently is an E5007, whatever
   endpoint kind served it. *)
let fetch_routed ~(runner : Emo_pkg.Http_registry.runner)
    ~(registry : Emo_pkg.Registry.t) ~(manifest_dir : string) ~(name : string)
    ~(version : Emo_pkg.Version.t) ~(expected_checksum : string option) :
    Emo_pkg.Registry.fetched =
  match registry_for_name ~registry name with
  | Emo_pkg.Registry.Http base -> (
      match
        Emo_pkg.Http_registry.fetch runner ~base
          ~token:(token_for ~manifest_dir ~endpoint:base)
          ~expected_checksum ~name ~version
      with
      | Error m -> raise (dep_error ~manifest_dir m)
      | Ok f -> f)
  | reg -> (
      match Emo_pkg.Registry.fetch reg ~name ~version with
      | Error m -> raise (dep_error ~manifest_dir m)
      | Ok f -> (
          match expected_checksum with
          | Some expected
            when not (String.equal expected f.Emo_pkg.Registry.f_checksum) ->
              raise
                (dep_error ~manifest_dir
                   (Printf.sprintf
                      "checksum mismatch for %s@%s: the lockfile records %s \
                       but %s serves content digesting to %s"
                      name
                      (Emo_pkg.Version.to_string version)
                      expected
                      (Emo_pkg.Registry.describe reg)
                      f.Emo_pkg.Registry.f_checksum))
          | _ -> f))

(* Builds the resolver index for [names] and their transitive closure,
   routing each name to its endpoint kind: scoped names over HTTP when the
   configured registry is HTTP, unscoped names from the bundled stdlib,
   everything local otherwise. One merged index feeds one solve, so a
   scoped package's transitive pin of a stdlib package resolves in the same
   pass. *)
let index_closure_routed ?(runner = http_transport)
    ~(registry : Emo_pkg.Registry.t) ~(manifest_dir : string)
    (names : string list) : Emo_pkg.Resolve.index =
  let rec go seen acc pending =
    let fresh = List.filter (fun n -> not (List.mem n seen)) pending in
    if fresh = [] then acc
    else
      let http_names, local_names =
        List.partition
          (fun n ->
            match registry_for_name ~registry n with
            | Emo_pkg.Registry.Http _ -> true
            | _ -> false)
          fresh
      in
      let http_entries =
        match (registry, http_names) with
        | _, [] -> []
        | Emo_pkg.Registry.Http base, _ -> (
            match
              Emo_pkg.Http_registry.index runner ~base
                ~token:(token_for ~manifest_dir ~endpoint:base)
                http_names
            with
            | Error m -> raise (dep_error ~manifest_dir m)
            | Ok entries -> entries)
        | _, _ -> [] (* local registries never route a name to HTTP *)
      in
      let local_entries =
        List.concat_map
          (fun n ->
            Emo_pkg.Registry.index (registry_for_name ~registry n) [ n ])
          local_names
      in
      let entries = http_entries @ local_entries in
      let deps =
        List.concat_map
          (fun (_, pvs) ->
            List.concat_map
              (fun pv -> List.map fst pv.Emo_pkg.Resolve.pv_deps)
              pvs)
          entries
      in
      go (fresh @ seen) (acc @ entries) deps
  in
  go [] [] names

(* Solves [roots] against the registry and fetches every resolved package
   — the shared body of the explicit resolution (`emo deps resolve`) and
   the build-time resolution that carries the standard library's implicit
   pins. The target filters which published versions qualify. *)
let solved_entries ?(runner = http_transport) ~(registry : Emo_pkg.Registry.t)
    ~(manifest_dir : string) ~(target : string)
    (roots : (string * Emo_pkg.Version.t) list) : Emo_pkg.Lockfile.entry list =
  if roots = [] then []
  else
    let index =
      index_closure_routed ~runner ~registry ~manifest_dir (List.map fst roots)
    in
    match Emo_pkg.Resolve.solve ~target ~roots ~index with
    | Error errors ->
        raise
          (dep_error ~manifest_dir
             (String.concat "; "
                (List.map
                   (fun e ->
                     Printf.sprintf "%s: %s" e.Emo_pkg.Resolve.e_dep
                       e.Emo_pkg.Resolve.e_message)
                   errors)))
    | Ok r ->
        List.map
          (fun (dep, version) ->
            (* The checksum the lockfile will record: what the index
               advertised for this exact version, verified at fetch. *)
            let expected_checksum =
              match List.assoc_opt dep index with
              | Some pvs -> (
                  match
                    List.find_opt
                      (fun pv -> pv.Emo_pkg.Resolve.pv_version = version)
                      pvs
                  with
                  | Some pv -> Some pv.Emo_pkg.Resolve.pv_checksum
                  | None -> None)
              | None -> None
            in
            let f =
              fetch_routed ~runner ~registry ~manifest_dir ~name:dep ~version
                ~expected_checksum
            in
            {
              Emo_pkg.Lockfile.dep;
              version;
              checksum = f.Emo_pkg.Registry.f_checksum;
            })
          r.Emo_pkg.Resolve.resolved

(* Resolves the manifest's exact pins against the registry, fresh — the
   explicit regeneration path (`emo deps resolve`). *)
let resolve_deps ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string)
    ~(target : string) : Emo_pkg.Lockfile.entry list =
  solved_entries ~registry:(registry ~manifest) ~manifest_dir ~target
    manifest.Emo_pkg.deps

(* Unscoped requires name standard-library packages: the official standard
   library owns the top-level short names (README, Package Management),
   ships with the compiler, and needs no manifest pin. A scoped require
   (`acme/tools`) still pairs with the manifest's deps strictly. Each name
   appears once, with the span of its first require; a name the project
   already defines as a module is left to that module. *)
let stdlib_requires (p : project) : (string * Emo_support.Span.t) list =
  let seen : (string, Emo_support.Span.t) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.iter
    (fun _ file ->
      let items = try parse_cached p file with _ -> [] in
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.item_desc with
          | Ast.Item_require name
            when (not (String.contains name '/'))
                 && (not (Hashtbl.mem p.files [ name ]))
                 && not (Hashtbl.mem p.dirs [ name ]) ->
              if not (Hashtbl.mem seen name) then
                Hashtbl.replace seen name item.Ast.item_span
          | _ -> ())
        items)
    p.files;
  Hashtbl.fold (fun name span acc -> (name, span) :: acc) seen []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* The implicit pins for the project's standard-library requires: the
   highest version the registry publishes for each name the manifest does
   not already pin. A name the registry does not publish is neither a
   standard-library package nor (being unscoped) a third-party one — an
   error at the require. *)
let stdlib_pins (registry : Emo_pkg.Registry.t) ~(explicit : string list)
    (requires : (string * Emo_support.Span.t) list) :
    (string * Emo_pkg.Version.t) list =
  List.filter_map
    (fun (name, span) ->
      if List.mem name explicit then None
      else
        (* Unscoped names are standard-library-owned; under an HTTP
           registry they route to the bundled standard library. *)
        let reg = registry_for_name ~registry name in
        match Emo_pkg.Registry.versions reg ~name with
        | [] ->
            raise
              (Static_errors
                 [
                   {
                     Emo_support.Diagnostic.severity = Error;
                     code = Some "E5009";
                     message =
                       Printf.sprintf
                         "`require \"%s\"` names no standard-library package \
                          in %s"
                         name
                         (Emo_pkg.Registry.describe reg);
                     span;
                     hint =
                       Some
                         "check the package name; a third-party package needs \
                          its scoped name and a manifest deps entry";
                   };
                 ])
        | versions -> Some (name, List.nth versions (List.length versions - 1)))
    requires

(* The build-time resolution: a satisfied lockfile is used as recorded; a
   mismatch is an error prompting explicit regeneration — never a silent
   re-resolve. With no lockfile at all, the run resolves in memory and
   writes nothing. *)
let resolution_for_run ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string)
    ~(target : string) : Emo_pkg.Lockfile.entry list =
  let lock_path = Filename.concat manifest_dir Emo_pkg.Lockfile.filename in
  match Emo_pkg.Lockfile.read lock_path with
  | Ok entries -> (
      match Emo_pkg.Lockfile.verify ~roots:manifest.Emo_pkg.deps entries with
      | [] -> entries
      | message :: _ -> raise (dep_error ~manifest_dir message))
  | Error _ -> resolve_deps ~manifest ~manifest_dir ~target

(* The build-time resolution when the project also carries implicit
   standard-library pins: the manifest's own resolution is established
   first (a satisfied lockfile is used as recorded, a mismatch still
   fails), and the implicit pins join it in one solve, so a stdlib package
   a declared dependency also needs resolves once. Implicit pins never
   enter package.lock: the standard library ships with the compiler, so
   the manifest stays the recorded resolution. *)
let resolution_with_stdlib ~(manifest : Emo_pkg.manifest)
    ~(manifest_dir : string) ~(target : string) ~(registry : Emo_pkg.Registry.t)
    ~(implicit : (string * Emo_pkg.Version.t) list) :
    Emo_pkg.Lockfile.entry list =
  ignore (resolution_for_run ~manifest ~manifest_dir ~target);
  let entries =
    solved_entries ~registry ~manifest_dir ~target
      (manifest.Emo_pkg.deps @ implicit)
  in
  (* An implicit pin must not silently move a manifest pin: MVS takes the
     highest exact version named, so a stdlib closure demanding a higher
     one than the manifest states is a conflict the manifest must settle. *)
  List.iter
    (fun (dep, pinned) ->
      match
        List.find_opt (fun e -> String.equal e.Emo_pkg.Lockfile.dep dep) entries
      with
      | Some e when e.Emo_pkg.Lockfile.version = pinned -> ()
      | Some e ->
          raise
            (dep_error ~manifest_dir
               (Printf.sprintf
                  "the standard library requires `%s` at %s, but the manifest \
                   pins it at %s — update the manifest pin"
                  dep
                  (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version)
                  (Emo_pkg.Version.to_string pinned)))
      | None -> ())
    manifest.Emo_pkg.deps;
  entries

(* `emo install`: resolve the manifest, fetch every package into the
   user cache, and write the lockfile — the project is then ready for
   `emo run` / `emo build`. Idempotent: a second run re-verifies and
   reports, changing nothing. Raises [Static_errors] on resolution or
   fetch failure. *)
let install_deps ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string)
    ~(target : string) : string list =
  if manifest.Emo_pkg.deps = [] then
    [ "nothing to install — the manifest declares no dependencies" ]
  else
    let reg = registry ~manifest in
    let entries = resolve_deps ~manifest ~manifest_dir ~target in
    let cache_dir = Emo_pkg.Registry.default_cache_dir () in
    let fetched =
      List.map
        (fun (entry : Emo_pkg.Lockfile.entry) ->
          (* The lockfile's checksum is enforced on every fetch — the
             registry's content must digest to exactly what resolved. *)
          let f =
            fetch_routed ~runner:http_transport ~registry:reg ~manifest_dir
              ~name:entry.Emo_pkg.Lockfile.dep
              ~version:entry.Emo_pkg.Lockfile.version
              ~expected_checksum:(Some entry.Emo_pkg.Lockfile.checksum)
          in
          let cached = Emo_pkg.Registry.is_cached ~cache_dir f in
          match Emo_pkg.Registry.materialize ~cache_dir f with
          | Error m -> raise (dep_error ~manifest_dir m)
          | Ok _ ->
              Printf.sprintf "fetched %s %s%s" entry.Emo_pkg.Lockfile.dep
                (Emo_pkg.Version.to_string entry.Emo_pkg.Lockfile.version)
                (if cached then " (already cached)"
                 else
                   Printf.sprintf " (%s)"
                     (String.sub f.Emo_pkg.Registry.f_checksum 0 12)))
        entries
    in
    let lock_path = Filename.concat manifest_dir Emo_pkg.Lockfile.filename in
    let lock_line =
      match Emo_pkg.Lockfile.read lock_path with
      | Ok existing when existing = entries -> "package.lock is up to date"
      | _ ->
          Emo_pkg.Lockfile.write ~path:lock_path entries;
          "wrote package.lock"
    in
    Printf.sprintf "resolved %d dependencies" (List.length entries)
    :: (fetched @ [ lock_line ])

(* Registers a fetched package's module tree under its short name — the
   package name is a module-path prefix (README: "a package name becomes a
   top-level module path prefix"). The package root's `<short>.emo` is the
   module `<short>` a require binds; every other entry becomes a child
   (`<short>.internal`, `<short>.mark`), so two packages' `internal` and
   `mark` no longer collide. The package's own manifest is data, not a
   module, and is skipped. *)
let register_package (p : project) (short : string) (dir : string) : unit =
  walk ~body:short p [ short ] dir;
  p.packages <- [ short ] :: p.packages;
  match diagnostics p with [] -> () | ds -> raise (Static_errors ds)

(* The native side of one resolved dependency: the C sources it carries
   (absolute paths into the materialized cache dir — the c target compiles
   them into the program) and the system libraries its manifest links.
   Both are empty for a pure-Emo package. *)
type native_dep = {
  nd_name : string;
  nd_csources : string list;
  nd_link : string list;
}

(* The dependency side of a run: resolve or verify, then fetch every
   resolved package into the shared cache and register its modules.
   The target gates twice: the fresh solve filters published versions,
   and each fetched package's own manifest must declare the target —
   a lockfile satisfied for one target must not silently serve
   another. Returns each package's native inputs; the interpreter and
   the non-c targets ignore them (the build's strictness gate refuses
   a native-carrying package off the c target). *)
let load_deps ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string)
    ~(target : string) (p : project) : native_dep list =
  let reg = registry ~manifest in
  let explicit = List.map fst manifest.Emo_pkg.deps in
  (* The standard library needs no manifest pin: every unscoped require
     resolves from the registry implicitly (README, Package Management). *)
  let implicit = stdlib_pins reg ~explicit (stdlib_requires p) in
  (* The root project's own deps, for the visibility rule and the
     require/manifest pairing — declared and implicit alike. *)
  p.package_deps <- ([], explicit @ List.map fst implicit) :: p.package_deps;
  if explicit = [] && implicit = [] then []
  else begin
    let entries =
      if implicit = [] then resolution_for_run ~manifest ~manifest_dir ~target
      else
        resolution_with_stdlib ~manifest ~manifest_dir ~target ~registry:reg
          ~implicit
    in
    List.map
      (fun entry ->
        (* The lockfile's (or the fresh resolution's) checksum is enforced
           on every fetch. *)
        let f =
          fetch_routed ~runner:http_transport ~registry:reg ~manifest_dir
            ~name:entry.Emo_pkg.Lockfile.dep
            ~version:entry.Emo_pkg.Lockfile.version
            ~expected_checksum:(Some entry.Emo_pkg.Lockfile.checksum)
        in
        match
          Emo_pkg.Registry.materialize
            ~cache_dir:(Emo_pkg.Registry.default_cache_dir ())
            f
        with
        | Error m -> raise (dep_error ~manifest_dir m)
        | Ok dir ->
            let pkg_file = Filename.concat dir "package.emo" in
            let pkg =
              Emo_pkg.parse_manifest ~file:pkg_file ~source:(read_file pkg_file)
            in
            if not (List.mem target pkg.Emo_pkg.targets) then
              raise
                (dep_error ~manifest_dir
                   (Printf.sprintf "package %s does not declare the `%s` target"
                      entry.Emo_pkg.Lockfile.dep target));
            let short = Emo_pkg.short_name entry.Emo_pkg.Lockfile.dep in
            register_package p short dir;
            p.package_deps <-
              ([ short ], List.map fst pkg.Emo_pkg.deps) :: p.package_deps;
            {
              nd_name = entry.Emo_pkg.Lockfile.dep;
              nd_csources =
                List.filter_map
                  (fun (rel, _) ->
                    if Filename.check_suffix rel ".c" then
                      Some (Filename.concat dir rel)
                    else None)
                  f.Emo_pkg.Registry.f_files;
              nd_link = pkg.Emo_pkg.link;
            })
      entries
  end

let entry_path (entry_file : string) : string =
  if Filename.is_relative entry_file then
    Filename.concat (Sys.getcwd ()) entry_file
  else entry_file

(* The entry's file identity: the walk registers physical keys (getcwd
   is physical), but the entry can arrive through a symlinked directory
   — `/tmp/x` naming what the walk stored as `/private/tmp/x` — so
   membership compares device and inode, not the strings. *)
let entry_file_id (entry_file : string) : (int * int) option =
  match try Some (Unix.stat (entry_path entry_file)) with _ -> None with
  | Some st -> Some (st.Unix.st_dev, st.Unix.st_ino)
  | None -> None

let same_file (id : (int * int) option) (file : string) : bool =
  match id with
  | None -> false
  | Some (dev, ino) -> (
      match try Some (Unix.stat file) with _ -> None with
      | Some st -> st.Unix.st_dev = dev && st.Unix.st_ino = ino
      | None -> false)

let entry_outside_error ~(root : string) (entry_file : string) =
  Static_errors
    [
      {
        Emo_support.Diagnostic.severity = Error;
        code = Some "E5011";
        message =
          Printf.sprintf
            "the entry `%s` is not a module of the package rooted at %s"
            entry_file root;
        span =
          Emo_support.Span.make ~file:(entry_path entry_file) ~line:1 ~col:1
            ~start:0 ~stop:0;
        hint =
          Some
            "run the command from the package directory that contains the entry";
      };
    ]

(* The entry's module path in [p]. An entry that is not one of the
   package's modules is not part of the project at all — E5011, rather
   than a silent fallback that compiles it as a root module of its own.
   A file registered under two paths answers with the shorter one, which
   is the one [compile_inputs] keeps as its unit. *)
let entry_module_in_project (p : project) (entry_file : string) : string list =
  let id = entry_file_id entry_file in
  let paths =
    Hashtbl.fold
      (fun path file acc -> if same_file id file then path :: acc else acc)
      p.files []
  in
  match
    List.sort (fun a b -> compare (List.length a) (List.length b)) paths
  with
  | path :: _ -> path
  | [] -> raise (entry_outside_error ~root:p.root entry_file)

(* The backend's lowering input: every module in the project, parsed and
   checked (the backend runs the full check), plus the entry module's
   path and the dependencies' native inputs (C sources to compile,
   libraries to link). Raises [Static_errors] on any diagnostic.
   A native-carrying package (C sources or a `link` list) is honored by
   the c target alone; any other target refuses the program outright —
   dropping the native inputs would be a silent fallback. *)
let compile_inputs ~entry_file ~target :
    Emo_ir.module_input list
    * string list
    * string list list
    * (string list * string list) =
  let p, (manifest, dir) = prepare () in
  ignore (entry_module_in_project p entry_file);
  let native_deps = load_deps ~manifest ~manifest_dir:dir ~target p in
  let c_sources = List.concat_map (fun d -> d.nd_csources) native_deps in
  let link_libs = List.concat_map (fun d -> d.nd_link) native_deps in
  let native_carrying =
    List.filter (fun d -> d.nd_csources <> [] || d.nd_link <> []) native_deps
  in
  (match native_carrying with
  | [] -> ()
  | ds when target = "c" -> ignore ds
  | ds ->
      let names = String.concat ", " (List.map (fun d -> d.nd_name) ds) in
      raise
        (Static_errors
           [
             {
               Emo_support.Diagnostic.severity = Error;
               code = Some "E5007";
               message =
                 Printf.sprintf
                   "the %s target cannot link native dependencies (%s) — only \
                    the c target carries a package's C sources and libraries"
                   target names;
               span =
                 Emo_support.Span.make ~file:p.root ~line:1 ~col:1 ~start:0
                   ~stop:0;
               hint = None;
             };
           ]));
  let module_paths = module_paths p in
  let diagnostics = ref [] in
  (* The entry file is reachable via two paths (the project root and
     its own name); keep one module_input per distinct file, preferring
     the shorter path so the entry module stays rooted. *)
  let seen_files = Hashtbl.create 8 in
  let units =
    Hashtbl.fold
      (fun path file acc ->
        match Hashtbl.find_opt seen_files file with
        | Some kept when List.length kept <= List.length path -> acc
        | kept ->
            let keep =
              match kept with
              | Some k when List.length k <= List.length path -> false
              | _ -> true
            in
            if not keep then acc
            else begin
              let acc =
                match kept with
                | Some old_path ->
                    List.filter
                      (fun (unit_path, _) ->
                        not
                          (String.equal
                             (String.concat "/" unit_path)
                             (String.concat "/" old_path)))
                      acc
                | None -> acc
              in
              Hashtbl.replace seen_files file path;
              (path, parse_cached p file) :: acc
            end)
      p.files []
  in
  let entry = entry_module_in_project p entry_file in
  (* The program's type tables (CHECK.md, cross-module types) come
   * before any module is checked, so every module's type declarations
   * resolve against every declaration. *)
  let program, preregister_errors =
    Emo_check.preregister_types ~packages:p.packages
      ~package_deps:p.package_deps ~units
  in
  diagnostics := preregister_errors;
  let inputs =
    List.fold_left
      (fun acc (path, items) ->
        let diags, _refs, _requires, types =
          Emo_check.check_module_typed ~modules:module_paths
            ~packages:p.packages ~package_deps:p.package_deps ~current:path
            ~program ~target items
        in
        diagnostics := !diagnostics @ diags;
        { Emo_ir.mpath = path; mitems = items; mtypes = types } :: acc)
      [] units
  in
  (match !diagnostics with [] -> () | ds -> raise (Static_errors ds));
  (inputs, entry, p.packages, (c_sources, link_libs))

(* `emo check`: the static stages over the whole module tree, including the
   dependency side, without evaluating. *)
let check_entry ~entry_file : Emo_support.Diagnostic.t list =
  let p, (manifest, dir) = prepare () in
  ignore (entry_module_in_project p entry_file);
  ignore (load_deps ~manifest ~manifest_dir:dir ~target:"c" p);
  let _paths, _graph, _program, errors = check_project p in
  diagnostics p @ errors

(* How the entry's evaluation is scheduled. [`Sequential] runs under the
   guard handler — process operations report E3009; [`Eio] is the phase A
   scheduler; [`Own] is the phase B effects runtime, the default for
   `emo run`. *)
type sched = Sequential | Eio | Own

let run_entry ~entry_file ?(check = false) ?(sched = Sequential)
    ?(globals : (string * Emo_eval.value) list = []) () : project =
  let p, (manifest, dir) = prepare () in
  let entry = entry_module_in_project p entry_file in
  ignore (load_deps ~manifest ~manifest_dir:dir ~target:"c" p);
  install_hooks p;
  (* Parsed through the path the walk registered, not the one the caller
     spelled: the two name the same file, but only the registered spelling
     shares the content-hash cache with the check below — the caller's can
     arrive through a symlinked directory (`/var` for `/private/var`). *)
  let entry_file =
    Option.value ~default:(entry_path entry_file)
      (Hashtbl.find_opt p.files entry)
  in
  let items = parse_cached p entry_file in
  (if check then
     let _paths, _graph, _program, errors = check_project p in
     match errors with [] -> () | ds -> raise (Static_errors ds));
  let env = Emo_eval.global_env () in
  (* Host-injected bindings: the CLI's internal tooling (publish's uploader)
     passes data in without a language-level channel. *)
  List.iter
    (fun (name, value) -> Emo_eval.define env name ~mutable_:false value)
    globals;
  let evaluate () = List.iter (Emo_eval.eval_item env) items in
  (try
     match sched with
     | Sequential -> Emo_eval.run_without_scheduler evaluate
     | Eio -> Emo_sched_eio.run evaluate
     | Own -> ignore (Emo_sched_det.run evaluate)
   with Emo_eval.Emo_raise (v, span, trace) ->
     raise (Static_errors [ Emo_eval.uncaught_diagnostic (v, span, trace) ]));
  p

(* ---- `emo test`: the test runner ----

   A test module is any module under the project's test/ directory; a
   test is a top-level `def test_*` in one. The whole tree passes the
   static stages first (like `emo run` with checking on); each test then
   runs in its own scheduler run, so one test's processes and output
   never leak into the next. *)

type test_outcome =
  | Passed
  | Failed of Emo_support.Diagnostic.t (* an assertion (or any raise) *)
  | Errored of Emo_support.Diagnostic.t (* a runtime error *)

type test_result = {
  t_module : string list;
  t_name : string;
  t_outcome : test_outcome;
  t_output : string; (* everything the test printed *)
}

(* Runs every test under test/ and returns one result per test, modules
   and tests in sorted order. Any lex/parse/check failure in the tree
   raises [Static_errors], like [run_entry ~check:true]. *)
let run_tests () : test_result list =
  let p, (manifest, dir) = prepare () in
  ignore (load_deps ~manifest ~manifest_dir:dir ~target:"c" p);
  let _paths, _graph, _program, errors = check_project p in
  (match errors with [] -> () | ds -> raise (Static_errors ds));
  install_hooks p;
  let test_modules =
    List.sort compare
      (List.filter
         (fun path ->
           (* Under test/ means two segments at least — a root-level
              test.emo file is an ordinary module, not a test file. *)
           match path with
           | "test" :: _ :: _ -> true
           | _ -> false)
         (module_paths p))
  in
  let results = ref [] in
  let push r = results := r :: !results in
  List.iter
    (fun mpath ->
      let file = Hashtbl.find p.files mpath in
      let span = Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0 in
      (* A module's items run once, in their own scheduler run. A
         top-level raise or error here fails the module's load rather
         than any single test — the run continues with the next
         module. *)
      let loaded =
        let env = ref None in
        try
          ignore
            (Emo_sched_det.run (fun () ->
                 env := Some (!Emo_eval.module_loader mpath)));
          match !env with
          | Some e -> Ok e
          | None -> assert false (* run returned without the body *)
        with
        | Emo_eval.Emo_raise (v, s, trace) ->
            Error (Emo_eval.uncaught_diagnostic (v, s, trace))
        | Emo_eval.Error d -> Error d
      in
      match loaded with
      | Error d ->
          push
            {
              t_module = mpath;
              t_name = "<load>";
              t_outcome = Errored d;
              t_output = "";
            }
      | Ok env ->
          let tests =
            Hashtbl.fold
              (fun name binding acc ->
                match binding.Emo_eval.bound with
                | Emo_eval.ArrowBlock c
                  when String.length name >= 5 && String.sub name 0 5 = "test_"
                  ->
                    (name, c) :: acc
                | _ -> acc)
              env.Emo_eval.frame []
          in
          List.iter
            (fun (name, closure) ->
              match closure.Emo_eval.params with
              | _ :: _ ->
                  push
                    {
                      t_module = mpath;
                      t_name = name;
                      t_outcome =
                        Errored
                          {
                            Emo_support.Diagnostic.severity = Error;
                            code = Some "E5008";
                            message =
                              Printf.sprintf
                                "test `%s` takes parameters; test functions \
                                 take none"
                                name;
                            span;
                            hint = None;
                          };
                      t_output = "";
                    }
              | [] ->
                  let buf = Buffer.create 256 in
                  Emo_eval.set_output (Buffer.add_string buf);
                  let outcome =
                    Fun.protect ~finally:Emo_eval.reset_output (fun () ->
                        try
                          ignore
                            (Emo_sched_det.run (fun () ->
                                 ignore (Emo_eval.apply_closure closure span [])));
                          Passed
                        with
                        | Emo_eval.Emo_raise (v, s, trace) ->
                            Failed (Emo_eval.uncaught_diagnostic (v, s, trace))
                        | Emo_eval.Error d -> Errored d)
                  in
                  push
                    {
                      t_module = mpath;
                      t_name = name;
                      t_outcome = outcome;
                      t_output = Buffer.contents buf;
                    })
            (List.sort compare tests))
    test_modules;
  List.rev !results

(* ---- embedded programs: internal tooling run against the bundled stdlib ----

   The CLI's own network tooling (publish's uploader, the HTTP registry's
   fetch programs) is written in Emo and interpreted here, resolving `http`
   and friends from the standard library shipped inside the binary — so a
   lone emo binary uploads and pulls with no HTTP stack of its own. *)

(* Splits one embedded program's printed output into the status line and
   the body that follows it — the framing every exchange program uses. *)
let parse_exchange = Emo_pkg.Http_registry.parse_exchange

let rec remove_tree path =
  if Sys.file_exists path && Sys.is_directory path then begin
    Sys.readdir path
    |> Array.iter (fun e -> remove_tree (Filename.concat path e));
    Unix.rmdir path
  end
  else if Sys.file_exists path then Sys.remove path

(* Runs one embedded program and returns everything it printed. The program
   resolves `http` against the standard library shipped with the binary —
   never the user's EMO_REGISTRY or manifest registry, which may point at a
   remote endpoint or a fixture the bundled packages are not in. *)
let run_embedded ~(tag : string) ~(program : string)
    ~(globals : (string * Emo_eval.value) list) : (string, string) result =
  let reg = bundled_registry () in
  match List.rev (Emo_pkg.Registry.versions reg ~name:"http") with
  | [] -> Error "the bundled standard library has no http package"
  | http_version :: _ -> (
      match List.rev (Emo_pkg.Registry.versions reg ~name:"net") with
      | [] -> Error "the bundled standard library has no net package"
      | net_version :: _ ->
          (* The resolver indexes manifest roots only, so both packages are
             pinned explicitly — same as a user project. *)
          let dir =
            Filename.concat
              (Filename.get_temp_dir_name ())
              (Printf.sprintf "emo-%s-%d-%d" tag (Unix.getpid ())
                 (int_of_float (Unix.gettimeofday () *. 1e6) land 0xFFFFFF))
          in
          Unix.mkdir dir 0o755;
          let write name content =
            let oc = open_out_bin (Filename.concat dir name) in
            output_string oc content;
            close_out oc
          in
          write "package.emo"
            (Printf.sprintf
               {|package {
  name = "internal/%s"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    "http" = "%s"
    "net" = "%s"
  }
}
|}
               tag
               (Emo_pkg.Version.to_string http_version)
               (Emo_pkg.Version.to_string net_version));
          write "main.emo" program;
          let out = Buffer.create 256 in
          let old_registry = Sys.getenv_opt "EMO_REGISTRY" in
          let old_cwd = Sys.getcwd () in
          (* The embedded program's resolution must see the bundled stdlib,
             never the user's EMO_REGISTRY — blank the variable for the run
             (an empty value means unset to the registry lookup). *)
          Unix.putenv "EMO_REGISTRY" "";
          Emo_eval.set_output (Buffer.add_string out);
          Sys.chdir dir;
          Fun.protect
            ~finally:(fun () ->
              Sys.chdir old_cwd;
              (match old_registry with
              | Some v -> Unix.putenv "EMO_REGISTRY" v
              | None -> ());
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout);
              remove_tree dir)
            (fun () ->
              match
                run_entry ~entry_file:"main.emo" ~check:false ~sched:Own
                  ~globals ()
              with
              | exception Static_errors ds ->
                  Error
                    (String.concat "; "
                       (List.map (fun d -> d.Emo_support.Diagnostic.message) ds))
              | exception Emo_eval.Error d ->
                  Error d.Emo_support.Diagnostic.message
              | _ -> Ok (Buffer.contents out)))

(* The HTTP registry's transport: [run_embedded] under a fixed tag. Filled
   at module initialization — the cell exists because [run_embedded] needs
   [run_entry], whose own dependency loading reaches [http_transport]. *)
let () =
  embedded_runner_cell :=
    Some (fun ~program ~globals -> run_embedded ~tag:"fetch" ~program ~globals)
