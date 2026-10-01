open Emo_support

let tc name f = Alcotest.test_case name `Quick f

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

let () =
  Alcotest.run "emo_pkg"
    [
      ("smoke", smoke_tests);
      ("version", version_tests);
      ("manifest", manifest_tests);
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

let () =
  Alcotest.run "emo_pkg"
    [
      ("smoke", smoke_tests);
      ("version", version_tests);
      ("manifest", manifest_tests);
      ("resolve", resolve_tests);
    ]
