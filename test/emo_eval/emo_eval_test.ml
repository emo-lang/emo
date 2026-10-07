open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

let index_of hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then -1
    else if String.equal (String.sub hay i n) needle then i
    else go (i + 1)
  in
  go 0

let span =
  Emo_support.Span.make ~file:"test.emo" ~line:1 ~col:1 ~start:0 ~stop:1

let value : Emo_eval.value Alcotest.testable =
  let pp fmt = function
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
          (Emo_eval.Tuple [ Emo_eval.Int64 1L; Emo_eval.String "a" ])
          (Emo_eval.Tuple [ Emo_eval.Int64 1L; Emo_eval.String "a" ]));
    tc "tuples of different lengths are not equal" (fun () ->
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value (Emo_eval.Tuple [ Emo_eval.Int64 1L ])
             (Emo_eval.Tuple [ Emo_eval.Int64 1L; Emo_eval.Int64 2L ])));
    tc "arrays compare element-wise" (fun () ->
        Alcotest.check value "arrays"
          (Emo_eval.Array [| Emo_eval.Int64 1L; Emo_eval.Int64 2L |])
          (Emo_eval.Array [| Emo_eval.Int64 1L; Emo_eval.Int64 2L |]);
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value (Emo_eval.Array [| Emo_eval.Int64 1L |])
             (Emo_eval.Array [| Emo_eval.Int64 2L |])));
    tc "boxes compare by current contents" (fun () ->
        Alcotest.check value "boxes"
          (Emo_eval.Box (ref (Emo_eval.Int64 1L)))
          (Emo_eval.Box (ref (Emo_eval.Int64 1L)));
        Alcotest.(check bool)
          "unequal" false
          (Emo_eval.equal_value
             (Emo_eval.Box (ref (Emo_eval.Bool true)))
             (Emo_eval.Box (ref (Emo_eval.Bool false)))));
    tc "different tags are never equal" (fun () ->
        Alcotest.(check bool)
          "int vs float" false
          (Emo_eval.equal_value (Emo_eval.Int64 1L) (Emo_eval.Float 1.0));
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
        Emo_eval.define global "x" ~mutable_:false (Emo_eval.Int64 1L);
        let inner = Emo_eval.child global in
        Alcotest.check value "through chain" (Emo_eval.Int64 1L)
          (Emo_eval.lookup inner span "x"));
    tc "a child frame shadows its parent" (fun () ->
        let global = Emo_eval.global_env () in
        Emo_eval.define global "x" ~mutable_:false (Emo_eval.Int64 1L);
        let inner = Emo_eval.child global in
        Emo_eval.define inner "x" ~mutable_:false (Emo_eval.Int64 2L);
        Alcotest.check value "shadowed" (Emo_eval.Int64 2L)
          (Emo_eval.lookup inner span "x");
        Alcotest.check value "parent intact" (Emo_eval.Int64 1L)
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
        Emo_eval.define global "x" ~mutable_:true (Emo_eval.Int64 1L);
        let inner = Emo_eval.child global in
        Emo_eval.assign inner span "x" (Emo_eval.Int64 7L);
        Alcotest.check value "mutated" (Emo_eval.Int64 7L)
          (Emo_eval.lookup global span "x"));
    tc "assignment to a const is a runtime error" (fun () ->
        let env = Emo_eval.global_env () in
        Emo_eval.define env "x" ~mutable_:false (Emo_eval.Int64 1L);
        let diagnostic =
          diag_err (fun () -> Emo_eval.assign env span "x" (Emo_eval.Int64 2L))
        in
        Alcotest.(check string) "code" "E3003" (code_of diagnostic);
        Alcotest.check value "unchanged" (Emo_eval.Int64 1L)
          (Emo_eval.lookup env span "x"));
    tc "assignment to an unbound name is a runtime error" (fun () ->
        let env = Emo_eval.global_env () in
        let diagnostic =
          diag_err (fun () -> Emo_eval.assign env span "x" (Emo_eval.Int64 2L))
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
    (fun () -> Emo_eval.run_program ~file:"test.emo" ~source);
  Buffer.contents buf

let program_err source =
  match run_program source with
  | _ -> Alcotest.fail "expected a runtime error"
  | exception Emo_eval.Error diagnostic -> diagnostic

let expression_tests =
  [
    tc "the if expression evaluates the taken branch" (fun () ->
        check_value "true arm" (Emo_eval.Int64 1L) "if true { 1 } else { 2 }";
        check_value "false arm" (Emo_eval.Int64 2L) "if false { 1 } else { 2 }";
        check_value "nested" (Emo_eval.String "b")
          "if false { \"a\" } else { if true { \"b\" } else { \"c\" } }";
        check_value "as operand" (Emo_eval.Int64 30L)
          "10 * (if 1 < 2 { 3 } else { 4 })");
    tc "the if expression's condition must be a Bool at runtime" (fun () ->
        let diagnostic = eval_err "if 1 { 2 } else { 3 }" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "arithmetic respects precedence and promotion" (fun () ->
        check_value "ints" (Emo_eval.Int64 7L) "1 + 2 * 3";
        check_value "promoted" (Emo_eval.Float 3.5) "1 + 2.5";
        check_value "float math" (Emo_eval.Float 2.0) "1.5 * 4 / 3";
        check_value "unary minus" (Emo_eval.Int64 (-3L)) "-3");
    tc "division and modulo" (fun () ->
        check_value "int div" (Emo_eval.Int64 3L) "7 / 2";
        check_value "int mod" (Emo_eval.Int64 1L) "7 % 2";
        check_value "float div" (Emo_eval.Float 3.5) "7.0 / 2";
        let diagnostic = eval_err "1 / 0" in
        Alcotest.(check string) "code" "E3005" (code_of diagnostic));
    tc "float math and conversion methods" (fun () ->
        check_value "sqrt" (Emo_eval.Float 1.5) "2.25.sqrt()";
        check_value "floor" (Emo_eval.Float (-2.0)) "(0.0 - 1.5).floor()";
        check_value "ceil" (Emo_eval.Float (-1.0)) "(0.0 - 1.5).ceil()";
        check_value "trunc" (Emo_eval.Float (-1.0)) "(0.0 - 1.5).trunc()";
        check_value "to_int64" (Emo_eval.Int64 2L) "2.9.to_int64()";
        check_value "to_float64" (Emo_eval.Float 3.0) "3.to_float64()");
    tc "string concatenation is +" (fun () ->
        check_value "concat" (Emo_eval.String "ab") "\"a\" + \"b\"";
        let diagnostic = eval_err "\"a\" + 1" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic);
        Alcotest.(check string)
          "names the tags"
          "operator `+` expects two numbers or two strings, got String and \
           Int64"
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
        check_value "array" (Emo_eval.Int64 20L) "[10, 20][1]";
        check_value "tuple" (Emo_eval.Int64 7L) "(7, 8)[0]";
        let diagnostic = eval_err "[1][5]" in
        Alcotest.(check string) "code" "E3004" (code_of diagnostic);
        let diagnostic = eval_err "[1][\"a\"]" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "arrow blocks are callable" (fun () ->
        check_value "call" (Emo_eval.Int64 3L)
          "-> (x Int64) { return x + 1 }(2)";
        check_value "named args" (Emo_eval.Int64 12L)
          "-> (x Int64, y Int64) { return x * 10 + y }(x: 1, y: 2)");
    tc "call errors name the problem" (fun () ->
        let diagnostic = eval_err "-> (x Int64) { return x }(2, 3)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic = eval_err "-> (x Int64) { return x }(y: 1)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic = eval_err "1(2)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
    tc "statements bind and assign" (fun () ->
        let env = run_stmts "const x = 1\nvar y = x + 1\ny = y * 10" in
        Alcotest.check value "y rebound" (Emo_eval.Int64 20L)
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
        check_str "int" "42" (Emo_eval.Int64 42L);
        check_str "negative int" "-7" (Emo_eval.Int64 (-7L));
        check_str "whole float" "1.0" (Emo_eval.Float 1.0);
        check_str "fractional float" "2.5" (Emo_eval.Float 2.5);
        check_str "bool" "true" (Emo_eval.Bool true);
        check_str "char" "a" (Emo_eval.Char 'a');
        check_str "string" "hi" (Emo_eval.String "hi");
        check_str "tuple" "(1, a)"
          (Emo_eval.Tuple [ Emo_eval.Int64 1L; Emo_eval.String "a" ]);
        check_str "array" "[1, 2]"
          (Emo_eval.Array [| Emo_eval.Int64 1L; Emo_eval.Int64 2L |]));
    tc "interpolation stringifies left to right" (fun () ->
        check_value "interp" (Emo_eval.String "a 3 b true")
          "\"a ${1 + 2} b ${true}\"");
    tc "to_string is callable on values" (fun () ->
        check_value "int" (Emo_eval.String "42") "42.to_string()");
    tc "println writes through the output hook" (fun () ->
        let buf = Buffer.create 16 in
        Emo_eval.set_output (Buffer.add_string buf);
        Fun.protect
          ~finally:(fun () ->
            Emo_eval.set_output (fun s ->
                print_string s;
                flush stdout))
          (fun () -> ignore (run_stmts "println(1 + 1)\nprintln(1.0)"));
        Alcotest.(check string) "output" "2\n1.0\n" (Buffer.contents buf));
    tc "length works on arrays and tuples" (fun () ->
        check_value "array" (Emo_eval.Int64 3L) "[1, 2, 3].length()";
        check_value "tuple" (Emo_eval.Int64 2L) "(1, 2).length()");
    tc "Box constructs, reads, replaces" (fun () ->
        check_value "read" (Emo_eval.Int64 2L)
          "-> {\n  const b = Box.new(1)\n  b.replace(2)\n  return b.read()\n}()";
        check_value "replace returns the new value" (Emo_eval.String "x")
          "Box.new(0).replace(\"x\")");
    tc "method errors name the receiver and method" (fun () ->
        let diagnostic = eval_err "1.frobnicate()" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        Alcotest.(check string)
          "message" "Int64 has no method `frobnicate`"
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
             {|def fib(n Int64) Int64 {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
println(fib(10))|}));
    tc "a def may call a def defined after it" (fun () ->
        Alcotest.(check string)
          "forward reference" "true\nfalse\n"
          (run_program
             {|def is_even(n Int64) Bool {
  if n == 0 {
    return true
  }
  return is_odd(n - 1)
}

def is_odd(n Int64) Bool {
  if n == 0 {
    return false
  }
  return is_even(n - 1)
}
println(is_even(4))
println(is_even(5))|}));
    tc "closures see bindings that appear after their definition" (fun () ->
        Alcotest.(check string)
          "by reference" "42\n"
          (run_program
             {|const later = -> {
  return x + 1
}
const x = 41
println(later())|}));
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
println(tick())
println(tick())|}));
    tc "an unbound name fails at call time" (fun () ->
        let diagnostic = program_err "println(nope)" in
        Alcotest.(check string) "code" "E3002" (code_of diagnostic));
    tc "receive outside a scheduler is refused" (fun () ->
        let diagnostic =
          program_err "receive {\n  (from, msg) -> { return msg }\n}"
        in
        Alcotest.(check string) "code" "E3009" (code_of diagnostic));
  ]

let tail_call_tests =
  [
    tc "the acceptance count_down runs a million frames flat" (fun () ->
        Alcotest.(check string)
          "count_down" "0\n"
          (run_program
             {|def count_down(n Int64) Int64 {
  if n == 0 {
    return 0
  }
  return count_down(n - 1)
}
println(count_down(1000000))|}));
    tc "tail calls work through if branches inside arrow blocks" (fun () ->
        Alcotest.(check string)
          "loop via blocks" "0\n"
          (run_program
             {|const loop = -> (n Int64) {
  if n == 0 {
    return 0
  }
  return loop(n - 1)
}
println(loop(500000))|}));
    tc "mutual recursion stays flat" (fun () ->
        Alcotest.(check string)
          "ping-pong" "true\n"
          (run_program
             {|def even(n Int64) Bool {
  if n == 0 {
    return true
  }
  return odd(n - 1)
}

def odd(n Int64) Bool {
  if n == 0 {
    return false
  }
  return even(n - 1)
}
println(even(500000))|}));
    tc "a return of a builtin call still yields its value" (fun () ->
        Alcotest.(check string)
          "builtin in return" "[1, 2]\n"
          (run_program
             "def arr() String {\n\
             \  return [1, 2].to_string()\n\
              }\n\
              println(arr())"));
  ]

let control_flow_tests =
  [
    tc "a Void function ends without `return`" (fun () ->
        Alcotest.(check string)
          "void def" "log: start\n2\n1\n"
          (run_program
             {|def log(msg String) {
  println("log: " + msg)
}

def tick(n Int64) {
  if n > 0 {
    println(n)
    tick(n - 1)
  }
}

log("start")
tick(2)|}));
    tc "a Void trailing block runs without a `return`" (fun () ->
        Alcotest.(check string)
          "void block" "title\ninside block\n"
          (run_program
             {|def page(title String, content Block) Block {
  println(title)
  content()
  return content
}

page(title: "title") {
  println("inside block")
}|}));
    tc "case matches literals first-match, top to bottom" (fun () ->
        Alcotest.(check string)
          "case" "one\ntwo\nmany\n"
          (run_program
             {|def name(n Int64) String {
  case n {
    1 -> { return "one" }
    2 -> { return "two" }
    _ -> { return "many" }
  }
}
println(name(1))
println(name(2))
println(name(3))|}));
    tc "binding patterns bind in the branch body" (fun () ->
        Alcotest.(check string)
          "binding" "5\n"
          (run_program
             {|def identity(n Int64) Int64 {
  case n {
    m -> { return m }
  }
}
println(identity(5))|}));
    tc "tuple patterns destructure by position" (fun () ->
        Alcotest.(check string)
          "tuple" "3\n"
          (run_program
             {|def sum(p (Int64, Int64)) Int64 {
  case p {
    (a, b) -> { return a + b }
  }
}
const pair = (1, 2)
println(sum(pair))|}));
    tc "guards filter branches and fall through" (fun () ->
        Alcotest.(check string)
          "guards" "big\nsmall\n"
          (run_program
             {|def size(n Int64) String {
  case n {
    x when x > 10 -> { return "big" }
    x -> { return "small" }
  }
}
println(size(42))
println(size(1))|}));
    tc "guards must be Bools" (fun () ->
        let diagnostic =
          program_err "case 1 {\n  x when x + 1 -> { return 1 }\n}"
        in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic));
    tc "an unmatched scrutinee is a runtime error naming the tag" (fun () ->
        let diagnostic = program_err "case 1 {\n  \"one\" -> { return 1 }\n}" in
        Alcotest.(check string) "code" "E3006" (code_of diagnostic);
        Alcotest.(check string)
          "message" "no `case` branch matched this Int64 value"
          diagnostic.Diagnostic.message);
    tc "enum member patterns only match enum members" (fun () ->
        Alcotest.(check string)
          "falls through" "w\n"
          (run_program
             {|def check(n Int64) String {
  case n {
    Color.red -> { return "r" }
    _ -> { return "w" }
  }
}
println(check(1))|}));
    tc "if conditions must be Bools, with a span" (fun () ->
        let diagnostic = program_err "if 1 {\n  println(2)\n}" in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic);
        Alcotest.(check string)
          "message" "the `if` condition must be a Bool, got Int64"
          diagnostic.Diagnostic.message;
        Alcotest.(check string)
          "span" "test.emo:1:4"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "raise unwinds to an uncaught-exception error" (fun () ->
        let diagnostic = program_err {|raise "boom"|} in
        Alcotest.(check string) "code" "E3010" (code_of diagnostic);
        Alcotest.(check string)
          "message" "uncaught exception: boom" diagnostic.Diagnostic.message;
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "raise inside a def escapes the function" (fun () ->
        let diagnostic =
          program_err "def f() Int64 {\n  raise 7\n}\nprintln(f())"
        in
        Alcotest.(check string) "code" "E3010" (code_of diagnostic);
        Alcotest.(check string)
          "message" "uncaught exception: 7" diagnostic.Diagnostic.message);
    tc "the builtin Exception constructs with a message" (fun () ->
        Alcotest.(check string)
          "field" "boom\n"
          (run_program
             {|const e = Exception.new(message: "boom")
println(e.message)|}));
    tc "Exception.new is strict about its argument" (fun () ->
        let diagnostic = program_err "Exception.new()" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic =
          program_err "Exception.new(message: \"a\", other: 1)"
        in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
    tc "raising the exception instance terminates uncaught" (fun () ->
        let diagnostic = program_err {|raise Exception.new(message: "boom")|} in
        Alcotest.(check string) "code" "E3010" (code_of diagnostic);
        Alcotest.(check string)
          "message" "uncaught exception: boom" diagnostic.Diagnostic.message;
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "uncaught raises carry the Emo call chain" (fun () ->
        let diagnostic =
          program_err
            {|def inner() Int64 {
  raise "boom"
}

def outer(n Int64) Int64 {
  return inner() + n
}

def mid(n Int64) Int64 {
  return outer(n) + 0
}
mid(1)|}
        in
        Alcotest.(check string) "code" "E3010" (code_of diagnostic);
        let hint =
          match diagnostic.Diagnostic.hint with Some h -> h | None -> ""
        in
        Alcotest.(check bool)
          "innermost frame" true
          (contains_substring hint "called from `inner`");
        Alcotest.(check bool)
          "outer frames in order" true
          (contains_substring hint "called from `outer`"
          && contains_substring hint "called from `mid`"
          && index_of hint "called from `inner`"
             < index_of hint "called from `outer`");
        Alcotest.(check bool)
          "frames carry spans" true
          (contains_substring hint "test.emo:6:10"));
    tc "method frames appear in the chain" (fun () ->
        let diagnostic =
          program_err
            {|class Boomer {
  def init() {}

  def go() Int64 {
    raise "bang"
  }
}
Boomer.new().go()|}
        in
        let hint =
          match diagnostic.Diagnostic.hint with Some h -> h | None -> ""
        in
        Alcotest.(check bool)
          "method frame" true
          (contains_substring hint "called from `Boomer.go`"));
  ]

let acceptance_tests =
  [
    tc "the step acceptance program runs end to end" (fun () ->
        Alcotest.(check string)
          "output" "6765\nhello, emo\n0\n"
          (run_program
             {|def fib(n Int64) Int64 {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

const greeting = -> (name String) {
  return "hello, ${name}"
}

println(fib(20))                 // 6765
println(greeting("emo"))         // hello, emo

def count_down(n Int64) Int64 {
  if n == 0 {
    return 0
  }
  return count_down(n - 1)
}
println(count_down(1000000))     // stack stays flat — tail calls work|}));
    tc "values compose across the whole surface" (fun () ->
        Alcotest.(check string)
          "output" "len=3 first=9\n(2, b)\n"
          (run_program
             {|def describe(xs Array[Int64]) String {
  return "len=${xs.length()} first=${xs[0]}"
}

const first = (1, "a")
const box = Box.new(first)
const second = (2, "b")
box.replace(second)
println(describe([9, 8, 7]))
println(box.read().to_string())|}));
    tc "runtime errors carry the offending span" (fun () ->
        let diagnostic =
          program_err "def f(n Int64) Int64 {\n  return n + \"s\"\n}\nf(1)"
        in
        Alcotest.(check string) "code" "E3001" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:10"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "parse errors surface unchanged from the pipeline" (fun () ->
        match run_program "def f() Int64 {\n  return 1 2\n}" with
        | _ -> Alcotest.fail "expected a parse error"
        | exception Emo_parser.Error d ->
            Alcotest.(check string) "code" "E2002" (code_of d));
  ]

let class_tests =
  [
    tc "User.new runs init and fields freeze" (fun () ->
        Alcotest.(check string)
          "fields via interpolation" "Ada 36\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }
}
const u = User.new(name: "Ada", age: 36)
println("${u.name} ${u.age}")|}));
    tc "constructors take positional arguments too" (fun () ->
        Alcotest.(check string)
          "positional" "Ada\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }
}
println(User.new("Ada", 36).name)|}));
    tc "a stateless class constructs without arguments" (fun () ->
        Alcotest.(check string)
          "stateless" "true\n"
          (run_program
             {|class English {
  def greet() String {
    return "Hello"
  }
}
const e = English.new()
println(e == e)|}));
    tc "constructor argument errors name the class" (fun () ->
        let diagnostic =
          program_err
            "class U {\n\
            \  def init(name String) {\n\
            \    self.name = name\n\
            \  }\n\
             }\n\
             U.new(age: 1)"
        in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        let diagnostic = program_err "class Empty {}\nEmpty.new(1)" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
    tc "reads of missing fields are errors" (fun () ->
        let diagnostic =
          program_err
            "class U {\n\
            \  def init(name String) {\n\
            \    self.name = name\n\
            \  }\n\
             }\n\
             println(U.new(\"a\").missing)"
        in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        Alcotest.(check string)
          "message" "`U` has no field `missing`" diagnostic.Diagnostic.message);
    tc "self outside a class is unbound" (fun () ->
        let diagnostic = program_err "println(self)" in
        Alcotest.(check string) "code" "E3002" (code_of diagnostic));
    tc "instances compare by content, not identity" (fun () ->
        Alcotest.(check string)
          "value semantics" "true\ntrue\nfalse\nfalse\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }
}
const u = User.new(name: "Ada", age: 36)
println(u == User.new(name: "Ada", age: 36))
const alias = u
println(alias == u)
println(u == User.new(name: "Ada", age: 37))
println(u == User.new(name: "Grace", age: 36))|}));
    tc "same-shaped instances of different classes are unequal" (fun () ->
        Alcotest.(check string)
          "class names differ" "false\n"
          (run_program
             {|class A {
  def init() {
    self.x = 1
  }
}

class B {
  def init() {
    self.x = 1
  }
}
println(A.new() == B.new())|}));
    tc "shared structure stays observably immutable" (fun () ->
        Alcotest.(check string)
          "aliasing and boxes" "true\ntrue\nfalse\n"
          (run_program
             {|class Holder {
  def init(items Array[Int64], cell Box) {
    self.items = items
    self.cell = cell
  }
}
const shared = [1, 2]
const cell = Box.new(7)
const h1 = Holder.new(shared, cell)
const h2 = Holder.new([1, 2], Box.new(7))
println(h1 == h2)
const h3 = h1
println(h3 == h1)
cell.replace(8)
println(h1 == h2)|}));
  ]

let enum_tests =
  [
    tc "enum members are singletons" (fun () ->
        Alcotest.(check string)
          "README Color" "true\ntrue\n"
          (run_program
             {|enum Color { red, green, blue }
println(Color.red == Color.red)
const painted = Color.green
println(painted == Color.green)|}));
    tc "unknown members are errors" (fun () ->
        let diagnostic =
          program_err "enum Color { red }\nprintln(Color.pink)"
        in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        Alcotest.(check string)
          "message" "enum `Color` has no member `pink`"
          diagnostic.Diagnostic.message);
    tc "is() checks classes, enums, and interface shapes" (fun () ->
        Alcotest.(check string)
          "README duck typing" "Hello\ntrue\ntrue\ntrue\nfalse\nfalse\n"
          (run_program
             {|interface Greeter {
  def greet() String
}

class English {
  def init() {}

  def greet() String {
    return "Hello"
  }
}

class Silent {
  def init() {}
}

enum Color { red }
def welcome(g Greeter) String {
  return g.greet()
}
println(welcome(English.new()))
println(English.new().is(Greeter))
println(English.new().is(English))
println(Color.red.is(Color))
println(Silent.new().is(Greeter))
println(Color.red.is(Greeter))|}));
    tc "is() on primitives is a type error" (fun () ->
        let diagnostic = program_err "println(1.is(Int64))" in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic));
  ]

let method_tests =
  [
    tc "methods dispatch with self bound to the receiver" (fun () ->
        Alcotest.(check string)
          "README User" "Ada (36)\ntrue\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " (" + self.age.to_string() + ")"
  }

  def is_older?() Bool {
    return self.age > 35
  }
}
const u = User.new(name: "Ada", age: 36)
println(u.full_name())
println(u.is_older?())|}));
    tc "methods bind arguments by name" (fun () ->
        Alcotest.(check string)
          "named args" "7\n"
          (run_program
             {|class Calc {
  def init() {
    self.base = 1
  }

  def plus(a Int64, b Int64) Int64 {
    return self.base + a + b
  }
}
println(Calc.new().plus(b: 2, a: 4))|}));
    tc "a missing method names receiver and method" (fun () ->
        let diagnostic =
          program_err
            "class English {\n\
            \  def init() {\n\
            \    self.x = 1\n\
            \  }\n\
             }\n\
             println(English.new().greet())"
        in
        Alcotest.(check string) "code" "E3007" (code_of diagnostic);
        Alcotest.(check string)
          "message" "NoMethodError: `English` has no method `greet`"
          diagnostic.Diagnostic.message);
    tc "self methods can call each other" (fun () ->
        Alcotest.(check string)
          "delegation" "20\n"
          (run_program
             {|class N {
  def init(n Int64) {
    self.n = n
  }

  def double() Int64 {
    return self.n + self.n
  }

  def quadruple() Int64 {
    return self.double() + self.double()
  }
}
println(N.new(5).quadruple())|}));
    tc "method tail recursion keeps the stack flat" (fun () ->
        Alcotest.(check string)
          "flat recursion" "0\n"
          (run_program
             {|class Walker {
  def init() {}

  def walk(n Int64) Int64 {
    if n == 0 {
      return 0
    }
    return self.walk(n - 1)
  }
}
println(Walker.new().walk(200000))|}));
  ]

let to_string_tests =
  [
    tc "instances render with the provisional default format" (fun () ->
        Alcotest.(check string)
          "instance" "#User(name: \"Ada\", age: 36)\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }
}
println(User.new(name: "Ada", age: 36).to_string())|}));
    tc "enum members render as their member name" (fun () ->
        Alcotest.(check string)
          "enum" "red\nred\n"
          (run_program
             {|enum Color { red, green }
println(Color.red.to_string())
println("${Color.red}")|}));
    tc "exceptions render as their message" (fun () ->
        Alcotest.(check string)
          "exception" "boom\nboom\n"
          (run_program
             {|const e = Exception.new(message: "boom")
println(e.to_string())
println("${e}")|}));
  ]

let object_acceptance_tests =
  [
    tc "the step-06 acceptance program runs verbatim" (fun () ->
        Alcotest.(check string)
          "output" "Ada (36)\ntrue\ntrue\ntrue\nHello\ntrue\n"
          (run_program
             {|class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " (" + self.age.to_string() + ")"
  }

  def is_older?() Bool {
    return self.age > 35
  }
}

const u = User.new(name: "Ada", age: 36)
println(u.full_name())            // Ada (36)
println(u.is_older?())            // true
println(u == User.new(name: "Ada", age: 36))   // true — value semantics

enum Color { red, green, blue }
println(Color.red == Color.red)   // true

interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

def welcome(g Greeter) String {
  return g.greet()
}

println(welcome(English.new()))   // Hello — duck dispatch, no registration
println(English.new().is(Greeter))  // true — structural interface check|}));
    tc "self.x outside init is a parse-time error" (fun () ->
        match
          run_program
            "class U {\n\
            \  def init() {}\n\
            \  def m() Int64 {\n\
            \    self.x = 1\n\
            \    return 1\n\
            \  }\n\
             }"
        with
        | _ -> Alcotest.fail "expected a parse error"
        | exception Emo_parser.Error d ->
            Alcotest.(check string) "code" "E2016" (code_of d));
    tc "an uncaught raise carries the exception's message" (fun () ->
        let diagnostic =
          program_err {|raise Exception.new(message: " kaboom ")|}
        in
        Alcotest.(check string) "code" "E3010" (code_of diagnostic);
        Alcotest.(check string)
          "message" "uncaught exception:  kaboom " diagnostic.Diagnostic.message);
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
      ("tail_call", tail_call_tests);
      ("control_flow", control_flow_tests);
      ("acceptance", acceptance_tests);
      ("class", class_tests);
      ("method", method_tests);
      ("enum", enum_tests);
      ("to_string", to_string_tests);
      ("object_acceptance", object_acceptance_tests);
    ]
