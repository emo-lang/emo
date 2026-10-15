(* Bounded waits on the external tools the toolchain runs.

   A build shells out to cc, erlc, as, ld, ocamlfind and friends. Any of
   them can wedge — a compiler waiting on a lock, a fetch waiting on a
   socket — and an unbounded wait leaves the toolchain sitting there
   with no output saying which step stopped. So every wait the toolchain
   performs on a tool carries a deadline: on expiry the child's whole
   process group is SIGKILLed and [Timeout] is raised naming the
   command.

   Running the *user's* program is the one thing that stays unbounded —
   it may legitimately run forever. Nothing here is used for that. *)

exception Timeout of { command : string; timeout : float }

(* A toolchain step: cc, erlc, as, ld, ocamlfind. Generous on purpose —
   a cold OCaml link on a loaded machine is slow, and a false timeout
   costs more than a late one. *)
let step_deadline = 600.0

(* A probe: `command -v`, `<tool> --version`, a smoke run. These answer
   in milliseconds or not at all. *)
let probe_deadline = 10.0

(* A [Timeout] escaping an unconverted wait still has to name the
   command that hung, not print as an opaque exception. *)
let () =
  Printexc.register_printer (function
    | Timeout { command; timeout } ->
        Some
          (Printf.sprintf "the command did not finish within %.0fs: %s" timeout
             command)
    | _ -> None)

(* The deadline is absolute and on the wall clock — OCaml's Unix binds
   no monotonic one, and every other timer in this tree (the runtime's
   timeouts, the test-side wait) reads the same clock. A step that the
   system clock moves backwards past the deadline would be cut short;
   at 600s that is not a hazard worth a dependency. *)
let now () = Unix.gettimeofday ()

(* The shell's convention, and what `sh -c` itself reports for a job it
   lost to a signal. *)
let exit_code (status : Unix.process_status) : int =
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

(* Captured output beyond this is dropped: a runaway tool must not be
   able to exhaust memory through the pipe. *)
let capture_limit = 256 * 1024
let tick = 0.05

(* Runs [cmd] under the shell and returns its stdout (empty unless
   [capture]) with the exit status.

   The shell stays in the middle on purpose: the commands here use
   `2>&1`, `cd … && …` and `VAR=… tool …`. It is also why the deadline
   kills the *group* — the shell is what forks cc's `as` and `ld`. *)
let run_common ~(capture : bool) ~(timeout : float) (cmd : string) :
    string * Unix.process_status =
  let pipe = if capture then Some (Unix.pipe ()) else None in
  match Unix.fork () with
  | 0 ->
      (* Its own session, so its pid is also its process group id:
         the deadline can reach everything the shell forks and can
         never reach the toolchain that owns this process. *)
      (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
      (match pipe with
      | Some (r, w) ->
          Unix.close r;
          Unix.dup2 w Unix.stdout;
          Unix.close w
      | None -> ());
      (* /dev/null rather than the terminal: a tool that reads stdin
         sees EOF instead of blocking on it. stderr is inherited in
         both modes — compiler diagnostics belong on the terminal. *)
      let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      Unix.dup2 devnull Unix.stdin;
      Unix.close devnull;
      (try Unix.execvp "/bin/sh" [| "/bin/sh"; "-c"; cmd |] with _ -> ());
      Unix._exit 127
  | pid -> (
      let read_end =
        match pipe with
        | Some (r, w) ->
            Unix.close w;
            Unix.set_nonblock r;
            Some r
        | None -> None
      in
      let out = Buffer.create 4096 in
      let chunk = Bytes.create 65536 in
      let drain () =
        match read_end with
        | None -> ()
        | Some fd ->
            let rec go () =
              match Unix.read fd chunk 0 (Bytes.length chunk) with
              | 0 -> ()
              | n ->
                  if Buffer.length out < capture_limit then
                    Buffer.add_subbytes out chunk 0 n;
                  go ()
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
              | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> ()
              | exception Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ()
            in
            go ()
      in
      let status = ref None in
      let timed_out = ref false in
      let deadline = now () +. timeout in
      (* Termination is keyed on the child being *reaped*, never on the
         pipe reaching EOF: a grandchild that inherited the write end
         and outlives the shell must not be able to hold this wait
         open. *)
      let rec wait () =
        (match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ -> ()
        | _, st -> status := Some st
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
        drain ();
        if !status = None then
          if now () -. deadline >= 0.0 then timed_out := true
          else begin
            ignore (Unix.select [] [] [] tick);
            wait ()
          end
      in
      wait ();
      (match read_end with
      | Some fd -> ( try Unix.close fd with Unix.Unix_error _ -> ())
      | None -> ());
      match !status with
      | Some st -> (Buffer.contents out, st)
      | None ->
          (* Out of time. The group first — whatever the shell forked
             dies with it — then the pid itself, covering the window
             before setsid. SIGKILL with no grace: a wedged compiler
             will not answer SIGTERM, and this wait cannot hang. *)
          (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ());
          raise (Timeout { command = cmd; timeout }))

(* A build step with stdio inherited, so compiler diagnostics reach the
   terminal as they are produced. *)
let run_status ?(timeout = step_deadline) (cmd : string) : int =
  let _, status = run_common ~capture:false ~timeout cmd in
  exit_code status

(* A step whose stdout is the answer. *)
let run_capture ?(timeout = step_deadline) (cmd : string) :
    string * Unix.process_status =
  run_common ~capture:true ~timeout cmd

(* The first line of stdout, trimmed, with the status — the shape every
   probe in the toolchain wants (`command -v`, `<tool> --version`, a
   smoke binary's single line). *)
let probe ?(timeout = probe_deadline) (cmd : string) :
    string * Unix.process_status =
  let out, status = run_capture ~timeout cmd in
  let line =
    match String.index_opt out '\n' with
    | Some i -> String.sub out 0 i
    | None -> out
  in
  (String.trim line, status)

(* For waits whose result is already tolerated when it fails — a cache
   copy, a directory that is about to be written into anyway. Never
   raises; says what went wrong and returns whether it worked. *)
let run_or_warn ?(timeout = step_deadline) ~(what : string) (cmd : string) :
    bool =
  match run_common ~capture:false ~timeout cmd with
  | _, status when exit_code status = 0 -> true
  | _, status ->
      Printf.eprintf "%s: the command failed (exit %d): %s\n%!" what
        (exit_code status) cmd;
      false
  | exception Timeout { timeout; _ } ->
      Printf.eprintf
        "%s: the command did not finish within %.0fs and was killed: %s\n%!"
        what timeout cmd;
      false
