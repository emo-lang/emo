open Cmdliner

let version = "0.0.1"

let print_version () =
  Printf.printf "emo %s\n" version;
  Cmd.Exit.ok

let not_implemented () =
  print_endline "not implemented yet";
  1

let static_flags () =
  let no_color =
    Arg.(value & flag & info [ "no-color" ] ~doc:"Disable colored diagnostics.")
  in
  let error_limit =
    Arg.(
      value & opt int 20
      & info [ "error-limit" ] ~doc:"Maximum reported errors.")
  in
  (no_color, error_limit)

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

(* The static stage shared by run and check: parse, then type-check. Renders
   every diagnostic; returns the exit code when the program must not
   proceed (None when it is clean). *)
let static_stage ~file ~(source : string) ~(color : bool) ~(error_limit : int) :
    int option =
  let render_all diagnostics =
    prerr_endline
      (Emo_support.Render.render_all ~color ~limit:(Some error_limit) ~source
         diagnostics)
  in
  match Emo_parser.parse_program_with_diagnostics ~file ~source with
  | exception Emo_lexer.Error diagnostic ->
      render_all [ diagnostic ];
      Some 65
  | _, (_ :: _ as diagnostics) ->
      render_all diagnostics;
      Some 65
  | items, [] -> (
      let diagnostics = Emo_check.check_parsed items in
      match diagnostics with
      | [] -> None
      | _ ->
          render_all diagnostics;
          Some 65)

(* Runs one file through the lex → parse → check → evaluate pipeline and
   prints every stage's diagnostics. Exit codes: 0 success, 1 uncaught
   exception, 65 lex/parse/check, 66 unreadable input, 70 evaluation. *)
let run_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match read_file file with
  | exception Sys_error message ->
      prerr_endline message;
      66
  | source -> (
      let render diagnostic =
        prerr_endline (Emo_support.Render.render ~color ~source diagnostic)
      in
      match static_stage ~file ~source ~color ~error_limit with
      | Some code -> code
      | None -> (
          match
            Emo_eval.run_items
              (match
                 Emo_parser.parse_program_with_diagnostics ~file ~source
               with
              | items, _ -> items
              | exception _ -> [])
          with
          | () -> 0
          | exception Emo_eval.Error diagnostic -> (
              match diagnostic.Emo_support.Diagnostic.code with
              | Some "E3010" ->
                  render diagnostic;
                  1
              | _ ->
                  render diagnostic;
                  70)))

(* `emo check`: the static stage only. *)
let check_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match read_file file with
  | exception Sys_error message ->
      prerr_endline message;
      66
  | source -> (
      match static_stage ~file ~source ~color ~error_limit with
      | Some code -> code
      | None -> 0)

let run =
  let file = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE") in
  let no_color =
    Arg.(value & flag & info [ "no-color" ] ~doc:"Disable colored diagnostics.")
  in
  let error_limit =
    Arg.(
      value & opt int 20
      & info [ "error-limit" ] ~doc:"Maximum reported errors.")
  in
  let run file no_color error_limit =
    let color = (not no_color) && Unix.isatty Unix.stderr in
    match run_file ~file ~color ~error_limit with
    | 0 -> Cmd.Exit.ok
    | code -> exit code
  in
  Cmd.v
    (Cmd.info "run" ~doc:"Run an Emo program.")
    Term.(const run $ file $ no_color $ error_limit)

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
        with
        | Emo_eval.Error diagnostic -> render diagnostic
        | Emo_eval.Emo_raise (v, span, trace) ->
            render (Emo_eval.uncaught_diagnostic (v, span, trace)))
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
  let file = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE") in
  let no_color, error_limit = static_flags () in
  let check file no_color error_limit =
    let color = (not no_color) && Unix.isatty Unix.stderr in
    match check_file ~file ~color ~error_limit with
    | 0 -> Cmd.Exit.ok
    | code -> exit code
  in
  Cmd.v
    (Cmd.info "check" ~doc:"Check an Emo file without running it.")
    Term.(const check $ file $ no_color $ error_limit)

let version_cmd =
  Cmd.v
    (Cmd.info "version" ~doc:"Print the version.")
    Term.(const print_version $ const ())

let cmd =
  Cmd.group
    (Cmd.info "emo" ~version ~doc:"The Emo programming language toolchain.")
    [ run; repl; check; version_cmd ]

let main () = exit (Cmd.eval' cmd)
