module Ast = Emo_ast

(* The project layer: the directory tree is the module tree. Discovers the
   module table under the entry file's directory and resolves qualified
   paths. Codes for this stage are E5xxx.

   The root rule: a project is rooted at its nearest package.emo manifest —
   the module tree is the package. Manifest-less trees (the README's shop
   demo) stay rooted at the working directory, so `emo run
   shop/checkout.emo` resolves `shop.order` to ./shop/order.emo verbatim. *)

(* Raised when the static stages of any module found errors. *)
exception Static_errors of Emo_support.Diagnostic.t list

type module_kind =
  | File of string (* the .emo file backing the module *)
  | Dir of string (* the directory holding child modules *)

type project = {
  root : string; (* filesystem path of the project root (the working dir) *)
  files : (string list, string) Hashtbl.t; (* module path → .emo file *)
  dirs : (string list, string) Hashtbl.t; (* module path → directory *)
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
          else
            let path = Filename.concat dir entry in
            if Sys.file_exists path && Sys.is_directory path then
              Some (entry, `Dir path)
            else if Filename.check_suffix entry ".emo" then
              Some (Filename.remove_extension entry, `File path)
            else None)

(* Registers every .emo file and every directory under [fs_dir] as a module
   at [rel] ^ name. A file and a directory with the same stem are a
   collision — two modules claiming one path. *)
let rec walk p rel fs_dir =
  List.iter
    (fun (name, kind) ->
      let path = rel @ [ name ] in
      match kind with
      | `Dir fs_path ->
          if Hashtbl.mem p.files path then
            report p "E5005"
              (Printf.sprintf "module path `%s` is claimed by both %s and %s"
                 (String.concat "." path)
                 (Hashtbl.find p.files path)
                 fs_path)
          else if Hashtbl.mem p.dirs path then ()
          else (
            Hashtbl.replace p.dirs path fs_path;
            walk p path fs_path)
      | `File fs_path ->
          if Hashtbl.mem p.dirs path then
            report p "E5005"
              (Printf.sprintf "module path `%s` is claimed by both %s and %s"
                 (String.concat "." path) fs_path (Hashtbl.find p.dirs path))
          else if Hashtbl.mem p.files path then ()
          else Hashtbl.replace p.files path fs_path)
    (entries fs_dir)

(* Discovers the module tree under the working directory. *)
let discover ~entry_file : project =
  let root = Sys.getcwd () in
  let p =
    {
      root;
      files = Hashtbl.create 8;
      dirs = Hashtbl.create 8;
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

(* Child module names of a directory module, with their normalized paths. *)
let children p (path : string list) : (string * string list) list =
  match Hashtbl.find_opt p.dirs path with
  | None -> []
  | Some fs_dir ->
      List.map (fun (name, _) -> (name, path @ [ name ])) (entries fs_dir)

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
   run once, on first load, in file order. *)
let load_module p (path : string list) : Emo_eval.env =
  match Hashtbl.find_opt p.files path with
  | None ->
      failwith
        (Printf.sprintf "module `%s` has no backing file"
           (String.concat "." path))
  | Some file ->
      let items = parse_cached p file in
      let env = Emo_eval.global_env () in
      List.iter (Emo_eval.eval_item env) items;
      env

(* Installs the evaluator's module hooks for this project: discovery
   (normalized path → handle with children) and loading. *)
let install_hooks p =
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
  Emo_eval.module_loader := fun path -> load_module p path

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

let check_project ~(manifest : Emo_pkg.manifest option) (p : project) :
    string list list
    * (string list * string list list * (string * Emo_support.Span.t) list) list
    * Emo_support.Diagnostic.t list =
  let module_paths = module_paths p in
  let graph : (string list, string list list) Hashtbl.t = Hashtbl.create 8 in
  let requires_table :
      (string list, (string * Emo_support.Span.t) list) Hashtbl.t =
    Hashtbl.create 8
  in
  let errors, entries =
    Hashtbl.fold
      (fun path file ((errors, entries) as acc) ->
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
        let diagnostics, refs, requires =
          Emo_check.check_module ~modules:module_paths ~current:path items
        in
        Hashtbl.replace graph path refs;
        Hashtbl.replace requires_table path requires;
        match diagnostics with
        | [] -> acc
        | ds -> (ds @ errors, (path, refs) :: entries))
      p.files ([], [])
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
  (* Strict pairing: every require must name a manifest dependency. *)
  let pairing_errors =
    List.concat_map
      (fun (path, requires) ->
        match (manifest, requires) with
        | None, _ :: _ ->
            [
              {
                Emo_support.Diagnostic.severity = Error;
                code = Some "E5006";
                message =
                  "this project has `require`s but no package.emo manifest to \
                   declare dependencies";
                span =
                  (match requires with
                  | (_, s) :: _ -> s
                  | [] ->
                      Emo_support.Span.make ~file:p.root ~line:1 ~col:1 ~start:0
                        ~stop:0);
                hint = Some "create a package.emo manifest with a deps block";
              };
            ]
        | Some m, _ ->
            List.filter_map
              (fun (pkg, span) ->
                match List.assoc_opt pkg m.Emo_pkg.deps with
                | Some _ -> None
                | None ->
                    Some
                      {
                        Emo_support.Diagnostic.severity = Error;
                        code = Some "E5006";
                        message =
                          Printf.sprintf
                            "module `%s` requires `%s`, but the manifest \
                             (package.emo) does not list it in deps"
                            (String.concat "." path) pkg;
                        span;
                        hint =
                          Some
                            "add the package to the manifest's deps block, or \
                             remove the require";
                      })
              requires
        | None, [] -> [])
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
    errors @ internal_errors @ cycle_error @ pairing_errors )

(* Runs the entry file: the graph is discovered up front (collisions report
   immediately), modules load lazily on first access with load-once
   semantics, and the entry's own items evaluate in file order. With
   ~check:true every module is checked first. *)
(* The manifest is the nearest package.emo at or above the entry file's
   directory; None when the project has no manifest. *)
let find_manifest ~entry_file : string option =
  let dir = ref (Filename.dirname entry_file) in
  let rec walk () =
    let candidate = Filename.concat !dir "package.emo" in
    if Sys.file_exists candidate then Some candidate
    else if Filename.dirname !dir = !dir then None
    else (
      dir := Filename.dirname !dir;
      walk ())
  in
  walk ()

(* Discovers the project, parses the nearest manifest, and re-roots the
   module tree at the manifest's directory — the package, not whatever
   directory the compiler ran in, is the module tree's root. *)
let prepare ~entry_file :
    project * (Emo_pkg.manifest * string (* its directory *)) option =
  let p = discover ~entry_file in
  (match diagnostics p with [] -> () | ds -> raise (Static_errors ds));
  match find_manifest ~entry_file with
  | None -> (p, None)
  | Some manifest_path ->
      let manifest =
        match
          Emo_pkg.parse_manifest ~file:manifest_path
            ~source:(read_file manifest_path)
        with
        | m -> m
        | exception Emo_pkg.Manifest_error d -> raise (Static_errors [ d ])
      in
      let dir = Filename.dirname manifest_path in
      Hashtbl.reset p.files;
      Hashtbl.reset p.dirs;
      Hashtbl.replace p.dirs [] dir;
      walk p [] dir;
      (* The project's own manifest is data, not a module. *)
      Hashtbl.remove p.files [ "package" ];
      (p, Some (manifest, dir))

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

let registry () =
  match Sys.getenv_opt "EMO_REGISTRY" with
  | Some endpoint when endpoint <> "" -> { Emo_pkg.Registry.endpoint }
  | _ ->
      raise
        (dep_error ~manifest_dir:"."
           "this project has dependencies but no registry is configured — set \
            EMO_REGISTRY")

(* Resolves the manifest's exact pins against the registry, fresh — the
   explicit regeneration path (`emo deps resolve`). *)
let resolve_deps ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string) :
    Emo_pkg.Lockfile.entry list =
  if manifest.Emo_pkg.deps = [] then []
  else
    let reg = registry () in
    let index =
      Emo_pkg.Registry.index reg (List.map fst manifest.Emo_pkg.deps)
    in
    match
      Emo_pkg.Resolve.solve ~target:"native" ~roots:manifest.Emo_pkg.deps ~index
    with
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
            match Emo_pkg.Registry.fetch reg ~name:dep ~version with
            | Error m -> raise (dep_error ~manifest_dir m)
            | Ok f ->
                {
                  Emo_pkg.Lockfile.dep;
                  version;
                  checksum = f.Emo_pkg.Registry.f_checksum;
                })
          r.Emo_pkg.Resolve.resolved

(* The build-time resolution: a satisfied lockfile is used as recorded; a
   mismatch is an error prompting explicit regeneration — never a silent
   re-resolve. With no lockfile at all, the run resolves in memory and
   writes nothing. *)
let resolution_for_run ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string) :
    Emo_pkg.Lockfile.entry list =
  let lock_path = Filename.concat manifest_dir "emo.lock" in
  match Emo_pkg.Lockfile.read lock_path with
  | Ok entries -> (
      match Emo_pkg.Lockfile.verify ~roots:manifest.Emo_pkg.deps entries with
      | [] -> entries
      | message :: _ -> raise (dep_error ~manifest_dir message))
  | Error _ -> resolve_deps ~manifest ~manifest_dir

(* Registers a fetched package's module tree at the top level — a package's
   directory tree is its public module tree, so `json_tools.emo` at the
   package root is the module `json_tools` that a require binds. The
   package's own manifest is data, not a module, and is skipped. *)
let register_package (p : project) (dir : string) : unit =
  walk p [] dir;
  Hashtbl.remove p.files [ "package" ];
  match diagnostics p with [] -> () | ds -> raise (Static_errors ds)

(* The dependency side of a run: resolve or verify, then fetch every
   resolved package into the shared cache and register its modules. *)
let load_deps ~(manifest : Emo_pkg.manifest) ~(manifest_dir : string)
    (p : project) : unit =
  if manifest.Emo_pkg.deps = [] then ()
  else
    let entries = resolution_for_run ~manifest ~manifest_dir in
    let reg = registry () in
    List.iter
      (fun entry ->
        match
          Emo_pkg.Registry.fetch reg ~name:entry.Emo_pkg.Lockfile.dep
            ~version:entry.Emo_pkg.Lockfile.version
        with
        | Error m -> raise (dep_error ~manifest_dir m)
        | Ok f -> (
            match
              Emo_pkg.Registry.materialize
                ~cache_dir:(Emo_pkg.Registry.default_cache_dir ())
                f
            with
            | Error m -> raise (dep_error ~manifest_dir m)
            | Ok dir -> register_package p dir))
      entries

let entry_path (entry_file : string) : string =
  if Filename.is_relative entry_file then
    Filename.concat (Sys.getcwd ()) entry_file
  else entry_file

(* The deps commands operate on the project at the working directory — the
   root rule makes the manifest's directory the project root. *)
let manifest_here () : string option =
  let candidate = Filename.concat (Sys.getcwd ()) "package.emo" in
  if Sys.file_exists candidate then Some candidate else None

(* `emo check`: the static stages over the whole module tree, including the
   dependency side, without evaluating. *)
let check_entry ~entry_file : Emo_support.Diagnostic.t list =
  let p, prepared = prepare ~entry_file in
  Option.iter
    (fun (m, dir) -> load_deps ~manifest:m ~manifest_dir:dir p)
    prepared;
  let manifest = Option.map fst prepared in
  let items = parse_cached p (entry_path entry_file) in
  let module_paths = module_paths p in
  let _paths, _graph, errors = check_project ~manifest p in
  let entry_diags, _refs, _requires =
    Emo_check.check_module ~modules:module_paths ~current:[] items
  in
  diagnostics p @ errors @ entry_diags

(* How the entry's evaluation is scheduled. [`Sequential] runs under the
   guard handler — process operations report E3009; [`Eio] is the phase A
   scheduler. *)
type sched = Sequential | Eio

let run_entry ~entry_file ?(check = false) ?(sched = Sequential) () : project =
  let p, prepared = prepare ~entry_file in
  Option.iter
    (fun (m, dir) -> load_deps ~manifest:m ~manifest_dir:dir p)
    prepared;
  let manifest = Option.map fst prepared in
  install_hooks p;
  let items = parse_cached p (entry_path entry_file) in
  (if check then
     let module_paths = module_paths p in
     let _paths, _graph, errors = check_project ~manifest p in
     (* The entry file itself may live outside the discovered tree (an
        absolute path); it is always checked too. *)
     let entry_diags, _refs, _requires =
       Emo_check.check_module ~modules:module_paths ~current:[] items
     in
     match errors @ entry_diags with [] -> () | ds -> raise (Static_errors ds));
  let env = Emo_eval.global_env () in
  let evaluate () = List.iter (Emo_eval.eval_item env) items in
  (try
     match sched with
     | Sequential -> Emo_eval.run_without_scheduler evaluate
     | Eio -> Emo_sched_eio.run evaluate
   with Emo_eval.Emo_raise (v, span, trace) ->
     raise (Static_errors [ Emo_eval.uncaught_diagnostic (v, span, trace) ]));
  p
