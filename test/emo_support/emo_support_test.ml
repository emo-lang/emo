open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let span =
  Span.make ~file:"examples/user.emo" ~line:9 ~col:5 ~start:120 ~stop:133

let diagnostic ?code ?hint severity message =
  Diagnostic.{ severity; code; message; span; hint }

let rendered = String.concat "\n"

let span_tests =
  [
    tc "to_string renders file:line:col" (fun () ->
        Alcotest.(check string) "location" "examples/user.emo:9:5"
          (Span.to_string span));
    tc "make rejects a stop before the start" (fun () ->
        Alcotest.check_raises "inverted span"
          (Invalid_argument "Span.make: stop precedes start")
          (fun () ->
            ignore (Span.make ~file:"a.emo" ~line:1 ~col:1 ~start:10 ~stop:5)));
    tc "merge covers both spans" (fun () ->
        let later =
          Span.make ~file:"examples/user.emo" ~line:10 ~col:1 ~start:140 ~stop:145
        in
        let merged = Span.merge span later in
        Alcotest.(check int) "start" 120 merged.Span.start;
        Alcotest.(check int) "stop" 145 merged.Span.stop;
        Alcotest.(check string) "file" "examples/user.emo" merged.Span.file);
    tc "merge keeps the earliest start point" (fun () ->
        let earlier =
          Span.make ~file:"examples/user.emo" ~line:8 ~col:1 ~start:100 ~stop:110
        in
        let merged = Span.merge span earlier in
        Alcotest.(check int) "line" 8 merged.Span.line;
        Alcotest.(check int) "col" 1 merged.Span.col;
        Alcotest.(check int) "start" 100 merged.Span.start;
        Alcotest.(check int) "stop" 133 merged.Span.stop);
    tc "merge rejects spans from different files" (fun () ->
        let other = Span.make ~file:"other.emo" ~line:1 ~col:1 ~start:0 ~stop:1 in
        Alcotest.check_raises "different files"
          (Invalid_argument "Span.merge: spans belong to different files")
          (fun () -> ignore (Span.merge span other)));
  ]

let severity_tests =
  [
    tc "error and warning render their names" (fun () ->
        Alcotest.(check string) "error" "error" (Severity.to_string Severity.Error);
        Alcotest.(check string) "warning" "warning"
          (Severity.to_string Severity.Warning));
  ]

let renderer_tests =
  [
    tc "error with code and hint" (fun () ->
        let d =
          diagnostic ~code:"E2003" ~hint:"fields freeze after `init`" Severity.Error
            "assigning to `self.age` outside `init`"
        in
        Alcotest.(check string) "rendering"
          (rendered
             [
               "error[E2003]: assigning to `self.age` outside `init`";
               "  --> examples/user.emo:9:5";
               "  hint: fields freeze after `init`";
             ])
          (Render.render d));
    tc "error without code renders the bare severity" (fun () ->
        let d = diagnostic Severity.Error "something went wrong" in
        Alcotest.(check string) "rendering"
          (rendered
             [ "error: something went wrong"; "  --> examples/user.emo:9:5" ])
          (Render.render d));
    tc "warning without hint" (fun () ->
        let d = diagnostic ~code:"E1001" Severity.Warning "unused value" in
        Alcotest.(check string) "rendering"
          (rendered
             [ "warning[E1001]: unused value"; "  --> examples/user.emo:9:5" ])
          (Render.render d));
  ]

let () =
  Alcotest.run "emo_support"
    [ ("span", span_tests); ("renderer", renderer_tests); ("severity", severity_tests) ]
