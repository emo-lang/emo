let tc name f = Alcotest.test_case name `Quick f

let smoke_tests =
  [ tc "library links" (fun () -> let module M = Emo_eval in ()) ]

let () = Alcotest.run "emo_eval" [ ("smoke", smoke_tests) ]
