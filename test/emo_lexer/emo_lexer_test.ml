let tc name f = Alcotest.test_case name `Quick f

let smoke_tests =
  [ tc "library links" (fun () -> let module M = Emo_lexer in ()) ]

let () = Alcotest.run "emo_lexer" [ ("smoke", smoke_tests) ]
