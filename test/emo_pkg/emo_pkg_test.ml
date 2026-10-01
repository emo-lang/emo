open Emo_support

let tc name f = Alcotest.test_case name `Quick f

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
