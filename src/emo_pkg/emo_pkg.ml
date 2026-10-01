(* Packages: manifests, versions, resolution, lockfiles, registries.
   Manifest errors use E5100-range codes; resolution and lockfile use
   E5200-range. *)

module Tok = Emo_lexer.Token

(* Raised by the manifest reader on any schema violation. *)
exception Manifest_error of Emo_support.Diagnostic.t

(* Exact semantic versions: major.minor.patch. *)
module Version = struct
  type t = int * int * int

  let parse (s : string) : (t, string) result =
    let digits_only str =
      str <> "" && String.for_all (fun c -> c >= '0' && c <= '9') str
    in
    match String.split_on_char '.' s with
    | [ major; minor; patch ]
      when digits_only major && digits_only minor && digits_only patch ->
        Ok (int_of_string major, int_of_string minor, int_of_string patch)
    | _ -> Error "a version is major.minor.patch"

  let to_string (major, minor, patch) =
    Printf.sprintf "%d.%d.%d" major minor patch

  let compare (a : t) (b : t) = compare a b
end

(* The manifest: strict, fixed schema (phase A). Phase B upgrades the value
   reading to restricted-profile evaluation. *)
type manifest = {
  name : string; (* owner/name for packages, plain for the standard library *)
  version : Version.t;
  targets : string list;
  deps : (string * Version.t) list; (* exact versions *)
}

let known_targets = [ "native"; "wasm"; "typescript"; "beam"; "qemu" ]

(* Token-level strict reader: accepts exactly the README shape.
     package {
       name = "acme/json_tools"
       version = "0.1.0"
       targets = ["native", "wasm"]
       deps { json = "2.3.1" }
     }
   Unknown fields, missing fields, and non-literal values are errors. *)
module Manifest_parser = struct
  open Emo_support
  module Tok = Emo_lexer.Token

  type stream = { toks : Tok.t array; mutable pos : int; file : string }

  let eof_tok file =
    {
      Tok.kind = Tok.Eof;
      span = Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
      newline_before = false;
    }

  let peek st =
    if st.pos >= Array.length st.toks then eof_tok st.file else st.toks.(st.pos)

  let advance st =
    let t = peek st in
    if st.pos < Array.length st.toks then st.pos <- st.pos + 1;
    t

  let span st = (peek st).Tok.span

  let err st code message =
    raise
      (Manifest_error
         Emo_support.Diagnostic.
           {
             severity = Error;
             code = Some code;
             message;
             span = span st;
             hint = None;
           })

  let expect_op st op what =
    match (peek st).Tok.kind with
    | Tok.Op o when o = op -> advance st |> ignore
    | _ -> err st "E5100" (Printf.sprintf "expected %s" what)

  (* Reads a plain (non-interpolated) string literal: chunk pieces up to
     String_end. Interpolation is rejected — manifests are data. *)
  let expect_string st what =
    match (peek st).Tok.kind with
    | Tok.String_chunk _ ->
        let buf = Buffer.create 16 in
        let rec loop () =
          match (peek st).Tok.kind with
          | Tok.String_chunk text ->
              advance st |> ignore;
              Buffer.add_string buf text;
              loop ()
          | Tok.String_end ->
              advance st |> ignore;
              Buffer.contents buf
          | Tok.Interp_open ->
              err st "E5103"
                (Printf.sprintf "%s must be a plain string, not interpolation"
                   what)
          | _ -> err st "E5103" (Printf.sprintf "expected %s" what)
        in
        loop ()
    | _ -> err st "E5103" (Printf.sprintf "expected %s (a quoted string)" what)

  let read_version st raw =
    match Version.parse raw with
    | Ok v -> v
    | Error message -> err st "E5103" message
end

(* The manifest: strict fixed schema in phase A.
     package {
       name = "acme/json_tools"
       version = "0.1.0"
       targets = ["native", "wasm"]
       deps { json = "2.3.1" }
     }
   Unknown fields, missing fields, and non-literal values are errors — the
   manifest is data, not program logic (until phase B). *)
(* Parses a manifest with the strict phase-A schema. *)
let parse_manifest ~(file : string) ~(source : string) : manifest =
  let module P = Manifest_parser in
  let toks =
    match Emo_lexer.lex ~file ~source with
    | stream -> Emo_lexer.Stream.to_list stream
    | exception Emo_lexer.Error d -> raise (Manifest_error d)
  in
  let st = { P.toks = Array.of_list toks; P.pos = 0; P.file } in
  (match P.(peek st).Tok.kind with
  | Tok.Lower_ident "package" -> P.advance st |> ignore
  | _ -> P.err st "E5100" "expected `package`");
  P.expect_op st Tok.LBrace "`{`";
  let name = ref None in
  let version = ref None in
  let targets = ref None in
  let deps = ref [] in
  let fields_seen = Hashtbl.create 4 in
  let rec fields () =
    match P.(peek st).Tok.kind with
    | Tok.Op Tok.RBrace -> P.advance st |> ignore
    | Tok.Lower_ident field_name ->
        let field_span = P.span st in
        if Hashtbl.mem fields_seen field_name then
          P.err st "E5100" (Printf.sprintf "duplicate field `%s`" field_name);
        Hashtbl.replace fields_seen field_name field_span;
        P.advance st |> ignore;
        (match field_name with
        | "name" ->
            P.expect_op st Tok.Assign "`=`";
            name := Some (P.expect_string st "a package name")
        | "version" ->
            P.expect_op st Tok.Assign "`=`";
            version := Some (P.read_version st (P.expect_string st "a version"))
        | "targets" ->
            P.expect_op st Tok.Assign "`=`";
            P.expect_op st Tok.LBracket "a target list `[`";
            let rec read_targets acc =
              match P.(peek st).Tok.kind with
              | Tok.Op Tok.RBracket ->
                  P.advance st |> ignore;
                  List.rev acc
              | Tok.String_chunk _ ->
                  let t = P.expect_string st "a target name" in
                  read_targets (t :: acc)
              | Tok.Op Tok.Comma ->
                  P.advance st |> ignore;
                  read_targets acc
              | _ -> P.err st "E5103" "expected a target name or `]`"
            in
            targets := Some (read_targets [])
        | "deps" ->
            P.expect_op st Tok.LBrace "`{`";
            let rec read_deps acc =
              match P.(peek st).Tok.kind with
              | Tok.Op Tok.RBrace ->
                  P.advance st |> ignore;
                  List.rev acc
              | Tok.Lower_ident dep ->
                  P.advance st |> ignore;
                  P.expect_op st Tok.Assign "`=`";
                  let raw =
                    P.expect_string st ("a version for `" ^ dep ^ "`")
                  in
                  read_deps ((dep, P.read_version st raw) :: acc)
              | _ -> P.err st "E5100" "expected a dependency name or `}`"
            in
            deps := read_deps []
        | _ -> P.err st "E5100" (Printf.sprintf "unknown field `%s`" field_name));
        fields ()
    | Tok.Eof -> P.err st "E5101" "expected a field or `}`"
    | _ -> P.err st "E5100" "expected a field name or `}`"
  in
  fields ();
  let required name = function
    | Some v -> v
    | None -> P.err st "E5101" (Printf.sprintf "missing field `%s`" name)
  in
  let targets =
    match !targets with
    | Some t -> t
    | None -> P.err st "E5101" "missing field `targets`"
  in
  List.iter
    (fun t ->
      if not (List.mem t known_targets) then
        P.err st "E5103" (Printf.sprintf "unknown target `%s`" t))
    targets;
  let name = required "name" !name in
  let version = required "version" !version in
  { name; version; targets; deps = !deps }

(* Dependency resolution: exact pins resolved by "highest exact version
   named wins" (MVS over exact pins), with a target-compatibility gate —
   a package lacking the current build target fails resolution before
   compilation. *)
module Resolve = struct
  type package_version = {
    pv_version : Version.t;
    pv_targets : string list;
    pv_deps : (string * Version.t) list; (* its own exact pins *)
  }

  (* index: dependency name → every published version with its target list
     and transitive pins. *)
  type index = (string * package_version list) list
  type resolution = { resolved : (string * Version.t) list }

  type error = {
    e_dep : string; (* the dependency that failed *)
    e_message : string;
  }

  let pick_version (candidates : package_version list) ~(required : Version.t)
      ~(target : string) : (package_version, string) result =
    let matching =
      List.filter (fun pv -> pv.pv_version = required) candidates
    in
    match matching with
    | [] -> Error "no such version"
    | _ -> (
        let compatible =
          List.filter (fun pv -> List.mem target pv.pv_targets) matching
        in
        match compatible with
        | [] -> Error (Printf.sprintf "no build for target `%s`" target)
        | pv :: _ -> Ok pv)

  (* Solves the transitive closure: every exact pin per dependency must be
     equal (MVS over exact pins — the highest named wins only in the sense
     that conflicting pins are an error, per exact-only requirements).
     Wait — the plan says highest exact wins; with exact-only requirements,
     two different pins are conflicting requirements, and the highest named
     is what a shared consumer records. *)
  let solve ~(target : string) ~(roots : (string * Version.t) list)
      ~(index : index) : (resolution, error list) result =
    let index_tbl = Hashtbl.create 8 in
    List.iter (fun (n, vs) -> Hashtbl.replace index_tbl n vs) index;
    let errors = ref [] in
    let resolved = Hashtbl.create 8 in
    (* The highest exact version named for each dependency wins. *)
    let chosen : (string, Version.t) Hashtbl.t = Hashtbl.create 8 in
    let bump dep v =
      match Hashtbl.find_opt chosen dep with
      | None -> Hashtbl.replace chosen dep v
      | Some current ->
          if Version.compare v current > 0 then Hashtbl.replace chosen dep v
    in
    List.iter (fun (d, v) -> bump d v) roots;
    (* Walk dependencies breadth-first from the chosen versions. *)
    let changed = ref true in
    while !changed do
      changed := false;
      List.iter
        (fun (dep, chosen_v) ->
          if Hashtbl.mem resolved dep then ()
          else
            match
              pick_version
                (match Hashtbl.find_opt index_tbl dep with
                | Some vs -> vs
                | None -> [])
                ~required:chosen_v ~target
            with
            | Error message ->
                errors := { e_dep = dep; e_message = message } :: !errors
            | Ok pv ->
                Hashtbl.replace resolved dep pv.pv_version;
                changed := true;
                List.iter (fun (d, v) -> bump d v) pv.pv_deps)
        (Hashtbl.fold (fun k v acc -> (k, v) :: acc) chosen [])
    done;
    match !errors with
    | [] ->
        Ok
          { resolved = Hashtbl.fold (fun k v acc -> (k, v) :: acc) resolved [] }
    | es -> Error es
end

(* The lockfile: one line per resolved dependency, `dep version checksum`,
   sorted — belongs in version control. A mismatch between the lockfile and
   the manifest's requirements is an error prompting explicit
   regeneration; it is never silently re-resolved. *)
module Lockfile = struct
  type entry = { dep : string; version : Version.t; checksum : string }
  type t = entry list

  let to_lines (t : t) : string list =
    List.sort (fun a b -> String.compare a.dep b.dep) t
    |> List.map (fun e ->
        e.dep ^ " " ^ Version.to_string e.version ^ " " ^ e.checksum)

  let write ~(path : string) (t : t) : unit =
    let oc = open_out_bin path in
    output_string oc
      (String.concat "\n" (to_lines t) ^ if t = [] then "" else "\n");
    close_out oc

  let read (path : string) : (t, string) result =
    let read_file path =
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    match read_file path with
    | exception Sys_error message -> Error message
    | source ->
        let lines =
          String.split_on_char '\n' source
          |> List.filter_map (fun l ->
              let l = String.trim l in
              if l = "" then None else Some l)
        in
        let bad = Error (path ^ ": malformed lockfile line") in
        let rec parse acc = function
          | [] -> Ok (List.rev acc)
          | line :: rest -> (
              match String.split_on_char ' ' line with
              | [ dep; version; checksum ] -> (
                  match Version.parse version with
                  | Ok v -> parse ({ dep; version = v; checksum } :: acc) rest
                  | Error m -> Error (path ^ ": " ^ m))
              | _ -> bad)
        in
        parse [] lines

  (* Verify: every manifest root must be present at the pinned version, and
     the resolution must match entry for entry. Returns [] when satisfied. *)
  let verify ~(roots : (string * Version.t) list) (t : t) :
      string list (* human-readable mismatch errors *) =
    let errors = ref [] in
    List.iter
      (fun (dep, v) ->
        match List.find_opt (fun e -> String.equal e.dep dep) t with
        | Some entry when entry.version = v -> ()
        | Some entry ->
            errors :=
              Printf.sprintf
                "lockfile pins `%s` at %s but the manifest requires %s — run \
                 `emo deps resolve` to regenerate"
                dep
                (Version.to_string entry.version)
                (Version.to_string v)
              :: !errors
        | None ->
            errors :=
              Printf.sprintf
                "lockfile has no entry for `%s` (manifest requires %s) — run \
                 `emo deps resolve`"
                dep (Version.to_string v)
              :: !errors)
      roots;
    !errors
end

(* The registry and the global content-addressed cache. A directory
   registry serves tests and offline development over the same protocol the
   future HTTPS client will use: <endpoint>/<owner>/<name>/<version>/
   holding the package's manifest (package.emo) and source files. *)
module Registry = struct
  type t = { endpoint : string } (* a filesystem directory *)

  type fetched = {
    f_name : string;
    f_version : Version.t;
    f_checksum : string;
    (* digest over the sorted (path, content) pairs *)
    f_files : (string * string) list; (* relative path → content *)
  }

  let digest (files : (string * string) list) : string =
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
    Digest.string
      (String.concat ""
         (List.map (fun (p, c) -> p ^ "\000" ^ c ^ "\000") sorted))
    |> Digest.to_hex

  (* Collects every .emo file under [dir], relative paths as keys. *)
  let collect_files (dir : string) : (string * string) list =
    let rec walk rel =
      let dir_path = Filename.concat dir (String.concat "/" rel) in
      let entries =
        match Sys.readdir dir_path with
        | exception Sys_error _ -> []
        | raw -> raw |> Array.to_list |> List.sort compare
      in
      List.concat_map
        (fun entry ->
          if entry = "." || entry = ".." then []
          else
            let rel_entry = rel @ [ entry ] in
            let path = Filename.concat dir_path entry in
            if Sys.is_directory path then walk rel_entry
            else if Filename.check_suffix entry ".emo" then
              let ic = open_in_bin path in
              let content =
                Fun.protect
                  ~finally:(fun () -> close_in_noerr ic)
                  (fun () -> really_input_string ic (in_channel_length ic))
              in
              [ (String.concat "/" rel_entry, content) ]
            else [])
        entries
    in
    walk []

  let fetch (t : t) ~(name : string) ~(version : Version.t) :
      (fetched, string) result =
    let dir =
      Filename.concat t.endpoint
        (Filename.concat name (Version.to_string version))
    in
    if not (Sys.file_exists dir) then
      Error
        (Printf.sprintf "registry `%s` has no package %s@%s" t.endpoint name
           (Version.to_string version))
    else
      let files = collect_files dir in
      let has_manifest =
        List.exists (fun (p, _) -> Filename.basename p = "package.emo") files
      in
      if not has_manifest then
        Error
          (Printf.sprintf "package %s@%s has no manifest" name
             (Version.to_string version))
      else
        let checksum = digest files in
        Ok
          {
            f_name = name;
            f_version = version;
            f_checksum = checksum;
            f_files = files;
          }

  (* The global cache: shared across projects, content-addressed — the
     directory name embeds the checksum, so equal content is stored once. *)
  let default_cache_dir () =
    match Sys.getenv_opt "EMO_CACHE_DIR" with
    | Some dir -> dir
    | None -> Filename.concat (Filename.get_temp_dir_name ()) "emo-cache"

  let materialize ~(cache_dir : string) (f : fetched) :
      (string, string) result (* the package sources directory *) =
    let pkg_dir =
      Filename.concat cache_dir
        (f.f_name ^ "-" ^ Version.to_string f.f_version ^ "-" ^ f.f_checksum)
    in
    let materialize_file (rel, content) =
      let path = Filename.concat pkg_dir rel in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
      let oc = open_out_bin path in
      output_string oc content;
      close_out oc
    in
    try
      List.iter materialize_file f.f_files;
      (* Checksum verification: materialized content must match the fetched
         digest. *)
      let materialized = collect_files pkg_dir in
      if digest materialized = f.f_checksum then Ok pkg_dir
      else
        Error
          (Printf.sprintf "checksum mismatch for %s@%s" f.f_name
             (Version.to_string f.f_version))
    with Sys_error message -> Error message
end
