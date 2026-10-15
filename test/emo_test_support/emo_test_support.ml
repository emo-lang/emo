(* The child-process wait the test executables share.

   A program under test can block: the `beam`, `wasm` and node-hosted
   targets have no deadlock detection, so where the `c` target and the
   interpreter print `deadlock` and exit 70, those simply never return.
   An unbounded wait on a pipe that never closes leaves the runner
   sitting there with no output saying which test stopped — so every
   wait carries a deadline. On expiry the child's whole process group is
   killed and the test fails naming the command it ran. *)

let deadline = 120.0

(* Runs [cmd] under the shell, capturing stdout and stderr apart, and
   returns them with the exit status. *)
let run_cmd ?(timeout = deadline) cmd =
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  let pid =
    match Unix.fork () with
    | 0 ->
        (* Its own session, so the deadline can kill the group: a shell
           that forks for `cc ... && ar ...` leaves no orphan behind. *)
        (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
        Unix.close out_r;
        Unix.close err_r;
        Unix.dup2 out_w Unix.stdout;
        Unix.dup2 err_w Unix.stderr;
        (* /dev/null rather than a pipe nobody writes to: a program that
           reads stdin then sees EOF instead of blocking on it. *)
        let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
        Unix.dup2 devnull Unix.stdin;
        Unix.close out_w;
        Unix.close err_w;
        Unix.close devnull;
        (try Unix.execvp "/bin/sh" [| "/bin/sh"; "-c"; cmd |] with _ -> ());
        Unix._exit 127
    | pid ->
        Unix.close out_w;
        Unix.close err_w;
        pid
  in
  let buf_out = Buffer.create 1024 and buf_err = Buffer.create 256 in
  let open_out_fd = ref true and open_err_fd = ref true in
  let timed_out = ref false in
  let chunk = Bytes.create 65536 in
  let deadline_at = Unix.gettimeofday () +. timeout in
  let drain fd buf =
    let n = Unix.read fd chunk 0 (Bytes.length chunk) in
    if n = 0 then begin
      Unix.close fd;
      false
    end
    else begin
      Buffer.add_subbytes buf chunk 0 n;
      true
    end
  in
  let give_up () =
    timed_out := true;
    if !open_out_fd then Unix.close out_r;
    if !open_err_fd then Unix.close err_r;
    open_out_fd := false;
    open_err_fd := false
  in
  (* The deadline is absolute, so a signal that interrupts `select` —
    EINTR — costs the wait nothing. *)
  let rec wait fds =
    let remaining = deadline_at -. Unix.gettimeofday () in
    if remaining <= 0.0 then []
    else
      match Unix.select fds [] [] remaining with
      | ready, _, _ -> ready
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait fds
  in
  while !open_out_fd || !open_err_fd do
    let fds =
      (if !open_out_fd then [ out_r ] else [])
      @ if !open_err_fd then [ err_r ] else []
    in
    match wait fds with
    | [] -> give_up ()
    | ready ->
        List.iter
          (fun fd ->
            if fd = out_r then open_out_fd := drain fd buf_out
            else open_err_fd := drain fd buf_err)
          ready
  done;
  if !timed_out then begin
    (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    ignore (Unix.waitpid [] pid);
    Alcotest.fail
      (Printf.sprintf
         "the command did not finish within %.0fs and was killed:\n\
          %s\n\
          --- stdout ---\n\
          %s\n\
          --- stderr ---\n\
          %s"
         timeout cmd (Buffer.contents buf_out) (Buffer.contents buf_err))
  end;
  let _, status = Unix.waitpid [] pid in
  (Buffer.contents buf_out, Buffer.contents buf_err, status)
