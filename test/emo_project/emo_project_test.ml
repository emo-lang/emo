open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let codes_of diagnostics =
  List.map
    (fun d -> match d.Diagnostic.code with Some c -> c | None -> "?")
    diagnostics

let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-project-fixtures"

(* Writes files into a scratch project and discovers it from entry. *)
let with_project files entry =
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
    files;
  Emo_project.discover ~entry_file:(Filename.concat scratch entry)

let resolution_tests =
  [
    tc "the shop tree resolves every module" (fun () ->
        let p =
          with_project
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
        let p = with_project [ ("shop/order.emo", "") ] "shop/order.emo" in
        Alcotest.(check bool)
          "nope" false
          (match
             Emo_project.resolve p (Emo_project.normalize p [ "shop"; "nope" ])
           with
          | Some _ -> true
          | None -> false));
    tc "a file and directory with one stem collide" (fun () ->
        let p =
          with_project
            [ ("shop/order.emo", ""); ("shop/order/util.emo", "") ]
            "shop/order.emo"
        in
        Alcotest.(check bool)
          "E5005" true
          (List.mem "E5005" (codes_of (Emo_project.diagnostics p))));
    tc "the root-name prefix is elided" (fun () ->
        let p = with_project [ ("shop/order.emo", "") ] "shop/order.emo" in
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

let () = Alcotest.run "emo_project" [ ("resolution", resolution_tests) ]
