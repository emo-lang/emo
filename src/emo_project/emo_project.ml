module Ast = Emo_ast

(* The project layer: the directory tree is the module tree. Discovers the
   module table under the entry file's directory and resolves qualified
   paths. Codes for this stage are E5xxx.

   Transitional root rule (replaced by manifest-based roots in step 10): the
   project root is the working directory the compiler runs in —
   `emo run shop/checkout.emo` resolves `shop.order` to ./shop/order.emo and
   `other.thing` to ./other/thing.emo, so the README's shop tree and its
   internal-privacy scenario both work verbatim. *)

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
      let () =
        let oc =
          open_out_gen [ Open_append; Open_creat ] 0o644 "/tmp/emo-parse.txt"
        in
        output_string oc
          ("parse: " ^ file ^ " count=" ^ string_of_int p.parses ^ "\n");
        close_out oc
      in
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

let check_project p :
    string list list
    * (string list * string list list) list
    * Emo_support.Diagnostic.t list =
  let () =
    let oc = open_out_gen [ Open_append; Open_creat ] 0o644 "/tmp/emo-cp.txt" in
    output_string oc
      (Printf.sprintf "check_project: files=%d root=%s\n"
         (Hashtbl.length p.files) p.root);
    close_out oc
  in
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
        let oc =
          open_out_gen [ Open_append; Open_creat ] 0o644 "/tmp/emo-refs.txt"
        in
        output_string oc
          (String.concat "." path ^ " -> "
          ^ String.concat "; " (List.map (String.concat ".") refs)
          ^ "\n");
        close_out oc;
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
  (module_paths, entries, errors @ internal_errors @ cycle_error)

(* Runs the entry file: the graph is discovered up front (collisions report
   immediately), modules load lazily on first access with load-once
   semantics, and the entry's own items evaluate in file order. With
   ~check:true every module is checked first. *)
let run_entry ~entry_file ?(check = false) () : project =
  let p = discover ~entry_file in
  (match diagnostics p with [] -> () | ds -> raise (Static_errors ds));
  install_hooks p;
  let entry_file =
    if Filename.is_relative entry_file then Filename.concat p.root entry_file
    else entry_file
  in
  let items = parse_cached p entry_file in
  (if check then
     let _paths, _graph, errors = check_project p in
     (* The entry file itself may live outside the discovered tree (an
        absolute path); it is always checked too. *)
     let entry_diags, _refs =
       Emo_check.check_module ~modules:_paths ~current:[] items
     in
     match errors @ entry_diags with [] -> () | ds -> raise (Static_errors ds));
  let env = Emo_eval.global_env () in
  try
    List.iter (Emo_eval.eval_item env) items;
    p
  with Emo_eval.Emo_raise (v, span, _trace) ->
    error span "E3010" (Printf.sprintf "uncaught exception: %s" (to_string v))
