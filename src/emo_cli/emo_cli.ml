open Cmdliner

let version = "0.0.1"

let not_yet () =
  print_endline "not implemented yet";
  1

let print_version () =
  Printf.printf "emo %s\n" version;
  Cmd.Exit.ok

let run =
  let file =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE")
  in
  Cmd.v
    (Cmd.info "run" ~doc:"Run an Emo program.")
    (Term.(const (fun _ -> not_yet ()) $ file))

let repl =
  Cmd.v
    (Cmd.info "repl" ~doc:"Start an interactive Emo session.")
    Term.(const not_yet $ const ())

let check =
  let path =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  Cmd.v
    (Cmd.info "check" ~doc:"Check Emo files.")
    (Term.(const (fun _ -> not_yet ()) $ path))

let version_cmd =
  Cmd.v
    (Cmd.info "version" ~doc:"Print the version.")
    Term.(const print_version $ const ())

let cmd =
  Cmd.group
    (Cmd.info "emo" ~version ~doc:"The Emo programming language toolchain.")
    [ run; repl; check; version_cmd ]

let main () = exit (Cmd.eval' cmd)
