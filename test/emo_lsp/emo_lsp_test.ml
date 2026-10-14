(* Unit tests for the language server's position mapping, URI handling,
   and declaration index. *)

open Emo_lsp

let tc name f = Alcotest.test_case name `Quick f

(* ---- Positions ------------------------------------------------------ *)

let test_ascii_positions () =
  let text = "def add(a Int64) Int64 {\n  return a + 1\n}\n" in
  let starts = Lsp_util.line_starts text in
  Alcotest.(check (pair int int))
    "line 0 col 0" (0, 0)
    (Lsp_util.offset_to_position text starts 0);
  Alcotest.(check (pair int int))
    "after def" (0, 3)
    (Lsp_util.offset_to_position text starts 3);
  Alcotest.(check (pair int int))
    "line 1 start" (1, 0)
    (Lsp_util.offset_to_position text starts 25);
  Alcotest.(check (pair int int))
    "line 1 return" (1, 2)
    (Lsp_util.offset_to_position text starts 27)

let test_utf16_positions () =
  (* The six Chinese characters are 3 bytes each in UTF-8 and one UTF-16
     code unit each; the emoji is 4 bytes and two UTF-16 code units. *)
  let text = "你好世界\nemoji 🚀 end" in
  let starts = Lsp_util.line_starts text in
  (* '你' + '好' = 6 bytes => 2 UTF-16 units. *)
  Alcotest.(check (pair int int))
    "two CJK" (0, 2)
    (Lsp_util.offset_to_position text starts 6);
  (* 12 bytes => 4 units. *)
  Alcotest.(check (pair int int))
    "four CJK" (0, 4)
    (Lsp_util.offset_to_position text starts 12);
  (* "emoji " is 6 bytes, then the emoji is 4 bytes => 6 + 2 = 8 units. *)
  Alcotest.(check (pair int int))
    "after emoji" (1, 8)
    (Lsp_util.offset_to_position text starts (String.length "你好世界\nemoji 🚀"))

let test_position_roundtrip () =
  let text = "const 名字 = \"值\"\nprintln(名字)\n" in
  let starts = Lsp_util.line_starts text in
  let check_offset off =
    let line, ch = Lsp_util.offset_to_position text starts off in
    let back = Lsp_util.position_to_offset text starts ~line ~character:ch in
    Alcotest.(check int) (Printf.sprintf "roundtrip at %d" off) off back
  in
  List.iter check_offset [ 0; 5; 6; 9; 15; 16; 19; 20; 28; String.length text ]

let test_position_clamped () =
  let text = "abc\ndef" in
  let starts = Lsp_util.line_starts text in
  Alcotest.(check int)
    "past end of line clamps" 3
    (Lsp_util.position_to_offset text starts ~line:0 ~character:99);
  Alcotest.(check int)
    "past last line clamps" (String.length text)
    (Lsp_util.position_to_offset text starts ~line:99 ~character:0)

(* ---- URIs ----------------------------------------------------------- *)

let test_uri_roundtrip () =
  let paths =
    [
      "/Users/daqing/project/main.emo";
      "/tmp/a b/c+d/main.emo";
      "/tmp/unicode/文件.emo";
    ]
  in
  List.iter
    (fun p ->
      match Lsp_util.uri_to_path (Lsp_util.path_to_uri p) with
      | Some back -> Alcotest.(check string) "roundtrip" p back
      | None -> Alcotest.failf "uri parsed to None for %s" p)
    paths

(* ---- Declaration index ---------------------------------------------- *)

let source =
  {|class User {
  def init(name String) {
    self.name = name
  }

  def greet() String {
    return "hi"
  }
}

emo Math {
  const tau = 6
  def abs(x Int64) Int64 {
    return x
  }
}

enum Color { red, green }
|}

let symbols_of source =
  match Emo_parser.parse_program_with_diagnostics ~file:"test.emo" ~source with
  | items, [] -> Lsp_index.collect_items ~file:"test.emo" ~module_path:[] items
  | _, diagnostics ->
      Alcotest.failf "parse failed: %d diagnostics" (List.length diagnostics)

let test_index_symbols () =
  let symbols = symbols_of source in
  let names =
    List.map (fun (s : Lsp_index.symbol) -> s.Lsp_index.name) symbols
  in
  let has name = List.mem name names in
  Alcotest.(check bool) "class User" true (has "User");
  Alcotest.(check bool) "method greet" true (has "greet");
  Alcotest.(check bool) "field name" true (has "name");
  Alcotest.(check bool) "group Math" true (has "Math");
  Alcotest.(check bool) "const tau" true (has "tau");
  Alcotest.(check bool) "def abs" true (has "abs");
  Alcotest.(check bool) "enum Color" true (has "Color");
  Alcotest.(check bool) "member Color.red" true (has "Color.red")

let test_locals_not_members () =
  match Emo_parser.parse_program_with_diagnostics ~file:"test.emo" ~source with
  | _, _ :: _ -> Alcotest.fail "parse failed"
  | items, [] ->
      let locals =
        Lsp_index.collect_locals ~file:"test.emo" ~module_path:[] items
      in
      let params =
        List.filter (fun (s : Lsp_index.symbol) -> s.Lsp_index.local) locals
      in
      Alcotest.(check bool) "a local was collected" true (params <> []);
      (* Parameters and bindings must stay out of member completion, so
         their container is always None. *)
      Alcotest.(check bool)
        "locals have no container" true
        (List.for_all
           (fun (s : Lsp_index.symbol) -> s.Lsp_index.container = None)
           locals)

let test_members_of () =
  let symbols = symbols_of source in
  let ix = Lsp_index.index_of "/tmp" ~modules:[] ~symbols in
  let names =
    List.map
      (fun (s : Lsp_index.symbol) -> s.Lsp_index.name)
      (Lsp_index.members_of ix "User")
  in
  Alcotest.(check bool) "greet present" true (List.mem "greet" names);
  Alcotest.(check bool) "name present" true (List.mem "name" names);
  let math_names =
    List.map
      (fun (s : Lsp_index.symbol) -> s.Lsp_index.name)
      (Lsp_index.members_of ix "Math")
  in
  Alcotest.(check bool) "abs in Math" true (List.mem "abs" math_names);
  Alcotest.(check bool) "tau in Math" true (List.mem "tau" math_names)

(* ---- Receiver extraction -------------------------------------------- *)

let test_receiver_segments () =
  let text = "println(user.full_name())" in
  let offset = String.length "println(user." in
  Alcotest.(check (option (list string)))
    "user receiver" (Some [ "user" ])
    (Lsp_resolve.receiver_segments text offset);
  let text2 = "shop.order.total(1)" in
  let offset2 = String.length "shop.order." in
  Alcotest.(check (option (list string)))
    "module receiver"
    (Some [ "shop"; "order" ])
    (Lsp_resolve.receiver_segments text2 offset2);
  Alcotest.(check (option (list string)))
    "no receiver" None
    (Lsp_resolve.receiver_segments "foo(" (String.length "foo("))

(* ---- Dependency modules --------------------------------------------- *)

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "emo_lsp_test_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm p =
        if Sys.is_directory p then begin
          Array.iter (fun e -> rm (Filename.concat p e)) (Sys.readdir p);
          Unix.rmdir p
        end
        else Sys.remove p
      in
      rm dir)
    (fun () -> f dir)

let write path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let test_dependency_modules () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      let pkg = Filename.concat reg "foo/0.1.0" in
      Unix.mkdir (Filename.concat reg "foo") 0o755;
      Unix.mkdir pkg 0o755;
      write
        (Filename.concat root "package.emo")
        "package {\n\
        \  name = \"local/demo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps { foo = \"0.1.0\" }\n\
         }\n";
      write
        (Filename.concat pkg "package.emo")
        "package {\n\
        \  name = \"foo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      write (Filename.concat pkg "foo.emo") "def bar() Int64 {\n  return 1\n}\n";
      let modules =
        Lsp_index.dependency_modules ~root ~registry:(Some reg)
          ~project_modules:[]
      in
      let paths = List.map fst modules in
      Alcotest.(check bool)
        "package file registers under its short name" true
        (List.mem [ "foo" ] paths);
      match List.assoc_opt [ "foo" ] modules with
      | Some file ->
          Alcotest.(check bool)
            "backing file exists" true (Sys.file_exists file)
      | None -> Alcotest.fail "no foo module")

let parse_items source =
  match Emo_parser.parse_program_with_diagnostics ~file:"test.emo" ~source with
  | items, [] -> items
  | _, ds -> Alcotest.failf "parse failed: %d diagnostics" (List.length ds)

let diagnostic_codes ds =
  List.filter_map
    (fun (d : Lsp_server.Diagnostic.t) -> d.Lsp_server.Diagnostic.code)
    ds

(* A scoped require still needs a manifest pin (E5006); an unscoped one needs
   no entry, but a name the registry does not publish is E5009. *)
let test_missing_dep_diagnostics () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      Unix.mkdir (Filename.concat reg "sync") 0o755;
      Unix.mkdir (Filename.concat reg "sync/0.1.0") 0o755;
      write
        (Filename.concat root "package.emo")
        "package {\n\
        \  name = \"local/demo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      let check source =
        Lsp_server.missing_dep_diagnostics ~registry:reg root
          (parse_items source)
        |> diagnostic_codes
      in
      Alcotest.(check (list string))
        "a scoped require needs a pin" [ "E5006" ]
        (check "require \"acme/tools\"\n");
      Alcotest.(check (list string))
        "an unpinned stdlib require is fine" []
        (check "require \"sync\"\n");
      Alcotest.(check (list string))
        "an unknown unscoped name" [ "E5009" ]
        (check "require \"nope\"\n"))

(* ---- Protocol -------------------------------------------------------- *)

let test_stdlib_requires_indexed () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      let pkg = Filename.concat reg "sync/0.1.0" in
      Unix.mkdir (Filename.concat reg "sync") 0o755;
      Unix.mkdir pkg 0o755;
      write
        (Filename.concat root "package.emo")
        "package {\n\
        \  name = \"local/demo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      write
        (Filename.concat pkg "package.emo")
        "package {\n\
        \  name = \"sync\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      write
        (Filename.concat pkg "sync.emo")
        "def wait_group(n Int64) Pid {\n  return self_pid()\n}\n";
      write (Filename.concat root "main.emo") "require \"sync\"\n";
      let project_modules = Lsp_index.scan root in
      let modules =
        Lsp_index.dependency_modules ~root ~registry:(Some reg) ~project_modules
      in
      let paths = List.map fst modules in
      Alcotest.(check bool)
        "an unpinned stdlib require registers its package" true
        (List.mem [ "sync" ] paths))

(* A dependency's members resolve when the check runs against the index's
   pre-registered program — the mechanism behind live diagnostics for
   `require "sync"` and every declared dependency. *)
let test_dependency_members_resolve () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      Unix.mkdir (Filename.concat reg "foo") 0o755;
      Unix.mkdir (Filename.concat reg "foo/0.1.0") 0o755;
      write
        (Filename.concat root "package.emo")
        "package {\n\
        \  name = \"local/demo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      write
        (Filename.concat reg "foo/0.1.0/package.emo")
        "package {\n\
        \  name = \"foo\"\n\
        \  version = \"0.1.0\"\n\
        \  targets = [\"ocaml\"]\n\
        \  deps {}\n\
         }\n";
      write
        (Filename.concat reg "foo/0.1.0/foo.emo")
        "def bar() Int64 {\n  return 1\n}\n";
      let source = "require \"foo\"\n\nprintln(foo.bar())\n" in
      write (Filename.concat root "main.emo") source;
      let ix = Lsp_index.get ~registry:reg root in
      let items = parse_items source in
      let units = Lsp_index.units_for ix ~current:[ "main" ] items in
      let program, _ =
        Emo_check.preregister_types ~packages:[] ~package_deps:[] ~units
      in
      let modules = List.map fst ix.modules in
      let diags, _, _, _ =
        Emo_check.check_module_typed ~modules ~current:[ "main" ] ~program items
      in
      Alcotest.(check (list string))
        "a dependency member resolves" [] (diagnostic_codes diags))

(* `package.emo` is a manifest, not a module: a valid one produces no
   diagnostics, and a malformed one reports the manifest error instead of
   reading `name`/`version` as unbound Emo names. *)
let test_manifest_diagnostics () =
  Alcotest.(check bool)
    "package.emo is a manifest" true
    (Lsp_server.is_manifest_file "/x/package.emo");
  Alcotest.(check bool)
    "main.emo is not" false
    (Lsp_server.is_manifest_file "/x/main.emo");
  let valid =
    "package {\n\
    \  name = \"local/demo\"\n\
    \  version = \"0.1.0\"\n\
    \  targets = [\"ocaml\"]\n\
    \  deps {}\n\
     }\n"
  in
  Alcotest.(check (list string))
    "a valid manifest has no diagnostics" []
    (diagnostic_codes
       (Lsp_server.manifest_diagnostics ~file:"package.emo" valid));
  let missing_name = "package {\n  version = \"0.1.0\"\n}\n" in
  Alcotest.(check (list string))
    "a missing name is a manifest error" [ "E5101" ]
    (diagnostic_codes
       (Lsp_server.manifest_diagnostics ~file:"package.emo" missing_name))

let test_initialize_result () =
  let result = Lsp_server.initialize_result () in
  let capabilities = Yojson.Safe.Util.member "capabilities" result in
  Alcotest.(check bool) "capabilities is an object" true (capabilities <> `Null);
  Alcotest.(check bool)
    "textDocumentSync present" true
    (Yojson.Safe.Util.member "textDocumentSync" capabilities <> `Null);
  Alcotest.(check bool)
    "completionProvider present" true
    (Yojson.Safe.Util.member "completionProvider" capabilities <> `Null);
  Alcotest.(check bool)
    "serverInfo present" true
    (Yojson.Safe.Util.member "serverInfo" result <> `Null)

let () =
  Alcotest.run "emo_lsp"
    [
      ( "positions",
        [
          tc "ascii" test_ascii_positions;
          tc "utf16" test_utf16_positions;
          tc "roundtrip" test_position_roundtrip;
          tc "clamped" test_position_clamped;
        ] );
      ("uris", [ tc "roundtrip" test_uri_roundtrip ]);
      ( "index",
        [
          tc "symbols" test_index_symbols;
          tc "locals" test_locals_not_members;
          tc "members" test_members_of;
          tc "dependency modules" test_dependency_modules;
          tc "unpinned stdlib require" test_stdlib_requires_indexed;
          tc "missing dep diagnostics" test_missing_dep_diagnostics;
          tc "dependency members resolve" test_dependency_members_resolve;
          tc "manifest diagnostics" test_manifest_diagnostics;
        ] );
      ( "resolve",
        [
          tc "receiver segments" test_receiver_segments;
          tc "initialize result" test_initialize_result;
        ] );
    ]
