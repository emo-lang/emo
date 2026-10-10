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
    tc "an annotation naming an undeclared type is an error" (fun () ->
        let diagnostics = check "def f(x Widget) Int64 {\n  return 1\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005");
        Alcotest.(check string) "span" "test.emo:1:9" (span_of diagnostics));
    tc "parameterized annotation vocabulary resolves" (fun () ->
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
    tc "a bad parameterized annotation is an error" (fun () ->
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
            {|const box = Box.new(1)
const v = if true { box.get() } else { 2 }
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
       call-site checks (T8.7). *)
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

(* The step-08 acceptance corpus: strict-annotated rejections, inference
   successes, and the zero-false-positive discipline. *)
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
        (* The parser rejects the missing annotation before the checker
           runs; the program never reaches a false positive. *)
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
  ]

let void_tests =
  [
    tc "a def with no return annotation is a Void function" (fun () ->
        if List.length (check {|def log(msg String) {
  println(msg)
}|}) > 0
        then Alcotest.fail "expected a clean check");
    tc "an explicit Void annotation behaves like the omitted form" (fun () ->
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

(* The Map: literal inference, the annotation, Map.new, and the method
   surface. *)
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
    tc "the Map annotation type-checks and drives the method surface" (fun () ->
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
    tc "a wrong Map annotation arity is an unknown type" (fun () ->
        let diagnostics = check "def f(m Map[String]) Int64 {\n  return 1\n}" in
        Alcotest.(check bool) "E4005" true (has_code diagnostics "E4005"));
    tc "a bare Map annotation is the map of anything" (fun () ->
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
  let program, pre_errors = Emo_check.preregister_types ~units in
  let paths = List.map fst units in
  List.concat_map
    (fun (path, items) ->
      let diags, _refs, _requires =
        Emo_check.check_module ~modules:paths ~current:path ~program items
      in
      diags)
    units
  @ pre_errors

let cross_module_tests =
  [
    tc "an annotation names another module's type" (fun () ->
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
                {|def view() VNode {
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
                {|def show(c Crate) Int64 {
  return c.area()
}

println(show(Crate.new()))|}
              );
            ]
        in
        if List.length diagnostics > 0 then
          Alcotest.fail ("codes: " ^ codes_dump diagnostics));
    tc "a type name declared twice is a loud collision" (fun () ->
        let diagnostics =
          check_program
            [
              ("a", {|class Widget {
  def init() {
    self.w = 1
  }
}
|});
              ("b", {|class Widget {
  def init() {
    self.w = 2
  }
}
|});
            ]
        in
        Alcotest.(check bool) "E4021" true (has_code diagnostics "E4021");
        let collision =
          List.find (fun d -> d.Diagnostic.code = Some "E4021") diagnostics
        in
        if
          not
            (contains_substring collision.Diagnostic.message "module `a`"
            && contains_substring collision.Diagnostic.message "module `b`")
        then
          Alcotest.fail
            ("collision does not name both modules: "
           ^ collision.Diagnostic.message));
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
      ("case", case_tests);
      ("void", void_tests);
      ("map", map_tests);
      ("corpus", corpus_tests);
      ("printf", printf_tests);
      ("cross_module", cross_module_tests);
    ]
