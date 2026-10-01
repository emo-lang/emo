open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let span =
  Emo_support.Span.make ~file:"test.emo" ~line:1 ~col:1 ~start:0 ~stop:1

let value : Emo_eval.value Alcotest.testable =
  let pp fmt = function
    | Emo_eval.Int n -> Format.pp_print_int fmt n
    | Emo_eval.String s -> Format.fprintf fmt "%S" s
    | Emo_eval.Bool b -> Format.fprintf fmt "%b" b
    | v -> Format.fprintf fmt "<%s>" (Emo_eval.type_name v)
  in
  Alcotest.testable pp Emo_eval.equal_value

let diag_err f =
  match f () with
  | _ -> Alcotest.fail "expected a runtime error"
  | exception Emo_eval.Error diagnostic -> diagnostic

let code_of diagnostic =
  match diagnostic.Emo_support.Diagnostic.code with Some c -> c | None -> ""

let equality_tests =
  [
    tc "equal tuples compare element-wise" (fun () ->
        Alcotest.check value "tuples"
          (Emo_eval.Tuple [ Emo_eval.Int 1; Emo_eval.String "a" ])
          (Emo_eval.Tuple [ Emo_eval.Int 1; Emo_eval.String "a" ]));
    tc "tuples of different lengths are not equal" (fun () ->
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value (Emo_eval.Tuple [ Emo_eval.Int 1 ])
             (Emo_eval.Tuple [ Emo_eval.Int 1; Emo_eval.Int 2 ])));
    tc "arrays compare element-wise" (fun () ->
        Alcotest.check value "arrays"
          (Emo_eval.Array [| Emo_eval.Int 1; Emo_eval.Int 2 |])
          (Emo_eval.Array [| Emo_eval.Int 1; Emo_eval.Int 2 |]);
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value (Emo_eval.Array [| Emo_eval.Int 1 |])
             (Emo_eval.Array [| Emo_eval.Int 2 |])));
    tc "boxes compare by current contents" (fun () ->
        Alcotest.check value "boxes"
          (Emo_eval.Box (ref (Emo_eval.Int 1)))
          (Emo_eval.Box (ref (Emo_eval.Int 1)));
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value
             (Emo_eval.Box (ref (Emo_eval.Bool true)))
             (Emo_eval.Box (ref (Emo_eval.Bool false)))));
    tc "different tags are never equal" (fun () ->
        Alcotest.(check bool)
          "int vs float" false
          (Emo_eval.equal_value (Emo_eval.Int 1) (Emo_eval.Float 1.0));
        Alcotest.(check bool)
          "string vs char" false
          (Emo_eval.equal_value (Emo_eval.String "a") (Emo_eval.Char 'a')));
    tc "enum members match by type and member name" (fun () ->
        Alcotest.check value "same"
          (Emo_eval.EnumMember ("Color", "red"))
          (Emo_eval.EnumMember ("Color", "red"));
        Alcotest.(check bool)
          "other member" false
          (Emo_eval.equal_value
             (Emo_eval.EnumMember ("Color", "red"))
             (Emo_eval.EnumMember ("Color", "blue"))));
  ]

let env_tests =
  [
    tc "lookup walks the parent chain" (fun () ->
        let global = Emo_eval.global_env () in
        Emo_eval.define global "x" ~mutable_:false (Emo_eval.Int 1);
        let inner = Emo_eval.child global in
        Alcotest.check value "through chain" (Emo_eval.Int 1)
          (Emo_eval.lookup inner span "x"));
    tc "a child frame shadows its parent" (fun () ->
        let global = Emo_eval.global_env () in
        Emo_eval.define global "x" ~mutable_:false (Emo_eval.Int 1);
        let inner = Emo_eval.child global in
        Emo_eval.define inner "x" ~mutable_:false (Emo_eval.Int 2);
        Alcotest.check value "shadowed" (Emo_eval.Int 2)
          (Emo_eval.lookup inner span "x");
        Alcotest.check value "parent intact" (Emo_eval.Int 1)
          (Emo_eval.lookup global span "x"));
    tc "an unbound name is a runtime error" (fun () ->
        let env = Emo_eval.global_env () in
        let diagnostic = diag_err (fun () -> Emo_eval.lookup env span "nope") in
        Alcotest.(check string) "code" "E3002" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Emo_support.Span.to_string diagnostic.Diagnostic.span));
    tc "assignment reaches the frame that owns the binding" (fun () ->
        let global = Emo_eval.global_env () in
        Emo_eval.define global "x" ~mutable_:true (Emo_eval.Int 1);
        let inner = Emo_eval.child global in
        Emo_eval.assign inner span "x" (Emo_eval.Int 7);
        Alcotest.check value "mutated" (Emo_eval.Int 7)
          (Emo_eval.lookup global span "x"));
    tc "assignment to a const is a runtime error" (fun () ->
        let env = Emo_eval.global_env () in
        Emo_eval.define env "x" ~mutable_:false (Emo_eval.Int 1);
        let diagnostic =
          diag_err (fun () -> Emo_eval.assign env span "x" (Emo_eval.Int 2))
        in
        Alcotest.(check string) "code" "E3003" (code_of diagnostic);
        Alcotest.check value "unchanged" (Emo_eval.Int 1)
          (Emo_eval.lookup env span "x"));
    tc "assignment to an unbound name is a runtime error" (fun () ->
        let env = Emo_eval.global_env () in
        let diagnostic =
          diag_err (fun () -> Emo_eval.assign env span "x" (Emo_eval.Int 2))
        in
        Alcotest.(check string) "code" "E3003" (code_of diagnostic));
  ]

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_eval in
        ());
  ]

let () =
  Alcotest.run "emo_eval"
    [ ("smoke", smoke_tests); ("equality", equality_tests); ("env", env_tests) ]
