let tc name f = Alcotest.test_case name `Quick f

let smoke_tests =
  [
    tc "library links" (fun () -> let module M = Emo_cli in ());
    tc "version matches the CLI contract" (fun () ->
        Alcotest.(check string) "version" "0.0.1" Emo_cli.version);
  ]

let () = Alcotest.run "emo_cli" [ ("smoke", smoke_tests) ]
