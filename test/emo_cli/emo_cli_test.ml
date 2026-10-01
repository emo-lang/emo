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

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_cli in
        ());
    tc "version matches the CLI contract" (fun () ->
        Alcotest.(check string) "version" "0.0.1" Emo_cli.version);
  ]

let () = Alcotest.run "emo_cli" [ ("smoke", smoke_tests); ("run", run_tests) ]
