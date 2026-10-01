open Cmdliner

let version = "0.0.1"

let print_version () =
  Printf.printf "emo %s\n" version;
  Cmd.Exit.ok

let not_implemented () =
  print_endline "not implemented yet";
  1

let render_diagnostic source diagnostic =
  prerr_endline (Emo_support.Render.render ~source diagnostic)

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
      let render = render_diagnostic source in
      match Emo_parser.parse_program_with_diagnostics ~file ~source with
      | exception Emo_lexer.Error diagnostic ->
          render diagnostic;
          65
      | _, first :: rest ->
          render first;
          List.iter render rest;
          65
      | items, [] -> (
          match Emo_eval.run_items items with
          | () -> 0
          | exception Emo_eval.Error diagnostic -> (
              match diagnostic.Emo_support.Diagnostic.code with
              | Some "E3010" ->
                  render diagnostic;
                  1
              | _ ->
                  render diagnostic;
                  70)))

let run =
  let file = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE") in
  let run file =
    match run_file ~file with 0 -> Cmd.Exit.ok | code -> exit code
  in
  Cmd.v (Cmd.info "run" ~doc:"Run an Emo program.") Term.(const run $ file)

(* True while the source still has open brackets or an unterminated string —
   the REPL keeps reading with a continuation prompt. *)
let unbalanced source =
  match Emo_lexer.lex ~file:"<repl>" ~source with
  | stream ->
      let depth =
        List.fold_left
          (fun d tok ->
            match tok.Emo_lexer.Token.kind with
            | Emo_lexer.Token.(Op LParen | Op LBracket | Op LBrace) -> d + 1
            | Emo_lexer.Token.(Op RParen | Op RBracket | Op RBrace) -> d - 1
            | _ -> d)
          0
          (Emo_lexer.Stream.to_list stream)
      in
      depth > 0
  | exception Emo_lexer.Error _ -> true

(* The interactive loop: definitions register, statements run, and expression
   lines echo their value (a REPL convenience, not a language rule). Runtime
   errors print and the environment survives. *)
let repl_loop ~(prompt : bool) ~(input : unit -> string option)
    ~(output : string -> unit) : unit =
  Hashtbl.reset Emo_eval.interface_registry;
  let env = Emo_eval.global_env () in
  let evaluate source =
    let render d = output (Emo_support.Render.render ~source d ^ "\n") in
    match Emo_parser.parse_program_with_diagnostics ~file:"<repl>" ~source with
    | exception Emo_lexer.Error diagnostic -> render diagnostic
    | _, first :: rest ->
        render first;
        List.iter render rest
    | items, [] -> (
        try
          List.iter
            (fun item ->
              match item.Emo_ast.item_desc with
              | Emo_ast.Item_stmt { Emo_ast.stmt_desc = Emo_ast.Expr_stmt e; _ }
                ->
                  output
                    ("= " ^ Emo_eval.to_string (Emo_eval.eval_expr env e) ^ "\n")
              | _ -> Emo_eval.eval_item env item)
            items
        with Emo_eval.Error diagnostic -> render diagnostic)
  in
  let rec loop pending =
    if prompt then output (if pending = "" then "emo> " else "... ");
    match input () with
    | None -> if prompt then output "\n"
    | Some "exit" when pending = "" -> ()
    | Some line ->
        let source = if pending = "" then line else pending ^ "\n" ^ line in
        if unbalanced source then loop source
        else
          let () = evaluate source in
          loop ""
  in
  loop ""

let start_repl () =
  repl_loop ~prompt:true
    ~input:(fun () ->
      match read_line () with
      | line -> Some line
      | exception End_of_file -> None)
    ~output:(fun s ->
      print_string s;
      flush stdout);
  0

let repl =
  Cmd.v
    (Cmd.info "repl" ~doc:"Start an interactive Emo session.")
    Term.(const start_repl $ const ())

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
