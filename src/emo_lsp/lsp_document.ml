(* Open text documents, keyed by URI. The server uses full-text sync, so
   every didChange replaces the whole buffer with the last change's text;
   the line-start index is recomputed on demand. *)

type t = {
  uri : string;
  path : string; (* filesystem path, or "" for non-file URIs *)
  mutable text : string;
  mutable version : int;
}

let store : (string, t) Hashtbl.t = Hashtbl.create 16
let find (uri : string) : t option = Hashtbl.find_opt store uri

let find_by_path (path : string) : t option =
  let target = Lsp_util.normalize_path path in
  Hashtbl.fold
    (fun _ doc acc ->
      match acc with
      | Some _ -> acc
      | None ->
          if doc.path <> "" && Lsp_util.normalize_path doc.path = target then
            Some doc
          else None)
    store None

let all () : t list = Hashtbl.fold (fun _ d acc -> d :: acc) store []

(* The effective text for [path]: the open buffer when present, otherwise
   the file on disk. *)
let text_for_path (path : string) : string option =
  match find_by_path path with
  | Some doc -> Some doc.text
  | None -> Lsp_util.read_file path

let open_ (uri : string) ~(path : string) ~(version : int) ~(text : string) : t
    =
  let doc = { uri; path; text; version } in
  Hashtbl.replace store uri doc;
  doc

let change (uri : string) ~(version : int) ~(text : string) : unit =
  match Hashtbl.find_opt store uri with
  | Some doc ->
      doc.text <- text;
      doc.version <- version
  | None -> ()
[@@warning "-32"]

let close (uri : string) : unit = Hashtbl.remove store uri
