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
