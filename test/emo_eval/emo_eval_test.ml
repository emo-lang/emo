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

(* Evaluates one expression in a fresh global environment. *)
let eval_expr source =
  let e = Emo_parser.parse_expr_source ~file:"test.emo" ~source in
  Emo_eval.eval_expr (Emo_eval.global_env ()) e

let eval_err source =
  match eval_expr source with
  | _ -> Alcotest.fail "expected a runtime error"
  | exception Emo_eval.Error diagnostic -> diagnostic

let check_value name expected source =
  Alcotest.check value name expected (eval_expr source)

(* Runs a newline-separated statement list in one environment. *)
let run_stmts source =
  let items = Emo_parser.parse_program ~file:"test.emo" ~source in
  let env = Emo_eval.global_env () in
  List.iter
    (fun item ->
      match item.Emo_ast.item_desc with
      | Emo_ast.Item_stmt s -> Emo_eval.eval_stmt env s
      | _ -> Alcotest.fail "expected statements only")
    items;
  env

(* Runs a whole program with stdout captured into a buffer. *)
let run_program source =
  let buf = Buffer.create 64 in
  Emo_eval.set_output (Buffer.add_string buf);
  Fun.protect
    ~finally:(fun () ->
      Emo_eval.set_output (fun s ->
          print_string s;
          flush stdout))
    (fun () ->
      let items = Emo_parser.parse_program ~file:"test.emo" ~source in
      let env = Emo_eval.global_env () in
      List.iter (Emo_eval.eval_item env) items);
  Buffer.contents buf

let program_err source =
  match run_program source with
  | _ -> Alcotest.fail "expected a runtime error"
  | exception Emo_eval.Error diagnostic -> diagnostic

let expression_tests =
  [
    tc "arithmetic respects precedence and promotion" (fun () ->
        check_value "ints" (Emo_eval.Int 7) "1 + 2 * 3";
        check_value "promoted" (Emo_eval.Float 3.5) "1 + 2.5";
        check_value "float math" (Emo_eval.Float 2.0) "1.5 * 4 / 3";
        check_value "unary minus" (Emo_eval.Int (-3)) "-3");
    tc "division and modulo" (fun () ->
        check_value "int div" (Emo_eval.Int 3) "7 / 2";
        check_value "int mod" (Emo_eval.Int 1) "7 % 2";
        check_value "float div" (Emo_eval.Float 3.5) "7.0 / 2";
        let diagnostic = eval_err "1 / 0" in
        Alcotest.(check string) "code" "E3005" (code_of diagnostic));
    tc "string concatenation is +" (fun () ->
        check_value "concat" (Emo_eval.String "ab") "\"a\" + \"b\"";
        let diagnostic = eval_err "\"a\" + 1" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic);
        Alcotest.(check string)
          "names the tags"
          "operator `+` expects two numbers or two strings, got String and Int"
          diagnostic.Diagnostic.message);
    tc "comparisons work on numbers" (fun () ->
        check_value "less" (Emo_eval.Bool true) "1 < 2";
        check_value "promoted" (Emo_eval.Bool true) "1.5 >= 1";
        let diagnostic = eval_err "\"a\" < \"b\"" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "logic accepts Bools only" (fun () ->
        check_value "and" (Emo_eval.Bool false) "true && false";
        check_value "or" (Emo_eval.Bool true) "false || true";
        check_value "not" (Emo_eval.Bool false) "!true";
        let diagnostic = eval_err "1 && true" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "equality is deep and tag-strict" (fun () ->
        check_value "arrays" (Emo_eval.Bool true) "[1, 2] == [1, 2]";
        check_value "nested tuples" (Emo_eval.Bool true)
          "(1, (\"a\", \"b\")) == (1, (\"a\", \"b\"))";
        check_value "cross-tag" (Emo_eval.Bool false) "1 == 1.0";
        check_value "not-equal" (Emo_eval.Bool true) "(1, \"a\") != (1, \"b\")");
    tc "indexing reads arrays and tuples" (fun () ->
        check_value "array" (Emo_eval.Int 20) "[10, 20][1]";
        check_value "tuple" (Emo_eval.Int 7) "(7, 8)[0]";
        let diagnostic = eval_err "[1][5]" in
        Alcotest.(check string) "code" "E3004" (code_of diagnostic);
        let diagnostic = eval_err "[1][\"a\"]" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "arrow blocks are callable" (fun () ->
        check_value "call" (Emo_eval.Int 3) "-> (x Int) { return x + 1 }(2)";
        check_value "named args" (Emo_eval.Int 12)
          "-> (x Int, y Int) { return x * 10 + y }(x: 1, y: 2)");
    tc "call errors name the problem" (fun () ->
        let diagnostic = eval_err "-> (x Int) { return x }(2, 3)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic = eval_err "-> (x Int) { return x }(y: 1)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic = eval_err "1(2)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
    tc "statements bind and assign" (fun () ->
        let env = run_stmts "const x = 1\nvar y = x + 1\ny = y * 10" in
        Alcotest.check value "y rebound" (Emo_eval.Int 20)
          (Emo_eval.lookup env span "y"));
    tc "assigning a const is caught at runtime" (fun () ->
        let diagnostic =
          diag_err (fun () -> ignore (run_stmts "const x = 1\nx = 2"))
        in
        Alcotest.(check string) "code" "E3003" (code_of diagnostic));
  ]

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_eval in
        ());
  ]

let io_tests =
  [
    tc "to_string renders every primitive" (fun () ->
        let check_str name expected v =
          Alcotest.(check string) name expected (Emo_eval.to_string v)
        in
        check_str "int" "42" (Emo_eval.Int 42);
        check_str "negative int" "-7" (Emo_eval.Int (-7));
        check_str "whole float" "1.0" (Emo_eval.Float 1.0);
        check_str "fractional float" "2.5" (Emo_eval.Float 2.5);
        check_str "bool" "true" (Emo_eval.Bool true);
        check_str "char" "a" (Emo_eval.Char 'a');
        check_str "string" "hi" (Emo_eval.String "hi");
        check_str "tuple" "(1, a)"
          (Emo_eval.Tuple [ Emo_eval.Int 1; Emo_eval.String "a" ]);
        check_str "array" "[1, 2]"
          (Emo_eval.Array [| Emo_eval.Int 1; Emo_eval.Int 2 |]));
    tc "interpolation stringifies left to right" (fun () ->
        check_value "interp" (Emo_eval.String "a 3 b true")
          "\"a ${1 + 2} b ${true}\"");
    tc "to_string is callable on values" (fun () ->
        check_value "int" (Emo_eval.String "42") "42.to_string()");
    tc "print writes through the output hook" (fun () ->
        let buf = Buffer.create 16 in
        Emo_eval.set_output (Buffer.add_string buf);
        Fun.protect
          ~finally:(fun () ->
            Emo_eval.set_output (fun s ->
                print_string s;
                flush stdout))
          (fun () -> ignore (run_stmts "print(1 + 1)\nprint(1.0)"));
        Alcotest.(check string) "output" "2\n1.0\n" (Buffer.contents buf));
    tc "length works on arrays and tuples" (fun () ->
        check_value "array" (Emo_eval.Int 3) "[1, 2, 3].length()";
        check_value "tuple" (Emo_eval.Int 2) "(1, 2).length()");
    tc "Box constructs, reads, replaces" (fun () ->
        check_value "read" (Emo_eval.Int 2)
          "-> {\n  const b = Box.new(1)\n  b.replace(2)\n  return b.read()\n}()";
        check_value "replace returns the new value" (Emo_eval.String "x")
          "Box.new(0).replace(\"x\")");
    tc "method errors name the receiver and method" (fun () ->
        let diagnostic = eval_err "1.frobnicate()" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        Alcotest.(check string)
          "message" "Int has no method `frobnicate`"
          diagnostic.Diagnostic.message;
        let diagnostic = eval_err "Box.new()" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
  ]

let closure_tests =
  [
    tc "defs register closures and recurse" (fun () ->
        Alcotest.(check string)
          "fib" "55\n"
          (run_program
             {|def fib(n Int) Int {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
print(fib(10))|}));
    tc "a def may call a def defined after it" (fun () ->
        Alcotest.(check string)
          "forward reference" "true\nfalse\n"
          (run_program
             {|def is_even(n Int) Bool {
  if n == 0 {
    return true
  }
  return is_odd(n - 1)
}

def is_odd(n Int) Bool {
  if n == 0 {
    return false
  }
  return is_even(n - 1)
}
print(is_even(4))
print(is_even(5))|}));
    tc "closures see bindings that appear after their definition" (fun () ->
        Alcotest.(check string)
          "by reference" "42\n"
          (run_program
             {|const later = -> {
  return x + 1
}
const x = 41
print(later())|}));
    tc "closures share the enclosing frame across calls" (fun () ->
        Alcotest.(check string)
          "counter" "1\n2\n"
          (run_program
             {|const make_counter = -> {
  const count = Box.new(0)
  return -> {
    count.replace(count.read() + 1)
    return count.read()
  }
}
const tick = make_counter()
print(tick())
print(tick())|}));
    tc "an unbound name fails at call time" (fun () ->
        let diagnostic = program_err "print(nope)" in
        Alcotest.(check string) "code" "E3002" (code_of diagnostic));
    tc "declaration items are still not evaluated" (fun () ->
        let diagnostic = program_err "class User {}" in
        Alcotest.(check string) "code" "E3009" (code_of diagnostic));
  ]

let () =
  Alcotest.run "emo_eval"
    [
      ("smoke", smoke_tests);
      ("equality", equality_tests);
      ("env", env_tests);
      ("expression", expression_tests);
      ("io", io_tests);
      ("closure", closure_tests);
    ]
