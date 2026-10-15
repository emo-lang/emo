let tc name f = Alcotest.test_case name `Quick f

(* True when the wait aborted instead of returning. *)
let aborts f = match f () with _ -> false | exception _ -> true

let deadline_tests =
  [
    tc "a command that finishes returns its streams and status" (fun () ->
        let out, err, status =
          Emo_test_support.run_cmd "echo out; echo err >&2"
        in
        Alcotest.(check string) "stdout" "out\n" out;
        Alcotest.(check string) "stderr" "err\n" err;
        Alcotest.(check bool) "exit status" true (status = Unix.WEXITED 0));
    tc "a command that never finishes is killed at the deadline" (fun () ->
        let started = Unix.gettimeofday () in
        let aborted =
          aborts (fun () -> Emo_test_support.run_cmd ~timeout:1.0 "sleep 30")
        in
        let elapsed = Unix.gettimeofday () -. started in
        Alcotest.(check bool) "aborted" true aborted;
        Alcotest.(check bool)
          "at the deadline, not at the command's own end" true
          (elapsed >= 1.0 && elapsed < 15.0));
    tc "the deadline kills the whole process group" (fun () ->
        (* The shell exits at once, but its backgrounded child outlives it
           holding the pipe open — the shape that hangs a runner with no
           deadline. Only a group kill reaches that child. *)
        let marker = Printf.sprintf "deadline-orphan-%d" (Unix.getpid ()) in
        let cmd =
          Printf.sprintf "sh -c 'sleep 2; echo late > %s' & echo started" marker
        in
        let aborted =
          aborts (fun () -> Emo_test_support.run_cmd ~timeout:1.0 cmd)
        in
        Alcotest.(check bool) "aborted" true aborted;
        Unix.sleepf 2.5;
        Alcotest.(check bool)
          "the backgrounded child was killed too" false (Sys.file_exists marker));
  ]

let () = Alcotest.run "emo_test_support" [ ("deadline", deadline_tests) ]
