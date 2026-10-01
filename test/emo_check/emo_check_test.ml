open Emo_support

let tc name f = Alcotest.test_case name `Quick f
let check source = Emo_check.check_source ~file:"test.emo" ~source

let codes_of diagnostics =
  List.map
    (fun d -> match d.Diagnostic.code with Some c -> c | None -> "?")
    diagnostics

let has_code diagnostics code = List.mem code (codes_of diagnostics)

let span_of diagnostics =
  match diagnostics with
  | d :: _ -> Span.to_string d.Diagnostic.span
  | [] -> "no diagnostics"

let codes_dump diagnostics =
  String.concat ","
    (List.map
       (fun d ->
         match d.Diagnostic.code with
         | Some c ->
             c ^ "@"
             ^ Span.to_string d.Diagnostic.span
             ^ " " ^ d.Diagnostic.message
         | None -> "?")
       diagnostics)

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_check in
        ());
  ]

let collect_tests =
  [
    tc "a clean program produces no diagnostics" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|class User {
  def init(name String) {
    self.name = name
  }
}

enum Color { red, green }

interface Greeter {
  def greet() String
}

def add(a Int, b Int) Int {
  return a + b
}

const sum = 1 + 2
print(sum)|})));
    tc "an annotation naming an undeclared type is an error" (fun () ->
        let diagnostics = check "def f(x Widget) Int {\n  return 1\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005");
        Alcotest.(check string) "span" "test.emo:1:9" (span_of diagnostics));
    tc "parameterized annotation vocabulary resolves" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                "def first(xs Array[Int]) Int {\n\
                \  return xs[0]\n\
                 }\n\
                 const b = Box.new(1)")));
    tc "a bad parameterized annotation is an error" (fun () ->
        let diagnostics = check "def f(xs Widget[Int]) Int {\n  return 0\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005"));
  ]

let expression_tests =
  [
    tc "an undefined name is a certain error" (fun () ->
        let diagnostics = check "print(nope)" in
        Alcotest.(check bool) "E4003" true (has_code diagnostics "E4003");
        Alcotest.(check string) "span" "test.emo:1:7" (span_of diagnostics));
    tc "operator mismatches on known operands are errors" (fun () ->
        let diagnostics = check {|const bad = 1 + "a"|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "comparison needs numbers" (fun () ->
        let diagnostics = check {|const bad = "a" < "b"|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "logic needs Bools" (fun () ->
        let diagnostics = check {|const bad = 1 && true|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "mixed arrays widen to Unknown and stay silent" (fun () ->
        let diagnostics =
          check
            {|const mixed = [1, "a"]
const first = mixed[0]
print(first + "!")|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "const rebinding with a provable drift is an error" (fun () ->
        let diagnostics = check "const x = 1\nconst x = \"a\"" in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "same-type rebinding is silent" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length (check "const x = 1\nconst x = 2")));
    tc "assigning to a const is a compile error" (fun () ->
        let diagnostics = check "const x = 1\nx = 2" in
        Alcotest.(check bool) "E4007" true (has_code diagnostics "E4007"));
    tc "assigning a provably wrong type to a var is an error" (fun () ->
        let diagnostics = check "var x = 1\nx = \"a\"" in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "var rebinding with a conforming value is silent" (fun () ->
        Alcotest.(check int) "count" 0 (List.length (check "var x = 1\nx = 2")));
    tc "an if condition must be a Bool" (fun () ->
        let diagnostics = check "if 1 {\n  print(2)\n}" in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004");
        Alcotest.(check string) "span" "test.emo:1:4" (span_of diagnostics));
    tc "tuple indexing is bounds-checked on literals" (fun () ->
        let diagnostics = check "const p = (1, \"a\")\nprint(p[5])" in
        if not (has_code diagnostics "E4006") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4006" true (has_code diagnostics "E4006"));
    tc "in-bounds tuple indexing is silent" (fun () ->
        let diagnostics = check "const p = (1, \"a\")\nprint(p[1])" in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
  ]

let () =
  Alcotest.run "emo_check"
    [
      ("smoke", smoke_tests);
      ("collect", collect_tests);
      ("expression", expression_tests);
    ]
