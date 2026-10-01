open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-project-fixtures"

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

(* Writes files into a scratch project. *)
let write_project files =
  if Sys.file_exists scratch then
    (* best-effort clean slate per run *)
    ignore
      (Sys.command
         ("rm -rf " ^ Filename.quote scratch ^ " 2>/dev/null || true"));
  List.iter
    (fun (rel, source) ->
      let path = Filename.concat scratch rel in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
      let oc = open_out_bin path in
      output_string oc source;
      close_out oc)
    files

(* Writes files into a scratch project and discovers it with the scratch
   directory as the working-directory root. *)
let discover files entry =
  write_project files;
  Sys.chdir scratch;
  Emo_project.discover ~entry_file:entry

let with_project files entry =
  write_project files;
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
        let _, _, errors = Emo_project.check_project p in
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
        let _, _, errors = Emo_project.check_project p in
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
        let _, _, errors = Emo_project.check_project p in
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
        let _, _, errors = Emo_project.check_project p in
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

let () =
  Alcotest.run "emo_project"
    [
      ("resolution", resolution_tests);
      ("load", load_tests);
      ("privacy", privacy_tests);
      ("cycle", cycle_tests);
      ("cache", cache_tests);
    ]
