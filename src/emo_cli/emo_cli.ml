open Cmdliner

let version = Version.version

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

(* Renders a batch of diagnostics, capped at the error limit, with the
   project root as the excerpt source. *)
let render_errors ~(color : bool) ~(error_limit : int)
    (diagnostics : Emo_support.Diagnostic.t list) : unit =
  match diagnostics with
  | [] -> ()
  | _ ->
      let source = Sys.getcwd () in
      prerr_endline
        (Emo_support.Render.render_all ~color ~limit:(Some error_limit) ~source
           diagnostics)

(* Raised when compiling the generated FFI wrappers with cc fails. *)
exception Stub_cc_failed

(* Runs one file through the project pipeline: discover the module tree,
   check every module, then evaluate. Exit codes: 0 success, 1 uncaught
   exception, 65 lex/parse/check, 66 unreadable input, 70 evaluation. *)
let run_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match Sys.file_exists file with
  | false ->
      prerr_endline (Printf.sprintf "%s: No such file or directory" file);
      66
  | true -> (
      let render diagnostic =
        render_errors ~color ~error_limit [ diagnostic ]
      in
      try
        ignore
          (Emo_project.run_entry ~entry_file:file ~check:true
             ~sched:Emo_project.Own ());
        0
      with
      | Emo_project.Static_errors diagnostics ->
          render_errors ~color ~error_limit diagnostics;
          (* An uncaught raise terminated the run: exit 1, not 65. *)
          let uncaught =
            List.exists
              (fun d ->
                match d.Emo_support.Diagnostic.code with
                | Some "E3010" -> true
                | _ -> false)
              diagnostics
          in
          if uncaught then 1 else 65
      | Emo_lexer.Error diagnostic ->
          render diagnostic;
          65
      | Emo_eval.Error diagnostic -> (
          match diagnostic.Emo_support.Diagnostic.code with
          | Some "E3010" ->
              render diagnostic;
              1
          | _ ->
              render diagnostic;
              70))

(* ---- `emo build`: compile to a native binary ----

   Pipeline: resolve + check the project (the same static stages as
   `emo run`), lower every module to the IR, emit OCaml, and hand the
   file to the OCaml toolchain with the runtime libraries. The runtime's
   compiled interfaces are located relative to the emo executable —
   building requires the emo source tree today. *)

(* The OCaml toolchain comes from the opam switch: PATH first, then the
   switch prefixes under ~/.opam (dune test actions run without the opam
   environment). *)
let find_ocamlfind () : string =
  (* A switch qualifies when it has the tool AND the ssl library the
     runtime links; the running switch is preferred, then the newest
     qualifying switch under ~/.opam, then PATH. *)
  let qualifies sw =
    Sys.file_exists (Filename.concat (Filename.concat sw "bin") "ocamlfind")
    && Sys.file_exists (Filename.concat (Filename.concat sw "lib") "ssl")
  in
  let switch_bin sw = Filename.concat (Filename.concat sw "bin") "ocamlfind" in
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"" in
  let opam_dir = Filename.concat home ".opam" in
  let from_prefix =
    match Sys.getenv_opt "OPAM_SWITCH_PREFIX" with
    | Some prefix when qualifies prefix -> Some (switch_bin prefix)
    | _ -> None
  in
  match from_prefix with
  | Some path -> path
  | None -> (
      let entries =
        if Sys.file_exists opam_dir then
          Array.to_list (Sys.readdir opam_dir)
          |> List.filter (fun e -> e <> "config" && e <> "config.lock")
          |> List.filter (fun sw -> qualifies (Filename.concat opam_dir sw))
          |> List.sort (fun a b -> compare b a)
        else []
      in
      match entries with
      | sw :: _ -> switch_bin (Filename.concat opam_dir sw)
      | [] -> "ocamlfind")

(* The build command: entry file → artifact at [-o] (default: the
   entry's stem in the current directory). The target picks the
   backend: native (default) compiles through the OCaml toolchain;
   typescript emits one self-contained .ts file that runs on Node. *)
let build_file ~(entry : string) ~(output : string) ~(specialize : bool)
    ~(cclibs : string list) ~(target : string) : int =
  match Sys.file_exists entry with
  | false ->
      prerr_endline (Printf.sprintf "%s: No such file or directory" entry);
      66
  | true -> (
      try
        let inputs, entry_path, _manifest =
          Emo_project.compile_inputs ~entry_file:entry ~target
        in
        let program =
          Emo_ir.lower { Emo_ir.modules = inputs; entry = entry_path }
        in
        let build_dir = Filename.concat (Sys.getcwd ()) ".emo-build" in
        if not (Sys.file_exists build_dir) then
          ignore
            (Sys.command
               (Printf.sprintf "mkdir -p %s" (Filename.quote build_dir)));
        (* The runtime artifacts ride the build tree next to the emo
           binary; the path is resolved through symlinks so an
           installed alias still finds them. *)
        let exe_dir =
          Filename.dirname
            (try Unix.realpath Sys.executable_name
             with _ -> Sys.executable_name)
        in
        let src_dir = Filename.concat exe_dir ".." in
        match target with
        | "wasm" ->
            let module_ = Emo_codegen.Wasm.assemble program in
            let out =
              if Filename.check_suffix output ".wasm" then output
              else output ^ ".wasm"
            in
            let out_wat = Filename.remove_extension out ^ ".wat" in
            let binary = Emo_codegen.Wasm.to_binary module_ in
            let oc = open_out_bin out in
            output_string oc binary;
            close_out oc;
            let oc = open_out_bin out_wat in
            output_string oc (Emo_codegen.Wasm.to_text module_);
            close_out oc;
            Printf.printf "built %s\n" out;
            0
        | "beam" ->
            (* the .core file stem is the BEAM module atom: always
               emo_main, next to the requested output *)
            let core = Emo_codegen.Beam.emit program in
            let out =
              Filename.concat (Filename.dirname output) "emo_main.core"
            in
            let oc = open_out_bin out in
            output_string oc core;
            close_out oc;
            let beam = Filename.remove_extension out ^ ".beam" in
            let rc =
              Sys.command (Printf.sprintf "erlc %s" (Filename.quote out))
            in
            if rc <> 0 then (
              prerr_endline (Printf.sprintf "emo build: erlc failed on %s" out);
              70)
            else (
              Printf.printf "built %s\n" beam;
              0)
        | "typescript" -> (
            let runtime_path =
              Filename.concat
                (Filename.concat src_dir "emo_codegen")
                "ts_prelude.ts"
            in
            match Sys.file_exists runtime_path with
            | false ->
                prerr_endline
                  "emo build: the TypeScript runtime prelude is missing from \
                   the installation";
                70
            | true ->
                let ic = open_in_bin runtime_path in
                let runtime = really_input_string ic (in_channel_length ic) in
                close_in ic;
                let source = Emo_codegen.Ts.emit_ts ~runtime program in
                let digest =
                  Digest.to_hex
                    (Digest.string (Printf.sprintf "ts|%s|%s" source runtime))
                in
                let cache_file = Filename.concat build_dir ("ts-" ^ digest) in
                let out =
                  if Filename.check_suffix output ".ts" then output
                  else output ^ ".ts"
                in
                if Sys.file_exists cache_file then begin
                  ignore
                    (Sys.command
                       (Printf.sprintf "cp %s %s"
                          (Filename.quote cache_file)
                          (Filename.quote out)));
                  Printf.printf "built %s (cached)\n" out;
                  0
                end
                else begin
                  let oc = open_out_bin cache_file in
                  output_string oc source;
                  close_out oc;
                  ignore
                    (Sys.command
                       (Printf.sprintf "cp %s %s"
                          (Filename.quote cache_file)
                          (Filename.quote out)));
                  Printf.printf "built %s\n" out;
                  0
                end)
        | "native" ->
            let source = Emo_codegen.emit ~specialize program in
            (* Incremental: the digest of the emitted source plus the
               digests of the runtime libraries names the cached binary —
               an unchanged program (and unchanged runtime) skips the
               toolchain entirely, and any runtime change invalidates the
               cache. *)
            let libs =
              [
                "emo_support";
                "emo_lexer";
                "emo_parser";
                "emo_ast";
                "emo_check";
                "emo_eval";
                "emo_sched";
                "emo_runtime";
              ]
            in
            let runtime_digest =
              List.fold_left
                (fun acc lib ->
                  let path =
                    Filename.concat (Filename.concat src_dir lib) (lib ^ ".cmxa")
                  in
                  if Sys.file_exists path then
                    acc ^ Digest.to_hex (Digest.file path)
                  else acc)
                "" libs
            in
            let digest =
              Digest.to_hex
                (Digest.string
                   (Printf.sprintf "%s|%s|%b|%s" source runtime_digest
                      specialize (String.concat "," cclibs)))
            in
            let cache_binary = Filename.concat build_dir ("cache-" ^ digest) in
            if Sys.file_exists cache_binary then begin
              ignore
                (Sys.command
                   (Printf.sprintf "cp %s %s"
                      (Filename.quote cache_binary)
                      (Filename.quote output)));
              Printf.printf "built %s (cached)\n" output;
              0
            end
            else begin
              let ml_path = Filename.concat build_dir "main.ml" in
              let oc = open_out_bin ml_path in
              output_string oc source;
              close_out oc;
              (* locate the runtime libraries relative to the emo binary
             (exe_dir/src_dir were resolved at the top of this build) *)
              let libs =
                [
                  "emo_support";
                  "emo_lexer";
                  "emo_parser";
                  "emo_ast";
                  "emo_check";
                  "emo_eval";
                  "emo_sched";
                  "emo_runtime";
                ]
              in
              let includes =
                String.concat " "
                  (List.concat_map
                     (fun lib ->
                       let dir = Filename.concat src_dir lib in
                       [
                         Printf.sprintf "-I %s"
                           (Filename.concat dir
                              (Printf.sprintf ".%s.objs/native" lib));
                         Printf.sprintf "-I %s"
                           (Filename.concat dir
                              (Printf.sprintf ".%s.objs/byte" lib));
                       ])
                     libs)
              in
              let cmxas =
                String.concat " "
                  (List.map
                     (fun lib ->
                       Filename.concat
                         (Filename.concat src_dir lib)
                         (lib ^ ".cmxa"))
                     libs)
              in
              (* ocamlfind invokes its switch's compiler; the switch's bin dir
             must be on PATH for ocamlopt.opt to resolve. *)
              let ocamlfind = find_ocamlfind () in
              let switch_bin = Filename.dirname ocamlfind in
              (* Foreign bindings get a compiled C wrapper (ffi_stubs):
             ocaml's stdlib headers live in the switch, so cc can find
             caml/mlvalues.h there. *)
              let stub_obj =
                let stubs = Emo_codegen.ffi_stubs program in
                if stubs = "" then ""
                else begin
                  let c_path = Filename.concat build_dir "ffi_stubs.c" in
                  let oc = open_out_bin c_path in
                  output_string oc stubs;
                  close_out oc;
                  let obj_path = Filename.concat build_dir "ffi_stubs.o" in
                  let stdlib_dir =
                    Filename.concat
                      (Filename.concat switch_bin "..")
                      "lib/ocaml"
                  in
                  let cc_cmd =
                    Printf.sprintf "cc -O2 -I %s -c %s -o %s"
                      (Filename.quote stdlib_dir)
                      (Filename.quote c_path) (Filename.quote obj_path)
                  in
                  if Sys.command cc_cmd <> 0 then raise Stub_cc_failed;
                  Printf.sprintf " %s" (Filename.quote obj_path)
                end
              in
              let cclib_flags =
                String.concat " "
                  (List.concat_map (fun lib -> [ "-cclib"; "-l" ^ lib ]) cclibs)
              in
              let cmd =
                Printf.sprintf
                  "PATH=%s:$PATH %s ocamlopt -package \
                   unix,ssl,eio_main,eio_posix -linkpkg %s %s %s %s %s -o %s"
                  (Filename.quote switch_bin)
                  (Filename.quote ocamlfind) includes cclib_flags cmxas stub_obj
                  (Filename.quote ml_path) (Filename.quote output)
              in
              let exit_code = Sys.command cmd in
              if exit_code <> 0 then begin
                prerr_endline
                  (Printf.sprintf
                     "emo build: the OCaml toolchain failed (exit %d)" exit_code);
                70
              end
              else begin
                ignore
                  (Sys.command
                     (Printf.sprintf "cp %s %s" (Filename.quote output)
                        (Filename.quote cache_binary)));
                Printf.printf "built %s\n" output;
                0
              end
            end
        (* cache miss *)
        | other ->
            prerr_endline
              (Printf.sprintf
                 "emo build: unknown target `%s` (native, typescript, wasm, \
                  beam)"
                 other);
            65
      with
      | Emo_project.Static_errors diagnostics ->
          render_errors ~color:false ~error_limit:20 diagnostics;
          65
      | Stub_cc_failed ->
          prerr_endline "emo build: the C stub compilation failed";
          70
      | Emo_lexer.Error diagnostic ->
          render_errors ~color:false ~error_limit:20 [ diagnostic ];
          65
      | Emo_ir.Lower_error message ->
          prerr_endline ("emo build: " ^ message);
          65)

let build =
  let entry =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE")
  in
  let output =
    Arg.(
      value
      & opt (some string) None
      & info [ "o" ] ~docv:"FILE"
          ~doc:"Output binary (default: the entry's stem).")
  in
  let no_specialize =
    Arg.(
      value & flag
      & info [ "no-specialize" ] ~doc:"Disable Stage B specialization.")
  in
  let cclib =
    Arg.(
      value & opt_all string []
      & info [ "cclib" ] ~docv:"LIB" ~doc:"Link against C library (-lLIB).")
  in
  let target =
    Arg.(
      value & opt string "native"
      & info [ "target" ] ~docv:"TARGET"
          ~doc:"The compilation target: native, typescript, wasm, or beam.")
  in
  let build entry output no_specialize cclibs target =
    let out =
      match output with
      | Some o -> o
      | None ->
          let stem = Filename.remove_extension (Filename.basename entry) in
          stem
    in
    match
      build_file ~entry ~output:out ~specialize:(not no_specialize) ~cclibs
        ~target
    with
    | 0 -> Cmd.Exit.ok
    | code -> exit code
  in
  Cmd.v
    (Cmd.info "build" ~doc:"Compile an Emo program.")
    Term.(const build $ entry $ output $ no_specialize $ cclib $ target)

(* `emo check`: the static stages only, over the whole module tree. *)
let check_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match Sys.file_exists file with
  | false ->
      prerr_endline (Printf.sprintf "%s: No such file or directory" file);
      66
  | true -> (
      try
        let errors = Emo_project.check_entry ~entry_file:file in
        render_errors ~color ~error_limit errors;
        if errors = [] then 0 else 65
      with
      | Emo_project.Static_errors diagnostics ->
          render_errors ~color ~error_limit diagnostics;
          65
      | Emo_lexer.Error diagnostic ->
          render_errors ~color ~error_limit [ diagnostic ];
          65)

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
          Emo_eval.run_without_scheduler (fun () ->
              List.iter
                (fun item ->
                  match item.Emo_ast.item_desc with
                  | Emo_ast.Item_stmt
                      { Emo_ast.stmt_desc = Emo_ast.Expr_stmt e; _ } ->
                      output
                        ("= "
                        ^ Emo_eval.to_string (Emo_eval.eval_expr env e)
                        ^ "\n")
                  | _ -> Emo_eval.eval_item env item)
                items)
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

(* `emo deps`: resolution and regeneration are explicit commands — the
   lockfile is written only here. *)
let deps_resolve ~(name : string option) : int =
  let dir = Sys.getcwd () in
  let color = Unix.isatty Unix.stderr in
  try
    let manifest =
      match Emo_project.manifest_here () with
      | Some path -> (
          match
            Emo_pkg.parse_manifest ~file:path
              ~source:(Emo_project.read_file path)
          with
          | m -> m
          | exception Emo_pkg.Manifest_error d ->
              render_errors ~color ~error_limit:20 [ d ];
              exit 65)
      | None ->
          prerr_endline "no package.emo in the current directory";
          exit 66
    in
    (match name with
    | Some n ->
        if not (List.mem_assoc n manifest.Emo_pkg.deps) then (
          prerr_endline (Printf.sprintf "`%s` is not in the manifest's deps" n);
          exit 65)
    | None -> ());
    let entries =
      Emo_project.resolve_deps ~manifest ~manifest_dir:dir ~target:"native"
    in
    Emo_pkg.Lockfile.write ~path:(Filename.concat dir "emo.lock") entries;
    List.iter
      (fun e ->
        Printf.printf "%s %s %s\n" e.Emo_pkg.Lockfile.dep
          (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version)
          e.Emo_pkg.Lockfile.checksum)
      entries;
    Cmd.Exit.ok
  with Emo_project.Static_errors diagnostics ->
    render_errors ~color ~error_limit:20 diagnostics;
    65

let deps_list () : int =
  let lock = Filename.concat (Sys.getcwd ()) "emo.lock" in
  match Emo_pkg.Lockfile.read lock with
  | Ok entries ->
      List.iter
        (fun e ->
          Printf.printf "%s %s %s\n" e.Emo_pkg.Lockfile.dep
            (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version)
            e.Emo_pkg.Lockfile.checksum)
        entries;
      Cmd.Exit.ok
  | Error message ->
      prerr_endline message;
      66

let deps_resolve_cmd =
  Cmd.v
    (Cmd.info "resolve" ~doc:"Resolve the manifest and write emo.lock.")
    Term.(const (fun () -> deps_resolve ~name:None) $ const ())

let deps_update_cmd =
  let name = Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME") in
  Cmd.v
    (Cmd.info "update" ~doc:"Regenerate emo.lock after changing a pin.")
    Term.(const (fun n -> deps_resolve ~name:(Some n)) $ name)

let deps_list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List the locked dependencies.")
    Term.(const deps_list $ const ())

let deps =
  Cmd.group
    (Cmd.info "deps" ~doc:"Manage dependencies.")
    [ deps_resolve_cmd; deps_update_cmd; deps_list_cmd ]

let version_cmd =
  Cmd.v
    (Cmd.info "version" ~doc:"Print the version.")
    Term.(const print_version $ const ())

let cmd =
  Cmd.group
    (Cmd.info "emo" ~version ~doc:"The Emo programming language toolchain.")
    [ run; repl; check; build; deps; version_cmd ]

let main () = exit (Cmd.eval' cmd)
