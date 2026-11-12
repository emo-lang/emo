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

let test_syntax_member_completion () =
  (* `Syntax` is the checker's reserved compile-time type, no
     declaration any index carries — member completion after `Syntax.`
     answers from the completion module's own table, the surface
     design/macros.md documents and the evaluator implements. *)
  let labels =
    List.map
      (fun (i : Lsp_completion.item) -> i.Lsp_completion.label)
      Lsp_completion.syntax_member_items
  in
  let has name = List.mem name labels in
  Alcotest.(check int) "the documented surface" 30 (List.length labels);
  List.iter
    (fun name -> Alcotest.(check bool) (name ^ " present") true (has name))
    [ "new_def"; "gensym"; "lit_string"; "with_methods"; "bin_eq" ];
  (* the dotted receiver routes before the index is consulted *)
  let symbols = symbols_of source in
  let items =
    Lsp_completion.member_items
      (Lsp_index.index_of "/tmp" ~modules:[] ~symbols)
      [] "Syntax." "test.emo" 13 [ "Syntax" ]
  in
  let routed =
    List.map (fun (i : Lsp_completion.item) -> i.Lsp_completion.label) items
  in
  Alcotest.(check int) "Syntax. routes to the table" 30 (List.length routed)

let test_syntax_hover () =
  let text = "  const wrapped = Syntax.new_def(n, ps, r, b)" in
  let member_at = String.length "  const wrapped = Syntax.new_de" in
  let type_at = String.length "  const wrapped = " in
  (* a cursor over the member answers its signature *)
  Alcotest.(check bool)
    "member hover" true
    (match Lsp_completion.syntax_hover_at text member_at with
    | Some value ->
        Lsp_util.starts_with
          ~prefix:"```emo\nSyntax.new_def(name, params, result, body) -> Syntax"
          value
    | None -> false);
  (* a cursor over `Syntax` itself answers the type's blurb *)
  Alcotest.(check bool)
    "type hover" true
    (match Lsp_completion.syntax_hover_at text type_at with
    | Some value -> Lsp_util.starts_with ~prefix:"```emo\nSyntax\n```" value
    | None -> false);
  (* a word the reserved surface does not name stays with the index *)
  Alcotest.(check bool)
    "other words stay with the index" true
    (Lsp_completion.syntax_hover_at text (String.length "  const w") = None)

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
    "half-spelled member names its receiver" (Some [ "os" ])
    (Lsp_resolve.receiver_segments "os.getp" (String.length "os.getp"));
  Alcotest.(check (option (list string)))
    "a bare half-spelled word has no receiver" None
    (Lsp_resolve.receiver_segments "getp" (String.length "getp"));
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
        \  deps { \"foo\" = \"0.1.0\" }\n\
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
      let modules = Lsp_index.dependency_modules ~root ~registry:(Some reg) in
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

(* ---- The language's surface and the stdlib everywhere ---------------- *)

let completion_item_named name items =
  List.find_opt
    (fun (i : Lsp_completion.item) -> i.Lsp_completion.label = name)
    items

let test_builtin_member_completion () =
  (* `s.length` with `s: String` — the receiver carries no class
     declaration, so completion answers from the language's method
     surface, signatures typed the way the checker types them. *)
  let text = "def shout(s String) Int64 {\n  return s.length()\n}" in
  let offset = String.length "def shout(s String) Int64 {\n  return s." in
  let items =
    Lsp_completion.member_items (Lsp_index.standalone ()) (parse_items text)
      text "test.emo" offset [ "s" ]
  in
  match completion_item_named "substring" items with
  | Some i ->
      Alcotest.(check string)
        "substring signature" "def substring(start Int64, length Int64) String"
        i.Lsp_completion.detail
  | None -> Alcotest.fail "no substring after a String receiver"

let test_builtin_type_member_completion () =
  (* a builtin type name completes from the method surface, the way
     `Syntax.` does *)
  let items =
    Lsp_completion.member_items (Lsp_index.standalone ()) [] "Bytes." "test.emo"
      6 [ "Bytes" ]
  in
  match completion_item_named "get_u32_le" items with
  | Some i ->
      Alcotest.(check string)
        "Bytes.get_u32_le signature" "def get_u32_le(i Int64) Int64"
        i.Lsp_completion.detail
  | None -> Alcotest.fail "no get_u32_le after Bytes."

let test_builtin_literal_completion () =
  (* the receiver is a string literal: the cursor sits after `const s = "hi".` *)
  let text = "const s = \"hi\"." in
  let offset = String.length text in
  let items =
    Lsp_completion.member_items (Lsp_index.standalone ())
      (parse_items "const s = \"hi\"")
      text "test.emo" offset [ "hi" ]
  in
  Alcotest.(check bool)
    "length offered on a string literal" true
    (completion_item_named "length" items <> None)

let test_partial_member_completion () =
  (* a half-spelled member — `s.subs` — still routes to the receiver's
     members; matching the typed tail against the labels is the
     client's filter's job *)
  let prefix = "def f(s String) Int64 {\n  return s.subs" in
  let segments = Lsp_resolve.receiver_segments prefix (String.length prefix) in
  Alcotest.(check (option (list string)))
    "half-spelled member names its receiver" (Some [ "s" ]) segments;
  let items =
    Lsp_completion.member_items (Lsp_index.standalone ())
      (parse_items (prefix ^ "\n}"))
      prefix "test.emo" (String.length prefix)
      (Option.value segments ~default:[])
  in
  Alcotest.(check bool)
    "substring among the members" true
    (completion_item_named "substring" items <> None);
  let stdlib =
    Lsp_completion.member_items (Lsp_index.standalone ()) [] "os.getp"
      "test.emo" (String.length "os.getp") [ "os" ]
  in
  Alcotest.(check bool)
    "getpid among the os members" true
    (completion_item_named "getpid" stdlib <> None);
  Alcotest.(check bool)
    "getppid among the os members" true
    (completion_item_named "getppid" stdlib <> None)

let test_builtin_hover () =
  let text = "def f(data Bytes) Int64 {\n  return data.get_u32_le(0)\n}" in
  let items = parse_items text in
  (* a bare builtin function *)
  (match
     Lsp_completion.builtin_hover_at ~items "println(x)"
       (String.length "printl")
   with
  | Some value ->
      Alcotest.(check bool)
        "println hover" true
        (Lsp_util.starts_with ~prefix:"```emo\nprintln(value)" value)
  | None -> Alcotest.fail "println has no hover");
  (* a bare capability type *)
  (match
     Lsp_completion.builtin_hover_at ~items "const b = Bytes.new()"
       (String.length "const b = ")
   with
  | Some value ->
      Alcotest.(check bool)
        "Bytes hover" true
        (Lsp_util.starts_with ~prefix:"```emo\nBytes\n```" value)
  | None -> Alcotest.fail "Bytes has no hover");
  (* a member on a value of builtin type *)
  (match
     Lsp_completion.builtin_hover_at ~items text
       (String.length "def f(data Bytes) Int64 {\n  return data.get_u32_l")
   with
  | Some value ->
      Alcotest.(check bool)
        "Bytes member hover" true
        (Lsp_util.starts_with ~prefix:"```emo\ndef get_u32_le(i Int64) Int64"
           value)
  | None -> Alcotest.fail "data.get_u32_le has no hover");
  (* a word the surface does not name stays None *)
  Alcotest.(check bool)
    "other words stay None" true
    (Lsp_completion.builtin_hover_at ~items text (String.length "def ") = None)

let test_standalone_stdlib_completion () =
  (* a file outside any project still completes the standard library's
     surface — the packages ride the binary *)
  let ix = Lsp_index.standalone () in
  let items =
    Lsp_completion.member_items ix [] "os." "scratch.emo" 3 [ "os" ]
  in
  match completion_item_named "getpid" items with
  | Some i ->
      Alcotest.(check string)
        "os.getpid signature" "def getpid() Int64" i.Lsp_completion.detail
  | None -> Alcotest.fail "no getpid after os."

let test_standalone_stdlib_hover () =
  let ix = Lsp_index.standalone () in
  let text = "const status = os.wait_exit_code(0)" in
  let offset = String.length "const status = os.wait_exit_cod" in
  match Lsp_server.symbols_at ix [] "scratch.emo" text offset with
  | s :: _ -> (
      Alcotest.(check string)
        "stdlib signature" "def wait_exit_code(status Int64) Int64"
        s.Lsp_index.detail;
      match
        Lsp_server.doc_comment_of_symbol ~buffer:text ~buffer_file:"scratch.emo"
          s
      with
      | Some doc ->
          Alcotest.(check bool)
            "the doc comment rides the hover" true
            (String.length doc > 0)
      | None -> Alcotest.fail "no doc comment above wait_exit_code")
  | [] -> Alcotest.fail "os.wait_exit_code did not resolve outside a project"

(* Every require needs a manifest pin: a scoped name and a standard-library
   short name alike are E5006, the latter's hint naming the version to add;
   a name the registry does not publish is E5009. *)
let test_missing_dep_diagnostics () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      Unix.mkdir (Filename.concat reg "sync") 0o755;
      Unix.mkdir (Filename.concat reg "sync/0.1.0") 0o755;
      let manifest deps =
        write
          (Filename.concat root "package.emo")
          (Printf.sprintf
             "package {\n\
             \  name = \"local/demo\"\n\
             \  version = \"0.1.0\"\n\
             \  targets = [\"ocaml\"]\n\
             \  deps {%s}\n\
              }\n"
             deps)
      in
      let diagnostics source =
        Lsp_server.missing_dep_diagnostics ~registry:reg root
          (parse_items source)
      in
      let check source = diagnostic_codes (diagnostics source) in
      manifest "";
      Alcotest.(check (list string))
        "a scoped require needs a pin" [ "E5006" ]
        (check "require \"acme/tools\"\n");
      Alcotest.(check (list string))
        "an unpinned stdlib require needs a pin too" [ "E5006" ]
        (check "require \"sync\"\n");
      (match diagnostics "require \"sync\"\n" with
      | [ d ] ->
          Alcotest.(check (option string))
            "the hint names the version to add"
            (Some "add `\"sync\" = \"0.1.0\"` to the manifest's deps block")
            d.Lsp_server.Diagnostic.hint
      | _ -> Alcotest.fail "expected one diagnostic");
      Alcotest.(check (list string))
        "an unknown unscoped name" [ "E5009" ]
        (check "require \"nope\"\n");
      manifest " \"sync\" = \"0.1.0\" ";
      Alcotest.(check (list string))
        "a pinned stdlib require is fine" []
        (check "require \"sync\"\n"))

(* ---- Protocol -------------------------------------------------------- *)

(* The index follows the manifest's pins and nothing else: an unscoped
   require the manifest does not pin contributes no modules (the compiler
   refuses it), and the same require pinned registers its package. *)
let test_stdlib_requires_indexed () =
  with_temp_dir (fun root ->
      let reg = Filename.concat root "registry" in
      Unix.mkdir reg 0o755;
      let pkg = Filename.concat reg "sync/0.1.0" in
      Unix.mkdir (Filename.concat reg "sync") 0o755;
      Unix.mkdir pkg 0o755;
      let manifest deps =
        write
          (Filename.concat root "package.emo")
          (Printf.sprintf
             "package {\n\
             \  name = \"local/demo\"\n\
             \  version = \"0.1.0\"\n\
             \  targets = [\"ocaml\"]\n\
             \  deps {%s}\n\
              }\n"
             deps)
      in
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
      let indexed () =
        Lsp_index.dependency_modules ~root ~registry:(Some reg)
        |> List.map fst |> List.mem [ "sync" ]
      in
      manifest "";
      Alcotest.(check bool)
        "an unpinned stdlib require registers nothing" false (indexed ());
      manifest " \"sync\" = \"0.1.0\" ";
      Alcotest.(check bool)
        "a pinned stdlib require registers its package" true (indexed ()))

(* A dependency published from a project carries a `main.emo`: that file is
   the module a `require` binds, and the index mounts it under its own name
   beside it too — the compiler's `register_package` registers both paths,
   and the editor has to see the same two spellings. *)
let test_dependency_main_entry () =
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
        \  deps { \"foo\" = \"0.1.0\" }\n\
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
        (Filename.concat reg "foo/0.1.0/main.emo")
        "def bar() Int64 {\n  return 1\n}\n";
      write (Filename.concat root "main.emo") "require \"foo\"\n";
      let modules = Lsp_index.dependency_modules ~root ~registry:(Some reg) in
      let paths = List.map fst modules in
      Alcotest.(check bool)
        "the entry file is the module a require binds" true
        (List.mem [ "foo" ] paths);
      Alcotest.(check bool)
        "the entry file keeps its own name beside it" true
        (List.mem [ "foo"; "main" ] paths))

(* A package's files register under its short-name prefix, the way the
   compiler's `register_package` mounts them: `helper.emo` beside the
   entry file is `foo.helper`, never a top-level `helper` colliding with
   another package's. *)
let test_dependency_children_prefixed () =
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
        \  deps { \"foo\" = \"0.1.0\" }\n\
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
      write
        (Filename.concat reg "foo/0.1.0/helper.emo")
        "def twice(x Int64) Int64 {\n  return x * 2\n}\n";
      let tree = Lsp_index.dependency_tree ~root ~registry:(Some reg) in
      let paths = List.map fst tree.Lsp_index.dep_modules in
      Alcotest.(check bool)
        "the entry file is the module a require binds" true
        (List.mem [ "foo" ] paths);
      Alcotest.(check bool)
        "a sibling registers under the prefix" true
        (List.mem [ "foo"; "helper" ] paths);
      Alcotest.(check bool)
        "no top-level sibling leaks out" false
        (List.mem [ "helper" ] paths);
      Alcotest.(check (list (list string)))
        "the package prefix is reported" [ [ "foo" ] ]
        tree.Lsp_index.dep_packages)

(* Runs [f] with [key] bound to [value] in the environment, restoring the
   previous binding afterwards. *)
let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with Some v -> Unix.putenv key v | None -> ())
    f

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
        \  deps { \"foo\" = \"0.1.0\" }\n\
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
        Emo_check.preregister_types ~packages:[] ~package_deps:[] ~aliases:[]
          ~units
      in
      let modules = List.map fst ix.modules in
      let diags, _, _, _ =
        Emo_check.check_module_typed ~modules ~current:[ "main" ] ~program items
      in
      Alcotest.(check (list string))
        "a dependency member resolves" [] (diagnostic_codes diags))

(* The standard library rides the compiler binary, so with no registry
   configured a pinned stdlib require still indexes its package —
   fetched from the embedded data into the shared cache — and its
   members resolve in a check exactly as a build resolves them: the
   editor never needs a registry beside it. *)
let test_embedded_stdlib_resolves () =
  with_temp_dir (fun dir ->
      let root = Filename.concat dir "project" in
      let cache = Filename.concat dir "cache" in
      Unix.mkdir root 0o755;
      with_env "XDG_CACHE_HOME" cache (fun () ->
          write
            (Filename.concat root "package.emo")
            "package {\n\
            \  name = \"local/demo\"\n\
            \  version = \"0.1.0\"\n\
            \  targets = [\"ocaml\"]\n\
            \  deps { \"plot\" = \"0.1.0\" }\n\
             }\n";
          let source = "require \"plot\"\n\nconst m = plot.marker_at(0)\n" in
          write (Filename.concat root "main.emo") source;
          let tree = Lsp_index.dependency_tree ~root ~registry:None in
          let paths = List.map fst tree.Lsp_index.dep_modules in
          Alcotest.(check bool)
            "the required package mounts with no registry" true
            (List.mem [ "plot" ] paths);
          Alcotest.(check bool)
            "its modules ride under the prefix" true
            (List.mem [ "plot"; "mark" ] paths);
          let ix = Lsp_index.get root in
          let items = parse_items source in
          let units = Lsp_index.units_for ix ~current:[ "main" ] items in
          let program, _ =
            Emo_check.preregister_types ~packages:ix.Lsp_index.packages
              ~package_deps:ix.Lsp_index.package_deps
              ~aliases:ix.Lsp_index.aliases ~units
          in
          let modules = List.map fst ix.modules in
          let diags, _, _, _ =
            Emo_check.check_module_typed ~modules ~current:[ "main" ] ~program
              ~packages:ix.Lsp_index.packages
              ~package_deps:ix.Lsp_index.package_deps
              ~aliases:ix.Lsp_index.aliases items
          in
          Alcotest.(check (list string))
            "a stdlib member resolves with no registry" []
            (diagnostic_codes diags)))

(* An unpinned stdlib require registers nothing: the manifest's pins are
   the only road in with or without a registry — the compiler refuses an
   unpaired require, and the editor resolves no reference it refuses. *)
let test_embedded_stdlib_needs_pin () =
  with_temp_dir (fun dir ->
      let root = Filename.concat dir "project" in
      let cache = Filename.concat dir "cache" in
      Unix.mkdir root 0o755;
      with_env "XDG_CACHE_HOME" cache (fun () ->
          write
            (Filename.concat root "package.emo")
            "package {\n\
            \  name = \"local/demo\"\n\
            \  version = \"0.1.0\"\n\
            \  targets = [\"ocaml\"]\n\
            \  deps {}\n\
             }\n";
          write (Filename.concat root "main.emo") "require \"plot\"\n";
          let tree = Lsp_index.dependency_tree ~root ~registry:None in
          Alcotest.(check bool)
            "an unpinned stdlib require registers nothing" true
            (tree.Lsp_index.dep_modules = [])))

(* `package.emo` is a manifest, not a module: a valid one produces no
   diagnostics, and a malformed one reports the manifest error instead of
   reading `name`/`version` as unbound Emo names. *)
let test_manifest_diagnostics () =
  Alcotest.(check bool)
    "package.emo is a manifest" true
    (Emo_pkg.is_manifest_file "/x/package.emo");
  Alcotest.(check bool)
    "main.emo is not" false
    (Emo_pkg.is_manifest_file "/x/main.emo");
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

(* The code action that pins a dependency writes a deps entry, whose key
   is a string literal — the one spelling a manifest accepts. *)
let test_dep_insertion () =
  let with_block =
    "package {\n\
    \  name = \"local/demo\"\n\
    \  version = \"0.1.0\"\n\
    \  targets = [\"ocaml\"]\n\
    \  deps {}\n\
     }\n"
  in
  let _, insert = Lsp_server.dep_insertion with_block "emo/ui" "0.1.0" in
  Alcotest.(check string)
    "the entry keys the name as a string" "\n    \"emo/ui\" = \"0.1.0\"" insert;
  let without_block = "package {\n  name = \"local/demo\"\n}\n" in
  let _, insert = Lsp_server.dep_insertion without_block "json" "2.3.1" in
  Alcotest.(check string)
    "a fresh block does too" "\n  deps {\n    \"json\" = \"2.3.1\"\n  }\n"
    insert

(* ---- Root discovery ------------------------------------------------- *)

let mkdir dir = if not (Sys.file_exists dir) then Unix.mkdir dir 0o755

let touch path =
  let oc = open_out path in
  close_out oc

(* The compiler's root rule, mirrored: a directory is a project when it
   holds a package.emo, and no ancestor is ever consulted. *)
let test_find_root () =
  let base = Filename.concat (Sys.getcwd ()) "root-discovery-fixture" in
  let bare = Filename.concat base "bare" in
  let pkg = Filename.concat base "pkg" in
  mkdir base;
  mkdir bare;
  mkdir pkg;
  touch (Filename.concat pkg "package.emo");
  Alcotest.(check (option string))
    "the directory holding the manifest is the root" (Some pkg)
    (Lsp_index.find_root ~fallback:pkg (Filename.concat pkg "main.emo"));
  Alcotest.(check (option string))
    "the file's own directory is the other candidate" (Some pkg)
    (Lsp_index.find_root (Filename.concat pkg "main.emo"));
  Alcotest.(check (option string))
    "a manifest-less directory is no root" None
    (Lsp_index.find_root ~fallback:bare (Filename.concat bare "main.emo"));
  Alcotest.(check (option string))
    "and nothing above it is consulted either" None
    (Lsp_index.find_root (Filename.concat bare "main.emo"))

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
          tc "stdlib requires index only when pinned"
            test_stdlib_requires_indexed;
          tc "dependency main entry" test_dependency_main_entry;
          tc "dependency children prefixed" test_dependency_children_prefixed;
          tc "missing dep diagnostics" test_missing_dep_diagnostics;
          tc "dependency members resolve" test_dependency_members_resolve;
          tc "embedded stdlib resolves" test_embedded_stdlib_resolves;
          tc "embedded stdlib needs a pin" test_embedded_stdlib_needs_pin;
          tc "manifest diagnostics" test_manifest_diagnostics;
        ] );
      ( "resolve",
        [
          tc "receiver segments" test_receiver_segments;
          tc "syntax member completion" test_syntax_member_completion;
          tc "syntax hover" test_syntax_hover;
          tc "dep insertion" test_dep_insertion;
          tc "initialize result" test_initialize_result;
        ] );
      ( "completion",
        [
          tc "builtin member completion" test_builtin_member_completion;
          tc "builtin type member completion"
            test_builtin_type_member_completion;
          tc "builtin literal completion" test_builtin_literal_completion;
          tc "partial member completion" test_partial_member_completion;
          tc "builtin hover" test_builtin_hover;
          tc "standalone stdlib completion" test_standalone_stdlib_completion;
          tc "standalone stdlib hover" test_standalone_stdlib_hover;
        ] );
      ("root", [ tc "find_root" test_find_root ]);
    ]
