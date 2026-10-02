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
                 ("shop/order.emo", {|def total(n Int) Int {
  return n * 2
}|});
                 ("shop/checkout.emo", {|print(shop.order.total(21))|});
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check string) "output" "42\n" output);
    tc "aliasing a module is ordinary binding" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ("shop/order.emo", {|def total(n Int) Int {
  return n * 2
}|});
                 ( "shop/checkout.emo",
                   {|const order = shop.order
print(order.total(4))|} );
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
                   {|print("loading order")
def total(n Int) Int {
  return n
}|}
                 );
                 ( "shop/checkout.emo",
                   {|print(shop.order.total(1))
print(shop.order.total(2))|} );
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
                 ("shop/checkout.emo", {|print(shop.order.nope)|});
               ]
               "shop/checkout.emo")
        in
        Alcotest.(check bool) "E5004" true (contains_substring output "E5004"));
    tc "an unbound non-module name is still unbound" (fun () ->
        let output =
          run_entry
            (with_project
               [
                 ("shop/order.emo", ""); ("shop/checkout.emo", {|print(nope)|});
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
              ("main.emo", {|print(helper.run())|});
              ("helper.emo", {|def run() Int {
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
              ("shop/order.emo", {|def total(n Int) Int {
  return n * 2
}|});
              ("shop/checkout.emo", {|print(shop.order.total(21))|});
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
    tc "the README shop tree runs verbatim from its root" (fun () ->
        (* The dune rule passes the workspace's examples/ directory. *)
        (* dune materializes the declared examples/ dependency at its
           workspace-relative path, two levels up from this rule's dir. *)
        Sys.chdir (Filename.concat original_cwd "../../examples");
        let out = Buffer.create 64 in
        Emo_eval.set_output (Buffer.add_string out);
        Fun.protect
          ~finally:(fun () ->
            Emo_eval.set_output (fun s ->
                print_string s;
                flush stdout))
          (fun () ->
            ignore
              (Emo_project.run_entry ~entry_file:"shop/checkout.emo" ~check:true
                 ()));
        Alcotest.(check string) "output" "42\n30\n" (Buffer.contents out));
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
  targets = ["native"]
  deps {}
}
|};
  write_file
    (Filename.concat pkg_dir "json_tools.emo")
    {|def parse(s String) String {
  return s
}
|};
  dir

let app_manifest =
  {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["native"]

  deps {
    acme/json_tools = "2.3.1"
  }
}
|}

let app_main = {|require "acme/json_tools"
print(json_tools.parse("hello"))
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
            Alcotest.(check string) "output" "hello\n" output;
            (* A run resolves in memory when no lockfile exists; writing the
               lockfile is `emo deps resolve`'s explicit job. *)
            Alcotest.(check bool)
              "no lockfile written by a run" false
              (Sys.file_exists (Filename.concat dir "emo.lock"))));
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
                ~manifest_dir:dir
            in
            Alcotest.(check int) "count" 1 (List.length entries);
            (match entries with
            | [ e ] ->
                Alcotest.(check string)
                  "dep" "acme/json_tools" e.Emo_pkg.Lockfile.dep;
                Alcotest.(check string)
                  "version" "2.3.1"
                  (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version);
                Alcotest.(check bool)
                  "checksum present" true
                  (String.length e.Emo_pkg.Lockfile.checksum > 0)
            | _ -> ());
            Emo_pkg.Lockfile.write
              ~path:(Filename.concat dir "emo.lock")
              entries;
            let output =
              capture_output (fun () ->
                  ignore
                    (Emo_project.run_entry ~entry_file:entry ~check:true ()))
            in
            Alcotest.(check string) "output" "hello\n" output;
            (* A lockfile drifting from the manifest is an error prompting
               explicit regeneration — never a silent re-resolve. *)
            Emo_pkg.Lockfile.write
              ~path:(Filename.concat dir "emo.lock")
              [
                {
                  Emo_pkg.Lockfile.dep = "acme/json_tools";
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
  targets = ["native"]
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
  targets = ["native"]

  deps {
    acme/json_tools = "9.8.7"
  }
}
|}
              );
              ("main.emo", {|print("plain")|});
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
  ]

let sched_tests =
  [
    tc "the own scheduler runs a process program end to end" (fun () ->
        let entry =
          with_project
            [
              ( "main.emo",
                {|def worker(reply_to Pid) Int {
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
  v -> { print(v) }
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
  _ -> { print("never") }
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
  targets = ["native"]

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
print(resp.body)
print(resp.status)
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
    tc "the stdlib targets are honest: native resolves, wasm refuses" (fun () ->
        let registry = use_workspace_registry () in
        let reg = { Emo_pkg.Registry.endpoint = registry } in
        let index = Emo_pkg.Registry.index reg [ "http"; "net" ] in
        let roots =
          match Emo_pkg.Version.parse "0.1.0" with
          | Ok v -> [ ("http", v) ]
          | Error _ -> Alcotest.fail "bad fixture version"
        in
        (match Emo_pkg.Resolve.solve ~target:"native" ~roots ~index with
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

let () =
  Alcotest.run "emo_project"
    [
      ("resolution", resolution_tests);
      ("load", load_tests);
      ("privacy", privacy_tests);
      ("cycle", cycle_tests);
      ("cache", cache_tests);
      ("deps", deps_tests);
      ("sched", sched_tests);
      ("shop_golden", shop_golden_tests);
      ("stdlib_http", stdlib_http_tests);
    ]
