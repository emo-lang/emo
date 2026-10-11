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
   files to the OCaml toolchain. The runtime rides the compiler as
   generated data (step 26), so the toolchain alone decides whether the
   target can build, on any installation shape. *)

(* The OCaml toolchain comes from the opam switch: PATH first, then the
   switch prefixes under ~/.opam (dune test actions run without the opam
   environment). The switch scan checks the tool only — whether the
   runtime's own packages are present is [ocaml_target_ok]'s question,
   answered the same way on every installation shape (step 26). *)
let find_ocamlfind () : string =
  let has_tool sw =
    Sys.file_exists (Filename.concat (Filename.concat sw "bin") "ocamlfind")
  in
  let switch_bin sw = Filename.concat (Filename.concat sw "bin") "ocamlfind" in
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"" in
  let opam_dir = Filename.concat home ".opam" in
  let from_prefix =
    match Sys.getenv_opt "OPAM_SWITCH_PREFIX" with
    | Some prefix when has_tool prefix -> Some (switch_bin prefix)
    | _ -> None
  in
  match from_prefix with
  | Some path -> path
  | None -> (
      let entries =
        if Sys.file_exists opam_dir then
          Array.to_list (Sys.readdir opam_dir)
          |> List.filter (fun e -> e <> "config" && e <> "config.lock")
          |> List.filter (fun sw -> has_tool (Filename.concat opam_dir sw))
          |> List.sort (fun a b -> compare b a)
        else []
      in
      match entries with
      | sw :: _ -> switch_bin (Filename.concat opam_dir sw)
      | [] -> "ocamlfind")

(* Whether the ocaml target can run at all: ocamlfind with the unix and
   ssl packages the runtime itself uses. The runtime rides the compiler
   as generated data, so nothing about the emo installation matters —
   only the target's toolchain (step 26). `emo build --target ocaml`
   refuses on this with the fix named, and `emo doctor` reports it per
   target. *)
let tool_exists (name : string) : bool =
  let cmd = Printf.sprintf "command -v %s" (Filename.quote name) in
  let ic = Unix.open_process_in cmd in
  let line = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  line <> ""

let ocaml_target_ok () : bool =
  let found = find_ocamlfind () in
  (if found = "ocamlfind" then tool_exists "ocamlfind" else true)
  && Sys.command
       (Printf.sprintf "%s query unix ssl >/dev/null 2>&1"
          (Filename.quote found))
     = 0

(* The build command: entry file → artifact at [-o] (default: the
   entry's stem in the current directory). The target picks the
   backend: ocaml (default) emits OCaml compiled by the OCaml
   toolchain; c emits C compiled by the system cc into a standalone
   binary; typescript emits one self-contained .ts file that runs on
   Node. *)
(* The cache key's compiler component: the running executable's own
   content digest, so a new compiler invalidates every cached build —
   codegen changes otherwise ride stale cache-* binaries forever (the
   latch-era gotcha, hit for real by the cross-module fix). *)
let compiler_key = lazy (Digest.to_hex (Digest.file Sys.executable_name))

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
            let main_c_contents, defs_h_contents = Emo_codegen.C.emit program in
            (* Incremental, same scheme as the ocaml arm: the digest of
               the emitted C, the runtime sources, and the link inputs
               names the cached binary — an unchanged program skips cc.
               A cclib that names an existing file (a shim object)
               enters by content, so editing the shim invalidates the
               cached binary instead of silently relinking it. *)
            let cclib_key =
              String.concat ","
                (List.map
                   (fun lib ->
                     match lib.[0] with
                     | '/' when Sys.file_exists lib ->
                         let ic = open_in_bin lib in
                         let n = in_channel_length ic in
                         let s = really_input_string ic n in
                         close_in ic;
                         lib ^ "=" ^ Digest.to_hex (Digest.string s)
                     | _ -> lib)
                   cclibs)
            in
            let digest =
              Digest.to_hex
                (Digest.string
                   (Printf.sprintf "%s|%s|%s|%s|%s" main_c_contents
                      Emo_codegen.C.runtime_c Emo_codegen.C.runtime_h cclib_key
                      (Lazy.force compiler_key)))
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
              let defs_h = Filename.concat build_dir "emo_defs.h" in
              write defs_h defs_h_contents;
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
            (* The refusal is installation-independent (step 26): the
               runtime rides the compiler, so the only question is
               whether the target's own toolchain — ocamlfind with the
               unix and ssl packages — is on PATH. Name the fix, never
               raw ocamlfind output. Exit 69 (unavailable), the sysexits
               family of 65/66/70. *)
            if not (ocaml_target_ok ()) then begin
              prerr_endline
                "emo build: the ocaml target needs the OCaml toolchain on PATH \
                 — ocamlfind with the unix and ssl packages (opam brings both; \
                 the c target, the default, needs only the system cc)";
              69
            end
            else
              let source = Emo_codegen.emit ~specialize program in
              (* Incremental: the digest of the emitted source plus the
               runtime source names the cached binary — an unchanged
               program (and unchanged runtime) skips the toolchain
               entirely, and any runtime change invalidates the cache. *)
              let digest =
                Digest.to_hex
                  (Digest.string
                     (Printf.sprintf "%s|%s|%b|%s|%s" source
                        Emo_codegen.ocaml_runtime_ml specialize
                        (String.concat "," cclibs)
                        (Lazy.force compiler_key)))
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
                (* The runtime and the program are written side by side
                   and compiled by the target's own toolchain — nothing
                   is looked up beside the emo binary or in the host
                   build tree. *)
                let ml_path = Filename.concat build_dir "main.ml" in
                let oc = open_out_bin ml_path in
                output_string oc source;
                close_out oc;
                let rt_path =
                  Filename.concat build_dir "emo_ocaml_runtime.ml"
                in
                let oc = open_out_bin rt_path in
                output_string oc Emo_codegen.ocaml_runtime_ml;
                close_out oc;
                (* ocamlfind invokes its switch's compiler; the switch's
                   bin dir must be on PATH for ocamlopt.opt to resolve. *)
                let ocamlfind = find_ocamlfind () in
                let switch_bin = Filename.dirname ocamlfind in
                (* Foreign bindings get a compiled C wrapper
                   (ffi_stubs): ocaml's stdlib headers live in the
                   switch, so cc can find caml/mlvalues.h there. *)
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
                (* Two invocations: the runtime compiles alone (it never
                   opens itself), then the program links against it with
                   -open, so the emitter's qualified paths resolve
                   without touching the emitted source. ocamlfind brings
                   only the runtime's own packages (unix, ssl). *)
                let compile_runtime =
                  Printf.sprintf
                    "cd %s && PATH=%s:$PATH %s ocamlopt -package unix,ssl -c %s"
                    (Filename.quote build_dir)
                    (Filename.quote switch_bin)
                    (Filename.quote ocamlfind) (Filename.quote rt_path)
                in
                let link_cmd =
                  Printf.sprintf
                    "PATH=%s:$PATH %s ocamlopt -package unix,ssl -linkpkg -I \
                     %s -open Emo_ocaml_runtime %s %s %s %s -o %s"
                    (Filename.quote switch_bin)
                    (Filename.quote ocamlfind) (Filename.quote build_dir)
                    (Filename.quote
                       (Filename.concat build_dir "emo_ocaml_runtime.cmx"))
                    (Filename.quote ml_path) cclib_flags stub_obj
                    (Filename.quote output)
                in
                let exit_code = Sys.command compile_runtime in
                let exit_code =
                  if exit_code <> 0 then exit_code else Sys.command link_cmd
                in
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
        | "riscv64" ->
            (* Emit RV64 assembly for the GNU cross binutils: one
               freestanding ELF that boots under QEMU or on the machine
               (step 22). *)
            let asm = Emo_codegen.Riscv.emit program in
            let out =
              if Filename.check_suffix output ".elf" then output
              else output ^ ".elf"
            in
            let asm_file = Filename.concat build_dir "emo_main.s" in
            let obj_file = Filename.concat build_dir "emo_main.o" in
            let ld_file = Filename.concat build_dir "emo_link.ld" in
            let write path contents =
              let oc = open_out_bin path in
              output_string oc contents;
              close_out oc
            in
            write asm_file asm;
            write ld_file Emo_codegen.Riscv.linker_script;
            let prefix =
              List.find_opt
                (fun p -> tool_exists (p ^ "-as") && tool_exists (p ^ "-ld"))
                [ "riscv64-unknown-elf"; "riscv64-elf" ]
            in
            begin match prefix with
            | None ->
                prerr_endline
                  "emo build: the riscv64 target needs the GNU cross binutils \
                   on PATH — riscv64-unknown-elf-as and riscv64-unknown-elf-ld";
                69
            | Some prefix ->
                let as_cmd =
                  Printf.sprintf "%s-as -march=rv64gc -mabi=lp64d %s -o %s"
                    prefix (Filename.quote asm_file) (Filename.quote obj_file)
                in
                let ld_cmd =
                  Printf.sprintf "%s-ld -T %s %s -o %s" prefix
                    (Filename.quote ld_file) (Filename.quote obj_file)
                    (Filename.quote out)
                in
                let exit_code = Sys.command as_cmd in
                let exit_code =
                  if exit_code <> 0 then exit_code else Sys.command ld_cmd
                in
                if exit_code <> 0 then begin
                  prerr_endline
                    (Printf.sprintf
                       "emo build: the riscv64 cross binutils failed (exit %d)"
                       exit_code);
                  70
                end
                else begin
                  Printf.printf "built %s\n" out;
                  0
                end
            end
        (* cache miss *)
        | other ->
            prerr_endline
              (Printf.sprintf
                 "emo build: unknown target `%s` (ocaml, c, typescript, wasm, \
                  beam, riscv64)"
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
          ~doc:
            "The compilation target: c, ocaml, typescript, wasm, beam, or \
             riscv64.")
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
      & info [ "error-limit" ] ~docv:"N" ~doc:"Maximum reported errors.")
  in
  let target =
    Arg.(
      value
      & opt (some string) None
      & info [ "target" ] ~docv:"TARGET"
          ~doc:
            "Compile first and run the artifact (only riscv64 today: the ELF \
             boots under qemu-system-riscv64).")
  in
  let run file no_color error_limit target =
    let color = (not no_color) && Unix.isatty Unix.stderr in
    match target with
    | Some "riscv64" ->
        let build_dir = Filename.concat (Sys.getcwd ()) ".emo-build" in
        if not (Sys.file_exists build_dir) then
          ignore
            (Sys.command
               (Printf.sprintf "mkdir -p %s" (Filename.quote build_dir)));
        let elf = Filename.concat build_dir "emo_run.elf" in
        let code =
          build_file ~entry:file ~output:elf ~specialize:false ~cclibs:[]
            ~target:"riscv64"
        in
        if code <> 0 then exit code
        else if not (tool_exists "qemu-system-riscv64") then begin
          prerr_endline
            "emo run: the riscv64 target needs qemu-system-riscv64 on PATH";
          exit 69
        end
        else
          exit
            (Sys.command
               (Printf.sprintf
                  "qemu-system-riscv64 -machine virt -nographic -kernel %s"
                  (Filename.quote elf)))
    | Some other ->
        prerr_endline
          (Printf.sprintf
             "emo run: unknown target `%s` for run — --target supports only \
              riscv64 (other targets: `emo build`, then run the artifact)"
             other);
        exit 65
    | None -> (
        match run_file ~file ~color ~error_limit with
        | 0 -> Cmd.Exit.ok
        | code -> exit code)
  in
  Cmd.v
    (Cmd.info "run" ~doc:"Run an Emo program.")
    Term.(const run $ file $ no_color $ error_limit $ target)

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

(* The registry conversation rides embedded Emo programs: `__url` and the
   other `__`-prefixed names are bound by the host before the program runs.
   Each program prints the HTTP status on the first line and the response
   body after it — that is the whole channel back. A transport failure
   raises inside the program and surfaces as an uncaught Emo exception,
   which the host maps to a plain error. *)
let upload_program =
  {|require "http"

const resp = http.request("POST", __url, [("Authorization", "Bearer " + __token), ("Content-Type", "application/octet-stream")], __body, 120.0)
println(resp.status)
println(resp.body)
|}

(* The login step: email + password as JSON, no credentials header yet. *)
let login_program =
  {|require "http"

const resp = http.request("POST", __url, [("Content-Type", "application/json")], __body, 60.0)
println(resp.status)
println(resp.body)
|}

(* The token-minting step: HTTP basic auth — the account API's documented
   path for the CLI — in exchange for a fresh API token. *)
let token_program =
  {|require "http"

const resp = http.request("POST", __url, [("Authorization", "Basic " + __basic), ("Content-Type", "application/json")], __body, 60.0)
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

(* Strips one trailing slash, so joining endpoint paths never doubles it. *)
let registry_base (registry : string) : string =
  let n = String.length registry in
  if n > 0 && registry.[n - 1] = '/' then String.sub registry 0 (n - 1)
  else registry

(* Runs one embedded program against [registry] and returns everything it
   printed. The program resolves `http` against the standard library shipped
   with the binary — never the user's EMO_REGISTRY, which may point at a
   remote endpoint the filesystem client cannot read. *)
let run_embedded ~(registry : string) ~(tag : string) ~(program : string)
    ~(globals : (string * Emo_eval.value) list) : (string, string) result =
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
              (Printf.sprintf "emo-%s-%d-%d" tag (Unix.getpid ())
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
  name = "internal/%s"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    http = "%s"
    net = "%s"
  }
}
|}
               tag
               (Emo_pkg.Version.to_string http_version)
               (Emo_pkg.Version.to_string net_version));
          write "main.emo" program;
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
                  ~sched:Emo_project.Own ~globals ()
              with
              | exception Emo_project.Static_errors ds ->
                  Error
                    (String.concat "; "
                       (List.map (fun d -> d.Emo_support.Diagnostic.message) ds))
              | exception Emo_eval.Error d ->
                  Error d.Emo_support.Diagnostic.message
              | _ -> Ok (Buffer.contents out)))

(* Splits one exchange's printed output into the status line and the body
   that follows it. *)
let parse_exchange (text : string) : (int * string, string) result =
  match String.index_opt text '\n' with
  | None -> Error ("the request printed no status: " ^ text)
  | Some i -> (
      match int_of_string_opt (String.trim (String.sub text 0 i)) with
      | None -> Error ("the request printed no status: " ^ text)
      | Some status ->
          let body = String.sub text (i + 1) (String.length text - i - 1) in
          let body =
            (* println's trailing newline is not the body's. *)
            if String.length body > 0 && body.[String.length body - 1] = '\n'
            then String.sub body 0 (String.length body - 1)
            else body
          in
          Ok (status, body))

(* POSTs [archive] to {registry}/api/v1/packages and returns the HTTP status
   and response body. *)
let upload ~(registry : string) ~(token : string) ~(archive : string) :
    (int * string, string) result =
  match
    run_embedded ~registry ~tag:"publish" ~program:upload_program
      ~globals:
        [
          ( "__url",
            Emo_eval.String (registry_base registry ^ "/api/v1/packages") );
          ("__token", Emo_eval.String token);
          ("__body", Emo_eval.String archive);
        ]
  with
  | Error e -> Error e
  | Ok text -> parse_exchange text

(* ---- registry credentials ----

   `emo emoji login` stores one block per registry — registry, token,
   username — in a key = "value" file under the user's config directory.
   Entries never cross registries: publish matches the entry against the
   resolved endpoint, so a token minted for one host is never sent to
   another. The file holds API tokens in plaintext and is written 0600. *)

type stored_login = {
  c_registry : string;
  c_token : string;
  c_username : string;
  c_expires_at : string; (* RFC 3339, or "" when the token never expires *)
}

(* Parses the credentials file: `key = "value"` lines with the keys
   registry, token, username and the optional expires_at; blank lines and #
   comments are layout only. A new block starts at each `registry` line.
   Strict — any malformed or unknown line is an error naming the line
   number, never a silent skip. *)
let parse_credentials (content : string) : (stored_login list, string) result =
  let error line message =
    Error (Printf.sprintf "credentials: line %d: %s" line message)
  in
  let unquote line key rest =
    let n = String.length rest in
    if
      n < 2
      || rest.[0] <> '"'
      || rest.[n - 1] <> '"'
      ||
        try String.index (String.sub rest 1 (n - 2)) '"' <> -1
        with Not_found -> false
    then
      error line
        (Printf.sprintf "`%s` must be a quoted value without quotes" key)
    else Ok (String.sub rest 1 (n - 2))
  in
  let complete line entry =
    match (entry.c_registry, entry.c_token, entry.c_username) with
    | r, t, u when r <> "" && t <> "" && u <> "" -> Ok entry
    | r, _, _ when r <> "" ->
        error line
          (Printf.sprintf "the `%s` block is missing a token or username" r)
    | _ -> error line "a block must start with `registry`"
  in
  let parse_line line text entry entries =
    let trimmed = String.trim text in
    if trimmed = "" || trimmed.[0] = '#' then Ok (entry, entries)
    else
      match String.index_opt trimmed '=' with
      | None -> error line "expected `key = \"value\"`"
      | Some i -> (
          let key = String.trim (String.sub trimmed 0 i) in
          let rest =
            String.trim
              (String.sub trimmed (i + 1) (String.length trimmed - i - 1))
          in
          match key with
          | "registry" -> (
              match entry.c_registry with
              | "" -> (
                  match unquote line key rest with
                  | Ok v -> Ok ({ entry with c_registry = v }, entries)
                  | Error e -> Error e)
              | _ -> (
                  (* A repeated `registry` opens the next block; the current
                     one must be complete before it is set aside. *)
                  match complete line entry with
                  | Ok full -> (
                      match unquote line key rest with
                      | Ok v ->
                          Ok
                            ( {
                                c_registry = v;
                                c_token = "";
                                c_username = "";
                                c_expires_at = "";
                              },
                              full :: entries )
                      | Error e -> Error e)
                  | Error e -> Error e))
          | "token" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_token = v }, entries)
              | Error e -> Error e)
          | "username" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_username = v }, entries)
              | Error e -> Error e)
          | "expires_at" -> (
              match unquote line key rest with
              | Ok v -> Ok ({ entry with c_expires_at = v }, entries)
              | Error e -> Error e)
          | other -> error line (Printf.sprintf "unknown key `%s`" other))
  in
  let rec go line entry entries lines =
    match lines with
    | [] -> (
        if entry.c_registry = "" && entry.c_token = "" && entry.c_username = ""
        then Ok (List.rev entries)
        else
          match complete line entry with
          | Ok full -> Ok (List.rev (full :: entries))
          | Error e -> Error e)
    | text :: rest -> (
        match parse_line line text entry entries with
        | Ok (entry, entries) -> go (line + 1) entry entries rest
        | Error e -> Error e)
  in
  (* A trailing empty element (the newline-terminated file's last line) is
     just a blank line to skip; the final block flushes at the end either
     way, and line numbers stay honest. *)
  go 1
    { c_registry = ""; c_token = ""; c_username = ""; c_expires_at = "" }
    []
    (String.split_on_char '\n' content)

let load_credentials ~(file : string) : (stored_login list, string) result =
  if not (Sys.file_exists file) then Ok []
  else
    let ic = open_in_bin file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        parse_credentials (really_input_string ic (in_channel_length ic)))

(* Replaces the block for [registry] in place, or appends one, and rewrites
   the file 0600. Values are checked before anything is written: the format
   has no escapes, so a quote or newline cannot be smuggled in. *)
let store_credentials ~(file : string) ~(registry : string) ~(token : string)
    ~(username : string) ~(expires_at : string) : (unit, string) result =
  let entry =
    {
      c_registry = registry_base registry;
      c_token = token;
      c_username = username;
      c_expires_at = expires_at;
    }
  in
  let plain (label : string) (v : string) =
    if v = "" then Error (label ^ " is empty")
    else if String.contains v '"' || String.contains v '\n' then
      Error (label ^ " must not contain quotes or newlines")
    else Ok ()
  in
  (* The expiry may be empty — a token that never expires. *)
  let expiry =
    if entry.c_expires_at = "" then Ok ()
    else if
      String.contains entry.c_expires_at '"'
      || String.contains entry.c_expires_at '\n'
    then Error "expires_at must not contain quotes or newlines"
    else Ok ()
  in
  match
    ( plain "registry" entry.c_registry,
      plain "token" entry.c_token,
      plain "username" entry.c_username,
      expiry )
  with
  | Error e, _, _, _ | _, Error e, _, _ | _, _, Error e, _ | _, _, _, Error e ->
      Error e
  | Ok (), Ok (), Ok (), Ok () -> (
      match load_credentials ~file with
      | Error e -> Error e
      | Ok stored -> (
          let entries =
            match
              List.partition (fun e -> e.c_registry = entry.c_registry) stored
            with
            | _, kept -> entry :: kept
          in
          let buf = Buffer.create 256 in
          Buffer.add_string buf
            "# Emo registry credentials, written by `emo emoji login`.\n\
             # One block per registry; publish only sends a token to its own \
             registry.\n\
             # Keep this file private — it holds API tokens in plaintext.\n";
          List.iter
            (fun e ->
              Buffer.add_char buf '\n';
              Buffer.add_string buf
                (Printf.sprintf "registry = \"%s\"\n" e.c_registry);
              Buffer.add_string buf
                (Printf.sprintf "token = \"%s\"\n" e.c_token);
              Buffer.add_string buf
                (Printf.sprintf "username = \"%s\"\n" e.c_username);
              Buffer.add_string buf
                (Printf.sprintf "expires_at = \"%s\"\n" e.c_expires_at))
            entries;
          let dir = Filename.dirname file in
          let rec ensure_dir d =
            if not (Sys.file_exists d) then begin
              ensure_dir (Filename.dirname d);
              try Unix.mkdir d 0o755 with Sys_error _ -> ()
            end
          in
          (try ensure_dir dir with Sys_error _ -> ());
          match open_out_bin file with
          | exception Sys_error m -> Error m
          | oc ->
              Fun.protect
                ~finally:(fun () -> close_out_noerr oc)
                (fun () ->
                  output_string oc (Buffer.contents buf);
                  close_out_noerr oc;
                  match Unix.chmod file 0o600 with
                  | () -> Ok ()
                  | exception Unix.Unix_error (e, _, _) ->
                      Error (Unix.error_message e))))

(* The credentials file: $EMO_CONFIG_DIR, then the XDG config home, then the
   user's .config — mirroring the cache directory's resolution. *)
let credentials_file () : string =
  let dir =
    match Sys.getenv_opt "EMO_CONFIG_DIR" with
    | Some d when d <> "" -> d
    | _ ->
        let config_home =
          match Sys.getenv_opt "XDG_CONFIG_HOME" with
          | Some d when d <> "" -> d
          | _ -> (
              match Sys.getenv_opt "HOME" with
              | Some home -> Filename.concat home ".config"
              | None -> Filename.get_temp_dir_name ())
        in
        Filename.concat config_home "emo"
  in
  Filename.concat dir "credentials"

(* ---- `emo emoji login` ---- *)

(* Base64 for the basic-auth header — RFC 4648, with padding. *)
let base64 (s : string) : string =
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  in
  let n = String.length s in
  let buf = Buffer.create ((n + 2) / 3 * 4) in
  let i = ref 0 in
  while !i + 2 < n do
    let v =
      (Char.code s.[!i] lsl 16)
      lor (Char.code s.[!i + 1] lsl 8)
      lor Char.code s.[!i + 2]
    in
    Buffer.add_char buf alphabet.[(v lsr 18) land 0x3F];
    Buffer.add_char buf alphabet.[(v lsr 12) land 0x3F];
    Buffer.add_char buf alphabet.[(v lsr 6) land 0x3F];
    Buffer.add_char buf alphabet.[v land 0x3F];
    i := !i + 3
  done;
  let remaining = n - !i in
  if remaining = 1 then begin
    let v = Char.code s.[!i] lsl 16 in
    Buffer.add_char buf alphabet.[(v lsr 18) land 0x3F];
    Buffer.add_char buf alphabet.[(v lsr 12) land 0x3F];
    Buffer.add_string buf "=="
  end
  else if remaining = 2 then begin
    let v = (Char.code s.[!i] lsl 16) lor (Char.code s.[!i + 1] lsl 8) in
    Buffer.add_char buf alphabet.[(v lsr 18) land 0x3F];
    Buffer.add_char buf alphabet.[(v lsr 12) land 0x3F];
    Buffer.add_char buf alphabet.[(v lsr 6) land 0x3F];
    Buffer.add_char buf '='
  end;
  Buffer.contents buf

(* Escapes a string for a JSON request body. *)
let json_escape (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* Reads one line with the terminal echo disabled, so a password never
   lands in the scrollback. Platforms without termios (Windows) read
   visibly, and say so. *)
let read_hidden_line ~(prompt : string) : string =
  prerr_string prompt;
  flush stderr;
  let fd = Unix.descr_of_in_channel stdin in
  match Unix.tcgetattr fd with
  | exception _ ->
      prerr_endline "(the input will be visible as you type)";
      read_line ()
  | tm ->
      tm.Unix.c_echo <- false;
      (try Unix.tcsetattr fd Unix.TCSANOW tm with _ -> ());
      Fun.protect
        ~finally:(fun () ->
          tm.Unix.c_echo <- true;
          (try Unix.tcsetattr fd Unix.TCSANOW tm with _ -> ());
          (* The newline Enter sent without echoing. *)
          prerr_newline ())
        read_line

(* The two-step login: verify the credentials against the account API, then
   exchange them — HTTP basic auth, the account API's documented path for
   the CLI — for a fresh push/yank/read API token. Returns each step's
   status and body; the token step's status is 0 when the login step
   already failed. *)
let login ~(registry : string) ~(email : string) ~(password : string)
    ~(token_name : string) ~(expires_in_days : int) :
    (int * string * int * string, string) result =
  let run program globals =
    match run_embedded ~registry ~tag:"login" ~program ~globals with
    | Error e -> Error e
    | Ok text -> parse_exchange text
  in
  match
    run login_program
      [
        ("__url", Emo_eval.String (registry_base registry ^ "/api/v1/login"));
        ( "__body",
          Emo_eval.String
            (Printf.sprintf {|{"email":"%s","password":"%s"}|}
               (json_escape email) (json_escape password)) );
      ]
  with
  | Error e -> Error e
  | Ok (200, login_body) -> (
      match
        run token_program
          [
            ( "__url",
              Emo_eval.String (registry_base registry ^ "/api/v1/tokens") );
            ("__basic", Emo_eval.String (base64 (email ^ ":" ^ password)));
            ( "__body",
              Emo_eval.String
                (Printf.sprintf
                   {|{"name":"%s","scopes":["push","yank","read"],"expires_in_days":%d}|}
                   (json_escape token_name) expires_in_days) );
          ]
      with
      | Error e -> Error e
      | Ok (token_status, token_body) ->
          Ok (200, login_body, token_status, token_body))
  | Ok (status, body) -> Ok (status, body, 0, "")

(* Flattens one refused exchange into a report line: the registry's stable
   code and human message when present, the raw status and body otherwise. *)
let describe_refusal (status : int) (body : string) : string =
  match (json_string_field "code" body, json_string_field "message" body) with
  | Some code, Some message -> code ^ ": " ^ message
  | _ -> Printf.sprintf "HTTP %d: %s" status (String.trim body)

type login_outcome =
  | Logged_in of string * string * string
    (* the username, the plaintext token, and the expiry — "" when none *)
  | Rejected of string (* the registry answered, and said no *)
  | Unreachable of string (* transport or protocol failure *)
  | Not_stored of string (* the login worked; the local write did not *)

(* The ledger name a CLI-minted token carries: which machine minted it. *)
let cli_token_name () : string =
  let host = try Unix.gethostname () with _ -> "" in
  let name = if host = "" then "emo CLI" else "emo CLI on " ^ host in
  if String.length name > 64 then String.sub name 0 64 else name

(* Runs the whole login: the two registry steps, then the credentials
   write. stdin supplies the email and password — prompted and hidden on a
   terminal, two plain lines otherwise. *)
let apply_login ~(file : string) ~(registry : string) ~(email : string)
    ~(password : string) ~(expires_in_days : int) : login_outcome =
  match
    login ~registry ~email ~password ~token_name:(cli_token_name ())
      ~expires_in_days
  with
  | Error m -> Unreachable m
  | Ok (200, login_body, 201, token_body) -> (
      match json_string_field "username" login_body with
      | Some username -> (
          match json_string_field "token" token_body with
          | Some token -> (
              if username = "" then
                Rejected "the login response carried no username"
              else if token = "" then
                Rejected "the token response carried no token"
              else
                (* No expiry on the response — a token that never expires. *)
                let expires_at =
                  match json_string_field "expires_at" token_body with
                  | Some at -> at
                  | None -> ""
                in
                match
                  store_credentials ~file ~registry:(registry_base registry)
                    ~token ~username ~expires_at
                with
                | Ok () -> Logged_in (username, token, expires_at)
                | Error m -> Not_stored m)
          | None -> Rejected "the token response carried no token")
      | None -> Rejected "the login response carried no username")
  | Ok (status, body, 0, _) -> Rejected (describe_refusal status body)
  | Ok (_, _, status, body) -> Rejected (describe_refusal status body)

(* Resolves publish's endpoint and token: the flags win, then the
   environment, then the stored `emo emoji login` entries — the registry
   falls back to the most recent login, and a token is only ever taken
   from the entry belonging to the resolved registry, never another
   registry's. *)
let resolve_publish_auth ~(registry_opt : string option)
    ~(env_registry : string option) ~(token_opt : string option)
    ~(env_token : string option) ~(stored : stored_login list) :
    (string * string, string) result =
  let registry =
    match (registry_opt, env_registry) with
    | Some r, _ -> Some r
    | None, Some r when r <> "" -> Some r
    | _ -> (
        match List.rev stored with e :: _ -> Some e.c_registry | [] -> None)
  in
  let token =
    match (token_opt, env_token) with
    | Some t, _ -> Some t
    | None, Some t when t <> "" -> Some t
    | _ -> (
        match registry with
        | None -> None
        | Some r -> (
            match
              List.find_opt
                (fun e -> registry_base e.c_registry = registry_base r)
                stored
            with
            | Some e -> Some e.c_token
            | None -> None))
  in
  match (registry, token) with
  | None, _ ->
      Error
        "no registry configured — pass --registry or set EMO_REGISTRY (or run \
         `emo emoji login`)"
  | _, None ->
      Error
        "no API token — pass --token, set EMO_TOKEN, or run `emo emoji login`"
  | Some registry, Some token -> Ok (registry, token)

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
          let env_registry =
            match Sys.getenv_opt "EMO_REGISTRY" with
            | Some r when r <> "" -> Some r
            | _ -> None
          in
          let env_token =
            match Sys.getenv_opt "EMO_TOKEN" with
            | Some t when t <> "" -> Some t
            | _ -> None
          in
          (* The stored logins are consulted only when a fallback is
             actually needed; a damaged file then surfaces instead of
             being silently ignored. *)
          match
            if
              (registry_opt = None && env_registry = None)
              || (token_opt = None && env_token = None)
            then load_credentials ~file:(credentials_file ())
            else Ok []
          with
          | Error m ->
              prerr_endline ("emo publish: " ^ m);
              65
          | Ok stored -> (
              match
                resolve_publish_auth ~registry_opt ~env_registry ~token_opt
                  ~env_token ~stored
              with
              | Error message ->
                  prerr_endline ("emo publish: " ^ message);
                  65
              | Ok (registry, token) -> (
                  match upload ~registry ~token ~archive:p.p_archive with
                  | Error message ->
                      prerr_endline ("emo publish: upload failed: " ^ message);
                      70
                  | Ok (201, _) ->
                      Printf.printf "published %s %s\n" m.Emo_pkg.name version;
                      Printf.printf "  %s/p/%s\n" (registry_base registry)
                        m.Emo_pkg.name;
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
                              "hint: versions are immutable — bump `version` \
                               in package.emo";
                          if code = "token_expired" then
                            prerr_endline
                              (Printf.sprintf
                                 "hint: the stored API token has expired — run \
                                  `emo emoji login --registry %s` to mint a \
                                  fresh one"
                                 (registry_base registry));
                          1
                      | _ ->
                          prerr_endline
                            (Printf.sprintf "emo publish: HTTP %d: %s" status
                               (String.trim body));
                          1))))

let publish_cmd =
  let registry =
    Arg.(
      value
      & opt (some string) None
      & info [ "registry" ] ~docv:"URL"
          ~doc:
            "Registry endpoint (default: the EMO_REGISTRY environment \
             variable, then the most recent `emo emoji login`).")
  in
  let token =
    Arg.(
      value
      & opt (some string) None
      & info [ "token" ] ~docv:"TOKEN"
          ~doc:
            "API token (default: the EMO_TOKEN environment variable, then the \
             stored `emo emoji login` token for this registry).")
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

(* The ocaml target's check: ocamlfind with the unix and ssl packages
   the runtime itself uses — the same question on every installation
   shape, since the runtime rides the compiler (step 26). *)
let doctor ~(emit : string -> unit) : int =
  let ocaml_ok = ocaml_target_ok () in
  emit (Printf.sprintf "emo %s" version);
  emit "stdlib: embedded in the binary";
  let broken = ref false in
  let line name report = emit (Printf.sprintf "%-11s %s" name report) in
  (match cc_smoke () with
  | Ok () -> line "c:" ("ok" ^ tool_version "cc" ^ " — compiles and runs")
  | Error why ->
      broken := true;
      line "c:" ("BROKEN — " ^ why ^ " (the default target needs a C compiler)"));
  if ocaml_ok then
    line "ocaml:" "ok — ocamlfind with the unix and ssl packages found"
  else
    line "ocaml:"
      "unavailable — the ocaml target needs the OCaml toolchain on PATH \
       (ocamlfind with the unix and ssl packages)";
  if tool_exists "node" then line "typescript:" ("ok" ^ tool_version "node")
  else line "typescript:" "unavailable — node not found";
  if tool_exists "erlc" then line "beam:" "ok"
  else line "beam:" "unavailable — erlc not found";
  line "wasm:" "ok — no external tools needed";
  if
    tool_exists "riscv64-unknown-elf-as" && tool_exists "riscv64-unknown-elf-ld"
  then
    if tool_exists "qemu-system-riscv64" then
      line "riscv64:" ("ok" ^ tool_version "qemu-system-riscv64")
    else
      line "riscv64:"
        "unavailable — qemu-system-riscv64 not found (the dev loop needs it)"
  else
    line "riscv64:"
      "unavailable — the riscv64 target needs the GNU cross binutils on PATH \
       (riscv64-unknown-elf-as and riscv64-unknown-elf-ld)";
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

(* ---- `emo emoji`: the shared-package lifecycle ----

   The group gathers the authoring flow for packages meant for the
   registry — new, build, publish — under the name of the archive
   format itself. *)

(* `emo emoji new <owner/name>`: the package scaffold — package.emo,
   the public module named after the package, a README (packed on
   publish), and .gitignore. Strictness holds: the name must be the
   publishable owner/name form and an existing directory refuses;
   nothing is ever overwritten. *)
let scaffold_package ~(name : string) ~(path : string) : int =
  match Emo_pkg.Publish.validate_name name with
  | Error message ->
      prerr_endline (Printf.sprintf "emo emoji new: %s" message);
      65
  | Ok (owner, short) ->
      if Sys.file_exists path then begin
        prerr_endline
          (Printf.sprintf
             "emo emoji new: refusing to overwrite — `%s` already exists" path);
        65
      end
      else begin
        let make_dirs dir =
          let rec go d =
            if not (Sys.file_exists d) then begin
              go (Filename.dirname d);
              Unix.mkdir d 0o755
            end
          in
          go dir
        in
        let write file contents =
          let oc = open_out_bin (Filename.concat path file) in
          output_string oc contents;
          close_out oc
        in
        make_dirs (Filename.dirname path);
        Unix.mkdir path 0o755;
        write "package.emo"
          (Printf.sprintf
             {|package {
  name = "%s/%s"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {}
}
|}
             owner short);
        write (short ^ ".emo")
          (Printf.sprintf
             {|// %s, the public module of %s/%s — consumers require it as
// "%s" once the package is in their deps.

def hello(whom String) String {
  return "Hello, ${whom}!"
}
|}
             short owner short short);
        write "README.md"
          (Printf.sprintf "# %s/%s\n\nA shared Emo package.\n" owner short);
        write ".gitignore" ".emo-build/\n";
        Printf.printf "created %s — next: cd %s && emo emoji build\n" path path;
        0
      end

let emoji_new_cmd =
  let name =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"OWNER/NAME"
          ~doc:
            "The publishable package name — owner/name, each part 1-64 \
             lowercase letters, digits, `_` or `-`. The directory is named \
             after the second part.")
  in
  Cmd.v
    (Cmd.info "new" ~doc:"Scaffold a shareable package.")
    Term.(
      const (fun name ->
          let path =
            match String.index_opt name '/' with
            | Some i -> String.sub name (i + 1) (String.length name - i - 1)
            | None -> name
          in
          match scaffold_package ~name ~path with
          | 0 -> Cmd.Exit.ok
          | code -> exit code)
      $ name)

(* `emo emoji build`: the pre-publish gate — the package's entry module
   must compile under every target the manifest declares. *)
let emoji_build ~(dir : string) : int =
  let manifest_path = Filename.concat dir "package.emo" in
  if not (Sys.file_exists manifest_path) then begin
    prerr_endline "no package.emo in the current directory";
    66
  end
  else
    match
      Emo_pkg.parse_manifest ~file:manifest_path
        ~source:(Emo_project.read_file manifest_path)
    with
    | exception Emo_pkg.Manifest_error d ->
        render_errors ~color:false ~error_limit:20 [ d ];
        65
    | m ->
        let short =
          match String.index_opt m.Emo_pkg.name '/' with
          | Some i ->
              String.sub m.Emo_pkg.name (i + 1)
                (String.length m.Emo_pkg.name - i - 1)
          | None -> m.Emo_pkg.name
        in
        let entry =
          if Sys.file_exists (Filename.concat dir (short ^ ".emo")) then
            Filename.concat dir (short ^ ".emo")
          else if Sys.file_exists (Filename.concat dir "main.emo") then
            Filename.concat dir "main.emo"
          else begin
            prerr_endline
              (Printf.sprintf
                 "emo emoji build: no entry module — expected `%s.emo` beside \
                  the manifest"
                 short);
            exit 66
          end
        in
        let results =
          List.map
            (fun target ->
              let output =
                Filename.concat dir
                  (Filename.concat ".emo-build" ("emoji-" ^ target))
              in
              let code =
                build_file ~entry ~output ~specialize:true ~cclibs:[] ~target
              in
              (target, code))
            m.Emo_pkg.targets
        in
        let failed = List.filter (fun (_, code) -> code <> 0) results in
        if failed = [] then begin
          List.iter
            (fun (target, _) -> Printf.printf "%-11s ok\n" target)
            results;
          0
        end
        else begin
          List.iter
            (fun (target, _) ->
              prerr_endline
                (Printf.sprintf "emo emoji build: the %s target failed" target))
            failed;
          match List.find_opt (fun (_, code) -> code = 70) failed with
          | Some (_, code) -> code
          | None -> 65
        end

let emoji_build_cmd =
  Cmd.v
    (Cmd.info "build"
       ~doc:"Compile the package's entry module under every declared target.")
    Term.(
      const (fun () ->
          match emoji_build ~dir:(Sys.getcwd ()) with
          | 0 -> Cmd.Exit.ok
          | code -> exit code)
      $ const ())

(* `emo emoji login`: verify the account against the registry, mint a
   push/yank/read API token, and store it — afterwards `emo publish` needs
   neither --token nor EMO_TOKEN. The email and password come from the
   terminal (the password read with the echo disabled) or, when stdin is
   piped, as two plain lines. *)
let emoji_login ~(registry_opt : string option) ~(expires_in_days : int) : int =
  if expires_in_days < 0 then begin
    prerr_endline
      "emo emoji login: --expires-in-days must not be negative (0 = the token \
       never expires)";
    65
  end
  else
    let registry =
      match (registry_opt, Sys.getenv_opt "EMO_REGISTRY") with
      | Some r, _ -> Some r
      | None, Some r when r <> "" -> Some r
      | _ -> None
    in
    match registry with
    | None ->
        prerr_endline
          "emo emoji login: no registry configured — pass --registry or set \
           EMO_REGISTRY";
        65
    | Some registry -> (
        let interactive = Unix.isatty Unix.stdin in
        let read_line_of prompt =
          if interactive then begin
            prerr_string prompt;
            flush stderr;
            read_line ()
          end
          else read_line ()
        in
        match
          try
            let email =
              String.trim (read_line_of (if interactive then "Email: " else ""))
            in
            let password =
              if interactive then read_hidden_line ~prompt:"Password: "
              else read_line ()
            in
            Some (email, password)
          with End_of_file -> None
        with
        | None ->
            prerr_endline
              "emo emoji login: expected an email and a password on stdin";
            65
        | Some (email, password) -> (
            if email = "" then begin
              prerr_endline "emo emoji login: an email is required";
              65
            end
            else if password = "" then begin
              prerr_endline "emo emoji login: a password is required";
              65
            end
            else
              let file = credentials_file () in
              match
                apply_login ~file ~registry ~email ~password ~expires_in_days
              with
              | Logged_in (username, _token, expires_at) ->
                  Printf.printf "logged in as %s\n" username;
                  let scope_note =
                    if expires_at = "" then "push, yank, read"
                    else
                      Printf.sprintf "push, yank, read, expires %s" expires_at
                  in
                  Printf.printf "token \"%s\" (%s) for %s — stored in %s\n"
                    (cli_token_name ()) scope_note (registry_base registry) file;
                  0
              | Rejected message ->
                  prerr_endline ("emo emoji login: " ^ message);
                  65
              | Unreachable message ->
                  prerr_endline ("emo emoji login: " ^ message);
                  70
              | Not_stored message ->
                  prerr_endline ("emo emoji login: " ^ message);
                  65))

let emoji_login_cmd =
  let registry =
    Arg.(
      value
      & opt (some string) None
      & info [ "registry" ] ~docv:"URL"
          ~doc:
            "Registry endpoint (default: the EMO_REGISTRY environment \
             variable).")
  in
  let expires_in_days =
    Arg.(
      value & opt int 0
      & info [ "expires-in-days" ] ~docv:"DAYS"
          ~doc:
            "Expire the minted token after this many days (default: 0, the \
             token never expires). The expiry is recorded alongside the token; \
             when it passes, the registry refuses the token and `emo publish` \
             says to log in again.")
  in
  Cmd.v
    (Cmd.info "login"
       ~doc:
         "Sign in to a registry: verifies the account and stores a \
          push/yank/read API token, so `emo publish` needs neither --token nor \
          EMO_TOKEN. With a terminal, asks for the email and password; \
          otherwise reads them as two lines from stdin.")
    Term.(
      const (fun r days ->
          match emoji_login ~registry_opt:r ~expires_in_days:days with
          | 0 -> Cmd.Exit.ok
          | code -> exit code)
      $ registry $ expires_in_days)

let emoji =
  Cmd.group
    (Cmd.info "emoji"
       ~doc:"Manage shared packages — the lifecycle of a .emoji archive.")
    [ emoji_new_cmd; emoji_build_cmd; emoji_login_cmd; publish_cmd ]

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
      emoji;
      new_cmd;
      doctor_cmd;
      version_cmd;
    ]

let main () = exit (Cmd.eval' cmd)
