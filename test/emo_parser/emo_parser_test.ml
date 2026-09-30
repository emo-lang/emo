let tc name f = Alcotest.test_case name `Quick f

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_parser in
        ());
  ]

let () = Alcotest.run "emo_parser" [ ("smoke", smoke_tests) ]
