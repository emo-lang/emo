(* The project layer: the directory tree is the module tree. Discovers the
   module table under the entry file's directory and resolves qualified
   paths. Codes for this stage are E5xxx.

   Transitional root rule (replaced by manifest-based roots in step 10): the
   project root is the entry file's directory, and a module path whose first
   segment equals the root directory's own name has that segment elided —
   `emo run shop/checkout.emo` resolves `shop.order` to shop/order.emo. *)

type module_kind =
  | File of string (* the .emo file backing the module *)
  | Dir of string (* the directory holding child modules *)

type project = {
  root : string; (* filesystem path of the entry file's directory *)
  root_name : string; (* basename of root, elidable as a path prefix *)
  files : (string list, string) Hashtbl.t; (* module path → .emo file *)
  dirs : (string list, string) Hashtbl.t; (* module path → directory *)
  diagnostics : Emo_support.Diagnostic.t list ref;
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

(* Discovers the module tree under the entry file's directory. *)
let discover ~entry_file : project =
  let root = Filename.dirname entry_file in
  let p =
    {
      root;
      root_name = Filename.basename (if root = "" then "." else root);
      files = Hashtbl.create 8;
      dirs = Hashtbl.create 8;
      diagnostics = ref [];
    }
  in
  (* The root directory is itself a module (the empty path). *)
  Hashtbl.replace p.dirs [] p.root;
  walk p [] p.root;
  p

(* Elides the project-name prefix: inside the `shop` project, `shop.order`
   addresses the same module as `order`. *)
let normalize p (path : string list) : string list =
  match path with
  | first :: rest when String.equal first p.root_name -> rest
  | _ -> path

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

(* Raised when the static stages of any module found errors. *)
exception Static_errors of Emo_support.Diagnostic.t list

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
      let env = Emo_eval.global_env () in
      List.iter (Emo_eval.eval_item env) items;
      env

(* Installs the evaluator's module hooks for this project: discovery
   (normalized path → handle with children) and loading. *)
let install_hooks p =
  let normalize = normalize p in
  (* Handles are memoized per module path: every reference to `shop.order`
     shares one namespace and one load. *)
  let handles : (string list, Emo_eval.module_handle) Hashtbl.t =
    Hashtbl.create 8
  in
  let handle_of raw_path =
    let path = normalize raw_path in
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
  Emo_eval.module_loader := fun raw_path -> load_module p (normalize raw_path)

(* Checks every module in the project, collecting the reference graph.
   Returns per-module references and every diagnostic found. *)
let check_project p :
    string list list
    * (string list * string list list) list
    * Emo_support.Diagnostic.t list =
  let module_paths = module_paths p in
  let graph : (string list, string list list) Hashtbl.t = Hashtbl.create 8 in
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
        let diagnostics, refs =
          Emo_check.check_module ~modules:module_paths ~current:path items
        in
        Hashtbl.replace graph path refs;
        match diagnostics with
        | [] -> acc
        | ds -> (ds @ errors, (path, refs) :: entries))
      p.files ([], [])
  in
  (module_paths, entries, errors)

(* Runs the entry file: the graph is discovered up front (collisions report
   immediately), modules load lazily on first access with load-once
   semantics, and the entry's own items evaluate in file order. With
   ~check:true every module is checked first. *)
let run_entry ~entry_file ?(check = false) () : unit =
  let p = discover ~entry_file in
  (match diagnostics p with [] -> () | ds -> raise (Static_errors ds));
  install_hooks p;
  let source = read_file entry_file in
  let items =
    match
      Emo_parser.parse_program_with_diagnostics ~file:entry_file ~source
    with
    | exception Emo_lexer.Error d -> raise (Static_errors [ d ])
    | (_, first :: _) as parsed ->
        let _, diagnostics = parsed in
        ignore first;
        raise (Static_errors diagnostics)
    | items, [] -> items
  in
  let () =
    let oc = open_out_gen [ Open_append; Open_creat ] 0o644 "/tmp/emo-d5.txt" in
    output_string oc ("d5: items=" ^ string_of_int (List.length items) ^ "\n");
    close_out oc
  in
  (if check then
     let _paths, _graph, errors = check_project p in
     match errors with [] -> () | ds -> raise (Static_errors ds));
  let env = Emo_eval.global_env () in
  List.iter (Emo_eval.eval_item env) items
