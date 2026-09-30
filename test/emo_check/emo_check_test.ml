let tc name f = Alcotest.test_case name `Quick f

let smoke_tests =
  [ tc "library links" (fun () -> let module M = Emo_check in ()) ]

let () = Alcotest.run "emo_check" [ ("smoke", smoke_tests) ]
