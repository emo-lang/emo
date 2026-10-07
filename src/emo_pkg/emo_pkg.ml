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

let known_targets = [ "ocaml"; "c"; "wasm"; "typescript"; "beam"; "riscv64" ]

(* Token-level strict reader: accepts exactly the README shape.
     package {
       name = "acme/json_tools"
       version = "0.1.0"
       targets = ["ocaml", "wasm"]
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
       targets = ["ocaml", "wasm"]
       deps { json = "2.3.1" }
     }
   Unknown fields, missing fields, and non-literal values are errors — the
   manifest is data, not program logic (until phase B). *)
(* The budget for restricted manifest evaluation: generous but finite. *)
let manifest_budget = 10_000

exception Manifest_budget_exceeded of int

(* Phase B: the manifest is evaluated as real Emo in the restricted profile
   (hermetic, step-budgeted, no I/O builtins in scope). The `package { ... }`
   block's bindings become the fields and a `deps { ... }` block's bindings
   become the dependencies. *)
let parse_manifest ~(file : string) ~(source : string) : manifest =
  let items =
    match Emo_parser.parse_program ~file ~source with
    | items -> items
    | exception Emo_lexer.Error d -> raise (Manifest_error d)
    | exception Emo_parser.Error d -> raise (Manifest_error d)
  in
  let manifest_error code message =
    Manifest_error
      Emo_support.Diagnostic.
        {
          severity = Error;
          code = Some code;
          message;
          span = Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
          hint = None;
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
    | Emo_eval.Emo_raise (v, span, trace) ->
        let d = Emo_eval.uncaught_diagnostic (v, span, trace) in
        raise
          (Manifest_error { d with Emo_support.Diagnostic.code = Some "E5103" })
  in
  (* Strict fixed schema: nothing besides name, version, and targets may be
     defined in the package block. *)
  Hashtbl.iter
    (fun k _ ->
      if
        not
          (String.equal k "name" || String.equal k "version"
         || String.equal k "targets")
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
  let read_targets () =
    match Emo_eval.lookup_opt env "targets" with
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
                           Printf.sprintf "targets must be strings, got %s"
                             (Emo_eval.type_name other);
                         span =
                           Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0
                             ~stop:0;
                         hint = None;
                       }))
          (Array.to_list items)
    | Some other ->
        raise
          (Manifest_error
             Emo_support.Diagnostic.
               {
                 severity = Error;
                 code = Some "E5103";
                 message = Printf.sprintf "`targets` must be an array";
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
                 message = "missing field `targets`";
                 span =
                   Emo_support.Span.make ~file ~line:1 ~col:1 ~start:0 ~stop:0;
                 hint = None;
               })
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
  let targets = read_targets () in
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
  { name; version; targets; deps }

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
    List.iter
      (fun e ->
        if not (List.mem_assoc e.dep roots) then
          errors :=
            Printf.sprintf
              "lockfile pins `%s` but the manifest does not list it — run `emo \
               deps resolve` to regenerate"
              e.dep
            :: !errors)
      t;
    !errors
end

(* The registry and the global content-addressed cache. A directory
   registry serves tests and offline development over the same protocol the
   future HTTPS client will use: <endpoint>/<owner>/<name>/<version>/
   holding the package's manifest (package.emo) and source files. *)
module Registry = struct
  (* A registry endpoint: a filesystem directory, or the standard
     library carried in the compiler binary itself (T25.2) — a lone emo
     binary resolves stdlib packages with nothing beside it. *)
  type t = Fs_dir of string | Embedded

  (* The name the diagnostics show for the endpoint. *)
  let describe = function
    | Fs_dir dir -> dir
    | Embedded -> "the bundled standard library"

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
                            }
                      | exception Manifest_error _ -> None)))
            (versions t ~name) ))
      names

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

(* The .emoji archive: a deterministic gzip-compressed tar. The same file
   set always packs to the same bytes — paths sorted, every metadata field
   zeroed, and the gzip stream carries no timestamp. The deflate payload
   uses stored (uncompressed) blocks: publishing favors a byte-stable,
   dependency-free encoding over compression ratio, and every gzip reader
   accepts stored blocks. *)
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
end

(* Publishing: the client side of the registry's publish protocol.
   [prepare] validates the package rooted at [dir] and builds the .emoji
   archive — the CLI ships the bytes over HTTP. The content digest is the
   Registry digest over the .emo sources; a root README.md rides along but
   is never digested, matching the server. *)
module Publish = struct
  type prepared = {
    p_manifest : manifest;
    p_files : (string * string) list; (* archive members, sorted by path *)
    p_checksum : string;
    p_archive : string; (* the .emoji bytes *)
    p_archive_name : string; (* owner--name--version.emoji *)
  }

  (* The registry's name rule: owner/name, each segment 1–64 chars of
     [a-z0-9_-]. Plain (stdlib-style) names are not publishable. *)
  let valid_name_part (s : string) : bool =
    let ok c =
      (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' || c = '-'
    in
    String.length s >= 1 && String.length s <= 64 && String.for_all ok s

  let validate_name (name : string) : (string * string, string) result =
    match String.split_on_char '/' name with
    | [ owner; short ] when valid_name_part owner && valid_name_part short ->
        Ok (owner, short)
    | _ ->
        Error
          (Printf.sprintf
             "package name `%s` is not publishable: expected owner/name, each \
              part 1-64 lowercase letters, digits, `_` or `-`"
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
                    Printf.sprintf "%s--%s--%s.emoji" owner short version;
                })
end
