open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let codes_of diagnostics =
  List.map
    (fun d -> match d.Diagnostic.code with Some c -> c | None -> "?")
    diagnostics

let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-project-fixtures"

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

(* Writes files into a scratch project and discovers it from entry. *)
let discover files entry =
  write_project files;
  Emo_project.discover ~entry_file:(Filename.concat scratch entry)

let with_project files entry =
  write_project files;
  Filename.concat scratch entry

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
        let resolve path =
          Emo_project.resolve p (Emo_project.normalize p path)
        in
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
          (match
             Emo_project.resolve p (Emo_project.normalize p [ "shop"; "nope" ])
           with
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
    tc "the root-name prefix is elided" (fun () ->
        let p = discover [ ("shop/order.emo", "") ] "shop/order.emo" in
        Alcotest.(check bool)
          "elided resolves" true
          (match
             Emo_project.resolve p (Emo_project.normalize p [ "shop"; "order" ])
           with
          | Some (File f) -> String.contains f 'o'
          | _ -> false);
        (* normalize only strips the leading project name *)
        let path =
          Emo_project.normalize p [ "shop"; "internal"; "discounts" ]
        in
        Alcotest.(check int) "stripped to two segments" 2 (List.length path));
  ]

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
      try Emo_project.run_entry ~entry_file:source () with
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
      | Failure message -> Buffer.add_string out ("failure: " ^ message)
      | e -> Buffer.add_string out ("EXC: " ^ Printexc.to_string e))

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

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

let () =
  Alcotest.run "emo_project"
    [ ("resolution", resolution_tests); ("load", load_tests) ]

let () =
  Alcotest.run "emo_project"
    [ ("resolution", resolution_tests); ("load", load_tests) ]
