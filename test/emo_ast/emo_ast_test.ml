let tc name f = Alcotest.test_case name `Quick f
let span = Emo_support.Span.make ~file:"a.emo" ~line:1 ~col:1 ~start:0 ~stop:1

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_ast in
        ());
    tc "nodes carry their spans" (fun () ->
        let e = Emo_ast.{ span; desc = Int64 1L } in
        Alcotest.(check int) "start" 0 e.Emo_ast.span.Emo_support.Span.start;
        let call =
          Emo_ast.
            {
              span;
              desc =
                Call
                  ( { span; desc = Ident "f" },
                    [
                      {
                        arg_name = Some "k";
                        arg_value = { span; desc = Bool true };
                      };
                    ] );
            }
        in
        match call.Emo_ast.desc with
        | Call (_, args) ->
            Alcotest.(check bool)
              "named arg" true
              (match args with
              | [ { arg_name; _ } ] -> arg_name <> None
              | _ -> false)
        | _ -> Alcotest.fail "expected a call");
  ]

let () = Alcotest.run "emo_ast" [ ("smoke", smoke_tests) ]
