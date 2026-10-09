open Emo_support

let tc name f = Alcotest.test_case name `Quick f

(* The process-start working directory (the dune sandbox rule dir); tests
   that chdir elsewhere must not break later relative paths. *)
let original_cwd = Sys.getcwd ()

let codes_dump diagnostics =
  String.concat ","
    (List.map
       (fun d ->
         match d.Diagnostic.code with
         | Some c -> c ^ "@" ^ Span.to_string d.Diagnostic.span
         | None -> "?")
       diagnostics)

let codes_of diagnostics =
  List.map
    (fun d -> match d.Diagnostic.code with Some c -> c | None -> "?")
    diagnostics

let has_code diagnostics code = List.mem code (codes_of diagnostics)

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

(* Every project gets a fresh scratch directory: no deletion anywhere, and
   no stale files leaking between tests. *)
let scratch_counter = ref 0

let fresh_scratch () =
  incr scratch_counter;
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "emo-project-%d-%d"
       (int_of_float (Sys.time () *. 1000.))
       !scratch_counter)

(* Writes files into a fresh scratch project and returns its directory. *)
let write_project files =
  let scratch = fresh_scratch () in
  List.iter
    (fun (rel, source) ->
      let path = Filename.concat scratch rel in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
      let oc = open_out_bin path in
      output_string oc source;
      close_out oc)
    files;
  scratch

(* Writes files into a fresh scratch project and discovers it with the
   scratch directory as the working-directory root. *)
let discover files entry =
  let scratch = write_project files in
  Sys.chdir scratch;
  Emo_project.discover ~entry_file:entry

let with_project files entry =
  let scratch = write_project files in
  Sys.chdir scratch;
  Filename.concat scratch entry

let out = Buffer.create 256

let capture_output f =
  Buffer.clear out;
  Emo_eval.set_output (Buffer.add_string out);
  Fun.protect
    ~finally:(fun () ->
      Emo_eval.set_output (fun s ->
          print_string s;
          flush stdout))
    f;
  Buffer.contents out

let run_entry source =
  capture_output (fun () ->
      try ignore (Emo_project.run_entry ~entry_file:source ()) with
      | Emo_eval.Error d ->
          let source_text = Emo_project.read_file source in
          let text = Emo_support.Render.render ~source:source_text d in
          Buffer.add_string out text
      | Emo_project.Static_errors ds ->
          List.iter
            (fun d ->
              let source_text = Emo_project.read_file source in
              let text = Emo_support.Render.render ~source:source_text d in
              Buffer.add_string out (text ^ "\n"))
            ds
      | e -> Buffer.add_string out ("EXC: " ^ Printexc.to_string e))

let resolution_tests =
  [
    tc "the shop tree resolves every module" (fun () ->
        let p =
          discover
            [
              ("shop/order.emo", "");
              ("shop/pricing.emo", "");
              ("shop/internal/discounts.emo", "");
              ("shop/checkout.emo", "");
            ]
            "shop/checkout.emo"
        in
        let resolve path = Emo_project.resolve p path in
        Alcotest.(check bool)
          "order" true
          (match resolve [ "shop"; "order" ] with
          | Some (File _) -> true
          | _ -> false);
        Alcotest.(check bool)
          "pricing" true
          (match resolve [ "shop"; "pricing" ] with
          | Some (File _) -> true
          | _ -> false);
        Alcotest.(check bool)
          "discounts" true
          (match resolve [ "shop"; "internal"; "discounts" ] with
          | Some (File _) -> true
          | _ -> false);
        Alcotest.(check bool)
          "shop is a directory module" true
          (match resolve [ "shop" ] with Some (Dir _) -> true | _ -> false);
        Alcotest.(check bool)
          "internal is a directory module" true
          (match resolve [ "shop"; "internal" ] with
          | Some (Dir _) -> true
          | _ -> false));
    tc "a missing module resolves to nothing" (fun () ->
        let p = discover [ ("shop/order.emo", "") ] "shop/order.emo" in
        Alcotest.(check bool)
          "nope" false
          (match Emo_project.resolve p [ "shop"; "nope" ] with
          | Some _ -> true
          | None -> false));
    tc "a file and directory with one stem collide" (fun () ->
        let p =
          discover
            [ ("shop/order.emo", ""); ("shop/order/util.emo", "") ]
            "shop/order.emo"
        in
        Alcotest.(check bool)
          "E5005" true
          (List.mem "E5005" (codes_of (Emo_project.diagnostics p))));
    tc "module paths resolve from the working directory" (fun () ->
        let p = discover [ ("shop/order.emo", "") ] "shop/order.emo" in
        Alcotest.(check bool)
          "elided resolves" true
          (match Emo_project.resolve p [ "shop"; "order" ] with
          | Some (File f) -> String.contains f 'o'
          | _ -> false);
        Alcotest.(check bool)
          "the root itself is the empty-path module" true
          (match Emo_project.resolve p [] with
          | Some (Dir _) -> true
          | _ -> false));
  ]

let load_tests =
  [
    tc "the entry loads modules through qualified paths" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ( "shop/order.emo",
                   {|def total(n Int64) Int64 {
  return n * 2
}|} );
                 ("shop/checkout.emo", {|println(shop.order.total(21))|});
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check string) "output" "42\n" output);
    tc "aliasing a module is ordinary binding" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ( "shop/order.emo",
                   {|def total(n Int64) Int64 {
  return n * 2
}|} );
                 ( "shop/checkout.emo",
                   {|const order = shop.order
println(order.total(4))|} );
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check string) "output" "8\n" output);
    tc "a module's items run once even with several accesses" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ( "shop/order.emo",
                   {|println("loading order")
def total(n Int64) Int64 {
  return n
}|}
                 );
                 ( "shop/checkout.emo",
                   {|println(shop.order.total(1))
println(shop.order.total(2))|}
                 );
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check string) "output" "loading order\n1\n2\n" output);
    tc "a missing member is an error" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ("shop/order.emo", "");
                 ("shop/checkout.emo", {|println(shop.order.nope)|});
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check bool) "E5004" true (contains_substring output "E5004"));
    tc "an unbound non-module name is still unbound" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ("shop/order.emo", ""); ("shop/checkout.emo", {|println(nope)|});
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check bool) "E3002" true (contains_substring output "E3002"));
  ]

let privacy_tests =
  [
    tc "internal is reachable from its own subtree" (fun () ->
        let p =
          discover
            [
              ("shop/pricing.emo", {|const rate = shop.internal.discounts.rate|});
              ("shop/internal/discounts.emo", {|const rate = 1|});
            ]
            "shop/pricing.emo"
        in
        let _, _, errors = Emo_project.check_project ~manifest:None p in
        if List.length errors > 0 then
          Alcotest.fail ("codes: " ^ codes_dump errors);
        Alcotest.(check int) "count" 0 (List.length errors));
    tc "internal is rejected outside its subtree, naming both modules"
      (fun () ->
        let p =
          discover
            [
              ("shop/internal/discounts.emo", {|const rate = 1|});
              ("other/thing.emo", {|const rate = shop.internal.discounts.rate|});
            ]
            "other/thing.emo"
        in
        let _, _, errors = Emo_project.check_project ~manifest:None p in
        if not (has_code errors "E5001") then
          Alcotest.fail ("codes: " ^ codes_dump errors);
        let message =
          match errors with d :: _ -> d.Diagnostic.message | [] -> ""
        in
        Alcotest.(check bool)
          "names the use site" true
          (contains_substring message "other.thing");
        Alcotest.(check bool)
          "names the internal module" true
          (contains_substring message "shop.internal.discounts"));
  ]

let cycle_tests =
  [
    tc "a two-module cycle is rejected with the full chain" (fun () ->
        let p =
          discover
            [
              ("a.emo", {|const from_b = other.b.back
const once = 1|});
              ("other/b.emo", {|const back = a.once|});
            ]
            "a.emo"
        in
        let _, _, errors = Emo_project.check_project ~manifest:None p in
        if not (has_code errors "E5003") then
          Alcotest.fail ("codes: " ^ codes_dump errors);
        let message =
          match errors with d :: _ -> d.Diagnostic.message | [] -> ""
        in
        Alcotest.(check bool)
          "names the chain" true
          (contains_substring message "->"));
    tc "an acyclic reference graph is silent" (fun () ->
        let p =
          discover
            [
              ("main.emo", {|println(helper.run())|});
              ("helper.emo", {|def run() Int64 {
  return 1
}|});
            ]
            "main.emo"
        in
        let _, _, errors = Emo_project.check_project ~manifest:None p in
        Alcotest.(check int) "count" 0 (List.length errors));
  ]

let cache_tests =
  [
    tc "unchanged modules parse once across all stages" (fun () ->
        let entry =
          with_project
            [
              ("shop/order.emo", {|def total(n Int64) Int64 {
  return n * 2
}|});
              ("shop/checkout.emo", {|println(shop.order.total(21))|});
            ]
            "shop/checkout.emo"
        in
        let p, output =
          let out = Buffer.create 64 in
          Emo_eval.set_output (Buffer.add_string out);
          Fun.protect
            ~finally:(fun () ->
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout))
            (fun () ->
              let proj =
                Emo_project.run_entry ~entry_file:entry ~check:true ()
              in
              (proj, Buffer.contents out))
        in
        Alcotest.(check string) "output" "42\n" output;
        (* entry: 1 parse shared by run + check; order.emo: 1 parse shared
           by the load and the check. *)
        Alcotest.(check int) "parses" 2 p.Emo_project.parses);
    tc "changed content invalidates the cache entry" (fun () ->
        let entry = with_project [ ("m.emo", "const x = 1") ] "m.emo" in
        let p = Emo_project.discover ~entry_file:entry in
        let file = Filename.concat p.Emo_project.root "m.emo" in
        let (_ : Emo_support.Diagnostic.t list) =
          Emo_check.check_parsed (Emo_project.parse_cached p file)
        in
        let parses_after_first = p.Emo_project.parses in
        (* rewrite with new content: the cache must miss *)
        let oc = open_out_bin file in
        output_string oc "const x = 2";
        close_out oc;
        let (_ : Emo_support.Diagnostic.t list) =
          Emo_check.check_parsed (Emo_project.parse_cached p file)
        in
        Alcotest.(check int)
          "re-parsed" (parses_after_first + 1) p.Emo_project.parses);
  ]

let shop_golden_tests =
  [
    tc "the shop project runs verbatim from its own directory" (fun () ->
        (* dune materializes the declared examples/ dependency at its
           workspace-relative path, two levels up from this rule's dir. *)
        Sys.chdir (Filename.concat original_cwd "../../examples/shop");
        let out = Buffer.create 64 in
        Emo_eval.set_output (Buffer.add_string out);
        Fun.protect
          ~finally:(fun () ->
            Emo_eval.set_output (fun s ->
                print_string s;
                flush stdout))
          (fun () ->
            ignore (Emo_project.run_entry ~entry_file:"main.emo" ~check:true ()));
        Alcotest.(check string) "output" "42\n15\n" (Buffer.contents out));
  ]

(* The dependency fixture: a directory registry holding one published
   package, and a local project that requires it — the README scenario end
   to end. *)
let write_file path content =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let registry_dir =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "emo-registry-%d" (int_of_float (Sys.time () *. 1000.)))
  in
  let pkg_dir =
    Filename.concat dir
      (Filename.concat "acme" (Filename.concat "json_tools" "2.3.1"))
  in
  write_file
    (Filename.concat pkg_dir "package.emo")
    {|package {
  name = "acme/json_tools"
  version = "2.3.1"
  targets = ["ocaml"]
  deps {}
}
|};
  write_file
    (Filename.concat pkg_dir "json_tools.emo")
    {|def parse(s String) String {
  return s
}
|};
  let wasm_dir =
    Filename.concat dir
      (Filename.concat "acme" (Filename.concat "wasm_tools" "1.0.0"))
  in
  write_file
    (Filename.concat wasm_dir "package.emo")
    {|package {
  name = "acme/wasm_tools"
  version = "1.0.0"
  targets = ["ocaml", "wasm"]
  deps {}
}
|};
  write_file
    (Filename.concat wasm_dir "wasm_tools.emo")
    {|def shrink(n Int64) Int64 {
  return n - 1
}
|};
  let c_dir =
    Filename.concat dir
      (Filename.concat "acme" (Filename.concat "c_tools" "1.0.0"))
  in
  write_file
    (Filename.concat c_dir "package.emo")
    {|package {
  name = "acme/c_tools"
  version = "1.0.0"
  targets = ["ocaml", "c"]
  deps {}
}
|};
  write_file
    (Filename.concat c_dir "c_tools.emo")
    {|def halve(n Int64) Int64 {
  return n / 2
}
|};
  dir

let app_manifest =
  (* The run path resolves dependencies for the default target (`c`,
     the T25.1 flip), so the mechanism fixture deps a package that
     declares it; the gate-refusal tests below use the ocaml-only
     json_tools. *)
  {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    acme/c_tools = "1.0.0"
  }
}
|}

let app_main = {|require "acme/c_tools"
println(c_tools.halve(84))
|}

let with_registry f =
  let old = Sys.getenv_opt "EMO_REGISTRY" in
  let old_cache = Sys.getenv_opt "EMO_CACHE_DIR" in
  Unix.putenv "EMO_REGISTRY" registry_dir;
  Unix.putenv "EMO_CACHE_DIR" (Filename.concat registry_dir "cache");
  Fun.protect
    ~finally:(fun () ->
      (match old with Some v -> Unix.putenv "EMO_REGISTRY" v | None -> ());
      match old_cache with
      | Some v -> Unix.putenv "EMO_CACHE_DIR" v
      | None -> ())
    f

let parsed_app_manifest dir =
  let path = Filename.concat dir "package.emo" in
  match
    Emo_pkg.parse_manifest ~file:path ~source:(Emo_project.read_file path)
  with
  | m -> m
  | exception Emo_pkg.Manifest_error d -> Alcotest.fail d.Diagnostic.message

(* ---- install: the project-dependencies front end (T25.4) ---- *)

let install_tests =
  [
    tc "install resolves, fetches, and locks idempotently" (fun () ->
        let entry =
          with_project
            [ ("package.emo", app_manifest); ("main.emo", app_main) ]
            "main.emo"
        in
        let dir = Filename.dirname entry in
        Sys.chdir dir;
        with_registry (fun () ->
            let manifest = parsed_app_manifest dir in
            let first =
              Emo_project.install_deps ~manifest ~manifest_dir:dir ~target:"c"
            in
            Alcotest.(check bool)
              "resolved line" true
              (contains_substring (List.nth first 0) "resolved 1 dependencies");
            Alcotest.(check bool)
              "fetched line carries the checksum" true
              (contains_substring (List.nth first 1)
                 "fetched acme/c_tools 1.0.0");
            Alcotest.(check bool)
              "lock written" true
              (Sys.file_exists (Filename.concat dir Emo_pkg.Lockfile.filename));
            let second =
              Emo_project.install_deps ~manifest ~manifest_dir:dir ~target:"c"
            in
            Alcotest.(check bool)
              "second run hits the cache" true
              (contains_substring (List.nth second 1) "(already cached)");
            Alcotest.(check bool)
              "second run leaves the lock" true
              (contains_substring (List.nth second 2)
                 "package.lock is up to date")));
    tc "an unsatisfiable pin fails at resolution" (fun () ->
        let bad =
          String.concat "\n"
            [
              "package {";
              "  name = \"local/app\"";
              "  version = \"0.1.0\"";
              "  targets = [\"ocaml\"]";
              "";
              "  deps {";
              "    acme/c_tools = \"9.9.9\"";
              "  }";
              "}";
            ]
        in
        let entry =
          with_project
            [ ("package.emo", bad); ("main.emo", app_main) ]
            "main.emo"
        in
        let dir = Filename.dirname entry in
        Sys.chdir dir;
        with_registry (fun () ->
            match
              Emo_project.install_deps ~manifest:(parsed_app_manifest dir)
                ~manifest_dir:dir ~target:"c"
            with
            | _ -> Alcotest.fail "expected the pin to fail"
            | exception Emo_project.Static_errors ds -> (
                match ds with
                | [ d ] ->
                    Alcotest.(check string)
                      "code" "E5007"
                      (match d.Diagnostic.code with Some c -> c | None -> "?")
                | _ -> Alcotest.fail ("codes: " ^ codes_dump ds))));
    tc "an empty manifest reports nothing to install" (fun () ->
        let bare =
          {|package {
  name = "local/bare"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {}
}
|}
        in
        let entry =
          with_project
            [ ("package.emo", bare); ("main.emo", "println(1)\n") ]
            "main.emo"
        in
        let dir = Filename.dirname entry in
        Sys.chdir dir;
        with_registry (fun () ->
            match
              Emo_project.install_deps ~manifest:(parsed_app_manifest dir)
                ~manifest_dir:dir ~target:"c"
            with
            | lines ->
                Alcotest.(check bool)
                  "nothing to install" true
                  (contains_substring (List.hd lines) "nothing to install")
            | exception Emo_project.Static_errors ds ->
                Alcotest.fail ("codes: " ^ codes_dump ds)));
  ]

let deps_tests =
  [
    tc "the README require scenario runs against a fixture registry" (fun () ->
        let entry =
          with_project
            [ ("package.emo", app_manifest); ("main.emo", app_main) ]
            "main.emo"
        in
        let dir = Filename.dirname entry in
        with_registry (fun () ->
            let output =
              capture_output (fun () ->
                  ignore
                    (Emo_project.run_entry ~entry_file:entry ~check:true ()))
            in
            Alcotest.(check string) "output" "42\n" output;
            (* A run resolves in memory when no lockfile exists; writing the
               lockfile is `emo deps resolve`'s explicit job. *)
            Alcotest.(check bool)
              "no lockfile written by a run" false
              (Sys.file_exists (Filename.concat dir Emo_pkg.Lockfile.filename))));
    tc "the lockfile pins the resolution and a run verifies it" (fun () ->
        let entry =
          with_project
            [ ("package.emo", app_manifest); ("main.emo", app_main) ]
            "main.emo"
        in
        let dir = Filename.dirname entry in
        Sys.chdir dir;
        with_registry (fun () ->
            let entries =
              Emo_project.resolve_deps ~manifest:(parsed_app_manifest dir)
                ~manifest_dir:dir ~target:"ocaml"
            in
            Alcotest.(check int) "count" 1 (List.length entries);
            (match entries with
            | [ e ] ->
                Alcotest.(check string)
                  "dep" "acme/c_tools" e.Emo_pkg.Lockfile.dep;
                Alcotest.(check string)
                  "version" "1.0.0"
                  (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version);
                Alcotest.(check bool)
                  "checksum present" true
                  (String.length e.Emo_pkg.Lockfile.checksum > 0)
            | _ -> ());
            Emo_pkg.Lockfile.write
              ~path:(Filename.concat dir Emo_pkg.Lockfile.filename)
              entries;
            let output =
              capture_output (fun () ->
                  ignore
                    (Emo_project.run_entry ~entry_file:entry ~check:true ()))
            in
            Alcotest.(check string) "output" "42\n" output;
            (* A lockfile drifting from the manifest is an error prompting
               explicit regeneration — never a silent re-resolve. *)
            Emo_pkg.Lockfile.write
              ~path:(Filename.concat dir Emo_pkg.Lockfile.filename)
              [
                {
                  Emo_pkg.Lockfile.dep = "acme/c_tools";
                  version =
                    (match Emo_pkg.Version.parse "9.9.9" with
                    | Ok v -> v
                    | Error _ -> assert false);
                  checksum = "x";
                };
              ];
            match Emo_project.run_entry ~entry_file:entry ~check:true () with
            | _ -> Alcotest.fail "expected a lockfile mismatch error"
            | exception Emo_project.Static_errors ds -> (
                match ds with
                | [ d ] ->
                    Alcotest.(check string)
                      "code" "E5007"
                      (match d.Diagnostic.code with Some c -> c | None -> "?");
                    Alcotest.(check bool)
                      "prompts regeneration" true
                      (contains_substring d.Diagnostic.message "regenerate")
                | _ -> Alcotest.fail ("codes: " ^ codes_dump ds))));
    tc "removing a dep while its require remains is a compile error" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}
|}
              );
              ("main.emo", app_main);
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match Emo_project.run_entry ~entry_file:entry ~check:true () with
            | _ -> Alcotest.fail "expected E5006"
            | exception Emo_project.Static_errors ds ->
                if not (has_code ds "E5006") then
                  Alcotest.fail ("codes: " ^ codes_dump ds)));
    tc "a pin the registry cannot satisfy fails before compiling" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    acme/json_tools = "9.8.7"
  }
}
|}
              );
              ("main.emo", {|println("plain")|});
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match Emo_project.run_entry ~entry_file:entry ~check:true () with
            | _ -> Alcotest.fail "expected a resolution error"
            | exception Emo_project.Static_errors ds -> (
                match ds with
                | [ d ] ->
                    Alcotest.(check string)
                      "code" "E5007"
                      (match d.Diagnostic.code with Some c -> c | None -> "?");
                    Alcotest.(check bool)
                      "names the dep and the cause" true
                      (contains_substring d.Diagnostic.message
                         "acme/json_tools: no such version")
                | _ -> Alcotest.fail ("codes: " ^ codes_dump ds))));
    tc "a wasm build refuses a package without a wasm build" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml", "wasm"]

  deps {
    acme/json_tools = "2.3.1"
  }
}
|}
              );
              ( "main.emo",
                {|require "acme/json_tools"
println(json_tools.parse("hello"))
|}
              );
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match
              Emo_project.compile_inputs ~entry_file:entry ~target:"wasm"
            with
            | _ -> Alcotest.fail "expected the wasm gate to refuse"
            | exception Emo_project.Static_errors ds -> (
                match ds with
                | [ d ] ->
                    Alcotest.(check string)
                      "code" "E5007"
                      (match d.Diagnostic.code with Some c -> c | None -> "?");
                    Alcotest.(check bool)
                      "names the dep and the target" true
                      (contains_substring d.Diagnostic.message "acme/json_tools"
                      && contains_substring d.Diagnostic.message "wasm")
                | _ -> Alcotest.fail ("codes: " ^ codes_dump ds))));
    tc "a wasm build accepts a package that declares the target" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml", "wasm"]

  deps {
    acme/wasm_tools = "1.0.0"
  }
}
|}
              );
              ( "main.emo",
                {|require "acme/wasm_tools"
println(wasm_tools.shrink(4))
|} );
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match
              Emo_project.compile_inputs ~entry_file:entry ~target:"wasm"
            with
            | _ -> ()
            | exception Emo_project.Static_errors ds ->
                Alcotest.fail ("codes: " ^ codes_dump ds)));
    tc "a c build refuses a package without a c build" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    acme/json_tools = "2.3.1"
  }
}
|}
              );
              ( "main.emo",
                {|require "acme/json_tools"
println(json_tools.parse("hello"))
|}
              );
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match Emo_project.compile_inputs ~entry_file:entry ~target:"c" with
            | _ -> Alcotest.fail "expected the c gate to refuse"
            | exception Emo_project.Static_errors ds -> (
                match ds with
                | [ d ] ->
                    Alcotest.(check string)
                      "code" "E5007"
                      (match d.Diagnostic.code with Some c -> c | None -> "?");
                    Alcotest.(check bool)
                      "names the dep and the target" true
                      (contains_substring d.Diagnostic.message "acme/json_tools"
                      && contains_substring d.Diagnostic.message "`c`")
                | _ -> Alcotest.fail ("codes: " ^ codes_dump ds))));
    tc "a c build accepts a package that declares the target" (fun () ->
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    acme/c_tools = "1.0.0"
  }
}
|}
              );
              ("main.emo", {|require "acme/c_tools"
println(c_tools.halve(8))
|});
            ]
            "main.emo"
        in
        with_registry (fun () ->
            match Emo_project.compile_inputs ~entry_file:entry ~target:"c" with
            | _ -> ()
            | exception Emo_project.Static_errors ds ->
                Alcotest.fail ("codes: " ^ codes_dump ds)));
  ]

let sched_tests =
  [
    tc "the own scheduler runs a process program end to end" (fun () ->
        let entry =
          with_project
            [
              ( "main.emo",
                {|def worker(reply_to Pid) Int64 {
  receive {
    n -> {
      reply_to <- n * 2
      return halt()
    }
  }
}

const pid = do worker(self_pid())
pid <- 21
receive {
  v -> { println(v) }
}
|}
              );
            ]
            "main.emo"
        in
        let output =
          capture_output (fun () ->
              ignore
                (Emo_project.run_entry ~entry_file:entry ~check:true
                   ~sched:Emo_project.Own ()))
        in
        Alcotest.(check string) "output" "42\n" output);
    tc "a deadlock surfaces as a static error" (fun () ->
        let entry =
          with_project
            [ ("main.emo", {|receive {
  _ -> { println("never") }
}
|}) ]
            "main.emo"
        in
        match
          Emo_project.run_entry ~entry_file:entry ~sched:Emo_project.Own ()
        with
        | _ -> Alcotest.fail "expected E3012"
        | exception Emo_eval.Error d ->
            Alcotest.(check string)
              "code" "E3012"
              (match d.Diagnostic.code with Some c -> c | None -> "?"));
  ]

(* ---- The standard library, exercised for real ----

   The stdlib registry in the workspace serves `net` and `http`; the
   roundtrip runs one program that serves and requests over loopback. *)

(* The stdlib registry rides the build tree next to examples/ (both are
   declared source-tree deps of this rule), so the path is stable from
   the process's original working directory — earlier suites chdir into
   scratch dirs and never come back. *)
let from_original_cwd dir =
  if Filename.is_relative dir then Filename.concat original_cwd dir else dir

let use_workspace_registry () =
  let registry =
    Filename.concat (from_original_cwd "../../stdlib") "registry"
  in
  Unix.putenv "EMO_REGISTRY" registry;
  registry

(* The emo executable under test, re-anchored to the real workspace root
   when dune relativized the setenv value against the sandbox. *)
let emo_exe_path () =
  let workspace_root =
    let cwd = original_cwd in
    match
      let rec find i =
        if i < 0 then None
        else if
          String.sub cwd 0 (min i (String.length cwd))
          |> String.ends_with ~suffix:"/_build/.sandbox/"
        then Some (String.sub cwd 0 (i - String.length "/_build/.sandbox/" + 1))
        else find (i - 1)
      in
      find (String.length cwd)
    with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  match Sys.getenv_opt "EMO_EXE" with
  | Some path when Filename.is_relative path ->
      let tail =
        if String.length path > 6 && String.sub path 0 6 = "../../" then
          String.sub path 6 (String.length path - 6)
        else path
      in
      Filename.concat workspace_root tail
  | Some path -> path
  | None -> Alcotest.fail "EMO_EXE is not set"

(* Builds [source] with `emo build` and returns (build output, exit
   status, binary path). Pinned to the ocaml target — the tests here
   cover that backend's wrapper FFI and goldens; the c backend has its
   own CI group. *)
let build_binary ?(cclib = []) source name =
  let emo_exe = emo_exe_path () in
  let entry = with_project [ ("main.emo", source) ] "main.emo" in
  let bin = Filename.concat (Filename.dirname entry) name in
  let cclib_args =
    String.concat "" (List.concat_map (fun lib -> [ " --cclib "; lib ]) cclib)
  in
  let out = Buffer.create 256 in
  let ic =
    Unix.open_process_in
      (Printf.sprintf "exec 2>&1; %s build %s --target ocaml -o %s%s"
         (Filename.quote emo_exe) (Filename.quote entry) (Filename.quote bin)
         cclib_args)
  in
  (try
     while true do
       Buffer.add_channel out ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (Buffer.contents out, status, bin)

let stdlib_http_tests =
  [
    tc "an http server and client round-trip on localhost" (fun () ->
        use_workspace_registry () |> ignore;
        let entry =
          with_project
            [
              ( "package.emo",
                {|package {
  name = "roundtrip"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    http = "0.1.0"
    net = "0.1.0"
  }
}|}
              );
              ( "main.emo",
                {|require "http"
require "net"

const listener = net.listen("127.0.0.1", 0)

do http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(200, [], "hello from emo")
}

const resp = http.get("http://127.0.0.1:" + listener.port().to_string() + "/hello")
println(resp.body)
println(resp.status)
|}
              );
            ]
            "main.emo"
        in
        let output =
          capture_output (fun () ->
              match
                Emo_project.run_entry ~entry_file:entry ~check:true
                  ~sched:Emo_project.Own ()
              with
              | _project -> ()
              | exception Emo_project.Static_errors ds ->
                  Alcotest.fail
                    (String.concat "\n"
                       (List.map
                          (fun d ->
                            Printf.sprintf "%s at %s: %s"
                              (match d.Emo_support.Diagnostic.code with
                              | Some c -> c
                              | None -> "?")
                              (Emo_support.Span.to_string
                                 d.Emo_support.Diagnostic.span)
                              d.Emo_support.Diagnostic.message)
                          ds)))
        in
        Alcotest.(check string) "output" "hello from emo\n200\n" output);
    tc "the http_roundtrip example runs through the committed lockfile"
      (fun () ->
        use_workspace_registry () |> ignore;
        let examples =
          match Sys.getenv_opt "EMO_EXAMPLES_DIR" with
          | Some dir -> from_original_cwd dir
          | None -> Alcotest.fail "EMO_EXAMPLES_DIR is not set"
        in
        let entry = Filename.concat examples "http_roundtrip/main.emo" in
        let output =
          capture_output (fun () ->
              match
                Emo_project.run_entry ~entry_file:entry ~check:true
                  ~sched:Emo_project.Own ()
              with
              | _project -> ()
              | exception Emo_project.Static_errors ds ->
                  Alcotest.fail
                    (String.concat "\n"
                       (List.map
                          (fun d ->
                            Printf.sprintf "%s at %s: %s"
                              (match d.Emo_support.Diagnostic.code with
                              | Some c -> c
                              | None -> "?")
                              (Emo_support.Span.to_string
                                 d.Emo_support.Diagnostic.span)
                              d.Emo_support.Diagnostic.message)
                          ds)))
        in
        Alcotest.(check string) "output" "hello from emo\n200\n" output);
    tc "emo build caches by content hash across builds" (fun () ->
        use_workspace_registry () |> ignore;
        let emo_exe = emo_exe_path () in
        let entry =
          with_project [ ("main.emo", {|println(40 + 2)|}) ] "main.emo"
        in
        let bin = Filename.concat (Filename.dirname entry) "cached-prog" in
        let build () =
          let out = Buffer.create 128 in
          let ic =
            Unix.open_process_in
              (Printf.sprintf "exec 2>&1; %s build %s -o %s"
                 (Filename.quote emo_exe) (Filename.quote entry)
                 (Filename.quote bin))
          in
          (try
             while true do
               Buffer.add_channel out ic 1
             done
           with End_of_file -> ());
          ignore (Unix.close_process_in ic);
          Buffer.contents out
        in
        (* The first build compiles; the second hits the content-hash
           cache and skips the toolchain. The first build's output is
           asserted, so a failed compile surfaces here instead of as a
           confusing cache miss below. *)
        let first = build () in
        Alcotest.(check bool)
          "first build compiles" true
          (contains_substring first "built"
          && not (contains_substring first "(cached)"));
        let second = build () in
        Alcotest.(check bool)
          "second build is cached" true
          (contains_substring second "built"
          && contains_substring second "(cached)");
        ignore (build ());
        (* the binary runs and prints *)
        let ic = Unix.open_process_in bin in
        let run_out = input_line ic in
        ignore (Unix.close_process_in ic);
        Alcotest.(check string) "output" "42" run_out);
    tc "the stdlib targets are honest: native resolves, wasm refuses" (fun () ->
        let registry = use_workspace_registry () in
        let reg = Emo_pkg.Registry.Fs_dir registry in
        let index = Emo_pkg.Registry.index reg [ "http"; "net" ] in
        let roots =
          match Emo_pkg.Version.parse "0.1.0" with
          | Ok v -> [ ("http", v) ]
          | Error _ -> Alcotest.fail "bad fixture version"
        in
        (match Emo_pkg.Resolve.solve ~target:"ocaml" ~roots ~index with
        | Ok _ -> ()
        | Error errors ->
            Alcotest.fail
              (String.concat "; "
                 (List.map
                    (fun e ->
                      Printf.sprintf "%s: %s" e.Emo_pkg.Resolve.e_dep
                        e.Emo_pkg.Resolve.e_message)
                    errors)));
        match Emo_pkg.Resolve.solve ~target:"wasm" ~roots ~index with
        | Ok _ -> Alcotest.fail "expected resolution to refuse wasm"
        | Error errors ->
            let messages =
              String.concat "; "
                (List.map (fun e -> e.Emo_pkg.Resolve.e_message) errors)
            in
            Alcotest.(check string)
              "wasm refusal" "no build for target `wasm`" messages);
  ]

let ffi_tests =
  [
    tc "emo build links a foreign def and the binary calls the C symbol"
      (fun () ->
        let build_out, status, bin =
          build_binary
            {|foreign def sqrt(x Float64) Float64 = "sqrt"
println(sqrt(4.0))
println(sqrt(2.0))|}
            "ffi-prog" ~cclib:[ "m" ]
        in
        (match status with
        | Unix.WEXITED 0 -> ()
        | _ -> Alcotest.fail (Printf.sprintf "build failed: %s" build_out));
        let ic = Unix.open_process_in bin in
        let first = input_line ic in
        let second = input_line ic in
        ignore (Unix.close_process_in ic);
        Alcotest.(check string) "sqrt(4.0)" "2.0" first;
        Alcotest.(check bool)
          "sqrt(2.0)" true
          (String.length second >= 6 && String.sub second 0 6 = "1.4142"));
    tc "the interpreter refuses foreign defs with E3009" (fun () ->
        use_workspace_registry () |> ignore;
        let entry =
          with_project
            [
              ( "main.emo",
                {|foreign def sqrt(x Float64) Float64 = "sqrt"
println(sqrt(4.0))|}
              );
            ]
            "main.emo"
        in
        match
          Emo_project.run_entry ~entry_file:entry ~check:true
            ~sched:Emo_project.Own ()
        with
        | _ -> Alcotest.fail "expected the interpreter to refuse foreign defs"
        | exception Emo_eval.Error d ->
            Alcotest.(check (option string))
              "code" (Some "E3009") d.Emo_support.Diagnostic.code;
            Alcotest.(check int)
              "line" 1 d.Emo_support.Diagnostic.span.Emo_support.Span.line);
  ]

(* ---- Step 13 bootstrap: the examples/ suite as compiled binaries ----
   Every example runs through the interpreter and through `emo build`,
   and both outputs must match the example's golden file byte-for-byte. *)

let examples_dir () =
  match Sys.getenv_opt "EMO_EXAMPLES_DIR" with
  | Some dir -> from_original_cwd dir
  | None -> Alcotest.fail "EMO_EXAMPLES_DIR is not set"

let read_all ic =
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_char buf (input_char ic)
     done
   with End_of_file -> ());
  Buffer.contents buf

let capture_program_output f =
  let out = Buffer.create 256 in
  Emo_eval.set_output (Buffer.add_string out);
  Fun.protect
    ~finally:(fun () ->
      Emo_eval.set_output (fun s ->
          print_string s;
          flush stdout))
    f;
  Buffer.contents out

(* Builds the example from [root] (the build cache lands in the root's
   .emo-build directory) and returns (status, build output, binary
   path). *)
let build_example root entry name =
  let emo_exe = emo_exe_path () in
  let bin = Filename.concat root (name ^ "-bin") in
  let out = Buffer.create 256 in
  let ic =
    Unix.open_process_in
      (Printf.sprintf "exec 2>&1; cd %s && %s build %s --target ocaml -o %s"
         (Filename.quote root) (Filename.quote emo_exe) (Filename.quote entry)
         (Filename.quote bin))
  in
  (try
     while true do
       Buffer.add_channel out ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (status, Buffer.contents out, bin)

(* The bootstrap assertion for one example: the interpreter run and the
   compiled binary agree with the golden text. [expected] picks the
   golden file; the http example has none, so its fixed output is
   spelled here. [root] is the project root discovery walks from — the
   examples/ directory, except http_roundtrip which is a package of its
   own. *)
let bootstrap_example root name entry expected =
  let golden =
    if expected then
      (* Root projects keep their golden beside the entry inside
         <root>/<name>/; a package project is its own root. *)
      let nested = Filename.concat (Filename.concat root name) "expected.txt" in
      if Sys.file_exists nested then Emo_project.read_file nested
      else Emo_project.read_file (Filename.concat root "expected.txt")
    else "hello from emo\n200\n"
  in
  (* Module and package discovery root at the current directory, so the
     interpreter runs from the project root, like `emo run`. *)
  Sys.chdir root;
  let interpreted =
    capture_program_output (fun () ->
        match
          Emo_project.run_entry ~entry_file:entry ~check:true
            ~sched:Emo_project.Own ()
        with
        | _project -> ()
        | exception Emo_project.Static_errors ds ->
            Alcotest.fail
              (String.concat "\n"
                 (List.map
                    (fun d ->
                      Printf.sprintf "%s at %s: %s"
                        (match d.Emo_support.Diagnostic.code with
                        | Some c -> c
                        | None -> "?")
                        (Emo_support.Span.to_string
                           d.Emo_support.Diagnostic.span)
                        d.Emo_support.Diagnostic.message)
                    ds)))
  in
  Alcotest.(check string)
    (name ^ ": interpreter matches golden")
    golden interpreted;
  let status, build_out, bin = build_example root entry name in
  (match status with
  | Unix.WEXITED 0 -> ()
  | _ -> Alcotest.fail (Printf.sprintf "%s: build failed: %s" name build_out));
  let ic = Unix.open_process_in bin in
  let compiled = read_all ic in
  ignore (Unix.close_process_in ic);
  Alcotest.(check string)
    (name ^ ": binary matches interpreter")
    interpreted compiled

let bootstrap_tests =
  [
    tc "fib compiles to a binary with the interpreter's output" (fun () ->
        bootstrap_example (examples_dir ()) "fib" "fib/main.emo" true);
    tc "hello_world compiles to a binary with the interpreter's output"
      (fun () ->
        bootstrap_example (examples_dir ()) "hello_world" "hello_world/main.emo"
          true);
    tc "objects compiles to a binary with the interpreter's output" (fun () ->
        bootstrap_example (examples_dir ()) "objects" "objects/main.emo" true);
    tc "language_tour compiles to a binary with the interpreter's output"
      (fun () ->
        bootstrap_example (examples_dir ()) "language_tour"
          "language_tour/main.emo" true);
    tc "shop compiles to a binary with the interpreter's output" (fun () ->
        bootstrap_example
          (Filename.concat (examples_dir ()) "shop")
          "shop" "main.emo" true);
    tc "pipeline compiles to a binary with the interpreter's output" (fun () ->
        bootstrap_example (examples_dir ()) "pipeline" "pipeline/main.emo" true);
    tc "list compiles to a binary with the interpreter's output" (fun () ->
        bootstrap_example (examples_dir ()) "list" "list/main.emo" true);
    tc "tcp_echo compiles to a binary with the interpreter's output" (fun () ->
        use_workspace_registry () |> ignore;
        bootstrap_example
          (Filename.concat (examples_dir ()) "tcp_echo")
          "tcp_echo" "main.emo" true);
    tc "http_roundtrip compiles to a binary with the interpreter's output"
      (fun () ->
        use_workspace_registry () |> ignore;
        bootstrap_example
          (Filename.concat (examples_dir ()) "http_roundtrip")
          "http_roundtrip" "main.emo" false);
    tc "json_demo compiles to a binary with the interpreter's output" (fun () ->
        use_workspace_registry () |> ignore;
        bootstrap_example
          (Filename.concat (examples_dir ()) "json_demo")
          "json_demo" "main.emo" true);
    tc "json_edge compiles to a binary with the interpreter's output" (fun () ->
        use_workspace_registry () |> ignore;
        bootstrap_example
          (Filename.concat (examples_dir ()) "json_edge")
          "json_edge" "main.emo" true);
  ]

(* ---- The TypeScript target (step 15) ----

   Each core example builds with --target typescript and the emitted
   program, run on Node, must match the example's golden output. *)
let ts_golden_tests =
  List.map
    (fun (name, entry) ->
      tc
        (Printf.sprintf
           "%s compiles to TypeScript with the interpreter's output" name)
        (fun () ->
          let dir = Filename.concat (examples_dir ()) name in
          let golden =
            Emo_project.read_file (Filename.concat dir "expected.txt")
          in
          Sys.chdir dir;
          let emo_exe = emo_exe_path () in
          let out = Filename.concat dir (name ^ "-ts-out") in
          let build =
            Printf.sprintf "exec 2>&1; %s build %s --target typescript -o %s"
              (Filename.quote emo_exe) (Filename.quote entry)
              (Filename.quote out)
          in
          let build_out = read_all (Unix.open_process_in build) in
          if not (Sys.file_exists (out ^ ".ts")) then
            Alcotest.fail ("build failed: " ^ build_out);
          let compiled =
            read_all
              (Unix.open_process_in ("node " ^ Filename.quote (out ^ ".ts")))
          in
          Alcotest.(check string)
            (name ^ ": typescript matches golden")
            golden compiled))
    [
      ("hello_world", "main.emo");
      ("fib", "main.emo");
      ("objects", "main.emo");
      ("function_group", "main.emo");
      ("showcase", "main.emo");
      ("bit_ops", "main.emo");
      ("fixed_width", "main.emo");
      ("list", "main.emo");
      ("map", "main.emo");
      ("json_demo", "main.emo");
    ]

let () =
  Alcotest.run "emo_project"
    [
      ("resolution", resolution_tests);
      ("load", load_tests);
      ("privacy", privacy_tests);
      ("cycle", cycle_tests);
      ("cache", cache_tests);
      ("deps", deps_tests);
      ("install", install_tests);
      ("sched", sched_tests);
      ("shop_golden", shop_golden_tests);
      ("stdlib_http", stdlib_http_tests);
      ("ffi", ffi_tests);
      ("bootstrap", bootstrap_tests);
      ("ts_golden", ts_golden_tests);
    ]
