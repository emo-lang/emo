(* Packages: manifests, versions, resolution, lockfiles, registries.
   Manifest errors use E5100-range codes; resolution and lockfile use
   E5200-range. *)

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

(* The manifest: the package block's fields. *)
type manifest = {
  name : string; (* owner/name for packages, plain for the standard library *)
  version : Version.t;
  targets : string list;
  link : string list;
      (* system libraries the c target links (bare names, `-l`-style) *)
  registry : string option;
      (* the HTTP(S) registry this project pulls dependencies from and
         publishes to. Only the project root's field is read; a dependency's
         manifest is fetched from the registry the consumer already chose,
         so its field is ignored. *)
  deps : (string * Version.t) list; (* exact versions *)
}

let known_targets = [ "ocaml"; "c"; "wasm"; "typescript"; "beam"; "riscv64" ]

(* The manifest's shape:
     package {
       name = "acme/json_tools"
       version = "0.1.0"
       targets = ["ocaml", "wasm"]
       link = ["sqlite3"]
       registry = "https://packages.example.com"
       deps { "json" = "2.3.1" }
     }
   Unknown fields, missing fields, and non-literal values are errors — the
   manifest is data, not program logic. `link` is optional (default []): the
   system libraries the c target links, as bare names. `registry` is optional
   (default none): the HTTP(S) endpoint this project resolves dependencies
   against and publishes to — read only when the manifest is the project
   root. *)
(* The budget for restricted manifest evaluation: generous but finite. *)
let manifest_budget = 10_000

exception Manifest_budget_exceeded of int

(* The manifest is evaluated as real Emo in the restricted profile
   (hermetic, step-budgeted, no I/O builtins in scope). The `package { ... }`
   block's bindings become the fields and a `deps { ... }` block's entries —
   each named by a string literal — become the dependencies. *)
let parse_manifest ~(file : string) ~(source : string) : manifest =
  let items =
    match Emo_parser.parse_program_in ~manifest:true ~file ~source with
    | items -> items
    | exception Emo_lexer.Error d -> raise (Manifest_error d)
    | exception Emo_parser.Error d -> raise (Manifest_error d)
  in
  let manifest_error ?hint ?span code message =
    Manifest_error
      Emo_support.Diagnostic.
        {
          severity = Error;
          code = Some code;
          message;
          span =
            (match span with
            | Some s -> s
            | None ->
                Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0);
          hint;
        }
  in
  let env, deps_pairs =
    try Emo_eval.run_restricted ~budget:manifest_budget ~file items with
    | Emo_eval.Budget_exceeded budget ->
        raise
          (manifest_error "E5200"
             (Printf.sprintf "manifest evaluation exceeded %d steps" budget))
    | Emo_eval.Duplicate_field name ->
        raise
          (manifest_error "E5100" (Printf.sprintf "duplicate field `%s`" name))
    | Emo_eval.Impure_field name ->
        raise
          (manifest_error "E5103"
             (Printf.sprintf "field `%s` must be literal data" name))
    | Emo_eval.Manifest_shape_error (shape, span) -> (
        let dep_key =
          {|write a dependency's name as a string: "acme/json_tools" = "1.2.3"|}
        in
        match shape with
        | Emo_eval.Dep_key_empty ->
            raise
              (manifest_error ~span "E5102" "a dependency's name is empty"
                 ~hint:
                   {|name the package you depend on: "acme/json_tools" = "1.2.3"|})
        | Emo_eval.Dep_key_not_string ->
            raise
              (manifest_error ~hint:dep_key ~span "E5102"
                 "a dependency's name is a string, not a field name")
        | Emo_eval.Field_name_not_ident ->
            raise
              (manifest_error ~span "E5102"
                 "a package field's name is not a string"
                 ~hint:
                   "the package block defines `name`, `version`, `targets`, \
                    `link` and `registry`; a dependency's name belongs in \
                    `deps`")
        | Emo_eval.Dep_entry_expected ->
            raise
              (manifest_error ~hint:dep_key ~span "E5104"
                 "a `deps` block holds dependency entries only"))
    | Emo_eval.Emo_raise (v, span, trace) ->
        let d = Emo_eval.uncaught_diagnostic (v, span, trace) in
        raise
          (Manifest_error { d with Emo_support.Diagnostic.code = Some "E5103" })
  in
  (* Strict fixed schema: nothing besides name, version, targets, link, and
     registry may be defined in the package block. *)
  Hashtbl.iter
    (fun k _ ->
      if
        not
          (String.equal k "name" || String.equal k "version"
         || String.equal k "targets" || String.equal k "link"
         || String.equal k "registry")
      then
        raise (manifest_error "E5100" (Printf.sprintf "unknown field `%s`" k)))
    env.Emo_eval.frame;
  let read_string name =
    match Emo_eval.lookup_opt env name with
    | Some (Emo_eval.String s) -> s
    | Some v ->
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message =
                   Printf.sprintf "field `%s` must be a string, got %s" name
                     (Emo_eval.type_name v);
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               })
    | None ->
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5101";
                 message = Printf.sprintf "missing field `%s`" name;
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               })
  in
  let read_string_list ~field ~missing_code =
    match Emo_eval.lookup_opt env field with
    | Some (Emo_eval.Array items) ->
        List.map
          (fun v ->
            match v with
            | Emo_eval.String s -> s
            | other ->
                raise
                  (Manifest_error
                     Emo_support.Diagnostic.
                       {
                         severity = Error;
                         code = Some "E5103";
                         message =
                           Printf.sprintf "%s must be strings, got %s" field
                             (Emo_eval.type_name other);
                         span =
                           Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0
                             ~stop:0;
                         hint = None;
                       }))
          (Array.to_list items)
    | Some _ ->
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message = Printf.sprintf "`%s` must be an array" field;
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               })
    | None -> (
        match missing_code with
        | Some code ->
            raise
              (Manifest_error
                 Emo_support.Diagnostic.
                   {
                     severity = Error;
                     code = Some code;
                     message = Printf.sprintf "missing field `%s`" field;
                     span =
                       Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0
                         ~stop:0;
                     hint = None;
                   })
        | None -> [])
  in
  let name = read_string "name" in
  let version =
    match Version.parse (read_string "version") with
    | Ok v -> v
    | Error message ->
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message;
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               })
  in
  let targets =
    read_string_list ~field:"targets" ~missing_code:(Some "E5101")
  in
  List.iter
    (fun t ->
      if not (List.mem t known_targets) then
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message = Printf.sprintf "unknown target `%s`" t;
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               }))
    targets;
  (* The libraries the c target links: bare names only — a `-`- or
     `/`-shaped entry is a flag or a path, not a library, and refusing it
     keeps the manifest data rather than a shell fragment. *)
  let link = read_string_list ~field:"link" ~missing_code:None in
  List.iter
    (fun lib ->
      if lib = "" || lib.[0] = '-' || String.contains lib '/' then
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message =
                   Printf.sprintf
                     "link entry `%s` must be a bare library name (like \
                      \"sqlite3\")"
                     lib;
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               }))
    link;
  (* The project's registry endpoint — pulls and publishes: an HTTP(S) URL
     only. A filesystem registry is a developer/test affordance and stays
     with EMO_REGISTRY — a committed manifest must name an endpoint every
     machine can reach the same way. *)
  let registry =
    match Emo_eval.lookup_opt env "registry" with
    | None -> None
    | Some (Emo_eval.String s) ->
        if
          String.starts_with ~prefix:"http://" s
          || String.starts_with ~prefix:"https://" s
        then Some s
        else
          raise
            (manifest_error "E5103"
               (Printf.sprintf
                  "field `registry` must be an http(s) URL, got `%s`" s)
               ~hint:
                 "a filesystem registry is set with the EMO_REGISTRY \
                  environment variable, not the manifest")
    | Some v ->
        raise
          (manifest_error "E5103"
             (Printf.sprintf "field `registry` must be a string, got %s"
                (Emo_eval.type_name v)))
  in
  let deps =
    List.map
      (fun (dep, raw) ->
        match Version.parse raw with
        | Ok v -> (dep, v)
        | Error message ->
            raise
              (Manifest_error
                 Emo_support.Diagnostic.
                   {
                     severity = Error;
                     code = Some "E5103";
                     message;
                     span =
                       Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0
                         ~stop:0;
                     hint = None;
                   }))
      deps_pairs
  in
  { name; version; targets; link; registry; deps }

(* A `package.emo` is the manifest: data in the restricted profile, never a
   module. A reader that walks Emo sources has to know that, or it reads
   `name`/`version`/`deps` as unbound names — so `emo check` and the editor
   both ask here rather than each keeping its own file-name rule. *)
let is_manifest_file (file : string) : bool =
  String.equal (Filename.basename file) "package.emo"

(* `acme/json_tools` binds as `json_tools`: the scoped name's short name is
   what a require brings into scope. Centralized here for a later
   scope-format swap. *)
let short_name (name : string) : string =
  match String.index_opt name '/' with
  | Some i -> String.sub name (i + 1) (String.length name - i - 1)
  | None -> name

module Resolve = struct
  type package_version = {
    pv_version : Version.t;
    pv_targets : string list;
    pv_deps : (string * Version.t) list; (* its own exact pins *)
    pv_checksum : string;
        (* the content digest this version must unpack to — what the
           lockfile records, verified on every fetch *)
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
  (* The lockfile's on-disk name, beside package.emo. *)
  let filename = "package.lock"

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

  (* Verify: every manifest root must be present at the pinned version.
     Returns [] when satisfied. The lockfile records the whole resolution,
     so its other entries are the roots' transitive closure — not something
     this check can weigh; that the closure is the one the roots induce is
     [unreachable]'s question, asked once the packages' own manifests have
     been read. *)
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

  (* The closure check, the strict half of the lockfile/manifest agreement:
     the resolution's every entry must be reachable from [roots] by
     following the [declared] edges — the dependencies each fetched
     package's own manifest states. An entry nothing reaches is one the
     manifest has moved past (a removed root leaving its old closure
     behind), so the recorded resolution is no longer this manifest's.
     Returns the unreachable entries' names. *)
  let unreachable ~(roots : string list)
      ~(declared : (string * string list) list) (t : t) : string list =
    let rec go reached = function
      | [] -> reached
      | name :: rest ->
          if List.mem name reached then go reached rest
          else
            let deps =
              match List.assoc_opt name declared with
              | Some deps -> deps
              | None -> []
            in
            go (name :: reached) (deps @ rest)
    in
    let reached = go [] roots in
    List.filter_map
      (fun e -> if List.mem e.dep reached then None else Some e.dep)
      t
end

(* The registry and the global content-addressed cache. A directory
   registry serves tests and offline development over the same protocol the
   future HTTPS client will use: <endpoint>/<owner>/<name>/<version>/
   holding the package's manifest (package.emo) and source files. *)
module Registry = struct
  (* A registry endpoint: a filesystem directory, the standard library
     carried in the compiler binary itself (T24.2), or an HTTP(S) service
     speaking the frozen pull protocol (B.1 versions / B.2 dependencies /
     B.3 downloads). The pure operations below serve the local kinds; the
     HTTP kind is fetched through [Http_registry] with a caller-supplied
     transport. *)
  type t = Fs_dir of string | Embedded | Http of string

  (* The name the diagnostics show for the endpoint. *)
  let describe = function
    | Fs_dir dir -> dir
    | Embedded -> "the bundled standard library"
    | Http url -> url

  type fetched = {
    f_name : string;
    f_version : Version.t;
    f_checksum : string;
    (* digest over the sorted (path, content) pairs *)
    f_files : (string * string) list; (* relative path → content *)
  }

  (* SHA-256 over the sorted (path, content) pairs, each fed as
     `path \0 content \0` — the digest the registry service recomputes and
     the checksum package.lock records. *)
  let digest (files : (string * string) list) : string =
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
    Digestif.SHA256.digest_string
      (String.concat ""
         (List.map (fun (p, c) -> p ^ "\000" ^ c ^ "\000") sorted))
    |> Digestif.SHA256.to_hex

  (* Collects every package file under [dir], relative paths as keys: the
     .emo modules plus the .c/.h sources a native-binding package carries
     (the c target compiles them into the program — CHECK.md, 2026-10-12).
     Build output (.emo-build) and dune's tree (_build) are not package
     content. *)
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
            if Sys.is_directory path then
              if entry = ".emo-build" || entry = "_build" then []
              else walk rel_entry
            else if
              Filename.check_suffix entry ".emo"
              || Filename.check_suffix entry ".c"
              || Filename.check_suffix entry ".h"
            then
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
    let files =
      match t with
      | Fs_dir dir ->
          let dir =
            Filename.concat dir
              (Filename.concat name (Version.to_string version))
          in
          if Sys.file_exists dir then collect_files dir else []
      | Embedded ->
          let prefix = Filename.concat name (Version.to_string version) ^ "/" in
          let plen = String.length prefix in
          List.filter_map
            (fun (path, content) ->
              if String.length path >= plen && String.sub path 0 plen = prefix
              then
                Some (String.sub path plen (String.length path - plen), content)
              else None)
            Emo_stdlib_data.files
      | Http _ ->
          (* The project pipeline routes HTTP endpoints through
             [Http_registry]; reaching this arm means a caller skipped the
             routing. *)
          []
    in
    if files = [] then
      Error
        (Printf.sprintf "registry `%s` has no package %s@%s" (describe t) name
           (Version.to_string version))
    else
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

  (* Every version of [name] the registry publishes, in ascending order. *)
  let versions (t : t) ~(name : string) : Version.t list =
    match t with
    | Fs_dir dir -> (
        let dir = Filename.concat dir name in
        match Sys.readdir dir with
        | exception Sys_error _ -> []
        | raw ->
            raw |> Array.to_list
            |> List.filter_map (fun entry ->
                match Version.parse entry with
                | Ok v -> Some v
                | Error _ -> None)
            |> List.sort Version.compare)
    | Embedded ->
        let prefix = name ^ "/" in
        let plen = String.length prefix in
        List.filter_map
          (fun (path, _) ->
            if String.length path >= plen && String.sub path 0 plen = prefix
            then
              let rest = String.sub path plen (String.length path - plen) in
              match String.index_opt rest '/' with
              | Some i -> (
                  match Version.parse (String.sub rest 0 i) with
                  | Ok v -> Some v
                  | Error _ -> None)
              | None -> None
            else None)
          Emo_stdlib_data.files
        |> List.sort_uniq Version.compare
    | Http _ ->
        (* Routed through [Http_registry] by the project pipeline. *)
        []

  (* Builds a resolver index for [names] by reading each published version's
     manifest. Versions with unreadable manifests are skipped — resolution
     only considers complete publishes. *)
  let index (t : t) (names : string list) : Resolve.index =
    List.map
      (fun name ->
        ( name,
          List.filter_map
            (fun version ->
              match fetch t ~name ~version with
              | Error _ -> None
              | Ok f -> (
                  match
                    List.find_opt
                      (fun (path, _) -> Filename.basename path = "package.emo")
                      f.f_files
                  with
                  | None -> None
                  | Some (_, source) -> (
                      match parse_manifest ~file:"package.emo" ~source with
                      | m ->
                          Some
                            {
                              Resolve.pv_version = version;
                              pv_targets = m.targets;
                              pv_deps = m.deps;
                              pv_checksum = f.f_checksum;
                            }
                      | exception Manifest_error _ -> None)))
            (versions t ~name) ))
      names

  (* Like [index], but walks each indexed package's own `deps` so a
     transitive dependency is present in the index. The solver walks the
     closure from the index, so indexing only the given names leaves a
     package's own deps unknown to it. *)
  let index_closure (t : t) (names : string list) : Resolve.index =
    let rec go seen acc pending =
      let fresh = List.filter (fun n -> not (List.mem n seen)) pending in
      if fresh = [] then acc
      else
        let entries = index t fresh in
        let deps =
          List.concat_map
            (fun (_, pvs) ->
              List.concat_map (fun pv -> List.map fst pv.Resolve.pv_deps) pvs)
            entries
        in
        go (fresh @ seen) (acc @ entries) deps
    in
    go [] [] names

  (* The global cache: shared across projects, content-addressed — the
     directory name embeds the checksum, so equal content is stored once. *)
  (* A durable user cache — the OS wipes the temp directory, and a
     product cannot re-fetch on every build (T24.4). EMO_CACHE_DIR
     overrides; XDG_CACHE_HOME is honored. *)
  let default_cache_dir () =
    match Sys.getenv_opt "EMO_CACHE_DIR" with
    | Some dir when dir <> "" -> dir
    | _ ->
        let cache_home =
          match Sys.getenv_opt "XDG_CACHE_HOME" with
          | Some dir when dir <> "" -> dir
          | _ -> (
              match Sys.getenv_opt "HOME" with
              | Some home -> Filename.concat home ".cache"
              | None ->
                  Filename.concat (Filename.get_temp_dir_name ()) "emo-cache")
        in
        Filename.concat cache_home "emo"

  (* The content-addressed directory a fetched package materializes
     into — the checksum is in the name, so equal content is stored
     once. *)
  let cache_path ~(cache_dir : string) (f : fetched) : string =
    Filename.concat cache_dir
      (f.f_name ^ "-" ^ Version.to_string f.f_version ^ "-" ^ f.f_checksum)

  let is_cached ~(cache_dir : string) (f : fetched) : bool =
    Sys.file_exists (cache_path ~cache_dir f)

  let materialize ~(cache_dir : string) (f : fetched) :
      (string, string) result (* the package sources directory *) =
    let pkg_dir = cache_path ~cache_dir f in
    let materialize_file (rel, content) =
      let path = Filename.concat pkg_dir rel in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then
        ignore
          (Emo_tool.run_or_warn ~what:"emo deps"
             ("mkdir -p " ^ Filename.quote dir));
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

(* The .emoji archive: a deterministic gzip-compressed tar. The same file
   set always packs to the same bytes — paths sorted, every metadata field
   zeroed, and the gzip stream carries no timestamp. The deflate payload
   uses stored (uncompressed) blocks: publishing favors a byte-stable,
   dependency-free encoding over compression ratio, and every gzip reader
   accepts stored blocks. The decoder is the general one — the registry
   service re-packs uploads into its canonical archive (a compressed
   deflate stream plus an EMO-METADATA.json member), so pulling must accept
   any valid deflate encoding, not just this encoder's. *)
module Archive = struct
  let crc32_table =
    Array.init 256 (fun i ->
        let rec step n crc =
          if n = 0 then crc
          else
            let crc =
              if Int32.logand crc 1l <> 0l then
                Int32.logxor (Int32.shift_right_logical crc 1) 0xEDB88320l
              else Int32.shift_right_logical crc 1
            in
            step (n - 1) crc
        in
        step 8 (Int32.of_int i))

  let crc32 (data : string) : int32 =
    let crc = ref 0xFFFFFFFFl in
    String.iter
      (fun c ->
        let idx = Int32.to_int (Int32.logand !crc 0xFFl) lxor Char.code c in
        crc := Int32.logxor crc32_table.(idx) (Int32.shift_right_logical !crc 8))
      data;
    Int32.logxor !crc 0xFFFFFFFFl

  let gzip (data : string) : string =
    let buf = Buffer.create (String.length data + 64) in
    Buffer.add_string buf "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff";
    let len = String.length data in
    let pos = ref 0 in
    let block last off n =
      Buffer.add_char buf (if last then '\x01' else '\x00');
      Buffer.add_char buf (Char.chr (n land 0xFF));
      Buffer.add_char buf (Char.chr ((n lsr 8) land 0xFF));
      Buffer.add_char buf (Char.chr (lnot n land 0xFF));
      Buffer.add_char buf (Char.chr ((lnot n lsr 8) land 0xFF));
      Buffer.add_substring buf data off n
    in
    if len = 0 then block true 0 0
    else
      while !pos < len do
        let n = min 0xFFFF (len - !pos) in
        block (!pos + n = len) !pos n;
        pos := !pos + n
      done;
    let le32 v =
      for i = 0 to 3 do
        Buffer.add_char buf
          (Char.chr
             (Int32.to_int
                (Int32.logand (Int32.shift_right_logical v (i * 8)) 0xFFl)))
      done
    in
    le32 (crc32 data);
    le32 (Int32.of_int (len land 0xFFFFFFFF));
    Buffer.contents buf

  (* One ustar header (512 bytes) for a regular file: mode 0644, uid/gid 0,
     mtime 0. Long names split across the prefix field at a `/`. *)
  let tar_header ~(name : string) ~(size : int) : string =
    let name, prefix =
      if String.length name <= 100 then (name, "")
      else
        let rec split_at i =
          if i < 0 then None
          else if name.[i] = '/' then
            let prefix = String.sub name 0 i in
            let rest = String.sub name (i + 1) (String.length name - i - 1) in
            if String.length prefix <= 155 && String.length rest <= 100 then
              Some (rest, prefix)
            else split_at (i - 1)
          else split_at (i - 1)
        in
        match split_at (String.length name - 1) with
        | Some parts -> parts
        | None ->
            invalid_arg
              (Printf.sprintf "archive: path too long for ustar: %s" name)
    in
    let header = Bytes.make 512 '\000' in
    let set off len s =
      Bytes.blit_string s 0 header off (min len (String.length s))
    in
    let octal off len v =
      let s = Printf.sprintf "%0*o" (len - 1) v in
      set off len s
    in
    set 0 100 name;
    octal 100 8 0o644;
    octal 108 8 0;
    octal 116 8 0;
    octal 124 12 size;
    octal 136 12 0;
    (* checksum field: spaces while summing *)
    Bytes.fill header 148 8 ' ';
    Bytes.set header 156 '0';
    set 257 6 "ustar";
    set 263 2 "00";
    set 345 155 prefix;
    let sum = Bytes.fold_left (fun acc c -> acc + Char.code c) 0 header in
    let s = Printf.sprintf "%06o" sum in
    Bytes.blit_string s 0 header 148 6;
    Bytes.set header 154 '\000';
    Bytes.set header 155 ' ';
    Bytes.unsafe_to_string header

  let tar (files : (string * string) list) : string =
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
    let buf = Buffer.create 4096 in
    List.iter
      (fun (name, content) ->
        Buffer.add_string buf (tar_header ~name ~size:(String.length content));
        Buffer.add_string buf content;
        let pad = (512 - (String.length content mod 512)) mod 512 in
        Buffer.add_string buf (String.make pad '\000'))
      sorted;
    Buffer.add_string buf (String.make 1024 '\000');
    Buffer.contents buf

  (* The published artifact: sorted tar inside a timestamp-free gzip. *)
  let build (files : (string * string) list) : string = gzip (tar files)

  (* Malformed input to the decoder — never a partial result. *)
  exception Bad_archive of string

  (* ---- inflate: the general RFC 1951 decoder ----

     Bit-level reading (LSB-first) and canonical Huffman decoding in the
     style of zlib's puff: per-length counts plus symbols sorted by code
     assignment order, no tables. *)

  type bitstream = { bs_data : string; mutable bs_pos : int (* in bits *) }

  let get_bit bs =
    let byte = bs.bs_pos / 8 in
    if byte >= String.length bs.bs_data then
      raise (Bad_archive "truncated deflate stream");
    let bit = (Char.code bs.bs_data.[byte] lsr (bs.bs_pos land 7)) land 1 in
    bs.bs_pos <- bs.bs_pos + 1;
    bit

  (* Deflate packs an n-bit value LSB-first. *)
  let get_bits bs n =
    let v = ref 0 in
    for i = 0 to n - 1 do
      v := !v lor (get_bit bs lsl i)
    done;
    !v

  (* Stored blocks start on a byte boundary. *)
  let align_byte bs = bs.bs_pos <- (bs.bs_pos + 7) land lnot 7

  type huffman = {
    h_count : int array; (* per code length, 1..15 *)
    h_symbol : int array; (* symbols in code-assignment order *)
  }

  let build_huffman (lengths : int array) : huffman =
    let count = Array.make 16 0 in
    Array.iter (fun l -> if l > 0 then count.(l) <- count.(l) + 1) lengths;
    let offs = Array.make 16 0 in
    for l = 1 to 15 do
      offs.(l) <- offs.(l - 1) + count.(l - 1)
    done;
    let nsyms = Array.fold_left ( + ) 0 count in
    let symbol = Array.make nsyms 0 in
    Array.iteri
      (fun sym l ->
        if l > 0 then begin
          symbol.(offs.(l)) <- sym;
          offs.(l) <- offs.(l) + 1
        end)
      lengths;
    { h_count = count; h_symbol = symbol }

  (* Walks the canonical code one bit at a time: [code] accumulates the
     bits most-significant-first, [first] is the first code of each
     length. *)
  let decode_huffman bs h =
    let code = ref 0 and first = ref 0 and index = ref 0 in
    let rec step len =
      if len > 15 then raise (Bad_archive "deflate: no such Huffman code");
      code := !code lor get_bit bs;
      let count = h.h_count.(len) in
      if !code - !first < count then h.h_symbol.(!index + (!code - !first))
      else begin
        index := !index + count;
        first := (!first + count) lsl 1;
        code := !code lsl 1;
        step (len + 1)
      end
    in
    step 1

  let length_base =
    [|
      3;
      4;
      5;
      6;
      7;
      8;
      9;
      10;
      11;
      13;
      15;
      17;
      19;
      23;
      27;
      31;
      35;
      43;
      51;
      59;
      67;
      83;
      99;
      115;
      131;
      163;
      195;
      227;
      258;
    |]

  let length_extra =
    [|
      0;
      0;
      0;
      0;
      0;
      0;
      0;
      0;
      1;
      1;
      1;
      1;
      2;
      2;
      2;
      2;
      3;
      3;
      3;
      3;
      4;
      4;
      4;
      4;
      5;
      5;
      5;
      5;
      0;
    |]

  let dist_base =
    [|
      1;
      2;
      3;
      4;
      5;
      7;
      9;
      13;
      17;
      25;
      33;
      49;
      65;
      97;
      129;
      193;
      257;
      385;
      513;
      769;
      1025;
      1537;
      2049;
      3073;
      4097;
      6145;
      8193;
      12289;
      16385;
      24577;
    |]

  let dist_extra =
    [|
      0;
      0;
      0;
      0;
      1;
      1;
      2;
      2;
      3;
      3;
      4;
      4;
      5;
      5;
      6;
      6;
      7;
      7;
      8;
      8;
      9;
      9;
      10;
      10;
      11;
      11;
      12;
      12;
      13;
      13;
    |]

  let fixed_litlen =
    let lengths = Array.make 288 8 in
    for i = 144 to 255 do
      lengths.(i) <- 9
    done;
    for i = 256 to 279 do
      lengths.(i) <- 7
    done;
    build_huffman lengths

  let fixed_dist = build_huffman (Array.make 30 5)

  (* The dynamic block header: the code-length code's lengths arrive in a
     fixed scrambling order, then the literal/length and distance lengths
     ride it with the copy/zero repeats. *)
  let read_dynamic_header bs =
    let hlit = get_bits bs 5 + 257 in
    let hdist = get_bits bs 5 + 1 in
    let hclen = get_bits bs 4 + 4 in
    if hlit > 286 || hdist > 30 then
      raise (Bad_archive "deflate: too many length/distance symbols");
    let order =
      [| 16; 17; 18; 0; 8; 7; 9; 6; 10; 5; 11; 4; 12; 3; 13; 2; 14; 1; 15 |]
    in
    let cl_lengths = Array.make 19 0 in
    for i = 0 to hclen - 1 do
      cl_lengths.(order.(i)) <- get_bits bs 3
    done;
    let cl = build_huffman cl_lengths in
    let total = hlit + hdist in
    let lengths = Array.make total 0 in
    let i = ref 0 in
    while !i < total do
      let sym = decode_huffman bs cl in
      if sym < 16 then begin
        lengths.(!i) <- sym;
        incr i
      end
      else begin
        let fill, value =
          match sym with
          | 16 ->
              if !i = 0 then
                raise (Bad_archive "deflate: a repeat with no previous length");
              (3 + get_bits bs 2, lengths.(!i - 1))
          | 17 -> (3 + get_bits bs 3, 0)
          | 18 -> (11 + get_bits bs 7, 0)
          | _ -> raise (Bad_archive "deflate: bad code-length symbol")
        in
        if !i + fill > total then
          raise (Bad_archive "deflate: code lengths overrun the header");
        for _ = 1 to fill do
          lengths.(!i) <- value;
          incr i
        done
      end
    done;
    if lengths.(256) = 0 then
      raise (Bad_archive "deflate: the end-of-block code is missing");
    ( build_huffman (Array.sub lengths 0 hlit),
      build_huffman (Array.sub lengths hlit hdist) )

  (* One compressed block: literals copy out; length/distance pairs reach
     back into the output. *)
  let inflate_block bs out litlen dist_h =
    let rec loop () =
      let sym = decode_huffman bs litlen in
      if sym < 256 then begin
        Buffer.add_char out (Char.chr sym);
        loop ()
      end
      else if sym = 256 then () (* end of block *)
      else begin
        if sym > 285 then
          raise (Bad_archive "deflate: invalid literal/length symbol");
        let li = sym - 257 in
        let len = length_base.(li) + get_bits bs length_extra.(li) in
        let dsym = decode_huffman bs dist_h in
        if dsym > 29 then raise (Bad_archive "deflate: invalid distance symbol");
        let dist = dist_base.(dsym) + get_bits bs dist_extra.(dsym) in
        if dist > Buffer.length out then
          raise (Bad_archive "deflate: distance reaches before the output");
        for _ = 1 to len do
          Buffer.add_char out (Buffer.nth out (Buffer.length out - dist))
        done;
        loop ()
      end
    in
    loop ()

  (* The gzip wrapper: header walk, the deflate stream (stored, fixed, or
     dynamic blocks), then both trailers verified. *)
  let gunzip (data : string) : (string, string) result =
    let n = String.length data in
    let u16 i = Char.code data.[i] lor (Char.code data.[i + 1] lsl 8) in
    let u32 i =
      Int32.logor
        (Int32.of_int (u16 i))
        (Int32.shift_left (Int32.of_int (u16 (i + 2))) 16)
    in
    let need i k = if i + k > n then raise (Bad_archive "truncated archive") in
    try
      need 0 18;
      if Char.code data.[0] <> 0x1f || Char.code data.[1] <> 0x8b then
        raise (Bad_archive "not a gzip stream");
      if Char.code data.[2] <> 8 then
        raise (Bad_archive "the gzip member is not deflate");
      let flg = Char.code data.[3] in
      if flg land 0xE0 <> 0 then raise (Bad_archive "gzip reserved flags set");
      let pos = ref 10 in
      if flg land 0x04 <> 0 then begin
        (* FEXTRA: a length, then that many bytes. *)
        need !pos 2;
        let xlen = u16 !pos in
        pos := !pos + 2;
        need !pos xlen;
        pos := !pos + xlen
      end;
      let skip_cstr () =
        let rec scan i =
          need i 1;
          if data.[i] = '\000' then i + 1 else scan (i + 1)
        in
        pos := scan !pos
      in
      if flg land 0x08 <> 0 then skip_cstr () (* FNAME *);
      if flg land 0x10 <> 0 then skip_cstr () (* FCOMMENT *);
      if flg land 0x02 <> 0 then begin
        (* FHCRC *)
        need !pos 2;
        pos := !pos + 2
      end;
      let bs = { bs_data = data; bs_pos = !pos * 8 } in
      let out = Buffer.create (String.length data * 3) in
      let finished = ref false in
      while not !finished do
        finished := get_bit bs = 1;
        match get_bits bs 2 with
        | 0 ->
            (* stored: byte-aligned LEN/NLEN then the raw bytes *)
            align_byte bs;
            let p = bs.bs_pos / 8 in
            need p 4;
            let len = u16 p and nlen = u16 (p + 2) in
            if len lxor 0xFFFF <> nlen then
              raise (Bad_archive "deflate stored block: LEN/NLEN disagree");
            need (p + 4) len;
            Buffer.add_substring out data (p + 4) len;
            bs.bs_pos <- (p + 4 + len) * 8
        | 1 -> inflate_block bs out fixed_litlen fixed_dist
        | 2 ->
            let litlen, dist_h = read_dynamic_header bs in
            inflate_block bs out litlen dist_h
        | _ -> raise (Bad_archive "deflate: reserved block type")
      done;
      let data_end = (bs.bs_pos + 7) / 8 in
      need data_end 8;
      let crc = u32 data_end and size = u32 (data_end + 4) in
      let payload = Buffer.contents out in
      if crc32 payload <> crc then raise (Bad_archive "gzip CRC mismatch");
      if Int32.of_int (String.length payload land 0xFFFFFFFF) <> size then
        raise (Bad_archive "the gzip size trailer disagrees with the payload");
      Ok payload
    with Bad_archive m -> Error ("archive: " ^ m)

  (* The ustar walk: 512-byte headers, regular files only, every header
     checksum verified, a zero block ends the archive. *)
  let untar (data : string) : ((string * string) list, string) result =
    let n = String.length data in
    let need i k = if i + k > n then raise (Bad_archive "truncated archive") in
    let cstr off len =
      let raw = String.sub data off len in
      match String.index_opt raw '\000' with
      | Some i -> String.sub raw 0 i
      | None -> raw
    in
    let octal off len =
      let acc = ref 0 in
      for i = off to off + len - 1 do
        match data.[i] with
        | '0' .. '7' as c -> acc := (!acc * 8) + Char.code c - Char.code '0'
        | ' ' | '\000' -> ()
        | _ -> raise (Bad_archive "tar header: a numeric field is not octal")
      done;
      !acc
    in
    try
      let rec walk pos acc =
        need pos 512;
        let zero =
          let rec check i stop =
            i >= stop || (data.[i] = '\000' && check (i + 1) stop)
          in
          check pos (pos + 512)
        in
        if zero then Ok (List.rev acc)
        else begin
          let checksum = octal (pos + 148) 8 in
          let sum = ref 0 in
          for i = pos to pos + 511 do
            sum :=
              !sum
              +
              if i >= pos + 148 && i < pos + 156 then 32 else Char.code data.[i]
          done;
          if !sum <> checksum then
            raise (Bad_archive "tar header: checksum mismatch");
          (match data.[pos + 156] with
          | '0' | '\000' -> ()
          | _ -> raise (Bad_archive "tar entry is not a regular file"));
          if String.sub data (pos + 257) 5 <> "ustar" then
            raise (Bad_archive "tar header: not a ustar entry");
          let name = cstr pos 100 and prefix = cstr (pos + 345) 155 in
          let path = if prefix = "" then name else prefix ^ "/" ^ name in
          if path = "" then raise (Bad_archive "tar entry with no name");
          let size = octal (pos + 124) 12 in
          let data_off = pos + 512 in
          need data_off size;
          let content = String.sub data data_off size in
          let pad = (512 - (size mod 512)) mod 512 in
          walk (data_off + size + pad) ((path, content) :: acc)
        end
      in
      walk 0 []
    with Bad_archive m -> Error ("archive: " ^ m)

  (* The inverse of [build]: the bytes a registry serves back into the
     package's (path, content) list. *)
  let unpack (data : string) : ((string * string) list, string) result =
    match gunzip data with Error _ as e -> e | Ok payload -> untar payload
end

(* Extracts a string field from a flat JSON object (the registry's frozen
   error shape); None when the field is absent or the body is not JSON. The
   publish/login flows in emo_cli read it through this same definition. *)
let json_string_field (key : string) (json : string) : string option =
  let pat = "\"" ^ key ^ "\"" in
  let n = String.length json and p = String.length pat in
  let rec find i =
    if i + p > n then None
    else if String.sub json i p = pat then Some (i + p)
    else find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some i ->
      let rec skip i =
        if i < n && (json.[i] = ' ' || json.[i] = ':' || json.[i] = '\t') then
          skip (i + 1)
        else i
      in
      let i = skip i in
      if i >= n || json.[i] <> '"' then None
      else
        let buf = Buffer.create 16 in
        let rec read i =
          if i >= n then None
          else
            match json.[i] with
            | '\\' when i + 1 < n ->
                Buffer.add_char buf json.[i + 1];
                read (i + 2)
            | '"' -> Some (Buffer.contents buf)
            | c ->
                Buffer.add_char buf c;
                read (i + 1)
        in
        read (i + 1)

(* The HTTP(S) pull client: the consumer half of the registry service's
   frozen protocol (registry/docs/design.md §5) — B.1 lists a package's
   versions with checksums and targets, B.2 answers dependencies in batch,
   B.3 serves the archive. The transport is injected: [runner] runs an
   embedded Emo program against the bundled standard library (the publish
   uploader's mechanism), so the client needs no HTTP stack of its own and
   works from a lone emo binary. Each program prints the HTTP status on its
   first line and a line-oriented payload after it; the parsers below are
   the payload's only readers. *)
module Http_registry = struct
  type runner =
    program:string ->
    globals:(string * Emo_eval.value) list ->
    (string, string) result

  (* Every request is a GET with an optional bearer token — a public
     package needs none, a private one is 404 without it, so the token is
     simply sent whenever the caller has one. A transport failure raises
     inside the program and comes back as the runner's Error, the same
     mapping publish's uploader uses. A non-200 status prints the raw body
     after the status line, so the registry's error JSON reaches the host
     for [refused] to format. *)
  let versions_program =
    {|require "http"
require "json"

var headers = []
if __token != "" {
  headers = [("Authorization", "Bearer " + __token)]
}
const resp = http.request("GET", __url, headers, "", 60.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    if ok.status == 200 {
      case json.decode(ok.body) {
        (R.error, why) -> { raise Exception.new(message: "registry answered invalid JSON: " + why) }
        (R.ok, doc)    -> {
          const versions = doc.get("versions").items()
          var i = 0
          while i < versions.length() {
            const v = versions[i]
            const targets = v.get("targets").items()
            var tlist = ""
            var t = 0
            while t < targets.length() {
              if t > 0 { tlist = tlist + "," }
              tlist = tlist + targets[t].as_string()
              t = t + 1
            }
            var yanked = "false"
            if v.get("yanked").as_bool() { yanked = "true" }
            println(v.get("version").as_string() + "\t" + v.get("checksum").as_string() + "\t" + tlist + "\t" + yanked)
            i = i + 1
          }
        }
      }
    } else {
      println(ok.body)
    }
  }
}
|}

  let deps_program =
    {|require "http"
require "json"

var headers = []
if __token != "" {
  headers = [("Authorization", "Bearer " + __token)]
}
const resp = http.request("GET", __url, headers, "", 60.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    if ok.status == 200 {
      case json.decode(ok.body) {
        (R.error, why) -> { raise Exception.new(message: "registry answered invalid JSON: " + why) }
        (R.ok, doc)    -> {
          const pkgs = doc.entries()
          var p = 0
          while p < pkgs.length() {
            const entry = pkgs[p]
            const versions = entry[1].items()
            var i = 0
            while i < versions.length() {
              const v = versions[i]
              const deps = v.get("deps").entries()
              var dlist = ""
              var d = 0
              while d < deps.length() {
                if d > 0 { dlist = dlist + "," }
                dlist = dlist + deps[d][0] + "=" + deps[d][1].as_string()
                d = d + 1
              }
              var yanked = "false"
              if v.get("yanked").as_bool() { yanked = "true" }
              println(entry[0] + "\t" + v.get("version").as_string() + "\t" + dlist + "\t" + yanked)
              i = i + 1
            }
            p = p + 1
          }
        }
      }
    } else {
      println(ok.body)
    }
  }
}
|}

  (* The archive body rides the same framing — status line, then the raw
     bytes; println's one trailing newline is stripped by the reader. Emo
     strings are byte strings (publish's upload test pins binary intactness
     through this channel), so the archive arrives verbatim. *)
  let download_program =
    {|require "http"

var headers = []
if __token != "" {
  headers = [("Authorization", "Bearer " + __token)]
}
const resp = http.request("GET", __url, headers, "", 120.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    println(ok.body)
  }
}
|}

  (* Splits one exchange's printed output into the status line and the body
     that follows it; println's trailing newline is not the body's. The
     publish/login programs share the framing. *)
  let parse_exchange (text : string) : (int * string, string) result =
    match String.index_opt text '\n' with
    | None -> Error ("the fetch printed no status: " ^ text)
    | Some i -> (
        match int_of_string_opt (String.trim (String.sub text 0 i)) with
        | None -> Error ("the fetch printed no status: " ^ text)
        | Some status ->
            let body = String.sub text (i + 1) (String.length text - i - 1) in
            let body =
              if String.length body > 0 && body.[String.length body - 1] = '\n'
              then String.sub body 0 (String.length body - 1)
              else body
            in
            Ok (status, body))

  (* Strips one trailing slash, so joining endpoint paths never doubles it. *)
  let base_url (base : string) : string =
    let n = String.length base in
    if n > 0 && base.[n - 1] = '/' then String.sub base 0 (n - 1) else base

  let token_global = function
    | Some t -> Emo_eval.String t
    | None -> Emo_eval.String ""

  let exchange (runner : runner) ~(program : string) ~(url : string)
      ~(token : string option) : (int * string, string) result =
    match
      runner ~program
        ~globals:
          [ ("__url", Emo_eval.String url); ("__token", token_global token) ]
    with
    | Error _ as e -> e
    | Ok text -> parse_exchange text

  let split_scoped ~(base : string) (name : string) :
      (string * string, string) result =
    match String.split_on_char '/' name with
    | [ owner; short ] -> Ok (owner, short)
    | _ ->
        Error
          (Printf.sprintf
             "registry `%s` serves scoped (owner/name) packages only; `%s` is \
              not one"
             base name)

  (* One registry refusal, formatted for an error diagnostic. The frozen
     error shape — {"error":{"code":...,"message":...}} — becomes
     "answered <status> error: `<subject>` (<code>) <message>", so the code
     and the human text stay visible instead of a raw JSON blob; any other
     body keeps the trimmed raw text. *)
  let refused ~(base : string) ~(status : int) ~(subject : string)
      (body : string) : string =
    match (json_string_field "code" body, json_string_field "message" body)
    with
    | Some code, Some message ->
        Printf.sprintf "registry `%s` answered %d error: `%s` (%s) %s" base
          status subject code (String.trim message)
    | _ ->
        Printf.sprintf "registry `%s` answered %d error: `%s` %s" base status
          subject (String.trim body)

  (* One published version as B.1 reports it. *)
  type version_info = {
    vi_version : Version.t;
    vi_checksum : string;
    vi_targets : string list;
    vi_yanked : bool;
  }

  (* The versions payload's lines: version, checksum, comma-separated
     targets, yanked — tab-separated, one version per line. *)
  let parse_versions_payload ~(base : string) (body : string) :
      (version_info list, string) result =
    let malformed () =
      Error
        (Printf.sprintf "registry `%s` answered a malformed versions payload"
           base)
    in
    let rec parse_lines acc = function
      | [] -> Ok (List.rev acc)
      | line :: rest -> (
          if String.trim line = "" then parse_lines acc rest
          else
            match String.split_on_char '\t' line with
            | [ version; checksum; targets; yanked ] -> (
                match Version.parse version with
                | Error _ -> malformed ()
                | Ok v -> (
                    match yanked with
                    | "true" | "false" ->
                        let vi =
                          {
                            vi_version = v;
                            vi_checksum = checksum;
                            vi_targets =
                              (if targets = "" then []
                               else String.split_on_char ',' targets);
                            vi_yanked = yanked = "true";
                          }
                        in
                        parse_lines (vi :: acc) rest
                    | _ -> malformed ()))
            | _ -> malformed ())
    in
    parse_lines [] (String.split_on_char '\n' body)

  let versions (runner : runner) ~(base : string) ~(token : string option)
      ~(name : string) : (version_info list, string) result =
    match split_scoped ~base name with
    | Error _ as e -> e
    | Ok (owner, short) -> (
        let url =
          Printf.sprintf "%s/api/v1/packages/%s/%s/versions" (base_url base)
            owner short
        in
        match exchange runner ~program:versions_program ~url ~token with
        | Error _ as e -> e
        | Ok (200, body) -> parse_versions_payload ~base body
        | Ok (status, body) -> Error (refused ~base ~status ~subject:name body))

  (* B.2: one row per (package, version): the version's own exact pins and
     its yank flag. *)
  type deps_info = {
    di_name : string;
    di_version : Version.t;
    di_deps : (string * Version.t) list;
    di_yanked : bool;
  }

  (* The dependencies payload's lines: name, version, comma-separated
     dep=version pairs, yanked — tab-separated. *)
  let parse_deps_payload ~(base : string) (body : string) :
      (deps_info list, string) result =
    let malformed () =
      Error
        (Printf.sprintf
           "registry `%s` answered a malformed dependencies payload" base)
    in
    let parse_dep_pairs text =
      if text = "" then Ok []
      else
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | pair :: rest -> (
              match String.split_on_char '=' pair with
              | [ dep; version ] -> (
                  match Version.parse version with
                  | Error _ -> malformed ()
                  | Ok v -> go ((dep, v) :: acc) rest)
              | _ -> malformed ())
        in
        go [] (String.split_on_char ',' text)
    in
    let rec parse_lines acc = function
      | [] -> Ok (List.rev acc)
      | line :: rest -> (
          if String.trim line = "" then parse_lines acc rest
          else
            match String.split_on_char '\t' line with
            | [ name; version; dep_pairs; yanked ] -> (
                match Version.parse version with
                | Error _ -> malformed ()
                | Ok v -> (
                    match parse_dep_pairs dep_pairs with
                    | Error _ as e -> e
                    | Ok deps -> (
                        match yanked with
                        | "true" | "false" ->
                            parse_lines
                              ({
                                 di_name = name;
                                 di_version = v;
                                 di_deps = deps;
                                 di_yanked = yanked = "true";
                               }
                              :: acc)
                              rest
                        | _ -> malformed ())))
            | _ -> malformed ())
    in
    parse_lines [] (String.split_on_char '\n' body)

  let deps (runner : runner) ~(base : string) ~(token : string option)
      ~(names : string list) : (deps_info list, string) result =
    if names = [] then Ok []
    else
      let url =
        Printf.sprintf "%s/api/v1/dependencies?packages=%s" (base_url base)
          (String.concat "," names)
      in
      match exchange runner ~program:deps_program ~url ~token with
      | Error _ as e -> e
      | Ok (200, body) -> parse_deps_payload ~base body
      | Ok (status, body) ->
          Error
            (refused ~base ~status ~subject:(String.concat ", " names) body)

  (* The resolver index for one batch of scoped names: B.1 per name joined
     with one batched B.2. Yanked versions are excluded — a fresh resolution
     never selects one, while an existing lockfile's pin still downloads.
     The closure walk across dependency edges is the caller's (routing may
     send a discovered name to a different endpoint kind). *)
  let index (runner : runner) ~(base : string) ~(token : string option)
      (names : string list) : (Resolve.index, string) result =
    let rec collect_versions acc = function
      | [] -> Ok (List.rev acc)
      | name :: rest -> (
          match versions runner ~base ~token ~name with
          | Error _ as e -> e
          | Ok vs -> collect_versions ((name, vs) :: acc) rest)
    in
    match collect_versions [] names with
    | Error _ as e -> e
    | Ok version_lists -> (
        match deps runner ~base ~token ~names with
        | Error _ as e -> e
        | Ok dep_rows ->
            let rec join acc = function
              | [] -> Ok (List.rev acc)
              | (name, vs) :: rest -> (
                  let rec join_versions vacc = function
                    | [] -> Ok (List.rev vacc)
                    | vi :: vrest -> (
                        if vi.vi_yanked then join_versions vacc vrest
                        else
                          match
                            List.find_opt
                              (fun di ->
                                di.di_name = name
                                && di.di_version = vi.vi_version)
                              dep_rows
                          with
                          | Some di ->
                              join_versions
                                ({
                                   Resolve.pv_version = vi.vi_version;
                                   pv_targets = vi.vi_targets;
                                   pv_deps = di.di_deps;
                                   pv_checksum = vi.vi_checksum;
                                 }
                                :: vacc)
                                vrest
                          | None ->
                              Error
                                (Printf.sprintf
                                   "registry `%s` metadata for `%s` is \
                                    inconsistent: the versions list has %s but \
                                    the dependencies endpoint does not — retry"
                                   base name
                                   (Version.to_string vi.vi_version)))
                  in
                  match join_versions [] vs with
                  | Error _ as e -> e
                  | Ok pvs -> join ((name, pvs) :: acc) rest)
            in
            join [] version_lists)

  (* B.3: download the archive, unpack it, and pin the content digest to
     what the index advertised. A README.md rides along but is not package
     content — the collected-source filter drops it before the digest,
     matching publish and the fs registry. *)
  let fetch (runner : runner) ~(base : string) ~(token : string option)
      ~(expected_checksum : string option) ~(name : string)
      ~(version : Version.t) : (Registry.fetched, string) result =
    match split_scoped ~base name with
    | Error _ as e -> e
    | Ok (owner, short) -> (
        let url =
          Printf.sprintf "%s/downloads/%s-%s-%s.emoji" (base_url base) owner
            short
            (Version.to_string version)
        in
        match exchange runner ~program:download_program ~url ~token with
        | Error _ as e -> e
        | Ok (200, archive) -> (
            match Archive.unpack archive with
            | Error _ as e -> e
            | Ok members -> (
                let files =
                  List.filter
                    (fun (path, _) ->
                      Filename.check_suffix path ".emo"
                      || Filename.check_suffix path ".c"
                      || Filename.check_suffix path ".h")
                    members
                in
                if
                  not
                    (List.exists
                       (fun (p, _) -> Filename.basename p = "package.emo")
                       files)
                then
                  Error
                    (Printf.sprintf "package %s@%s has no manifest" name
                       (Version.to_string version))
                else
                  let checksum = Registry.digest files in
                  match expected_checksum with
                  | Some expected when expected <> checksum ->
                      Error
                        (Printf.sprintf
                           "checksum mismatch for %s@%s: the registry \
                            advertises %s but the archive unpacks to %s"
                           name
                           (Version.to_string version)
                           expected checksum)
                  | _ ->
                      Ok
                        {
                          Registry.f_name = name;
                          f_version = version;
                          f_checksum = checksum;
                          f_files = files;
                        }))
        | Ok (status, body) ->
            Error
              (refused ~base ~status
                 ~subject:(name ^ "@" ^ Version.to_string version)
                 body))
end

(* Publishing: the client side of the registry's publish protocol.
   [prepare] validates the package rooted at [dir] and builds the .emoji
   archive — the CLI ships the bytes over HTTP. The content digest is the
   Registry digest over the package's collected sources (.emo plus any
   .c/.h); a root README.md rides along but is never digested, matching
   the server. *)
module Publish = struct
  type prepared = {
    p_manifest : manifest;
    p_files : (string * string) list; (* archive members, sorted by path *)
    p_checksum : string;
    p_archive : string; (* the .emoji bytes *)
    p_archive_name : string; (* owner-name-version.emoji *)
  }

  (* The registry's name rule: owner/name, each segment a lowercase
     identifier — 1–64 chars, a letter first, then letters, digits or `_`.
     The short name binds in code as the module identifier, so the segment
     alphabet is exactly the identifier alphabet; `-` is excluded (no
     identifier can spell it), and dash-free segments keep the archive
     filename's single-dash joins unambiguous. Plain (stdlib-style) names
     are not publishable. *)
  let valid_name_part (s : string) : bool =
    String.length s >= 1
    && String.length s <= 64
    && (match s.[0] with 'a' .. 'z' -> true | _ -> false)
    && String.for_all
         (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_')
         s

  let validate_name (name : string) : (string * string, string) result =
    match String.split_on_char '/' name with
    | [ owner; short ] when valid_name_part owner && valid_name_part short ->
        Ok (owner, short)
    | _ ->
        Error
          (Printf.sprintf
             "package name `%s` is not publishable: expected owner/name, each \
              part a lowercase identifier: a letter, then letters, digits or \
              `_`"
             name)

  let read_file path =
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))

  let prepare ~(dir : string) : (prepared, string) result =
    let manifest_path = Filename.concat dir "package.emo" in
    if not (Sys.file_exists manifest_path) then
      Error (dir ^ ": no package.emo manifest")
    else
      match
        parse_manifest ~file:manifest_path ~source:(read_file manifest_path)
      with
      | exception Manifest_error d -> Error d.Emo_support.Diagnostic.message
      | m -> (
          match validate_name m.name with
          | Error _ as error -> error
          | Ok (owner, short) ->
              let emo_files = Registry.collect_files dir in
              let readme = Filename.concat dir "README.md" in
              let files =
                if Sys.file_exists readme then
                  ("README.md", read_file readme) :: emo_files
                else emo_files
              in
              let version = Version.to_string m.version in
              Ok
                {
                  p_manifest = m;
                  p_files =
                    List.sort (fun (a, _) (b, _) -> String.compare a b) files;
                  p_checksum = Registry.digest emo_files;
                  p_archive = Archive.build files;
                  p_archive_name =
                    Printf.sprintf "%s-%s-%s.emoji" owner short version;
                })
end
