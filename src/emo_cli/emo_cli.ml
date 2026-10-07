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

(* Whether the ocaml target can run at all: its runtime libraries
   must stand beside the emo binary (a source or dune-tree install)
   and ocamlfind must exist — a prebuilt installation has neither.
   `emo build --target ocaml` refuses on this with the fix named, and
   `emo doctor` reports it per target. *)
let tool_exists (name : string) : bool =
  let cmd = Printf.sprintf "command -v %s" (Filename.quote name) in
  let ic = Unix.open_process_in cmd in
  let line = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  line <> ""

let ocaml_target_ok () : bool =
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
  let exe_dir =
    Filename.dirname
      (try Unix.realpath Sys.executable_name with _ -> Sys.executable_name)
  in
  let src_dir = Filename.concat exe_dir ".." in
  let cmxa_found =
    List.for_all
      (fun lib ->
        Sys.file_exists
          (Filename.concat (Filename.concat src_dir lib) (lib ^ ".cmxa")))
      libs
  in
  cmxa_found
  &&
  let found = find_ocamlfind () in
  if found = "ocamlfind" then tool_exists "ocamlfind" else true

(* The build command: entry file → artifact at [-o] (default: the
   entry's stem in the current directory). The target picks the
   backend: ocaml (default) emits OCaml compiled by the OCaml
   toolchain; c emits C compiled by the system cc into a standalone
   binary; typescript emits one self-contained .ts file that runs on
   Node. *)
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
        | "typescript" ->
            (* The prelude rides the compiler as generated data; the
               arm never touches the filesystem for it (step 26). *)
            let source = Emo_codegen.Ts.emit_ts program in
            let digest =
              Digest.to_hex
                (Digest.string
                   (Printf.sprintf "ts|%s|%s" source Emo_codegen.Ts.ts_prelude))
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
            end
        | "c" ->
            (* Emit one main.c plus the Emo runtime sources, compile
               with the system cc: a standalone binary with no OCaml
               runtime (step 24). *)
            let write path contents =
              let oc = open_out_bin path in
              output_string oc contents;
              close_out oc
            in
            let main_c_contents = Emo_codegen.C.emit program in
            (* Incremental, same scheme as the ocaml arm: the digest of
               the emitted C, the runtime sources, and the link flags
               names the cached binary — an unchanged program skips cc. *)
            let digest =
              Digest.to_hex
                (Digest.string
                   (Printf.sprintf "%s|%s|%s|%s" main_c_contents
                      Emo_codegen.C.runtime_c Emo_codegen.C.runtime_h
                      (String.concat "," cclibs)))
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
              let main_c = Filename.concat build_dir "main.c" in
              write main_c main_c_contents;
              let runtime_c = Filename.concat build_dir "emo_c_runtime.c" in
              write runtime_c Emo_codegen.C.runtime_c;
              let runtime_h = Filename.concat build_dir "emo_c_runtime.h" in
              write runtime_h Emo_codegen.C.runtime_h;
              (* cclib entries pass to cc: bare names become -l flags,
                 anything already flag- or path-shaped passes verbatim. *)
              let cclib_flags =
                String.concat " "
                  (List.map
                     (fun lib ->
                       if lib <> "" && (lib.[0] = '-' || lib.[0] = '/') then lib
                       else "-l" ^ lib)
                     cclibs)
              in
              let cmd =
                Printf.sprintf
                  "cc -O2 -std=c11 -Wall -Wno-deprecated-declarations -I %s %s \
                   %s                  %s -o %s"
                  (Filename.quote build_dir) (Filename.quote main_c)
                  (Filename.quote runtime_c) cclib_flags (Filename.quote output)
              in
              let exit_code = Sys.command cmd in
              if exit_code <> 0 then begin
                prerr_endline
                  (Printf.sprintf "emo build: the C compiler failed (exit %d)"
                     exit_code);
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
        | "ocaml" ->
            (* The settled refusal (CHECK.md, T25.1): a prebuilt
               installation lacks the toolchain and the runtime — say
               so and name the fix, never raw ocamlfind output. Exit
               69 (unavailable), the sysexits family of 65/66/70. *)
            if not (ocaml_target_ok ()) then begin
              prerr_endline
                "emo build: the ocaml target needs the OCaml toolchain and the \
                 emo runtime libraries, which this installation does not carry \
                 — install the source package with `opam install emo` (the c \
                 target, the default, needs only the system cc)";
              69
            end
            else
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
                      Filename.concat
                        (Filename.concat src_dir lib)
                        (lib ^ ".cmxa")
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
              let cache_binary =
                Filename.concat build_dir ("cache-" ^ digest)
              in
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
                    (List.concat_map
                       (fun lib -> [ "-cclib"; "-l" ^ lib ])
                       cclibs)
                in
                let cmd =
                  Printf.sprintf
                    "PATH=%s:$PATH %s ocamlopt -package \
                     unix,ssl,eio_main,eio_posix -linkpkg %s %s %s %s %s -o %s"
                    (Filename.quote switch_bin)
                    (Filename.quote ocamlfind) includes cclib_flags cmxas
                    stub_obj (Filename.quote ml_path) (Filename.quote output)
                in
                let exit_code = Sys.command cmd in
                if exit_code <> 0 then begin
                  prerr_endline
                    (Printf.sprintf
                       "emo build: the OCaml toolchain failed (exit %d)"
                       exit_code);
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
                 "emo build: unknown target `%s` (ocaml, c, typescript, wasm, \
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
      value & opt string "c"
      & info [ "target" ] ~docv:"TARGET"
          ~doc:"The compilation target: c, ocaml, typescript, wasm, or beam.")
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
      Emo_project.resolve_deps ~manifest ~manifest_dir:dir ~target:"c"
    in
    Emo_pkg.Lockfile.write
      ~path:(Filename.concat dir Emo_pkg.Lockfile.filename)
      entries;
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
  let lock = Filename.concat (Sys.getcwd ()) Emo_pkg.Lockfile.filename in
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
    (Cmd.info "resolve" ~doc:"Resolve the manifest and write package.lock.")
    Term.(const (fun () -> deps_resolve ~name:None) $ const ())

let deps_update_cmd =
  let name = Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME") in
  Cmd.v
    (Cmd.info "update" ~doc:"Regenerate package.lock after changing a pin.")
    Term.(const (fun n -> deps_resolve ~name:(Some n)) $ name)

let deps_list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List the locked dependencies.")
    Term.(const deps_list $ const ())

let deps =
  Cmd.group
    (Cmd.info "deps" ~doc:"Manage dependencies.")
    [ deps_resolve_cmd; deps_update_cmd; deps_list_cmd ]

(* `emo install`: the project-dependencies front end — resolve, fetch
   into the user cache, lock; the project is then ready for run/build
   (T25.4). `emo deps` keeps the explicit paths. *)
let install () : int =
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
    List.iter print_endline
      (Emo_project.install_deps ~manifest ~manifest_dir:dir ~target:"c");
    Cmd.Exit.ok
  with Emo_project.Static_errors diagnostics ->
    render_errors ~color ~error_limit:20 diagnostics;
    65

let install_cmd =
  Cmd.v
    (Cmd.info "install"
       ~doc:
         "Install the project's dependencies — resolve, fetch into the user \
          cache, and write package.lock.")
    Term.(
      const (fun () ->
          match install () with 0 -> Cmd.Exit.ok | code -> exit code)
      $ const ())

(* `emo publish`: pack the package rooted at the working directory and POST
   it to the registry. The upload is dogfooded: the request is made by the
   standard library's own http client, running as an embedded Emo program
   under the toolchain's scheduler. The endpoint, token, and archive bytes
   ride in as host-injected bindings — Emo has no file-reading builtin, and
   the gzip body is binary. *)

(* Extracts a string field from a flat JSON object (the registry's frozen
   error shape); None when the field is absent or the body is not JSON. *)
let json_string_field (key : string) (json : string) : string option =
  let pat = "\"" ^ key ^ "\"" in
  let n = String.length json and p = String.length pat in
  let rec find i =
    if i + p > n then None
    else if String.sub json i p = pat then Some (i + p)
    else find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some i ->
      let rec skip i =
        if i < n && (json.[i] = ' ' || json.[i] = ':' || json.[i] = '\t') then
          skip (i + 1)
        else i
      in
      let i = skip i in
      if i >= n || json.[i] <> '"' then None
      else
        let buf = Buffer.create 16 in
        let rec read i =
          if i >= n then None
          else
            match json.[i] with
            | '\\' when i + 1 < n ->
                Buffer.add_char buf json.[i + 1];
                read (i + 2)
            | '"' -> Some (Buffer.contents buf)
            | c ->
                Buffer.add_char buf c;
                read (i + 1)
        in
        read (i + 1)

(* The uploader program: `__url`, `__token`, and `__body` (the raw .emoji
   bytes) are bound by the host before it runs. It prints the HTTP status on
   the first line and the response body after it — that is the whole channel
   back. A transport failure raises inside the program and surfaces as an
   uncaught Emo exception, which the host maps to a plain error. *)
let upload_program =
  {|require "http"

const resp = http.request("POST", __url, [("Authorization", "Bearer " + __token), ("Content-Type", "application/octet-stream")], __body, 120.0)
println(resp.status)
println(resp.body)
|}

let rec remove_tree path =
  if Sys.file_exists path && Sys.is_directory path then begin
    Sys.readdir path
    |> Array.iter (fun e -> remove_tree (Filename.concat path e));
    Unix.rmdir path
  end
  else if Sys.file_exists path then Sys.remove path

(* POSTs [archive] to {registry}/api/v1/packages and returns the HTTP status
   and response body. The embedded uploader resolves `http` against the
   standard library shipped with the binary — never the user's EMO_REGISTRY,
   which may point at a remote endpoint the filesystem client cannot read. *)
let upload ~(registry : string) ~(token : string) ~(archive : string) :
    (int * string, string) result =
  let base =
    let n = String.length registry in
    if n > 0 && registry.[n - 1] = '/' then String.sub registry 0 (n - 1)
    else registry
  in
  let reg = Emo_project.bundled_registry () in
  match List.rev (Emo_pkg.Registry.versions reg ~name:"http") with
  | [] -> Error "the bundled standard library has no http package"
  | http_version :: _ -> (
      match List.rev (Emo_pkg.Registry.versions reg ~name:"net") with
      | [] -> Error "the bundled standard library has no net package"
      | net_version :: _ ->
          (* The resolver indexes manifest roots only, so both packages are
             pinned explicitly — same as a user project. *)
          let dir =
            Filename.concat
              (Filename.get_temp_dir_name ())
              (Printf.sprintf "emo-publish-%d-%d" (Unix.getpid ())
                 (int_of_float (Unix.gettimeofday () *. 1e6) land 0xFFFFFF))
          in
          Unix.mkdir dir 0o755;
          let write name content =
            let oc = open_out_bin (Filename.concat dir name) in
            output_string oc content;
            close_out oc
          in
          write "package.emo"
            (Printf.sprintf
               {|package {
  name = "internal/publish"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    http = "%s"
    net = "%s"
  }
}
|}
               (Emo_pkg.Version.to_string http_version)
               (Emo_pkg.Version.to_string net_version));
          write "main.emo" upload_program;
          let out = Buffer.create 256 in
          let old_registry = Sys.getenv_opt "EMO_REGISTRY" in
          let old_cwd = Sys.getcwd () in
          (* The uploader's resolution must see the bundled stdlib, never
             the user's EMO_REGISTRY — blank the variable for the run
             (an empty value means unset to the registry lookup). *)
          Unix.putenv "EMO_REGISTRY" "";
          Emo_eval.set_output (Buffer.add_string out);
          Sys.chdir dir;
          Fun.protect
            ~finally:(fun () ->
              Sys.chdir old_cwd;
              (match old_registry with
              | Some v -> Unix.putenv "EMO_REGISTRY" v
              | None -> ());
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout);
              remove_tree dir)
            (fun () ->
              match
                Emo_project.run_entry ~entry_file:"main.emo" ~check:false
                  ~sched:Emo_project.Own
                  ~globals:
                    [
                      ("__url", Emo_eval.String (base ^ "/api/v1/packages"));
                      ("__token", Emo_eval.String token);
                      ("__body", Emo_eval.String archive);
                    ]
                  ()
              with
              | exception Emo_project.Static_errors ds ->
                  Error
                    (String.concat "; "
                       (List.map (fun d -> d.Emo_support.Diagnostic.message) ds))
              | exception Emo_eval.Error d ->
                  Error d.Emo_support.Diagnostic.message
              | _ -> (
                  let text = Buffer.contents out in
                  match String.index_opt text '\n' with
                  | None -> Error ("the uploader printed no status: " ^ text)
                  | Some i -> (
                      match
                        int_of_string_opt (String.trim (String.sub text 0 i))
                      with
                      | None -> Error ("the uploader printed no status: " ^ text)
                      | Some status ->
                          let body =
                            String.sub text (i + 1) (String.length text - i - 1)
                          in
                          let body =
                            (* println's trailing newline is not the body's. *)
                            if
                              String.length body > 0
                              && body.[String.length body - 1] = '\n'
                            then String.sub body 0 (String.length body - 1)
                            else body
                          in
                          Ok (status, body)))))

let publish ~(registry_opt : string option) ~(token_opt : string option)
    ~(dry_run : bool) : int =
  let dir = Sys.getcwd () in
  if not (Sys.file_exists (Filename.concat dir "package.emo")) then begin
    prerr_endline "no package.emo in the current directory";
    66
  end
  else
    match Emo_pkg.Publish.prepare ~dir with
    | Error message ->
        prerr_endline ("emo publish: " ^ message);
        65
    | Ok p -> (
        let m = p.Emo_pkg.Publish.p_manifest in
        let version = Emo_pkg.Version.to_string m.Emo_pkg.version in
        if dry_run then begin
          Printf.printf "archive: %s (%d bytes)\n" p.p_archive_name
            (String.length p.p_archive);
          Printf.printf "package: %s %s\n" m.Emo_pkg.name version;
          Printf.printf "checksum: %s\n" p.p_checksum;
          print_endline "files:";
          List.iter
            (fun (path, content) ->
              Printf.printf "  %s (%d bytes)\n" path (String.length content))
            p.p_files;
          0
        end
        else
          let registry =
            match (registry_opt, Sys.getenv_opt "EMO_REGISTRY") with
            | Some r, _ -> Some r
            | None, Some r when r <> "" -> Some r
            | _ -> None
          in
          let token =
            match (token_opt, Sys.getenv_opt "EMO_TOKEN") with
            | Some t, _ -> Some t
            | None, Some t when t <> "" -> Some t
            | _ -> None
          in
          match (registry, token) with
          | None, _ ->
              prerr_endline
                "emo publish: no registry configured — pass --registry or set \
                 EMO_REGISTRY";
              65
          | _, None ->
              prerr_endline
                "emo publish: no API token — pass --token or set EMO_TOKEN";
              65
          | Some registry, Some token -> (
              match upload ~registry ~token ~archive:p.p_archive with
              | Error message ->
                  prerr_endline ("emo publish: upload failed: " ^ message);
                  70
              | Ok (201, _) ->
                  Printf.printf "published %s %s\n" m.Emo_pkg.name version;
                  let base =
                    let n = String.length registry in
                    if n > 0 && registry.[n - 1] = '/' then
                      String.sub registry 0 (n - 1)
                    else registry
                  in
                  Printf.printf "  %s/p/%s\n" base m.Emo_pkg.name;
                  0
              | Ok (status, body) -> (
                  let code = json_string_field "code" body in
                  let message = json_string_field "message" body in
                  match (code, message) with
                  | Some code, Some message ->
                      prerr_endline
                        (Printf.sprintf "emo publish: %s: %s" code message);
                      if code = "version_exists" then
                        prerr_endline
                          "hint: versions are immutable — bump `version` in \
                           package.emo";
                      1
                  | _ ->
                      prerr_endline
                        (Printf.sprintf "emo publish: HTTP %d: %s" status
                           (String.trim body));
                      1)))

let publish_cmd =
  let registry =
    Arg.(
      value
      & opt (some string) None
      & info [ "registry" ] ~docv:"URL"
          ~doc:
            "Registry endpoint (default: the EMO_REGISTRY environment \
             variable).")
  in
  let token =
    Arg.(
      value
      & opt (some string) None
      & info [ "token" ] ~docv:"TOKEN"
          ~doc:"API token (default: the EMO_TOKEN environment variable).")
  in
  let dry_run =
    Arg.(
      value & flag
      & info [ "dry-run" ]
          ~doc:"Validate and pack locally; print the archive without uploading.")
  in
  Cmd.v
    (Cmd.info "publish" ~doc:"Publish the package to the registry.")
    Term.(
      const (fun r t d ->
          match publish ~registry_opt:r ~token_opt:t ~dry_run:d with
          | 0 -> Cmd.Exit.ok
          | code -> exit code)
      $ registry $ token $ dry_run)

(* ---- `emo doctor`: the target-aware environment check (T25.5) ----

   One line per target: what it needs, what was found. The default
   target's health decides the exit code — the other targets are
   informational, and an unavailable one gets the honest fix named
   rather than a raw toolchain error. *)

let tool_version (name : string) : string =
  let ic = Unix.open_process_in (name ^ " --version 2>/dev/null") in
  let line = try input_line ic with End_of_file -> "" in
  let status = Unix.close_process_in ic in
  match status with
  | WEXITED 0 when line <> "" -> " (" ^ String.trim line ^ ")"
  | _ -> ""

(* The c target's check: cc exists, compiles, and the result runs. *)
let cc_smoke () : (unit, string) result =
  if not (tool_exists "cc") then Error "cc not found on PATH"
  else
    let dir =
      Filename.concat
        (Filename.get_temp_dir_name ())
        (Printf.sprintf "emo-doctor-%d" (Unix.getpid ()))
    in
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
    let c = Filename.concat dir "smoke.c" in
    let bin = Filename.concat dir "smoke" in
    let oc = open_out_bin c in
    output_string oc
      "#include <stdio.h>\nint main(void) { puts(\"emo\"); return 0; }\n";
    close_out oc;
    let compile =
      Sys.command
        (Printf.sprintf "cc -o %s %s" (Filename.quote bin) (Filename.quote c))
    in
    if compile <> 0 then begin
      remove_tree dir;
      Error "cc failed to compile a smoke program"
    end
    else begin
      let ic = Unix.open_process_in (Filename.quote bin) in
      let out = try input_line ic with End_of_file -> "" in
      let status = Unix.close_process_in ic in
      remove_tree dir;
      match status with
      | WEXITED 0 when out = "emo" -> Ok ()
      | _ -> Error "the cc smoke binary did not run"
    end

(* The ocaml target's check: its runtime libraries must stand beside the
   emo binary (a source or dune-tree install) and ocamlfind must exist. *)
let doctor ~(emit : string -> unit) : int =
  let ocaml_ok = ocaml_target_ok () in
  emit (Printf.sprintf "emo %s" version);
  emit
    (if ocaml_ok then "installation: source (runtime libraries found)"
     else "installation: prebuilt");
  emit "stdlib: embedded in the binary";
  let broken = ref false in
  let line name report = emit (Printf.sprintf "%-11s %s" name report) in
  (match cc_smoke () with
  | Ok () -> line "c:" ("ok" ^ tool_version "cc" ^ " — compiles and runs")
  | Error why ->
      broken := true;
      line "c:" ("BROKEN — " ^ why ^ " (the default target needs a C compiler)"));
  if ocaml_ok then
    line "ocaml:" "ok — ocamlfind and the runtime libraries are present"
  else
    line "ocaml:"
      "unavailable — a prebuilt installation; the ocaml target needs a source \
       install (opam install emo)";
  if tool_exists "node" then line "typescript:" ("ok" ^ tool_version "node")
  else line "typescript:" "unavailable — node not found";
  if tool_exists "erlc" then line "beam:" "ok"
  else line "beam:" "unavailable — erlc not found";
  line "wasm:" "ok — no external tools needed";
  if !broken then 1 else 0

let doctor_cmd =
  Cmd.v
    (Cmd.info "doctor" ~doc:"Check the toolchain environment, per target.")
    Term.(
      const (fun () ->
          let flushed s =
            print_string s;
            print_newline ()
          in
          match doctor ~emit:flushed with 0 -> Cmd.Exit.ok | code -> exit code)
      $ const ())

(* `emo new <name>`: the project scaffold — package.emo, a hello-world
   main.emo, and .gitignore (T25.3). Strictness holds: an existing
   directory or clashing files refuse; nothing is ever overwritten. The
   manifest carries the plain name when no owner is given — running,
   checking, and building work at once, and `emo publish` names the
   owner/name rule when the package is published. *)
let scaffold ~(path : string) : int =
  let leaf = Filename.basename path in
  if leaf = "." || leaf = ".." || leaf = "" || leaf = "/" then begin
    prerr_endline (Printf.sprintf "emo new: `%s` is not a project name" path);
    65
  end
  else if Sys.file_exists path then begin
    prerr_endline
      (Printf.sprintf "emo new: refusing to overwrite — `%s` already exists"
         path);
    65
  end
  else begin
    (* The manifest name: an `owner/name` argument is taken as given;
       anything else is the leaf name — running and building work at
       once, and `emo publish` names the owner/name rule when it is
       time to publish. *)
    let stripped =
      let n = String.length path in
      if n > 1 && path.[n - 1] = '/' then String.sub path 0 (n - 1) else path
    in
    let slashes =
      String.fold_left
        (fun acc c -> if c = '/' then acc + 1 else acc)
        0 stripped
    in
    let package_name =
      if slashes = 1 && stripped.[0] <> '/' then stripped else leaf
    in
    let make_dirs dir =
      let rec go d =
        if not (Sys.file_exists d) then begin
          go (Filename.dirname d);
          Unix.mkdir d 0o755
        end
      in
      go dir
    in
    let write name contents =
      let oc = open_out_bin (Filename.concat path name) in
      output_string oc contents;
      close_out oc
    in
    make_dirs (Filename.dirname path);
    Unix.mkdir path 0o755;
    write "package.emo"
      (Printf.sprintf
         {|package {
  name = "%s"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {}
}
|}
         package_name);
    write "main.emo"
      (Printf.sprintf
         {|// %s, scaffolded by `emo new` — run it with `emo run main.emo`.

def greet(whom String) String {
  return "Hello, ${whom}!"
}

println(greet("world"))
|}
         leaf);
    write ".gitignore" ".emo-build/\n";
    Printf.printf "created %s — next: cd %s && emo run main.emo\n" path path;
    0
  end

let new_cmd =
  let path =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"NAME"
          ~doc:
            "The project directory, and the package name unless an owner/name \
             form is given.")
  in
  Cmd.v
    (Cmd.info "new" ~doc:"Scaffold a new Emo project.")
    Term.(
      const (fun path ->
          match scaffold ~path with 0 -> Cmd.Exit.ok | code -> exit code)
      $ path)

let version_cmd =
  Cmd.v
    (Cmd.info "version" ~doc:"Print the version.")
    Term.(const print_version $ const ())

let cmd =
  Cmd.group
    (Cmd.info "emo" ~version ~doc:"The Emo programming language toolchain.")
    [
      run;
      repl;
      check;
      build;
      deps;
      install_cmd;
      publish_cmd;
      new_cmd;
      doctor_cmd;
      version_cmd;
    ]

let main () = exit (Cmd.eval' cmd)
