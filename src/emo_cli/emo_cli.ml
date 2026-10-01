open Cmdliner

let version = "0.0.1"

let print_version () =
  Printf.printf "emo %s\n" version;
  Cmd.Exit.ok

let not_implemented () =
  print_endline "not implemented yet";
  1

let render_diagnostic diagnostic =
  prerr_endline (Emo_support.Render.render diagnostic)

(* Runs one file through the lex → parse → evaluate pipeline and prints every
   stage's diagnostics. Exit codes: 0 success, 1 uncaught exception,
   65 lex/parse, 66 unreadable input, 70 evaluation. *)
let read_file file =
  let ic = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Runs one file through the lex → parse → evaluate pipeline and prints every
   stage's diagnostics. Exit codes: 0 success, 1 uncaught exception,
   65 lex/parse, 66 unreadable input, 70 evaluation. *)
let run_file ~(file : string) : int =
  match read_file file with
  | exception Sys_error message ->
      prerr_endline message;
      66
  | source -> (
      match Emo_parser.parse_program_with_diagnostics ~file ~source with
      | exception Emo_lexer.Error diagnostic ->
          render_diagnostic diagnostic;
          65
      | _, first :: rest ->
          render_diagnostic first;
          List.iter render_diagnostic rest;
          65
      | items, [] -> (
          match Emo_eval.run_items items with
          | () -> 0
          | exception Emo_eval.Error diagnostic -> (
              match diagnostic.Emo_support.Diagnostic.code with
              | Some "E3010" ->
                  render_diagnostic diagnostic;
                  1
              | _ ->
                  render_diagnostic diagnostic;
                  70)))

let run =
  let file = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE") in
  let run file =
    match run_file ~file with 0 -> Cmd.Exit.ok | code -> exit code
  in
  Cmd.v (Cmd.info "run" ~doc:"Run an Emo program.") Term.(const run $ file)

let repl =
  Cmd.v
    (Cmd.info "repl" ~doc:"Start an interactive Emo session.")
    Term.(const not_implemented $ const ())

let check =
  let path = Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH") in
  Cmd.v
    (Cmd.info "check" ~doc:"Check Emo files.")
    Term.(const (fun _ -> not_implemented ()) $ path)

let version_cmd =
  Cmd.v
    (Cmd.info "version" ~doc:"Print the version.")
    Term.(const print_version $ const ())

let cmd =
  Cmd.group
    (Cmd.info "emo" ~version ~doc:"The Emo programming language toolchain.")
    [ run; repl; check; version_cmd ]

let main () = exit (Cmd.eval' cmd)
