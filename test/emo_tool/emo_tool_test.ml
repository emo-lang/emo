let tc name f = Alcotest.test_case name `Quick f

(* True when the wait raised instead of returning. *)
let raises f = match f () with _ -> false | exception _ -> true

(* The runner's own contract. Each case here is a property the
   toolchain's builds rely on, so a regression shows up as a failing
   test rather than as a build that stops for no stated reason. *)
let runner_tests =
  [
    tc "a command that finishes returns its status" (fun () ->
        Alcotest.(check int) "exit 0" 0 (Emo_tool.run_status "exit 0");
        Alcotest.(check int) "exit 3" 3 (Emo_tool.run_status "exit 3"));
    tc "a signalled command is not mistaken for success" (fun () ->
        Alcotest.(check bool)
          "nonzero" true
          (Emo_tool.run_status "kill -KILL $$" <> 0));
    tc "captured stdout is the command's, and stderr stays out of it" (fun () ->
        let out, status =
          Emo_tool.run_capture "echo out; echo err >&2; exit 0"
        in
        Alcotest.(check string) "stdout" "out\n" out;
        Alcotest.(check bool) "status" true (Emo_tool.exit_code status = 0));
    tc "a probe answers with the first line" (fun () ->
        let line, status = Emo_tool.probe "printf 'first\\nsecond\\n'" in
        Alcotest.(check string) "first line" "first" line;
        Alcotest.(check bool) "status" true (Emo_tool.exit_code status = 0));
    tc "a probe of a missing tool answers with nothing" (fun () ->
        let line, status =
          Emo_tool.probe "command -v emo-no-such-tool-anywhere"
        in
        Alcotest.(check string) "no line" "" line;
        Alcotest.(check bool) "nonzero" true (Emo_tool.exit_code status <> 0));
    tc "a command that never finishes raises at the deadline" (fun () ->
        let started = Unix.gettimeofday () in
        let aborted =
          raises (fun () -> Emo_tool.run_status ~timeout:1.0 "sleep 30")
        in
        let elapsed = Unix.gettimeofday () -. started in
        Alcotest.(check bool) "raised" true aborted;
        Alcotest.(check bool)
          "at the deadline, not at the command's own end" true
          (elapsed >= 1.0 && elapsed < 15.0));
    tc "the deadline kills the whole process group" (fun () ->
        (* The shell is still running at the deadline because its
           foreground job hangs, and it has a backgrounded job of its own
           — a compiler driver's `as`, say. Killing the shell alone would
           leave that job working; only a group kill reaches it, so the
           line it would have written never appears. *)
        let marker = Printf.sprintf "emo-tool-orphan-%d" (Unix.getpid ()) in
        let cmd =
          Printf.sprintf "sh -c 'sleep 2; echo late > %s' & sleep 30" marker
        in
        let aborted = raises (fun () -> Emo_tool.run_status ~timeout:1.0 cmd) in
        Alcotest.(check bool) "raised" true aborted;
        Unix.sleepf 2.5;
        Alcotest.(check bool)
          "the backgrounded job was killed too" false (Sys.file_exists marker));
    tc "a grandchild holding the pipe cannot hold the wait open" (fun () ->
        (* The shell and its backgrounded child both outlive the command
           that was asked for: were the wait keyed on the pipe reaching
           EOF, the child's inherited write end would keep it blocked
           long past the shell's exit. *)
        let started = Unix.gettimeofday () in
        let _, status =
          Emo_tool.run_capture ~timeout:30.0 "sh -c 'sleep 8' & exit 0"
        in
        let elapsed = Unix.gettimeofday () -. started in
        Alcotest.(check bool)
          "the shell's own status" true
          (Emo_tool.exit_code status = 0);
        Alcotest.(check bool)
          "returned at the shell's exit, not at the pipe's close" true
          (elapsed < 4.0));
    tc "the deadline is per call, not a constant" (fun () ->
        Alcotest.(check bool)
          "a short deadline still lets a fast command through" true
          (Emo_tool.run_status ~timeout:0.5 "exit 0" = 0));
    tc "a tolerated command says what failed without raising" (fun () ->
        Alcotest.(check bool)
          "nonzero is false, not an exception" false
          (Emo_tool.run_or_warn ~what:"test" "exit 7");
        Alcotest.(check bool)
          "a timeout is false too" false
          (Emo_tool.run_or_warn ~what:"test" ~timeout:1.0 "sleep 30");
        Alcotest.(check bool)
          "success is true" true
          (Emo_tool.run_or_warn ~what:"test" "exit 0"));
  ]

let () = Alcotest.run "emo_tool" [ ("runner", runner_tests) ]
