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
    "json" = "2.3.1"
    "http" = "1.4.2"
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
    tc "a dependency's name is a string literal" (fun () ->
        match
          check
            {|package {
  name = "emo/ui_golden"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    "emo/ui" = "0.1.0"
    "json" = "2.3.1"
  }
}|}
        with
        | Error d -> Alcotest.fail (codes_of (Error d))
        | Ok m -> (
            match m.Emo_pkg.deps with
            | [ (first, _); (second, _) ] ->
                Alcotest.(check string) "scoped dep" "emo/ui" first;
                Alcotest.(check string) "bare dep" "json" second
            | ds ->
                Alcotest.fail
                  (Printf.sprintf "expected 2 deps, got %d" (List.length ds))));
    tc "the identifier key form is refused" (fun () ->
        match
          check
            {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    json = "2.3.1"
  }
}|}
        with
        | Ok _ -> Alcotest.fail "expected the key to be refused"
        | Error d ->
            Alcotest.(check string) "code" "E5102" (codes_of (Error d));
            Alcotest.(check (option string))
              "the hint names the string form"
              (Some
                 {|write a dependency's name as a string: "acme/json_tools" = "1.2.3"|})
              d.Diagnostic.hint);
    tc "the old scoped key is refused" (fun () ->
        match
          check
            {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    acme/json_tools = "2.3.1"
  }
}|}
        with
        | Ok _ -> Alcotest.fail "expected the key to be refused"
        | Error d -> Alcotest.(check string) "code" "E2015" (codes_of (Error d)));
    tc "an empty dependency name is refused" (fun () ->
        match
          check
            {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    "" = "2.3.1"
  }
}|}
        with
        | Ok _ -> Alcotest.fail "expected the name to be refused"
        | Error d ->
            Alcotest.(check string) "code" "E5102" (codes_of (Error d));
            Alcotest.(check string)
              "the message names the empty name" "a dependency's name is empty"
              d.Diagnostic.message);
    tc "a stray statement in deps is refused" (fun () ->
        match
          check
            {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    println("json")
  }
}|}
        with
        | Ok _ -> Alcotest.fail "expected the statement to be refused"
        | Error d -> Alcotest.(check string) "code" "E5104" (codes_of (Error d)));
    tc "a package field keyed by a string is refused" (fun () ->
        match
          check
            {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]
  "link" = ["sqlite3"]

  deps {}
}|}
        with
        | Ok _ -> Alcotest.fail "expected the field to be refused"
        | Error d -> Alcotest.(check string) "code" "E5102" (codes_of (Error d)));
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
    tc "link libraries parse" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["c"]
  link = ["sqlite3"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.fail
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok m ->
            Alcotest.(check (list string)) "link" [ "sqlite3" ] m.Emo_pkg.link);
    tc "link defaults to empty" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["c"]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.fail
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok m -> Alcotest.(check (list string)) "link" [] m.Emo_pkg.link);
    tc "a non-array link is rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["c"]
  link = "sqlite3"
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "non-string link entries are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["c"]
  link = [3]
  deps {}
}|}
        with
        | Error d ->
            Alcotest.(check string)
              "code" "E5103"
              (match d.Diagnostic.code with Some c -> c | None -> "?")
        | Ok _ -> Alcotest.fail "expected E5103");
    tc "flag-shaped link entries are rejected" (fun () ->
        List.iter
          (fun bad ->
            match
              check
                (Printf.sprintf
                   {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["c"]
  link = ["%s"]
  deps {}
}|}
                   bad)
            with
            | Error d ->
                Alcotest.(check string)
                  "code" "E5103"
                  (match d.Diagnostic.code with Some c -> c | None -> "?")
            | Ok _ -> Alcotest.fail ("expected E5103 for " ^ bad))
          [ "-lsqlite3"; "/usr/lib/libsqlite3.dylib"; "" ]);
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
    tc "an optional registry URL parses" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml"]
  registry = "https://packages.example.com"
  deps {}
}|}
        with
        | Error d -> Alcotest.fail (codes_of (Error d))
        | Ok m ->
            Alcotest.(check (option string))
              "registry" (Some "https://packages.example.com")
              m.Emo_pkg.registry);
    tc "the registry field defaults to none" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|}
        with
        | Error d -> Alcotest.fail (codes_of (Error d))
        | Ok m ->
            Alcotest.(check (option string)) "none" None m.Emo_pkg.registry);
    tc "the registry field is a URL, not a filesystem path" (fun () ->
        (* A committed manifest must name an endpoint every machine reaches
           the same way; filesystem registries stay an EMO_REGISTRY affair. *)
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml"]
  registry = "/srv/registry"
  deps {}
}|}
        with
        | Ok _ -> Alcotest.fail "expected the path to be refused"
        | Error d ->
            Alcotest.(check string) "code" "E5103" (codes_of (Error d));
            Alcotest.(check bool)
              "points at EMO_REGISTRY" true
              (match d.Diagnostic.hint with
              | Some h -> contains_substring h "EMO_REGISTRY"
              | None -> false));
    tc "the registry field rejects non-strings" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["ocaml"]
  registry = 42
  deps {}
}|}
        with
        | Ok _ -> Alcotest.fail "expected a type error"
        | Error d -> Alcotest.(check string) "code" "E5103" (codes_of (Error d)));
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
                  R.pv_checksum = "";
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
                  R.pv_checksum = "";
                };
                {
                  R.pv_version = v "1.2.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                  R.pv_checksum = "";
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
                  R.pv_checksum = "";
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
                  R.pv_checksum = "";
                };
              ] );
            ( "lib",
              [
                {
                  R.pv_version = v "2.0.0";
                  R.pv_targets = [ "ocaml" ];
                  R.pv_deps = [];
                  R.pv_checksum = "";
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
  let out, err, status = Emo_test_support.run_cmd cmd in
  (out ^ err, status)

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
    tc "unpack is the inverse of build" (fun () ->
        let archive = Emo_pkg.Archive.build archive_files in
        match Emo_pkg.Archive.unpack archive with
        | Error m -> Alcotest.fail m
        | Ok files ->
            Alcotest.(check (list (pair string string)))
              "round-trip"
              (List.sort
                 (fun (a, _) (b, _) -> String.compare a b)
                 archive_files)
              (List.sort (fun (a, _) (b, _) -> String.compare a b) files));
    tc "unpack rejects a truncated archive" (fun () ->
        let archive = Emo_pkg.Archive.build archive_files in
        let short = String.sub archive 0 (String.length archive - 40) in
        match Emo_pkg.Archive.unpack short with
        | Ok _ -> Alcotest.fail "expected a truncation error"
        | Error m ->
            Alcotest.(check bool)
              "names the truncation" true
              (contains_substring m "truncated"));
    tc "unpack rejects a corrupted CRC" (fun () ->
        (* One payload byte flipped; the gzip trailer must catch it. *)
        let archive = Bytes.of_string (Emo_pkg.Archive.build archive_files) in
        Bytes.set archive 20 'x';
        match Emo_pkg.Archive.unpack (Bytes.to_string archive) with
        | Ok _ -> Alcotest.fail "expected a CRC error"
        | Error m ->
            Alcotest.(check bool)
              "names the CRC" true
              (contains_substring m "CRC"));
    tc "unpack decodes a system-gzip member" (fun () ->
        (* The registry service re-packs uploads with a real compressor, so
           the decoder must handle dynamic-Huffman deflate streams, not just
           this encoder's stored blocks. *)
        let tmp = Filename.temp_file "emo-tar-" ".tar" in
        let oc = open_out_bin tmp in
        output_string oc (Emo_pkg.Archive.tar archive_files);
        close_out oc;
        let gzipped, status =
          run_capture (Printf.sprintf "gzip -9 -c %s" (Filename.quote tmp))
        in
        Alcotest.(check bool) "gzip ran" true (status = Unix.WEXITED 0);
        match Emo_pkg.Archive.unpack gzipped with
        | Error m -> Alcotest.fail m
        | Ok files ->
            Alcotest.(check (list (pair string string)))
              "same members"
              (List.sort
                 (fun (a, _) (b, _) -> String.compare a b)
                 archive_files)
              (List.sort (fun (a, _) (b, _) -> String.compare a b) files));
    tc "unpack rejects a reserved deflate block type" (fun () ->
        let reserved =
          "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff" ^ "\x07\x00"
          ^ "\x00\x00\x00\x00\x00\x00\x00\x00"
        in
        match Emo_pkg.Archive.unpack reserved with
        | Ok _ -> Alcotest.fail "expected a deflate block-type error"
        | Error m ->
            Alcotest.(check bool)
              "names the block type" true
              (contains_substring m "reserved block type"));
    tc "unpack rejects a corrupted tar header" (fun () ->
        (* Corrupt the tar stream, then wrap it in a fresh gzip member so
           the gzip layer stays consistent and the header checksum is what
           fails. *)
        let tar = Bytes.of_string (Emo_pkg.Archive.tar archive_files) in
        Bytes.set tar 1 'Z';
        let archive = Emo_pkg.Archive.gzip (Bytes.to_string tar) in
        match Emo_pkg.Archive.unpack archive with
        | Ok _ -> Alcotest.fail "expected a tar header error"
        | Error m ->
            Alcotest.(check bool)
              "names the header" true
              (contains_substring m "tar header: checksum mismatch"));
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

(* T24.2: the standard library rides the compiler binary as generated
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

(* The HTTP pull client (Protocol B): the runner is faked — it maps the
   request's URL (a host-injected global) to the embedded program's printed
   output, so no socket is involved. The wire format itself is exercised by
   the captive-server tests in emo_cli. *)
let fake_runner ~(routes : (string * (int * string)) list) :
    Emo_pkg.Http_registry.runner =
 fun ~program:_ ~globals ->
  let url =
    match List.assoc_opt "__url" globals with
    | Some (Emo_eval.String u) -> u
    | _ -> ""
  in
  match
    List.find_opt
      (fun (suffix, _) ->
        let n = String.length suffix in
        String.length url >= n
        && String.sub url (String.length url - n) n = suffix)
      routes
  with
  | Some (_, (status, body)) -> Ok (Printf.sprintf "%d\n%s" status body)
  | None -> Error ("no canned response for " ^ url)

let http_pkg_files =
  [
    ( "package.emo",
      "package {\n\
      \  name = \"acme/p\"\n\
      \  version = \"1.0.0\"\n\
      \  targets = [\"c\"]\n\
      \  deps {}\n\
       }\n" );
    ("p.emo", "def one() Int64 {\n  return 1\n}\n");
  ]

let http_registry_tests =
  let base = "http://pkgs.test" in
  [
    tc "versions parses a B.1 payload" (fun () ->
        let runner =
          fake_runner
            ~routes:
              [
                ( "/api/v1/packages/acme/p/versions",
                  (200, "1.0.0\taaa\tocaml,c\tfalse\n2.0.0\tbbb\tc\ttrue\n") );
              ]
        in
        match
          Emo_pkg.Http_registry.versions runner ~base ~token:None ~name:"acme/p"
        with
        | Error m -> Alcotest.fail m
        | Ok [ a; b ] ->
            Alcotest.(check string)
              "first" "1.0.0"
              (Emo_pkg.Version.to_string a.Emo_pkg.Http_registry.vi_version);
            Alcotest.(check string) "checksum" "aaa" a.vi_checksum;
            Alcotest.(check (list string))
              "targets" [ "ocaml"; "c" ] a.vi_targets;
            Alcotest.(check bool) "not yanked" false a.vi_yanked;
            Alcotest.(check bool) "yanked" true b.vi_yanked
        | Ok vs ->
            Alcotest.fail
              (Printf.sprintf "expected 2 versions, got %d" (List.length vs)));
    tc "versions maps a 404 to a missing package" (fun () ->
        let runner =
          fake_runner
            ~routes:
              [
                ( "/api/v1/packages/acme/missing/versions",
                  (404, {|{"error":{"code":"package_not_found"}}|}) );
              ]
        in
        match
          Emo_pkg.Http_registry.versions runner ~base ~token:None
            ~name:"acme/missing"
        with
        | Ok _ -> Alcotest.fail "expected a 404 error"
        | Error m ->
            Alcotest.(check bool)
              "names the package" true
              (contains_substring m "has no package `acme/missing`"));
    tc "an unscoped name is refused before any request" (fun () ->
        let runner = fake_runner ~routes:[] in
        match
          Emo_pkg.Http_registry.versions runner ~base ~token:None ~name:"json"
        with
        | Ok _ -> Alcotest.fail "expected a scoping error"
        | Error m ->
            Alcotest.(check bool)
              "names the scope rule" true
              (contains_substring m "scoped (owner/name)"));
    tc "index joins B.1 with B.2 and drops yanked versions" (fun () ->
        let runner =
          fake_runner
            ~routes:
              [
                ( "/api/v1/packages/acme/p/versions",
                  (200, "1.0.0\tsum1\tc\tfalse\n0.9.0\tsum0\tc\ttrue\n") );
                ( "/api/v1/dependencies?packages=acme/p",
                  ( 200,
                    "acme/p\t1.0.0\tjson=2.3.1,net=0.1.0\tfalse\n\
                     acme/p\t0.9.0\t\ttrue\n" ) );
              ]
        in
        match
          Emo_pkg.Http_registry.index runner ~base ~token:None [ "acme/p" ]
        with
        | Error m -> Alcotest.fail m
        | Ok [ ("acme/p", [ pv ]) ] ->
            Alcotest.(check string)
              "only the live version" "1.0.0"
              (Emo_pkg.Version.to_string pv.Emo_pkg.Resolve.pv_version);
            Alcotest.(check string) "checksum" "sum1" pv.pv_checksum;
            Alcotest.(check (list string))
              "deps" [ "json"; "net" ] (List.map fst pv.pv_deps)
        | Ok idx ->
            Alcotest.fail
              (Printf.sprintf "expected one package, got %d" (List.length idx)));
    tc "index refuses metadata skew between B.1 and B.2" (fun () ->
        let runner =
          fake_runner
            ~routes:
              [
                ( "/api/v1/packages/acme/p/versions",
                  (200, "1.0.0\tsum1\tc\tfalse\n") );
                ("/api/v1/dependencies?packages=acme/p", (200, ""));
              ]
        in
        match
          Emo_pkg.Http_registry.index runner ~base ~token:None [ "acme/p" ]
        with
        | Ok _ -> Alcotest.fail "expected an inconsistency error"
        | Error m ->
            Alcotest.(check bool)
              "says to retry" true
              (contains_substring m "inconsistent"));
    tc "fetch downloads, unpacks and pins the digest" (fun () ->
        let archive = Emo_pkg.Archive.build http_pkg_files in
        let checksum = Emo_pkg.Registry.digest http_pkg_files in
        let runner =
          fake_runner
            ~routes:[ ("/downloads/acme--p--1.0.0.emoji", (200, archive)) ]
        in
        match
          Emo_pkg.Http_registry.fetch runner ~base ~token:None
            ~expected_checksum:(Some checksum) ~name:"acme/p"
            ~version:(v "1.0.0")
        with
        | Error m -> Alcotest.fail m
        | Ok f ->
            Alcotest.(check string)
              "checksum" checksum f.Emo_pkg.Registry.f_checksum;
            Alcotest.(check int)
              "files" 2
              (List.length f.Emo_pkg.Registry.f_files));
    tc "fetch drops a README from the digest but a corrupt archive fails"
      (fun () ->
        let with_readme = http_pkg_files @ [ ("README.md", "# p\n") ] in
        let archive = Emo_pkg.Archive.build with_readme in
        let checksum = Emo_pkg.Registry.digest http_pkg_files in
        let runner =
          fake_runner
            ~routes:[ ("/downloads/acme--p--1.0.0.emoji", (200, archive)) ]
        in
        (match
           Emo_pkg.Http_registry.fetch runner ~base ~token:None
             ~expected_checksum:(Some checksum) ~name:"acme/p"
             ~version:(v "1.0.0")
         with
        | Error m -> Alcotest.fail m
        | Ok f ->
            Alcotest.(check int)
              "the README is not package content" 2
              (List.length f.Emo_pkg.Registry.f_files));
        let corrupt = Bytes.of_string archive in
        Bytes.set corrupt 20 'x';
        let bad_runner =
          fake_runner
            ~routes:
              [
                ( "/downloads/acme--p--1.0.0.emoji",
                  (200, Bytes.to_string corrupt) );
              ]
        in
        match
          Emo_pkg.Http_registry.fetch bad_runner ~base ~token:None
            ~expected_checksum:(Some checksum) ~name:"acme/p"
            ~version:(v "1.0.0")
        with
        | Ok _ -> Alcotest.fail "expected the corruption to surface"
        | Error m ->
            Alcotest.(check bool)
              "the gzip CRC catches it" true
              (contains_substring m "CRC"));
    tc "fetch rejects content that does not match the advertised digest"
      (fun () ->
        let archive = Emo_pkg.Archive.build http_pkg_files in
        let runner =
          fake_runner
            ~routes:[ ("/downloads/acme--p--1.0.0.emoji", (200, archive)) ]
        in
        match
          Emo_pkg.Http_registry.fetch runner ~base ~token:None
            ~expected_checksum:(Some (String.make 64 '0'))
            ~name:"acme/p" ~version:(v "1.0.0")
        with
        | Ok _ -> Alcotest.fail "expected a checksum mismatch"
        | Error m ->
            Alcotest.(check bool)
              "names the mismatch" true
              (contains_substring m "checksum mismatch"));
    tc "parse_exchange strips exactly the framing newline" (fun () ->
        (* A body that itself ends in a newline keeps it — only println's
           framing newline is stripped. *)
        match Emo_pkg.Http_registry.parse_exchange "200\npayload-bytes\n\n" with
        | Error m -> Alcotest.fail m
        | Ok (status, body) ->
            Alcotest.(check int) "status" 200 status;
            Alcotest.(check string)
              "body keeps its own newline" "payload-bytes\n" body);
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
      ("http_registry", http_registry_tests);
    ]
