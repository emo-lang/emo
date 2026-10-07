open Emo_support

let tc name f = Alcotest.test_case name `Quick f
let v s = Emo_pkg.Version.parse s |> function Ok v -> v | _ -> assert false

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

module R = Emo_pkg.Resolve

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_pkg in
        ());
  ]

let check source =
  match Emo_pkg.parse_manifest ~file:"package.emo" ~source with
  | m -> Ok m
  | exception Emo_pkg.Manifest_error d -> Error d

let codes_of = function
  | Error d -> ( match d.Diagnostic.code with Some c -> c | None -> "?")
  | Ok _ -> "ok"

let span_of = function
  | Error d -> Span.to_string d.Diagnostic.span
  | Ok _ -> ""

let version_tests =
  [
    tc "versions parse and render" (fun () ->
        match Emo_pkg.Version.parse "2.3.1" with
        | Ok v ->
            Alcotest.(check string)
              "render" "2.3.1"
              (Emo_pkg.Version.to_string v)
        | Error m -> Alcotest.fail m);
    tc "versions reject non-numeric parts" (fun () ->
        match Emo_pkg.Version.parse "2.x" with
        | Ok _ -> Alcotest.fail "expected a version error"
        | Error _ -> ());
  ]

let manifest_tests =
  [
    tc "the README shape parses" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml", "wasm"]

  deps {
    json = "2.3.1"
    http = "1.4.2"
  }
}|}
        with
        | Error d ->
            Alcotest.fail
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok m ->
            Alcotest.(check string) "name" "acme/json_tools" m.Emo_pkg.name;
            Alcotest.(check string)
              "version" "0.1.0"
              (Emo_pkg.Version.to_string m.Emo_pkg.version);
            Alcotest.(check int) "targets" 2 (List.length m.Emo_pkg.targets);
            Alcotest.(check int) "deps" 2 (List.length m.Emo_pkg.deps));
    tc "an empty deps block is allowed" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Ok m -> Alcotest.(check int) "deps" 0 (List.length m.Emo_pkg.deps)
        | Error d ->
            Alcotest.fail
              (match d.Diagnostic.code with Some c -> c | None -> "?"));
    tc "unknown fields are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["ocaml"]
  authors = ["someone"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5100"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5100");
    tc "missing fields are rejected" (fun () ->
        match check {|package {
  name = "x/y"
  targets = ["ocaml"]
}|} with
        | Error d ->
            Alcotest.(check string)
              "code" "E5101"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5101");
    tc "non-literal values are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = version
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "interpolated values are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/${"y"}"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "duplicate fields are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  name = "a/b"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5100"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5100");
    tc "a bad version is an error" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1"
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "an unknown target is an error" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["jvm"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "runaway evaluation hits the step budget" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}

def loop() Int64 { return loop() }
loop()|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5200"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5200");
  ]

let lockfile_tests =
  [
    tc "write then read round-trips" (fun () ->
        let path =
          Filename.concat
            (Filename.get_temp_dir_name ())
            "package-lock-test.lock"
        in
        let entries =
          [
            {
              Emo_pkg.Lockfile.dep = "json";
              version = v "2.3.1";
              checksum = "abc";
            };
            {
              Emo_pkg.Lockfile.dep = "http";
              version = v "1.4.2";
              checksum = "def";
            };
          ]
        in
        Emo_pkg.Lockfile.write ~path entries;
        match Emo_pkg.Lockfile.read path with
        | Ok read_back ->
            Alcotest.(check int) "count" 2 (List.length read_back);
            Alcotest.(check bool)
              "sorted" true
              (match read_back with
              | e :: _ -> String.equal e.Emo_pkg.Lockfile.dep "http"
              | [] -> false)
        | Error m -> Alcotest.fail m);
    tc "verify flags a version mismatch" (fun () ->
        let t =
          [
            {
              Emo_pkg.Lockfile.dep = "json";
              version = v "1.0.0";
              checksum = "x";
            };
          ]
        in
        let errors = Emo_pkg.Lockfile.verify ~roots:[ ("json", v "2.3.1") ] t in
        Alcotest.(check bool)
          "mismatch reported" true
          (List.length errors > 0
          && contains_substring (List.hd errors) "regenerate"));
    tc "verify accepts a matching lockfile" (fun () ->
        let t =
          [
            {
              Emo_pkg.Lockfile.dep = "json";
              version = v "2.3.1";
              checksum = "x";
            };
          ]
        in
        Alcotest.(check int)
          "clean" 0
          (List.length
             (Emo_pkg.Lockfile.verify ~roots:[ ("json", v "2.3.1") ] t)));
  ]

let resolve_tests =
  [
    tc "a single root resolves" (fun () ->
        let index =
          [
            ( "json",
              [
                {
                  R.pv_version =
                    ( Emo_pkg.Version.parse "2.3.1" |> function
                      | Ok v -> v
                      | _ -> assert false );
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"ocaml"
            ~roots:
              [
                ( "json",
                  Emo_pkg.Version.parse "2.3.1" |> function
                  | Ok v -> v
                  | _ -> assert false );
              ]
            ~index
        with
        | Ok r ->
            Alcotest.(check int)
              "resolved" 1
              (List.length r.Emo_pkg.Resolve.resolved)
        | Error es ->
            Alcotest.fail
              (String.concat ";"
                 (List.map (fun e -> e.Emo_pkg.Resolve.e_dep) es)));
    tc "the highest exact pin wins across consumers" (fun () ->
        let v s =
          Emo_pkg.Version.parse s |> function Ok v -> v | _ -> assert false
        in
        let index =
          [
            ( "shared",
              [
                {
                  R.pv_version = v "1.0.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                };
                {
                  R.pv_version = v "1.2.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"ocaml"
            ~roots:[ ("shared", v "1.0.0"); ("shared", v "1.2.0") ]
            ~index
        with
        | Ok r -> (
            match List.assoc_opt "shared" r.Emo_pkg.Resolve.resolved with
            | Some version ->
                Alcotest.(check string)
                  "highest wins" "1.2.0"
                  (Emo_pkg.Version.to_string version)
            | None -> Alcotest.fail "shared not resolved")
        | Error es -> Alcotest.fail "expected resolution");
    tc "a dep without the current target fails resolution" (fun () ->
        let v s =
          Emo_pkg.Version.parse s |> function Ok v -> v | _ -> assert false
        in
        let index =
          [
            ( "web",
              [
                {
                  R.pv_version = v "3.0.0";
                  R.pv_targets = [ "wasm" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"ocaml"
            ~roots:[ ("web", v "3.0.0") ]
            ~index
        with
        | Ok _ -> Alcotest.fail "expected a target failure"
        | Error es -> (
            match es with
            | [ e ] ->
                Alcotest.(check string) "dep" "web" e.Emo_pkg.Resolve.e_dep
            | _ -> Alcotest.fail "expected one error"));
    tc "transitive pins resolve" (fun () ->
        let v s =
          Emo_pkg.Version.parse s |> function Ok v -> v | _ -> assert false
        in
        let index =
          [
            ( "app",
              [
                {
                  R.pv_version = v "1.0.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [ ("lib", v "2.0.0") ];
                };
              ] );
            ( "lib",
              [
                {
                  R.pv_version = v "2.0.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"ocaml"
            ~roots:[ ("app", v "1.0.0") ]
            ~index
        with
        | Ok r ->
            Alcotest.(check bool)
              "lib resolved" true
              (List.mem_assoc "lib" r.Emo_pkg.Resolve.resolved)
        | Error _ -> Alcotest.fail "expected resolution");
  ]

let registry_tests =
  [
    tc "a directory registry fetches package sources" (fun () ->
        let root =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-reg-test"
        in
        let pkg_dir =
          Filename.concat root
            (Filename.concat "acme" (Filename.concat "json_tools" "2.3.1"))
        in
        ignore (Sys.command ("mkdir -p " ^ Filename.quote pkg_dir));
        let write rel content =
          let oc =
            open_out_bin (Filename.concat pkg_dir (String.concat "/" rel))
          in
          output_string oc content;
          close_out oc
        in
        write [ "package.emo" ]
          {|package {
  name = "acme/json_tools"
  version = "2.3.1"
  targets = ["ocaml"]
  deps {}
}|};
        write [ "json_tools.emo" ] {|def parse(s String) String {
  return s
}|};
        let reg = Emo_pkg.Registry.Fs_dir root in
        match
          Emo_pkg.Registry.fetch reg ~name:"acme/json_tools"
            ~version:(v "2.3.1")
        with
        | Ok fetched -> (
            Alcotest.(check int)
              "files" 2
              (List.length fetched.Emo_pkg.Registry.f_files);
            (* cache materialization verifies the checksum *)
            match
              Emo_pkg.Registry.materialize
                ~cache_dir:
                  (Filename.concat
                     (Filename.get_temp_dir_name ())
                     "emo-reg-cache")
                fetched
            with
            | Ok dir ->
                Alcotest.(check bool)
                  "manifest cached" true
                  (Sys.file_exists (Filename.concat dir "package.emo"))
            | Error m -> Alcotest.fail m)
        | Error m -> Alcotest.fail m);
    tc "a missing package version errors" (fun () ->
        let root =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-reg-test"
        in
        let reg = Emo_pkg.Registry.Fs_dir root in
        match
          Emo_pkg.Registry.fetch reg ~name:"json_tools" ~version:(v "9.9.9")
        with
        | Ok _ -> Alcotest.fail "expected a fetch error"
        | Error _ -> ());
  ]

let digest_tests =
  [
    tc "the digest is SHA-256 over sorted path\\0content\\0 pairs" (fun () ->
        (* Cross-checked with the registry service's reference construction:
           sha256("a.emo\x00first\x00b.emo\x00second\x00"). *)
        let d =
          Emo_pkg.Registry.digest [ ("b.emo", "second"); ("a.emo", "first") ]
        in
        Alcotest.(check string)
          "matches the registry"
          "a530354d1082c1dd90e11ee82c378bf98aa051b55f4c061416c9cf39b1d1c55e" d);
    tc "the digest is 64 lowercase hex chars" (fun () ->
        let d = Emo_pkg.Registry.digest [ ("x.emo", "x") ] in
        Alcotest.(check int) "length" 64 (String.length d);
        Alcotest.(check bool)
          "hex" true
          (String.for_all
             (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
             d));
  ]

let run_capture cmd =
  let ic = Unix.open_process_in cmd in
  let out = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel out ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (Buffer.contents out, status)

let archive_files =
  [
    ("package.emo", "package {\n  name = \"acme/hello\"\n}\n");
    ("hello.emo", "def greet() String {\n  return \"hi\"\n}\n");
    ("internal/util.emo", "def twice(n Int64) Int64 {\n  return n * 2\n}\n");
    ("README.md", "# hello\n");
  ]

let archive_tests =
  [
    tc "crc32 matches the check value" (fun () ->
        Alcotest.(check int32)
          "crc32(123456789)" 0xCBF43926l
          (Emo_pkg.Archive.crc32 "123456789"));
    tc "packing is deterministic" (fun () ->
        let a = Emo_pkg.Archive.build archive_files in
        let b =
          Emo_pkg.Archive.build
            (List.map (fun (p, c) -> (p, c ^ "")) archive_files)
        in
        Alcotest.(check string) "same bytes" a b);
    tc "the gzip stream decodes to the tar stream" (fun () ->
        let archive = Emo_pkg.Archive.build archive_files in
        let tmp = Filename.temp_file "emo-archive-" ".emoji" in
        let oc = open_out_bin tmp in
        output_string oc archive;
        close_out oc;
        let decoded, status =
          run_capture (Printf.sprintf "gzip -dc %s" (Filename.quote tmp))
        in
        Alcotest.(check bool) "gzip decodes" true (status = Unix.WEXITED 0);
        Alcotest.(check string)
          "payload is the tar"
          (Emo_pkg.Archive.tar archive_files)
          decoded);
    tc "system tar lists every member" (fun () ->
        let archive = Emo_pkg.Archive.build archive_files in
        let tmp = Filename.temp_file "emo-archive-" ".emoji" in
        let oc = open_out_bin tmp in
        output_string oc archive;
        close_out oc;
        let listing, status =
          run_capture (Printf.sprintf "tar tzf %s" (Filename.quote tmp))
        in
        Alcotest.(check bool) "tar reads it" true (status = Unix.WEXITED 0);
        let expect =
          archive_files |> List.map fst |> List.sort String.compare
          |> String.concat "\n"
        in
        Alcotest.(check string) "members" (expect ^ "\n") listing);
    tc "long paths split across the ustar prefix field" (fun () ->
        let dir =
          String.concat "/"
            (List.init 10 (fun i -> Printf.sprintf "directory_%02d" i))
        in
        let path = dir ^ "/mod.emo" in
        Alcotest.(check bool) "long" true (String.length path > 100);
        let archive = Emo_pkg.Archive.build [ (path, "x") ] in
        let tmp = Filename.temp_file "emo-archive-" ".emoji" in
        let oc = open_out_bin tmp in
        output_string oc archive;
        close_out oc;
        let listing, status =
          run_capture (Printf.sprintf "tar tzf %s" (Filename.quote tmp))
        in
        Alcotest.(check bool) "tar reads it" true (status = Unix.WEXITED 0);
        Alcotest.(check string) "path round-trips" (path ^ "\n") listing);
  ]

let publish_tests =
  [
    tc "prepare packs sources, the manifest and a root README" (fun () ->
        let dir =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-publish-test"
        in
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
        let write rel content =
          let oc = open_out_bin (Filename.concat dir rel) in
          output_string oc content;
          close_out oc
        in
        write "package.emo"
          {|package {
  name = "acme/hello"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|};
        write "hello.emo" {|def greet() String {
  return "hi"
}|};
        write "README.md" "# hello\n";
        match Emo_pkg.Publish.prepare ~dir with
        | Error m -> Alcotest.fail m
        | Ok p ->
            Alcotest.(check string)
              "archive name" "acme--hello--0.1.0.emoji"
              p.Emo_pkg.Publish.p_archive_name;
            Alcotest.(check int) "files" 3 (List.length p.p_files);
            (* the README rides along but never feeds the digest *)
            Alcotest.(check string)
              "digest ignores the README"
              (Emo_pkg.Registry.digest (Emo_pkg.Registry.collect_files dir))
              p.p_checksum;
            Alcotest.(check bool)
              "archive is gzip" true
              (String.length p.p_archive > 2
              && String.sub p.p_archive 0 2 = "\x1f\x8b"));
    tc "a plain (unscoped) name is not publishable" (fun () ->
        let dir =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-publish-badname"
        in
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
        let oc = open_out_bin (Filename.concat dir "package.emo") in
        output_string oc
          {|package {
  name = "hello"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|};
        close_out oc;
        match Emo_pkg.Publish.prepare ~dir with
        | Ok _ -> Alcotest.fail "expected a name error"
        | Error m ->
            Alcotest.(check bool)
              "mentions owner/name" true
              (contains_substring m "owner/name"));
    tc "a directory without a manifest fails" (fun () ->
        match Emo_pkg.Publish.prepare ~dir:(Filename.get_temp_dir_name ()) with
        | Ok _ -> Alcotest.fail "expected a manifest error"
        | Error _ -> ());
  ]

(* T25.2: the standard library rides the compiler binary as generated
   data — the embedded registry must match the filesystem one it was
   generated from, or a published stdlib and the binary drift apart. *)
let original_cwd = Sys.getcwd ()

let from_original_cwd dir =
  if Filename.is_relative dir then Filename.concat original_cwd dir else dir

let embedded_stdlib_tests =
  [
    tc "the embedded stdlib matches the filesystem registry" (fun () ->
        let root = from_original_cwd "../../stdlib/registry" in
        let embedded = Emo_pkg.Registry.Embedded in
        let fs = Emo_pkg.Registry.Fs_dir root in
        let compare_registry name =
          let v_of = List.map Emo_pkg.Version.to_string in
          Alcotest.(check (list string))
            ("versions of " ^ name)
            (v_of (Emo_pkg.Registry.versions fs ~name))
            (v_of (Emo_pkg.Registry.versions embedded ~name));
          List.iter
            (fun v ->
              match
                ( Emo_pkg.Registry.fetch fs ~name ~version:v,
                  Emo_pkg.Registry.fetch embedded ~name ~version:v )
              with
              | Ok a, Ok b ->
                  Alcotest.(check string)
                    (Printf.sprintf "checksum of %s@%s" name
                       (Emo_pkg.Version.to_string v))
                    a.Emo_pkg.Registry.f_checksum b.Emo_pkg.Registry.f_checksum
              | _ -> Alcotest.fail (Printf.sprintf "fetch failed for %s" name))
            (Emo_pkg.Registry.versions embedded ~name)
        in
        List.iter compare_registry [ "file"; "http"; "net" ];
        (* the embedded endpoint serves a stdlib-importing project with
           no filesystem registry at all *)
        match
          Emo_pkg.Registry.fetch embedded ~name:"http"
            ~version:
              (match Emo_pkg.Version.parse "0.1.0" with
              | Ok v -> v
              | Error _ -> Alcotest.fail "bad version")
        with
        | Ok f ->
            Alcotest.(check bool)
              "manifest rides along" true
              (List.exists
                 (fun (p, _) -> Filename.basename p = "package.emo")
                 f.Emo_pkg.Registry.f_files)
        | Error m -> Alcotest.fail m);
  ]

let () =
  Alcotest.run "emo_pkg"
    [
      ("smoke", smoke_tests);
      ("version", version_tests);
      ("manifest", manifest_tests);
      ("resolve", resolve_tests);
      ("lockfile", lockfile_tests);
      ("registry", registry_tests);
      ("digest", digest_tests);
      ("archive", archive_tests);
      ("publish", publish_tests);
      ("embedded_stdlib", embedded_stdlib_tests);
    ]
