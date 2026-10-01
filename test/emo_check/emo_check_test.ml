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

const sum = add(1, 2)
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

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_check in
        ());
  ]

let () =
  Alcotest.run "emo_check"
    [ ("smoke", smoke_tests); ("collect", collect_tests) ]
