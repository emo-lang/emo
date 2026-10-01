let tc name f = Alcotest.test_case name `Quick f

(* A scratch directory for fixture programs; files persist for the run. *)
let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-cli-test-fixtures"

let fixture name source =
  if not (Sys.file_exists scratch) then Unix.mkdir scratch 0o755;
  let path = Filename.concat scratch name in
  let oc = open_out_bin path in
  output_string oc source;
  close_out oc;
  path

let run_tests =
  [
    tc "a successful program exits 0" (fun () ->
        let file = fixture "ok.emo" "const x = 1\nprint(x + 1)\n" in
        Alcotest.(check int) "exit" 0 (Emo_cli.run_file ~file));
    tc "a parse error exits 65" (fun () ->
        let file = fixture "parse.emo" "const x =\n1\n" in
        Alcotest.(check int) "exit" 65 (Emo_cli.run_file ~file));
    tc "a runtime type error exits 70" (fun () ->
        let file = fixture "runtime.emo" {|print(1 + "a")|} in
        Alcotest.(check int) "exit" 70 (Emo_cli.run_file ~file));
    tc "an uncaught exception exits 1" (fun () ->
        let file = fixture "raise.emo" {|raise "boom"|} in
        Alcotest.(check int) "exit" 1 (Emo_cli.run_file ~file));
    tc "an unreadable file exits 66" (fun () ->
        Alcotest.(check int)
          "exit" 66
          (Emo_cli.run_file ~file:(Filename.concat scratch "missing.emo")));
  ]

let contains hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

let queue_input lines =
  let q = ref lines in
  fun () ->
    match !q with
    | [] -> None
    | line :: rest ->
        q := rest;
        Some line

let repl_tests =
  [
    tc "expression lines echo their value" (fun () ->
        let out = Buffer.create 64 in
        Emo_cli.repl_loop ~prompt:false
          ~input:(queue_input [ "1 + 2"; "exit" ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= 3\n" (Buffer.contents out));
    tc "definitions register and the environment persists" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:
            (queue_input
               [
                 "def double(n Int) Int {";
                 "  return n * 2";
                 "}";
                 "double(21)";
                 "exit";
               ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= 42\n" (Buffer.contents out));
    tc "runtime errors print and the environment survives" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:(queue_input [ "print(nope)"; "40 + 2"; "exit" ])
          ~output:(Buffer.add_string out);
        let text = Buffer.contents out in
        Alcotest.(check bool) "error reported" true (contains text "E3002");
        Alcotest.(check bool) "env survives" true (contains text "= 42"));
    tc "an uncaught raise prints and the repl survives" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:(queue_input [ {|raise "boom"|}; "2 * 3"; "exit" ])
          ~output:(Buffer.add_string out);
        let text = Buffer.contents out in
        Alcotest.(check bool) "raise reported" true (contains text "E3010");
        Alcotest.(check bool) "env survives" true (contains text "= 6"));
    tc "classes register in the repl" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:
            (queue_input
               [
                 "class Greeter {";
                 "  def init() {}";
                 "";
                 "  def greet() String {";
                 "    return \"hi\"";
                 "  }";
                 "}";
                 "Greeter.new().greet()";
                 "exit";
               ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= hi\n" (Buffer.contents out));
  ]

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_cli in
        ());
    tc "version matches the CLI contract" (fun () ->
        Alcotest.(check string) "version" "0.0.1" Emo_cli.version);
  ]

let () =
  Alcotest.run "emo_cli"
    [ ("smoke", smoke_tests); ("run", run_tests); ("repl", repl_tests) ]
