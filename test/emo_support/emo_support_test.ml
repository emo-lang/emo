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

let span =
  Span.make ~file:"examples/user.emo" ~line:9 ~col:5 ~start:120 ~stop:133

let diagnostic ?code ?hint severity message =
  Diagnostic.{ severity; code; message; span; hint }

let rendered = String.concat "\n"

(* A source whose ninth line matches the spec's excerpt example. *)
let source =
  String.concat "\n"
    [
      "class User {";
      "  def init(name String, age Int) {";
      "    self.name = name";
      "    self.age = age";
      "  }";
      "";
      "  // years pass";
      "";
      "  def birthday() Int {";
      "    return age + 1";
      "  }";
      "";
      "  def describe() String {";
      "    return self.age.to_string()";
      "  }";
      "}";
    ]

let diagnostic ?code ?hint severity message =
  Diagnostic.{ severity; code; message; span; hint }

let renderer_tests =
  [
    tc "an excerpt with carets and an inline hint" (fun () ->
        let d =
          diagnostic ~code:"E2003" ~hint:"fields freeze after `init`"
            Severity.Error "assigning to `self.age` outside `init`"
        in
        Alcotest.(check string)
          "rendering"
          (rendered
             [
               "error[E2003]: assigning to `self.age` outside `init`";
               "  --> examples/user.emo:9:5";
               "  |";
               "9 |   def birthday() Int {";
               "  |     ^^^^^^^^^^^^^ fields freeze after `init`";
             ])
          (Render.render ~source d));
    tc "a caret lands on the diagnostic column" (fun () ->
        let span =
          Span.make ~file:"examples/user.emo" ~line:14 ~col:13 ~start:230
            ~stop:245
        in
        let d =
          Diagnostic.
            {
              severity = Error;
              code = Some "E3007";
              message = "no such method";
              span;
              hint = None;
            }
        in
        Alcotest.(check string)
          "rendering"
          (rendered
             [
               "error[E3007]: no such method";
               "  --> examples/user.emo:14:13";
               "   |";
               "14 |     return self.age.to_string()";
               "   |             ^^^^^^^^^^^^^^^";
             ])
          (Render.render ~source d));
    tc "errors without codes or hints stay terse" (fun () ->
        let d = diagnostic Severity.Error "something went wrong" in
        Alcotest.(check string)
          "rendering"
          (rendered
             [
               "error: something went wrong";
               "  --> examples/user.emo:9:5";
               "  |";
               "9 |   def birthday() Int {";
               "  |     ^^^^^^^^^^^^^";
             ])
          (Render.render ~source d));
    tc "warnings keep their severity label" (fun () ->
        let d = diagnostic ~code:"E1001" Severity.Warning "unused value" in
        Alcotest.(check string)
          "rendering"
          (rendered
             [
               "warning[E1001]: unused value";
               "  --> examples/user.emo:9:5";
               "  |";
               "9 |   def birthday() Int {";
               "  |     ^^^^^^^^^^^^^";
             ])
          (Render.render ~source d));
    tc "color wraps the severity label in ANSI red" (fun () ->
        let d = diagnostic Severity.Error "something went wrong" in
        let text = Render.render ~color:true ~source d in
        Alcotest.(check bool)
          "has escape" true
          (contains_substring text "\027[31;1merror\027[0m"));
    tc "render_all sorts by position" (fun () ->
        let early =
          Diagnostic.
            {
              severity = Error;
              code = Some "E2001";
              message = "early";
              span = Span.make ~file:"a.emo" ~line:2 ~col:1 ~start:10 ~stop:11;
              hint = None;
            }
        in
        let late =
          Diagnostic.
            {
              severity = Error;
              code = Some "E2002";
              message = "late";
              span = Span.make ~file:"a.emo" ~line:7 ~col:1 ~start:60 ~stop:61;
              hint = None;
            }
        in
        let text = Render.render_all ~limit:None ~source [ late; early ] in
        let early_at =
          let rec go i =
            if contains_substring (String.sub text 0 i) "early" then i
            else go (i + 1)
          in
          go 1
        in
        let late_at =
          let rec go i =
            if contains_substring (String.sub text 0 i) "late" then i
            else go (i + 1)
          in
          go 1
        in
        Alcotest.(check bool)
          "early renders before late" true (early_at < late_at));
    tc "render_all caps at the error limit" (fun () ->
        let mk line =
          Diagnostic.
            {
              severity = Error;
              code = Some "E2001";
              message = Printf.sprintf "err%d" line;
              span = Span.make ~file:"a.emo" ~line ~col:1 ~start:0 ~stop:1;
              hint = None;
            }
        in
        let text =
          Render.render_all ~limit:(Some 2) ~source [ mk 2; mk 5; mk 9 ]
        in
        Alcotest.(check bool)
          "shows the first two" true
          (contains_substring text "err2" && contains_substring text "err5");
        Alcotest.(check bool)
          "hides the rest" true
          ((not (contains_substring text "err9"))
          && contains_substring text "1 more error(s) hidden"));
  ]

let span_tests =
  [
    tc "to_string renders file:line:col" (fun () ->
        Alcotest.(check string)
          "location" "examples/user.emo:9:5" (Span.to_string span));
    tc "make rejects a stop before the start" (fun () ->
        Alcotest.check_raises "inverted span"
          (Invalid_argument "Span.make: stop precedes start") (fun () ->
            ignore (Span.make ~file:"a.emo" ~line:1 ~col:1 ~start:10 ~stop:5)));
    tc "merge covers both spans" (fun () ->
        let later =
          Span.make ~file:"examples/user.emo" ~line:10 ~col:1 ~start:140
            ~stop:145
        in
        let merged = Span.merge span later in
        Alcotest.(check int) "start" 120 merged.Span.start;
        Alcotest.(check int) "stop" 145 merged.Span.stop;
        Alcotest.(check string) "file" "examples/user.emo" merged.Span.file);
    tc "merge keeps the earliest start point" (fun () ->
        let earlier =
          Span.make ~file:"examples/user.emo" ~line:8 ~col:1 ~start:100
            ~stop:110
        in
        let merged = Span.merge span earlier in
        Alcotest.(check int) "line" 8 merged.Span.line;
        Alcotest.(check int) "col" 1 merged.Span.col;
        Alcotest.(check int) "start" 100 merged.Span.start;
        Alcotest.(check int) "stop" 133 merged.Span.stop);
    tc "merge rejects spans from different files" (fun () ->
        let other =
          Span.make ~file:"other.emo" ~line:1 ~col:1 ~start:0 ~stop:1
        in
        Alcotest.check_raises "different files"
          (Invalid_argument "Span.merge: spans belong to different files")
          (fun () -> ignore (Span.merge span other)));
  ]

let severity_tests =
  [
    tc "error and warning render their names" (fun () ->
        Alcotest.(check string)
          "error" "error"
          (Severity.to_string Severity.Error);
        Alcotest.(check string)
          "warning" "warning"
          (Severity.to_string Severity.Warning));
  ]

let () =
  Alcotest.run "emo_support"
    [
      ("span", span_tests);
      ("renderer", renderer_tests);
      ("severity", severity_tests);
    ]
