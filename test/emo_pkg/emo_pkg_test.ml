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
  targets = ["native", "wasm"]

  deps {
    json = "2.3.1"
    http = "1.4.2"
  }
}|}
        with
        | Ok m ->
            Alcotest.(check string) "name" "acme/json_tools" m.Emo_pkg.name;
            Alcotest.(check string)
              "version" "0.1.0"
              (Emo_pkg.Version.to_string m.Emo_pkg.version);
            Alcotest.(check int) "targets" 2 (List.length m.Emo_pkg.targets);
            Alcotest.(check int) "deps" 2 (List.length m.Emo_pkg.deps)
        | Error d ->
            Alcotest.fail
              (d.Diagnostic.message ^ " @ " ^ Span.to_string d.Diagnostic.span));
    tc "an empty deps block is allowed" (fun () ->
        match
          check
            {|package {
  name = "acme/json_tools"
  version = "0.1.0"
  targets = ["native"]
  deps {}
}|}
        with
        | Ok m -> Alcotest.(check int) "deps" 0 (List.length m.Emo_pkg.deps)
        | Error _ -> Alcotest.fail "expected success");
    tc "unknown fields are rejected" (fun () ->
        match
          check
            {|package {
  name = "x/y"
  version = "0.1.0"
  targets = ["native"]
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
  targets = ["native"]
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
  targets = ["native"]
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
  targets = ["native"]
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
  targets = ["native"]
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
  targets = ["native"]
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
  ]

let lockfile_tests =
  [
    tc "write then read round-trips" (fun () ->
        let path =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-lock-test.lock"
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
                  R.pv_targets = [ "native" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"native"
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
                  R.pv_targets = [ "native" ];
                  R.pv_deps = [];
                };
                {
                  R.pv_version = v "1.2.0";
                  R.pv_targets = [ "native" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"native"
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
          Emo_pkg.Resolve.solve ~target:"native"
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
                  R.pv_targets = [ "native" ];
                  R.pv_deps = [ ("lib", v "2.0.0") ];
                };
              ] );
            ( "lib",
              [
                {
                  R.pv_version = v "2.0.0";
                  R.pv_targets = [ "native" ];
                  R.pv_deps = [];
                };
              ] );
          ]
        in
        match
          Emo_pkg.Resolve.solve ~target:"native"
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
        ignore (Sys.command ("rm -rf " ^ Filename.quote root));
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
  targets = ["native"]
  deps {}
}|};
        write [ "json_tools.emo" ] {|def parse(s String) String {
  return s
}|};
        let reg = { Emo_pkg.Registry.endpoint = root } in
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
        let reg = { Emo_pkg.Registry.endpoint = root } in
        match
          Emo_pkg.Registry.fetch reg ~name:"json_tools" ~version:(v "9.9.9")
        with
        | Ok _ -> Alcotest.fail "expected a fetch error"
        | Error _ -> ());
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
    ]
