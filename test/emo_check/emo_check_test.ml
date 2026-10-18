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

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

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

def add(a Int64, b Int64) Int64 {
  return a + b
}

const sum = 1 + 2
println(sum)|})));
    tc "a type declaration naming an undeclared type is an error" (fun () ->
        let diagnostics = check "def f(x Widget) Int64 {\n  return 1\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005");
        Alcotest.(check string) "span" "test.emo:1:9" (span_of diagnostics));
    tc "parameterized type declarations resolve" (fun () ->
        let diagnostics =
          check
            "def first(xs Array[Int64]) Int64 {\n\
            \  return xs[0]\n\
             }\n\
             const b = Box.new(1)"
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "a bad parameterized type declaration is an error" (fun () ->
        let diagnostics =
          check "def f(xs Widget[Int64]) Int64 {\n  return 0\n}"
        in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005"));
  ]

let expression_tests =
  [
    tc "an if expression types as its branches' shared type" (fun () ->
        let diagnostics =
          check
            {|const grade = if 90 > 80 { "high" } else { "low" }
println(grade)|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "an if expression's condition must be a Bool" (fun () ->
        let diagnostics = check {|const bad = if 1 { 2 } else { 3 }|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "an if expression's branches must agree" (fun () ->
        let diagnostics = check {|const bad = if true { 1 } else { "s" }|} in
        Alcotest.(check bool) "E4019" true (has_code diagnostics "E4019"));
    tc "Unknown branches join silently" (fun () ->
        let diagnostics =
          check
            {|const scores = Map.new()
const v = if true { scores.get("top") } else { 2 }
println(v.to_string())|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "an undefined name is a certain error" (fun () ->
        let diagnostics = check "println(nope)" in
        Alcotest.(check bool) "E4003" true (has_code diagnostics "E4003");
        Alcotest.(check string) "span" "test.emo:1:9" (span_of diagnostics));
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
println(first + "!")|}
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
        let diagnostics = check "if 1 {\n  println(2)\n}" in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004");
        Alcotest.(check string) "span" "test.emo:1:4" (span_of diagnostics));
    tc "tuple indexing is bounds-checked on literals" (fun () ->
        let diagnostics = check "const p = (1, \"a\")\nprintln(p[5])" in
        if not (has_code diagnostics "E4006") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4006" true (has_code diagnostics "E4006"));
    tc "in-bounds tuple indexing is silent" (fun () ->
        let diagnostics = check "const p = (1, \"a\")\nprintln(p[1])" in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
  ]

let signature_tests =
  [
    tc "a wrong return type against the signature is an error" (fun () ->
        let diagnostics = check {|def f() Int64 {
  return "s"
}|} in
        Alcotest.(check bool) "E4008" true (has_code diagnostics "E4008");
        Alcotest.(check string) "span" "test.emo:2:11" (span_of diagnostics));
    tc "parameter uses carry the declared types" (fun () ->
        let diagnostics = check {|def f(a Int64) Int64 {
  return a + ""
}|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "top-level defs are callable from later items" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length (check "def f() Int64 {\n  return 1\n}\nconst x = f()")));
    tc "init is exempt from return checks" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|class U {
  def init(n String) {
    self.name = n
  }
}|})));
    tc "arrow block bodies are checked under their param types" (fun () ->
        let diagnostics =
          check {|const bad = -> (n Int64) {
  return n + "s"
}|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "an inferrable block used as a value is silent" (fun () ->
        let diagnostics = check {|const g = -> (n Int64) {
  return n + 1
}|} in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "a block with no returns infers Void and stays silent as a value"
      (fun () ->
        let diagnostics = check {|const h = -> (n Int64) {
  println(n)
}|} in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "methods are checked against their signatures" (fun () ->
        let diagnostics =
          check
            {|class U {
  def init() {
    self.name = "x"
  }

  def bad() String {
    return 42
  }
}|}
        in
        Alcotest.(check bool) "E4008" true (has_code diagnostics "E4008"));
  ]

let narrowing_tests =
  [
    tc "narrowing gives the variable its target type inside the branch"
      (fun () ->
        let diagnostics =
          check
            {|class User {
  def init() {
    self.name = "x"
  }
}

var first = [1, "a"][0]
if first.is(User) {
  first = 1
}|}
        in
        Alcotest.(check bool)
          "E4004 proves the narrowing" true
          (has_code diagnostics "E4004"));
    tc "the else branch keeps the pre-test type" (fun () ->
        let diagnostics =
          check
            {|class User {
  def init() {
    self.name = "x"
  }
}

var first = [1, "a"][0]
if first.is(User) {
  println(1)
} else {
  first = 1
}|}
        in
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "narrowing a provably wrong receiver is an error" (fun () ->
        let diagnostics =
          check
            {|class User {
  def init() {
    self.name = "x"
  }
}

const s = "hi"
if s.is(User) {
  println(1)
}|}
        in
        Alcotest.(check bool) "E4011" true (has_code diagnostics "E4011"));
    tc "narrowing outside the branch does not leak" (fun () ->
        let diagnostics =
          check
            {|class User {
  def init() {
    self.name = "x"
  }
}

var first = [1, "a"][0]
if first.is(User) {
  println(1)
}
first = 1|}
        in
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "an interface narrows to a conforming class" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|interface Greeter {
  def greet() String
}

class Machine {
  def greet() String {
    return "beep"
  }

  def beep() String {
    return "b"
  }
}

def welcome(g Greeter) String {
  if g.is(Machine) {
    return g.beep()
  }
  return g.greet()
}|})));
    tc "an interface cannot narrow to a class it does not fit" (fun () ->
        let diagnostics =
          check
            {|interface Greeter {
  def greet() String
}

class Silent {
  def init() {}
}

def probe(g Greeter) String {
  if g.is(Silent) {
    return "yes"
  }
  return "no"
}|}
        in
        if not (has_code diagnostics "E4011") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4011" true (has_code diagnostics "E4011"));
    tc "a conforming class keeps its own type through an interface test"
      (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "hello"
  }

  def shout() String {
    return "HELLO"
  }
}

def probe(e English) String {
  if e.is(Greeter) {
    return e.shout()
  }
  return e.greet()
}|})));
    tc "an unknown value narrows to an interface" (fun () ->
        let diagnostics =
          check
            {|interface Greeter {
  def greet() String
}

var anything = [1, "a"][0]
if anything.is(Greeter) {
  anything = 1
}|}
        in
        Alcotest.(check bool)
          "E4004 proves the narrowing" true
          (has_code diagnostics "E4004"));
  ]

let () =
  let out = open_out "/tmp/emo-check-debug.txt" in
  output_string out
    ("misuse: "
    ^ codes_dump
        (check
           {|class User {
  def init() {
    self.name = "x"
  }
}

const s = "hi"
if s.is(User) {
  println(1)
}|})
    ^ "\n");
  close_out out

let interface_tests =
  [
    tc "a conforming instance passes where an interface is expected" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|interface Greeter {
  def greet() String
}

class English {
  def init() {}

  def greet() String {
    return "Hello"
  }
}

def welcome(g Greeter) String {
  return g.greet()
}

welcome(English.new())|})));
    (* Missing-method and wrong-shape call-site rejections land with the
       call-site checks (T9.7). *)
    tc "a class that does not conform cannot narrow to an interface" (fun () ->
        let diagnostics =
          check
            {|interface Greeter {
  def greet() String
}

class Silent {
  def init() {}
}

def probe(s Silent) String {
  if s.is(Greeter) {
    return "yes"
  }
  return "no"
}|}
        in
        if not (has_code diagnostics "E4011") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4011" true (has_code diagnostics "E4011"));
    tc "an unknown receiver against an interface stays silent" (fun () ->
        let diagnostics =
          check
            {|interface Greeter {
  def greet() String
}

const anything = [1, "a"][0]
println(anything.greet())|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
  ]

let () =
  let out = open_out "/tmp/emo-check-debug.txt" in
  output_string out
    ("narrow0: "
    ^ codes_dump
        (check
           {|class User {
  def init(name String) {
    self.name = name
  }
}

var first = [1, "a"][0]
if first.is(User) {
  first = 1
}|})
    ^ "\n");
  output_string out
    ("narrow-interface: "
    ^ codes_dump
        (check
           {|interface Greeter {
  def greet() String
}

class Silent {
  def init() {}
}

var anything = Silent.new()
if anything.is(Greeter) {
  println(1)
}|})
    ^ "\n");
  output_string out
    ("plain-is: "
    ^ codes_dump
        (check
           {|class S2 {
  def init() {}
}
var x = S2.new()
if x.is(S2) {
  println(1)
}|})
    ^ "\n");
  close_out out

let var_escape_tests =
  [
    tc "a var captured by a nested block is an error" (fun () ->
        let diagnostics =
          check
            {|def probe(flag Bool) Int64 {
  if flag {
    var x = 1
    if flag {
      const g = -> {
        return x
      }
      return g()
    }
  }
  return 0
}|}
        in
        if not (has_code diagnostics "E4012") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4012" true (has_code diagnostics "E4012"));
    tc "a const capture is fine" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|def probe(flag Bool) Int64 {
  if flag {
    const x = 1
    if flag {
      const g = -> {
        return x
      }
      return g()
    }
  }
  return 0
}|})));
    tc "a top-level var in a top-level block is fine" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check {|var x = 1
const g = -> {
  return x
}
println(g())|})));
    tc "a Box is the legal way to hold mutable state in a block" (fun () ->
        let diagnostics =
          check
            {|def probe(flag Bool) Int64 {
  if flag {
    const cell = Box.new(1)
    if flag {
      const g = -> {
        return cell.read()
      }
      return g()
    }
  }
  return 0
}|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
  ]

let case_tests =
  [
    tc "guards must be Bools" (fun () ->
        let diagnostics =
          check
            {|def f(n Int64) Int64 {
  case n {
    x when x -> { return 1 }
    _ -> { return 2 }
  }
}|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "enum patterns must belong to the scrutinee's enum" (fun () ->
        let diagnostics =
          check
            {|enum Color { red }
enum Mood { happy }

def f(c Color) Int64 {
  case c {
    Mood.happy -> { return 1 }
  }
}|}
        in
        Alcotest.(check bool) "E4013" true (has_code diagnostics "E4013"));
    tc "a literal pattern must match the scrutinee" (fun () ->
        let diagnostics =
          check
            {|def f(n Int64) Int64 {
  case n {
    "one" -> { return 1 }
    _ -> { return 2 }
  }
}|}
        in
        Alcotest.(check bool) "E4013" true (has_code diagnostics "E4013"));
    tc "a decidable enum scrutinee needs every member" (fun () ->
        let diagnostics =
          check
            {|enum Color { red, green, blue }

def f(c Color) Int64 {
  case c {
    Color.red -> { return 1 }
  }
}|}
        in
        if not (has_code diagnostics "E4014") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4014" true (has_code diagnostics "E4014");
        let message =
          match
            List.find_opt
              (fun d -> d.Diagnostic.code = Some "E4014")
              diagnostics
          with
          | Some d -> d.Diagnostic.message
          | None -> ""
        in
        Alcotest.(check bool)
          "names the missing members" true
          (contains_substring message "green"
          && contains_substring message "blue"));
    tc "a wildcard covers everything" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|enum Color { red, green }

def f(c Color) Int64 {
  case c {
    Color.red -> { return 1 }
    _ -> { return 2 }
  }
}|})));
    tc "a guarded branch does not count toward coverage" (fun () ->
        let diagnostics =
          check
            {|enum Color { red, green }

def f(c Color) Int64 {
  case c {
    Color.red when c == Color.red -> { return 1 }
  }
}|}
        in
        Alcotest.(check bool) "E4014" true (has_code diagnostics "E4014"));
    tc "the enum-tag tuple idiom is exhaustiveness-checked" (fun () ->
        let diagnostics =
          check
            {|enum Outcome { ok, failed }

def show(p (Outcome, Int64)) String {
  case p {
    (Outcome.ok, v) -> { return v.to_string() }
  }
}|}
        in
        if not (has_code diagnostics "E4014") then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check bool) "E4014" true (has_code diagnostics "E4014"));
    tc "a covered tuple tag is silent" (fun () ->
        let diagnostics =
          check
            {|enum Outcome { ok, failed }

def show(p (Outcome, Int64)) String {
  case p {
    (Outcome.ok, v) -> { return v.to_string() }
    (Outcome.failed, _) -> { return "no" }
    _ -> { return "?" }
  }
}|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "member branches cover the tuple idiom without a wildcard" (fun () ->
        (* The scrutinee is a call, so its tuple type is known — the two
           member branches must be credited on their own. *)
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|enum Outcome { ok, failed }

def grade(p (Outcome, Int64)) String {
  case p {
    (Outcome.ok, v) -> { return v.to_string() }
    (Outcome.failed, _) -> { return "no" }
  }
}

def go() String {
  const p = (Outcome.ok, 3)
  return grade(p)
}|})));
    tc "an undecidable scrutinee has no coverage requirement" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|const anything = [1, "a"][0]
case anything {
  1 -> { println(1) }
}|})));
  ]

(* The step-09 acceptance corpus: strict type-declaration rejections,
   inference successes, and the zero-false-positive discipline. *)
let corpus_tests =
  [
    tc "acceptance: String has no method revoke" (fun () ->
        let diagnostics =
          check {|def act(u String) String {
  return u.revoke()
}|}
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001");
        Alcotest.(check string) "span" "test.emo:2:10" (span_of diagnostics));
    tc "acceptance: an Unknown receiver is not reported" (fun () ->
        let diagnostics =
          check {|def ok(u) String {
  return u.to_string()
}|}
        in
        (* The parser rejects the missing type declaration before the
           checker runs; the program never reaches a false positive. *)
        Alcotest.(check bool)
          "parse rejection" true
          (has_code diagnostics "E2001"));
    tc "acceptance: every example checks clean" (fun () ->
        List.iter
          (fun name ->
            let dir = Filename.concat "../../examples" name in
            let source = read_file (Filename.concat dir "main.emo") in
            let diagnostics = check source in
            if List.length diagnostics > 0 then
              Alcotest.fail
                (name ^ " does not check clean: " ^ codes_dump diagnostics))
          [ "hello_world"; "fib"; "objects" ]);
    tc "rejection: a bad named argument" (fun () ->
        let diagnostics =
          check
            {|def page(title String) String {
  return title
}

page(titel: "Home")|}
        in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "acceptance: arguments in parameter order" (fun () ->
        if
          List.length
            (check
               {|def foo(a String, b Int64) Int64 {
  return b
}

foo(a: "hi", b: 33)
foo("hi", 33)|})
          > 0
        then Alcotest.fail "expected a clean check");
    tc "acceptance: an attached block follows a named argument" (fun () ->
        if
          List.length
            (check
               {|def page(title String, body Block) Void {
  body()
}

page(title: "Home") { println("hi") }|})
          > 0
        then Alcotest.fail "expected a clean check");
    tc "rejection: named arguments out of parameter order" (fun () ->
        let diagnostics =
          check
            {|def foo(a String, b Int64) Int64 {
  return b
}

foo(b: 33, a: "hi")|}
        in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009");
        Alcotest.(check bool)
          "message" true
          (contains_substring (codes_dump diagnostics)
             "passes `a` out of parameter order"));
    tc "rejection: a positional argument after a named one" (fun () ->
        let diagnostics =
          check
            {|def foo(a String, b Int64) Int64 {
  return b
}

foo(a: "hi", 33)|}
        in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009");
        Alcotest.(check bool)
          "message" true
          (contains_substring (codes_dump diagnostics)
             "passes a positional argument after a named one"));
  ]

let void_tests =
  [
    tc "a def with no return type declaration is a Void function" (fun () ->
        if List.length (check {|def log(msg String) {
  println(msg)
}|}) > 0
        then Alcotest.fail "expected a clean check");
    tc "an explicit Void type declaration behaves like the omitted form"
      (fun () ->
        if
          List.length (check {|def log(msg String) Void {
  println(msg)
}|})
          > 0
        then Alcotest.fail "expected a clean check");
    tc "a `return` in a Void function is E4016" (fun () ->
        let diagnostics =
          check {|def log(msg String) {
  println(msg)
  return
}|}
        in
        Alcotest.(check bool) "E4016" true (has_code diagnostics "E4016"));
    tc "a `return` carrying a value is E4016 too" (fun () ->
        let diagnostics = check {|def f() Void {
  return Void
}|} in
        Alcotest.(check bool) "E4016" true (has_code diagnostics "E4016"));
    tc "a def with a declared return type must return on every path" (fun () ->
        let diagnostics =
          check {|def f(x Int64) Int64 {
  if x > 0 {
    return 1
  }
}|}
        in
        Alcotest.(check bool) "E4017" true (has_code diagnostics "E4017"));
    tc "an exhaustive case satisfies the return requirement" (fun () ->
        if
          List.length
            (check
               {|enum Color { red, green }

def f(c Color) Int64 {
  case c {
    Color.red -> { return 1 }
    Color.green -> { return 2 }
  }
}|})
          > 0
        then Alcotest.fail "expected a clean check");
    tc "a valueless `return` in a typed function is E4018" (fun () ->
        let diagnostics =
          check
            {|def f(x Int64) Int64 {
  if x > 0 {
    return
  }
  return 2
}|}
        in
        Alcotest.(check bool) "E4018" true (has_code diagnostics "E4018"));
    tc "a Void block passed to a Block parameter checks clean" (fun () ->
        if
          List.length
            (check
               {|def page(title String, content Block) Block {
  println(title)
  content()
  return content
}

page(title: "Home") {
  println("inside")
}|})
          > 0
        then Alcotest.fail "expected a clean check");
    tc "a block returning a value must return on every path" (fun () ->
        let diagnostics =
          check {|const f = -> (n Int64) {
  if n > 0 {
    return 1
  }
}|}
        in
        Alcotest.(check bool) "E4017" true (has_code diagnostics "E4017"));
  ]

(* The Map: literal inference, the type declaration, Map.new, and the
   method surface. *)
let map_tests =
  [
    tc "a literal infers Map of its key and value types" (fun () ->
        let diagnostics =
          check {|
const ages = { "alice": 30 }
println(ages.get("alice"))|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "the empty map is Map of Unknowns" (fun () ->
        let diagnostics = check {|const empty = {}
println(empty.length())|} in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "the Map type declaration type-checks and drives the method surface"
      (fun () ->
        let diagnostics =
          check
            {|
def size(m Map[String, Int64]) Int64 {
  return m.length()
}
println(size({ "a": 1 }))|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "a wrong-arity Map type declaration is an unknown type" (fun () ->
        let diagnostics = check "def f(m Map[String]) Int64 {\n  return 1\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005"));
    tc "a bare Map type declaration is the map of anything" (fun () ->
        let diagnostics =
          check
            {|
def size(m Map) Int64 {
  return m.length()
}
println(size({ "a": 1 }))
println(size({ 1: "x", 2: "y" }))|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "Exception.new checks its message and optional data" (fun () ->
        let diagnostics =
          check {|raise Exception.new("boom", { "kind": "io" })|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "Exception.new is strict about the argument shapes" (fun () ->
        let diagnostics = check "Exception.new()" in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009");
        let diagnostics = check {|Exception.new("a", "b", "c")|} in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009");
        let diagnostics =
          check {|Exception.new(data: { "k": 1 }, message: "x")|}
        in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "Exception.new is strict about the argument types" (fun () ->
        let diagnostics = check "Exception.new(123)" in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004");
        let diagnostics = check {|Exception.new("x", 42)|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a provably unhashable key is an error" (fun () ->
        let diagnostics = check {|const bad = { [1]: "x" }|} in
        Alcotest.(check bool) "E4020" true (has_code diagnostics "E4020"));
    tc "Map.new builds from pairs" (fun () ->
        let diagnostics =
          check
            {|
const scores = Map.new(("a", 1), ("b", 2))
println(scores.get("a"))|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "Map.new rejects a non-pair argument" (fun () ->
        let diagnostics = check {|const bad = Map.new(("a", 1), 2)|} in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "get on a known key type checks the argument" (fun () ->
        let diagnostics =
          check {|const ages = { "a": 1 }
println(ages.get(2))|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "set accepts a conforming value and returns the map" (fun () ->
        let diagnostics =
          check
            {|
const ages = { "a": 1 }
println(ages.set("b", 2).set("c", 3).length())|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "set with a provably wrong value is an error" (fun () ->
        let diagnostics =
          check {|const ages = { "a": 1 }
ages.set("b", "x")|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "keys and values return arrays of the map's types" (fun () ->
        let diagnostics =
          check
            {|
const ages = { "a": 1 }
const ks = ages.keys()
const first = ks[0]
println(first + "!")|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "maps do not support indexing" (fun () ->
        let diagnostics =
          check {|const ages = { "a": 1 }
println(ages["a"])|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
  ]

(* ---- printf ---- *)

let printf_tests =
  [
    tc "a literal format with matching literal data checks clean" (fun () ->
        let diagnostics =
          check
            {|
printf("hello %s %d\n", ["world", 42])
printf("%*d|%.*f|%%\n", [8, 42, 2, 1.5])|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a conversion type mismatch is E4004" (fun () ->
        let diagnostics = check {|printf("%d\n", ["str"])|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a count mismatch is E4004" (fun () ->
        let diagnostics = check {|printf("%d %d\n", [1])|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004");
        Alcotest.(check bool)
          "message" true
          (List.exists
             (fun d -> contains_substring d.Diagnostic.message "consumes 2")
             diagnostics));
    tc "unknown conversions are E4004" (fun () ->
        let diagnostics = check {|printf("%y\n", [])|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "hex-float, %n, and %p are refused" (fun () ->
        let a = check {|printf("%a\n", [1.0])|} in
        Alcotest.(check bool) "%a" true (has_code a "E4004");
        let n = check {|printf("%n", [])|} in
        Alcotest.(check bool) "%n" true (has_code n "E4004");
        let p = check {|printf("%p", [])|} in
        Alcotest.(check bool) "%p" true (has_code p "E4004"));
    tc "length modifiers are refused" (fun () ->
        let diagnostics = check {|printf("%lld\n", [1])|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a lone percent is E4004" (fun () ->
        let diagnostics = check {|printf("100 %\n", [])|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "element types come from a typed array variable" (fun () ->
        let diagnostics = check {|
const xs = ["a", "b"]
printf("%d\n", xs)|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a dynamic format stays unchecked" (fun () ->
        let diagnostics =
          check
            {|
def fmt() String { return "%d\n" }
printf(fmt(), ["anything"])|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "printf arity is two" (fun () ->
        let diagnostics = check {|printf("hi\n")|} in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
  ]

(* ---- expect: the test assertions ---- *)

let expect_tests =
  [
    tc "expect calls check clean on any values" (fun () ->
        let diagnostics =
          check
            {|expect_equal([1, "x"], [1, "x"])
expect_true(1 == 1)
expect_false(1 == 2)
expect_fail("boom")|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "expect_equal arity is two" (fun () ->
        let diagnostics = check {|expect_equal(1)|} in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "expect_fail's message is a String" (fun () ->
        let diagnostics = check {|expect_fail(42)|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
  ]

(* The cross-module rule (CHECK.md, settled 2026-10-10): every module's
   type declarations pre-register before any module is checked, and a
   name's second declaration is a loud collision. *)
let units_of (modules : (string * string) list) =
  List.map
    (fun (name, source) ->
      ( [ name ],
        match Emo_parser.parse_program ~file:(name ^ ".emo") ~source with
        | items -> items
        | exception Emo_lexer.Error d ->
            Alcotest.fail (Printf.sprintf "lex: %s" d.Diagnostic.message)
        | exception Emo_parser.Error d ->
            Alcotest.fail (Printf.sprintf "parse: %s" d.Diagnostic.message) ))
    modules

(* Parses, pre-registers, and checks every module; every diagnostic. *)
let check_program (modules : (string * string) list) :
    Emo_support.Diagnostic.t list =
  let units = units_of modules in
  let program, pre_errors =
    Emo_check.preregister_types ~packages:[] ~package_deps:[] ~aliases:[] ~units
  in
  let paths = List.map fst units in
  List.concat_map
    (fun (path, items) ->
      let diags, _refs, _requires =
        Emo_check.check_module ~modules:paths ~current:path ~program items
      in
      diags)
    units
  @ pre_errors

(* Box.new types its cell: the argument's type is the element type, so
   `read`/`replace` check against it and every other member is refused
   — the runtime's rule, surfaced at check time (the stdlib builds its
   state exclusively from bare `Box.new`, so an untyped cell unchecked
   everything downstream). *)
let box_tests =
  [
    tc "a box's read and replace check against the cell's type" (fun () ->
        let diagnostics =
          check
            {|const n = Box.new(41)
n.replace(n.read() + 1)
println(n.read())|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "replace checks the value against the cell" (fun () ->
        let diagnostics = check {|const s = Box.new("text")
s.replace(42)|} in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "read's element flows to its consumers" (fun () ->
        let diagnostics =
          check
            {|const s = Box.new("text")
println(s.read() + "!")
const n = Box.new(1)
println(n.read() + 1)|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "an unknown method on a box is refused" (fun () ->
        let diagnostics = check {|const n = Box.new(1)
n.nope()|} in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a bare member access on a box is refused" (fun () ->
        let diagnostics = check {|const n = Box.new(1)
println(n.v)|} in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "Box.new arity and named arguments are checked" (fun () ->
        let diagnostics = check {|Box.new()
Box.new(1, 2)
Box.new(x: 1)|} in
        Alcotest.(check int)
          "three E4009s" 3
          (List.length
             (List.filter
                (fun d -> d.Diagnostic.code = Some "E4009")
                diagnostics)));
  ]

let array_builder_tests =
  [
    tc "the builder's spelling resolves bare and parameterized" (fun () ->
        let diagnostics =
          check
            {|def grow(b ArrayBuilder[String]) Int64 {
  return b.length()
}

def bare(b ArrayBuilder) Int64 {
  return b.length()
}

const kids = ArrayBuilder.new()
kids.push("a")
println(kids.to_array())|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics);
        Alcotest.(check int) "count" 0 (List.length diagnostics));
    tc "ArrayBuilder takes exactly one argument" (fun () ->
        let diagnostics =
          check "def f(b ArrayBuilder[String, Int64]) Int64 {\n  return 0\n}"
        in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005"));
    tc "ArrayBuilder.new takes no arguments" (fun () ->
        let diagnostics = check "const b = ArrayBuilder.new(1)" in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "the first push pins the const builder's element type" (fun () ->
        let diagnostics =
          check {|const kids = ArrayBuilder.new()
kids.push("a")
kids.push(1)|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a var builder is not pinned, so its pushes stay unchecked" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|var kids = ArrayBuilder.new()
kids.push("a")
kids.push(1)|})));
    tc "a push not in statement position does not pin" (fun () ->
        let diagnostics =
          check
            {|const kids = ArrayBuilder.new()
println(kids.push("a"))
kids.push(1)|}
        in
        Alcotest.(check int)
          "count" 0
          (List.length
             (List.filter
                (fun d -> d.Diagnostic.code = Some "E4004")
                diagnostics)));
    tc "push answers the builder, so chained pushes share one pin" (fun () ->
        let diagnostics =
          check
            {|const kids = ArrayBuilder.new()
kids.push("a").push("b")
kids.push(1)|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "get answers the element and to_array answers the array" (fun () ->
        let diagnostics =
          check
            {|const kids = ArrayBuilder.new()
kids.push("a")
println(kids.get(0) + "!")
const xs = kids.to_array()
println(xs[0])|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "get's index is an Int64" (fun () ->
        let diagnostics =
          check {|const kids = ArrayBuilder.new()
kids.push("a")
kids.get("0")|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "the element type crosses through push's argument" (fun () ->
        let diagnostics =
          check
            {|const kids = ArrayBuilder.new()
kids.push(1)
const n = kids.to_array()
println(n[0] + 1)|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a pinned builder refuses an element the array could not hold" (fun () ->
        let diagnostics =
          check
            {|const kids = ArrayBuilder.new()
kids.push("a")
const xs = kids.to_array()
println(xs[0] + 1)|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "an unknown method on a builder is refused" (fun () ->
        let diagnostics =
          check {|const kids = ArrayBuilder.new()
kids.nope()|}
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
  ]

let cross_module_tests =
  [
    tc "a type declaration names another module's type" (fun () ->
        let diagnostics =
          check_program
            [
              ( "ui",
                {|interface VNode {
  def kind() String
}

class VControl {
  def init() {
    self.kind = "control"
  }

  def kind() String {
    return self.kind
  }
}

def make() VNode {
  return VControl.new()
}
|}
              );
              ( "app",
                {|def view() ui.VNode {
  return ui.make()
}

const v = view()
println(v.kind())|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a parameter carries another module's class" (fun () ->
        let diagnostics =
          check_program
            [
              ( "shapes",
                {|class Crate {
  def init() {
    self.w = 1
  }

  def area() Int64 {
    return self.w
  }
}
|}
              );
              ( "use",
                {|def show(c shapes.Crate) Int64 {
  return c.area()
}

println(show(shapes.Crate.new()))|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "the same type name in two modules coexists, each module's own"
      (fun () ->
        let diagnostics =
          check_program
            [
              ( "a",
                {|class Widget {
  def init() {
    self.w = 1
  }

  def weight() Int64 {
    return self.w
  }
}

def make() Widget {
  return Widget.new()
}

println(make().weight())|}
              );
              ( "b",
                {|class Widget {
  def init() {
    self.w = 2
  }

  def weight() Int64 {
    return self.w
  }
}

def make() Widget {
  return Widget.new()
}

println(make().weight())|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "two modules' same-named types are told apart by their paths" (fun () ->
        let diagnostics =
          check_program
            [
              ("a", {|class Widget {
  def init() {
    self.w = 1
  }
}|});
              ("b", {|class Widget {
  def init() {
    self.w = 2
  }
}|});
              ( "main",
                {|def f(x a.Widget) Int64 {
  return 1
}

def g(y b.Widget) Int64 {
  return 2
}

def tag_a(x a.Widget) Int64 {
  if x.is(a.Widget) {
    return 1
  }
  return 0
}

def tag_b(y b.Widget) Int64 {
  if y.is(b.Widget) {
    return 2
  }
  return 0
}|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a same-name declaration inside one module stays its own" (fun () ->
        let diagnostics =
          check_program
            [
              ( "solo",
                {|class Widget {
  def init() {
    self.w = 1
  }
}

const w = Widget.new()
println(w)|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
  ]

(* The program's value signatures beside the type tables (CHECK.md,
   cross-module signatures): every module's defs and consts pre-register
   with their types, so a qualified `lib.f(x)` call checks its arguments
   and `lib.answer` reads as more than Unknown — the same rule the
   runtime's module loader enforces by raising. *)
let member_signature_tests =
  let lib =
    {|def make() Int64 {
  return 42
}

def greet(name String) String {
  return "hi ${name}"
}

const answer = 7
var counter = 0

emo Math {
  def double(n Int64) Int64 {
    return n * 2
  }

  const tau = 6
}
|}
  in
  [
    tc "a qualified call checks against the def's signature" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(lib.greet(\"yo\"))") ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a qualified call's argument type is the def's" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(lib.greet(42))") ]
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a qualified call's arity is the def's" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(lib.make(1))") ]
        in
        Alcotest.(check bool) "E4009" true (has_code diagnostics "E4009"));
    tc "the return type flows to the caller" (fun () ->
        let diagnostics =
          check_program
            [ ("lib", lib); ("app", "const x = lib.make()\nprintln(x.nope())") ]
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a const read carries its type" (fun () ->
        let diagnostics =
          check_program
            [ ("lib", lib); ("app", "const a = lib.answer\nprintln(a.nope())") ]
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a bare def reference is the closure value" (fun () ->
        let diagnostics =
          check_program
            [ ("lib", lib); ("app", "const f = lib.make\nprintln(f + 1)") ]
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "an unknown module member is refused statically" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(lib.missing)") ]
        in
        Alcotest.(check bool) "E5004" true (has_code diagnostics "E5004"));
    tc "another module's group checks its members" (fun () ->
        let diagnostics =
          check_program
            [
              ("lib", lib);
              ("app", "println(Math.tau)\nprintln(Math.double(21))");
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "another module's group member checks its argument" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(Math.double(\"x\"))") ]
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a group member miss is the group's E4001" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "println(Math.side())") ]
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a capitalized name resolving nowhere is not defined" (fun () ->
        let diagnostics =
          check_program [ ("lib", lib); ("app", "const r = Nope") ]
        in
        Alcotest.(check bool) "E4003" true (has_code diagnostics "E4003"));
    tc "a local shadows a module of the same name" (fun () ->
        let diagnostics =
          check_program
            [
              ("list", {|def length() Int64 {
  return 0
}
|});
              ("app", {|const list = [1, 2]
println(list.length())|});
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "the value-carrying builtins stay legal as names" (fun () ->
        let diagnostics =
          check
            {|println(List.new([1, 2]).length())
println(Map.new(("a", 1)).get("a"))
println(Bytes.new(4).length())
println(Byte.from_int64(200))
println(Float64.from_bits(4614256656552045848))|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
  ]

(* T39.1 — a class declares no field types; the type `init` first
   assigns is the field's type, so `self.width` inside a method and
   `r.style.color` from outside both read as more than Unknown. A read
   is asserted the way the signature tests assert a type: a member the
   type does not have reports E4001, where Unknown stays silent. *)
let field_type_tests =
  let shapes =
    {|class Style {
  def init(color (Int64, Int64, Int64), width Float64) {
    self.color = color
    self.width = width
  }
}

class Rect {
  def init(w Float64, style Style) {
    self.w = w
    self.style = style
  }

  def stroke() Float64 {
    return (self.w + self.style.width * 2.0) * 2.0
  }

  def color_sum() Int64 {
    return self.style.color[0] + self.style.color[1]
  }
}

const r = Rect.new(w: 4.0, style: Style.new(color: (1, 2, 3), width: 0.5))
println(r.stroke())
println(r.color_sum())
|}
  in
  let with_tail tail = check (shapes ^ "\n" ^ tail) in
  [
    tc "the field shapes check clean" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length (check shapes)));
    tc "a method's self.field carries the init type" (fun () ->
        let diagnostics =
          check
            {|class Probe {
  def init() {
    self.n = 0
  }

  def bad() Int64 {
    return self.n.nope()
  }
}
|}
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a field read from outside the class carries its type" (fun () ->
        Alcotest.(check bool)
          "E4001" true
          (has_code (with_tail "println(r.w.nope())") "E4001"));
    tc "a field of a field carries the inner field's type" (fun () ->
        Alcotest.(check bool)
          "E4001" true
          (has_code (with_tail "println(r.style.width.nope())") "E4001"));
    tc "a class-typed field reads as its class" (fun () ->
        Alcotest.(check bool)
          "E4001" true
          (has_code (with_tail "println(r.style.nope())") "E4001"));
    tc "a tuple-typed field reads as its tuple" (fun () ->
        Alcotest.(check bool)
          "E4001" true
          (has_code (with_tail "println(r.style.color.nope())") "E4001"));
    tc "another module's class fields type the same way" (fun () ->
        let diagnostics =
          check_program
            [
              ( "lib",
                {|class Point {
  def init(x Float64, y Float64) {
    self.x = x
    self.y = y
  }
}

def make(x Float64, y Float64) Point {
  return Point.new(x: x, y: y)
}
|} );
              ("app", {|const p = lib.make(1.0, 2.0)
println(p.x.nope())|});
            ]
        in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001"));
    tc "a later assignment must store the first assignment's type" (fun () ->
        let diagnostics =
          check
            {|class Bad {
  def init() {
    self.x = 1.0
    self.x = "s"
  }
}
|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a native field stores its own type, not a widened one" (fun () ->
        let diagnostics =
          check
            {|class Bad {
  def init(flag Bool) {
    if flag {
      self.x = 1.0
    } else {
      self.x = 1
    }
  }
}
|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a dynamic field takes a conforming value" (fun () ->
        let diagnostics =
          check
            {|class Good {
  def init(label String, other String) {
    self.label = label
    self.label = other
  }
}
|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
  ]

(* The callback contract (CHECK.md, 2026-10-11): a foreign parameter may
   name a single-method interface on the c target — its method stays in
   the marshaling tier with Void added to the return — while every
   other target refuses the parameter and the surface rules stay as
   before. *)
let callback_tests =
  [
    tc "a single-method interface is a valid foreign parameter on c" (fun () ->
        let diagnostics =
          check
            {|
interface Greeter {
  def greet(name String, n Int64) String
}

foreign def run_greet(g Greeter, times Int64) Void = "run_greet"
|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a multi-method interface is refused as a callback" (fun () ->
        let diagnostics =
          check
            {|
interface Two {
  def a() Int64
  def b() Int64
}

foreign def run(t Two) Void = "run"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true;
        Alcotest.(check bool)
          "names the one-method rule"
          (List.exists
             (fun d ->
               contains_substring d.Diagnostic.message
                 "must declare exactly one method")
             diagnostics)
          true);
    tc "a callback method parameter outside the marshaling tier is refused"
      (fun () ->
        let diagnostics =
          check
            {|
interface Bad {
  def go(xs Array) Int64
}

foreign def run(b Bad) Void = "run"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a callback method return outside the tier is refused" (fun () ->
        let diagnostics =
          check
            {|
interface Bad {
  def go(n Int64) Array
}

foreign def run(b Bad) Void = "run"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a foreign return of interface type is still refused" (fun () ->
        let diagnostics =
          check
            {|
interface Greeter {
  def greet() String
}

foreign def make() Greeter = "make"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a class-typed foreign parameter stays refused" (fun () ->
        let diagnostics =
          check
            {|
class Thing {
  def go() Int64 {
    return 1
  }
}

foreign def run(t Thing) Void = "run"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a non-c target refuses the interface parameter" (fun () ->
        match
          Emo_parser.parse_program ~file:"test.emo"
            ~source:
              {|
interface Greeter {
  def greet() String
}

foreign def run(g Greeter) Void = "run"
|}
        with
        | items ->
            let diagnostics, _, _, _ =
              Emo_check.check_module_typed ~modules:[] ~current:[]
                ~target:"ocaml" items
            in
            Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true
        | exception Emo_parser.Error d ->
            Alcotest.fail ("parse failed: " ^ d.Diagnostic.message));
  ]

(* The loop surface (CHECK.md, 2026-10-06): the header `var` scopes to the
   header and body, `break`/`continue` bind to the nearest enclosing loop
   and refuse outside one, and a loop never counts as a return point. *)
let loop_tests =
  [
    tc "a clean for loop checks" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|
def probe(n Int64) Int64 {
  for var i = 0; i < n; i = i + 1 {
    println(i)
  }
  return 0
}|})));
    tc "a clean while loop checks" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|
def probe(n Int64) Int64 {
  var i = 0
  while i < n {
    i = i + 1
  }
  return 0
}|})));
    tc "the header var ends with the loop" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  for var i = 0; i < n; i = i + 1 {
    println(i)
  }
  return i
}|}
        in
        Alcotest.(check bool) "E4003" true (has_code diagnostics "E4003"));
    tc "break and continue refuse outside a loop" (fun () ->
        let diagnostics = check {|
def probe() Int64 {
  break
  continue
}|} in
        Alcotest.(check bool) "E4022" true (has_code diagnostics "E4022"));
    tc "break and continue bind to the nearest loop" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|
def probe(n Int64) Int64 {
  var i = 0
  while i < n {
    for var j = 0; j < n; j = j + 1 {
      break
    }
    continue
  }
  return 0
}|})));
    tc "break cannot cross an arrow block" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  var i = 0
  while i < n {
    const g = -> {
      break
    }
    g()
  }
  return 0
}|}
        in
        Alcotest.(check bool) "E4022" true (has_code diagnostics "E4022"));
    tc "capturing the header var is the var-escape error" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  for var i = 0; i < n; i = i + 1 {
    const g = -> {
      return i
    }
    println(g())
  }
  return 0
}|}
        in
        Alcotest.(check bool) "E4012" true (has_code diagnostics "E4012"));
    tc "a loop does not satisfy a declared return" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  while n > 0 {
    n = n - 1
    return 0
  }
}|}
        in
        Alcotest.(check bool) "E4017" true (has_code diagnostics "E4017"));
    tc "loop conditions must be Bool" (fun () ->
        let diagnostics =
          check
            {|
def probe() Int64 {
  var i = 0
  while i {
    i = 1
  }
  for var j = 0; j; j = j + 1 {
    println(j)
  }
  return 0
}|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "the post clause may not retype the header var" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  for var i = 0; i < n; i = "many" {
    println(i)
  }
  return 0
}|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "the body scope ends before the post clause" (fun () ->
        let diagnostics =
          check
            {|
def probe(n Int64) Int64 {
  for var i = 0; i < n; i = j {
    var j = 1
  }
  return 0
}|}
        in
        Alcotest.(check bool) "E4003" true (has_code diagnostics "E4003"));
  ]

(* The struct shapes (CHECK.md, 2026-10-11): a tuple or a carrier class
   crosses the C ABI as a struct by value — the element types (or the
   class's init-assigned fields) are the layout, recursion through
   nested tuples is the nesting, and a compound return is always a
   tuple. *)
let shape_tests =
  [
    tc "a tuple shape is a valid foreign parameter and return on c" (fun () ->
        let diagnostics =
          check
            {|
foreign def stretch(r (Float64, Float64), by Float64) (Float64, Float64) = "stretch"
|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a carrier class is a valid foreign parameter on c" (fun () ->
        let diagnostics =
          check
            {|
class Point {
  def init(x Float64, y Float64) {
    self.x = x
    self.y = y
  }
}

foreign def dist(p Point) Float64 = "dist"
|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a nested tuple shape nests the struct" (fun () ->
        let diagnostics =
          check
            {|
foreign def stretch(r ((Float64, Int64), Bool)) Float64 = "stretch"
|}
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a shape field outside the tier is refused" (fun () ->
        let diagnostics =
          check
            {|
foreign def stretch(r (Float64, Array)) Float64 = "stretch"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a class-typed foreign return is refused — name the tuple" (fun () ->
        let diagnostics =
          check
            {|
class Point {
  def init(x Float64, y Float64) {
    self.x = x
    self.y = y
  }
}

foreign def make() Point = "make"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true;
        Alcotest.(check bool)
          "names the tuple rule"
          (List.exists
             (fun d ->
               contains_substring d.Diagnostic.message "crosses as a tuple type")
             diagnostics)
          true);
    tc "a carrier class whose fields diverge from init is refused" (fun () ->
        let diagnostics =
          check
            {|
class Bad {
  def init(x Float64, y Float64) {
    self.x = x
  }
}

foreign def dist(p Bad) Float64 = "dist"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a stateless class cannot carry a struct" (fun () ->
        let diagnostics =
          check
            {|
class Empty {
  def ping() Int64 {
    return 1
  }
}

foreign def dist(p Empty) Float64 = "dist"
|}
        in
        Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true);
    tc "a non-c target refuses the tuple shape" (fun () ->
        match
          Emo_parser.parse_program ~file:"test.emo"
            ~source:
              {|
foreign def stretch(r (Float64, Float64)) Float64 = "stretch"
|}
        with
        | items ->
            let diagnostics, _, _, _ =
              Emo_check.check_module_typed ~modules:[] ~current:[]
                ~target:"ocaml" items
            in
            Alcotest.(check bool) "E4200" (has_code diagnostics "E4200") true
        | exception Emo_parser.Error d ->
            Alcotest.fail ("parse failed: " ^ d.Diagnostic.message));
  ]

(* The built-in `R` enum (M10): the ok/error pair every program sees,
   no import needed, matched in `case` — and a name no declaration may
   take, beside the shipped `Exception` class. *)
let r_enum_tests =
  [
    tc "the built-in R constructs and matches like any enum" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|def pick(t (R, String)) String {
  case t {
    (R.ok, n) -> { return "ok ${n}" }
    (R.error, why) -> { return "error ${why}" }
  }
}

println(pick((R.ok, "7")))
println(pick((R.error, "boom")))|})));
    tc "a bare R scrutinee matches member patterns exhaustively" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|def show(x R) String {
  case x {
    R.ok -> { return "yes" }
    R.error -> { return "no" }
  }
}

println(show(R.ok))|})));
    tc "R's member table answers the member and coverage checks" (fun () ->
        let diagnostics = check "println(R.wrong)" in
        Alcotest.(check bool) "E4001" true (has_code diagnostics "E4001");
        let diagnostics =
          check
            {|
def pick(t (R, String)) String {
  case t {
    (R.ok, n) -> { return "ok ${n}" }
  }
}
|}
        in
        Alcotest.(check bool) "E4014" true (has_code diagnostics "E4014"));
    tc "declaring R or Exception is refused" (fun () ->
        let diagnostics = check "enum R { ok, error }" in
        Alcotest.(check bool) "enum R" true (has_code diagnostics "E4023");
        let first = List.hd diagnostics in
        if
          not
            (contains_substring first.Diagnostic.message
               "the enum name `R` is reserved for the built-in `R` enum")
        then Alcotest.fail ("unexpected message: " ^ first.Diagnostic.message);
        let diagnostics = check "class R {\n  def init() {\n  }\n}" in
        Alcotest.(check bool) "class R" true (has_code diagnostics "E4023");
        let diagnostics = check "interface R {\n  def ok() String\n}\n" in
        Alcotest.(check bool) "interface R" true (has_code diagnostics "E4023");
        let diagnostics =
          check "emo R {\n  def ok() String {\n    return \"x\"\n  }\n}"
        in
        Alcotest.(check bool) "group R" true (has_code diagnostics "E4023");
        let diagnostics = check "class Exception {\n  def init() {\n  }\n}" in
        Alcotest.(check bool)
          "class Exception" true
          (has_code diagnostics "E4023");
        let diagnostics = check "enum Exception { boom }" in
        Alcotest.(check bool)
          "enum Exception" true
          (has_code diagnostics "E4023"));
    tc "the refusal rides the program-wide name set too" (fun () ->
        let diagnostics =
          check_program [ ("a", {|class R {
  def init() {
  }
}
|}) ]
        in
        Alcotest.(check bool) "E4023" true (has_code diagnostics "E4023"));
  ]

(* Bindings take a full pattern; the checker runs it through the same
   `check_pattern` a `case` arm uses — the pattern must fit the
   initializer's type, and the pattern's names enter scope. *)
let binding_pattern_tests =
  [
    tc "a plain binding checks clean" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length (check "const x = 1\nprintln(x)")));
    tc "a destructured binding checks like a case arm" (fun () ->
        Alcotest.(check int)
          "count" 0
          (List.length
             (check
                {|
def show(t (R, Int64)) Int64 {
  const (R.ok, body) = t
  return body
}

println(show((R.ok, 7)))|})));
    tc "the pattern's names carry the initializer's parts" (fun () ->
        let diagnostics =
          check
            {|
def show(n Int64) Int64 {
  return n
}

const (R.ok, body) = (R.ok, "seven")
println(show(body))|}
        in
        Alcotest.(check bool) "E4004" true (has_code diagnostics "E4004"));
    tc "a pattern that cannot fit refuses like a case pattern" (fun () ->
        let diagnostics = check "const (R.ok, body) = 5" in
        Alcotest.(check bool) "E4013" true (has_code diagnostics "E4013"));
    tc "a `raise` carries an Exception instance and nothing else" (fun () ->
        Alcotest.(check int)
          "exception raise" 0
          (List.length (check {|raise Exception.new(message: "boom")|}));
        let diagnostics = check {|raise "boom"|} in
        Alcotest.(check bool) "string raise" true (has_code diagnostics "E4024");
        let diagnostics =
          check {|
class Ink {
  def init() {
  }
}

raise Ink.new()|}
        in
        Alcotest.(check bool) "class raise" true (has_code diagnostics "E4024"));
  ]

let () =
  Alcotest.run "emo_check"
    [
      ("smoke", smoke_tests);
      ("collect", collect_tests);
      ("expression", expression_tests);
      ("signature", signature_tests);
      ("narrowing", narrowing_tests);
      ("interface", interface_tests);
      ("var_escape", var_escape_tests);
      ("loop", loop_tests);
      ("case", case_tests);
      ("void", void_tests);
      ("map", map_tests);
      ("corpus", corpus_tests);
      ("printf", printf_tests);
      ("expect", expect_tests);
      ("box", box_tests);
      ("array_builder", array_builder_tests);
      ("member_signature", member_signature_tests);
      ("field_type", field_type_tests);
      ("cross_module", cross_module_tests);
      ("callback", callback_tests);
      ("shape", shape_tests);
      ("r_enum", r_enum_tests);
      ("binding_pattern", binding_pattern_tests);
    ]
