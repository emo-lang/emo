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

(* Raised when the build directory cannot be created. Every arm of the
   build needs it, so the failure is named once here rather than
   surfacing as a write error from whichever step reached it first. *)
exception Build_dir_failed of string

(* A `package.emo` is a manifest, not a program: the module walk leaves it
   out at every depth, so naming it as the entry would only read its fields
   as unbound names. `emo check` reads a manifest as what it is; the
   commands that need a program refuse the file and say which one to name. *)
let refuse_manifest_entry ~(file : string) ~(hint : string) : int =
  prerr_endline
    (Printf.sprintf "%s: a package manifest, not a program — %s" file hint);
  66

(* Runs one file through the project pipeline: discover the module tree,
   check every module, then evaluate. Exit codes: 0 success, 1 uncaught
   exception, 65 lex/parse/check, 66 unreadable input or a manifest in
   place of a program, 70 evaluation. *)
let run_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match Sys.file_exists file with
  | false ->
      prerr_endline (Printf.sprintf "%s: No such file or directory" file);
      66
  | true when Emo_pkg.is_manifest_file file ->
      refuse_manifest_entry ~file ~hint:"name the module to run"
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
   generated data (step 25), so the toolchain alone decides whether the
   target can build, on any installation shape. *)

(* The OCaml toolchain comes from the opam switch: PATH first, then the
   switch prefixes under ~/.opam (dune test actions run without the opam
   environment). The switch scan checks the tool only — whether the
   runtime's own packages are present is [ocaml_target_ok]'s question,
   answered the same way on every installation shape (step 25). *)
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
   only the target's toolchain (step 25). `emo build --target ocaml`
   refuses on this with the fix named, and `emo doctor` reports it per
   target. *)
(* Probes answer in milliseconds or not at all, so they get a short
   deadline — and a probe that hangs answers no better than one that
   fails: the tool is reported as missing or broken rather than left
   holding the command. Everything the toolchain actually runs goes
   through [Emo_tool.run_status] with its own, much longer, deadline. *)

let probe_ok ?(timeout = Emo_tool.probe_deadline) (cmd : string) : bool =
  match Emo_tool.run_status ~timeout cmd with
  | 0 -> true
  | _ -> false
  | exception Emo_tool.Timeout _ -> false

let probe_first_line ?(timeout = Emo_tool.probe_deadline) (cmd : string) :
    string =
  match Emo_tool.probe ~timeout cmd with
  | line, Unix.WEXITED 0 -> line
  | _ -> ""
  | exception Emo_tool.Timeout _ -> ""

let tool_exists (name : string) : bool =
  probe_first_line (Printf.sprintf "command -v %s" (Filename.quote name)) <> ""

(* The riscv64 target's assembler and linker: the GNU cross binutils
   arrive under the upstream prefix or a distribution's shorter one
   (Homebrew ships riscv64-elf). The build and the doctor must agree on
   the answer, so both ask here. *)
let riscv_binutils_prefix () : string option =
  List.find_opt
    (fun p -> tool_exists (p ^ "-as") && tool_exists (p ^ "-ld"))
    [ "riscv64-unknown-elf"; "riscv64-elf" ]

let ocaml_target_ok () : bool =
  let found = find_ocamlfind () in
  (if found = "ocamlfind" then tool_exists "ocamlfind" else true)
  && probe_ok
       (Printf.sprintf "%s query unix ssl >/dev/null 2>&1"
          (Filename.quote found))

(* The build command: entry file → artifact at [-o] (default: the
   entry's stem in the current directory). The target picks the
   backend: ocaml (default) emits OCaml compiled by the OCaml
   toolchain; c emits C compiled by the system cc into a standalone
   binary; typescript emits one self-contained .ts file that runs on
   Node. A `package.emo` is a manifest rather than a program, so it is
   refused like one (66) — `emo emoji build` is what builds a package. *)
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
  | true when Emo_pkg.is_manifest_file entry ->
      refuse_manifest_entry ~file:entry
        ~hint:"`emo emoji build` builds a package from its manifest"
  | true -> (
      try
        let inputs, entry_path, packages, (dep_csources, dep_links) =
          Emo_project.compile_inputs ~entry_file:entry ~target
        in
        let program =
          Emo_ir.lower { Emo_ir.modules = inputs; entry = entry_path; packages }
        in
        let build_dir = Filename.concat (Sys.getcwd ()) ".emo-build" in
        if
          (not (Sys.file_exists build_dir))
          && Emo_tool.run_status
               (Printf.sprintf "mkdir -p %s" (Filename.quote build_dir))
             <> 0
        then raise (Build_dir_failed build_dir);
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
            (* erlc requires the module atom to equal the .core file's
               stem (plan/step-18-beam.md), so the module is named after
               the requested output and both the file and the atom come
               from that one name. A stem that is not an atom is refused
               here, where the rule can still be explained. *)
            let stem = Filename.remove_extension (Filename.basename output) in
            if not (Emo_codegen.Beam.valid_module_name stem) then begin
              prerr_endline
                (Printf.sprintf
                   "emo build: `%s` is not a usable BEAM module name — the \
                    module is named after the output file, and a BEAM module \
                    name is a lower-case letter followed by letters, digits, \
                    `_` or `@`"
                   stem);
              65
            end
            else
              let core = Emo_codegen.Beam.emit ~module_name:stem program in
              let out =
                Filename.concat (Filename.dirname output) (stem ^ ".core")
              in
              let oc = open_out_bin out in
              output_string oc core;
              close_out oc;
              let beam = Filename.remove_extension out ^ ".beam" in
              (* erlc writes beside the source only with -o; without it the
                 .beam lands in the caller's working directory, wherever
                 that is *)
              let rc =
                Emo_tool.run_status
                  (Printf.sprintf "erlc -o %s %s"
                     (Filename.quote (Filename.dirname out))
                     (Filename.quote out))
              in
              if rc <> 0 then (
                prerr_endline
                  (Printf.sprintf "emo build: erlc failed on %s" out);
                70)
              else (
                Printf.printf "built %s\n" beam;
                0)
        | "typescript" ->
            (* The prelude rides the compiler as generated data; the
               arm never touches the filesystem for it (step 25). *)
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
                (Emo_tool.run_or_warn ~what:"emo build"
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
                (Emo_tool.run_or_warn ~what:"emo build"
                   (Printf.sprintf "cp %s %s"
                      (Filename.quote cache_file)
                      (Filename.quote out)));
              Printf.printf "built %s\n" out;
              0
            end
        | "c" ->
            (* Emit one main.c plus the Emo runtime sources, compile
               with the system cc: a standalone binary with no OCaml
               runtime (step 23). *)
            let write path contents =
              let oc = open_out_bin path in
              output_string oc contents;
              close_out oc
            in
            let main_c_contents, defs_h_contents = Emo_codegen.C.emit program in
            (* The resolved packages' native inputs ride the cclib
               mechanism: a package's .c sources pass to cc verbatim
               (absolute existing paths) and enter the cache key by
               content, its `link` libraries become -l flags. Sources
               come before libraries so the link resolves. *)
            let cclibs = cclibs @ dep_csources @ dep_links in
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
                (Emo_tool.run_or_warn ~what:"emo build"
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
              (* -lm carries the runtime's math functions (sqrt,
                 floor, ceil, trunc); macOS folds libm into libSystem,
                 so the flag is a no-op there and the fix on glibc,
                 where those symbols live in a separate library. It
                 stays after cclib_flags so a package's own library
                 (sqlite3, say) resolves its math imports too. *)
              let cmd =
                Printf.sprintf
                  "cc -O2 -ffp-contract=off -std=c11 -Wall \
                   -Wno-deprecated-declarations -I %s %s %s                  \
                   %s -lm -o %s"
                  (Filename.quote build_dir) (Filename.quote main_c)
                  (Filename.quote runtime_c) cclib_flags (Filename.quote output)
              in
              let exit_code = Emo_tool.run_status cmd in
              if exit_code <> 0 then begin
                prerr_endline
                  (Printf.sprintf "emo build: the C compiler failed (exit %d)"
                     exit_code);
                70
              end
              else begin
                ignore
                  (Emo_tool.run_or_warn ~what:"emo build"
                     (Printf.sprintf "cp %s %s" (Filename.quote output)
                        (Filename.quote cache_binary)));
                Printf.printf "built %s\n" output;
                0
              end
            end
        | "ocaml" ->
            (* The refusal is installation-independent (step 25): the
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
                        (String.concat "," cclibs) (Lazy.force compiler_key)))
              in
              let cache_binary =
                Filename.concat build_dir ("cache-" ^ digest)
              in
              if Sys.file_exists cache_binary then begin
                ignore
                  (Emo_tool.run_or_warn ~what:"emo build"
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
                    if Emo_tool.run_status cc_cmd <> 0 then raise Stub_cc_failed;
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
                let exit_code = Emo_tool.run_status compile_runtime in
                let exit_code =
                  if exit_code <> 0 then exit_code
                  else Emo_tool.run_status link_cmd
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
                    (Emo_tool.run_or_warn ~what:"emo build"
                       (Printf.sprintf "cp %s %s" (Filename.quote output)
                          (Filename.quote cache_binary)));
                  Printf.printf "built %s\n" output;
                  0
                end
              end
        | "riscv64" ->
            (* Emit RV64 assembly for the GNU cross binutils: one
               freestanding ELF that boots under QEMU or on the machine
               (step 19). *)
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
            let prefix = riscv_binutils_prefix () in
            begin match prefix with
            | None ->
                prerr_endline
                  "emo build: the riscv64 target needs the GNU cross binutils \
                   on PATH — riscv64-unknown-elf-as/-ld or riscv64-elf-as/-ld";
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
                let exit_code = Emo_tool.run_status as_cmd in
                let exit_code =
                  if exit_code <> 0 then exit_code
                  else Emo_tool.run_status ld_cmd
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
      | Emo_tool.Timeout { command; timeout } ->
          (* One handler covers every toolchain step below: a build that
             stopped because a tool stopped answering is an external
             command failing, which is what 70 already means here. *)
          prerr_endline
            (Printf.sprintf
               "emo build: %s did not finish within %.0fs and was killed"
               command timeout);
          70
      | Stub_cc_failed ->
          prerr_endline "emo build: the C stub compilation failed";
          70
      | Build_dir_failed dir ->
          prerr_endline (Printf.sprintf "emo build: cannot create %s" dir);
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

(* `emo check`: the static stages only, over the whole module tree. A
   `package.emo` is a manifest rather than a module, so it is read the way
   every other manifest reader reads it. *)
let check_file ~(file : string) ~(color : bool) ~(error_limit : int) : int =
  match Sys.file_exists file with
  | false ->
      prerr_endline (Printf.sprintf "%s: No such file or directory" file);
      66
  | true when Emo_pkg.is_manifest_file file -> (
      match
        Emo_pkg.parse_manifest ~file ~source:(Emo_project.read_file file)
      with
      | _ -> 0
      | exception Emo_pkg.Manifest_error d ->
          render_errors ~color ~error_limit [ d ];
          65)
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
        if
          (not (Sys.file_exists build_dir))
          && Emo_tool.run_status
               (Printf.sprintf "mkdir -p %s" (Filename.quote build_dir))
             <> 0
        then begin
          prerr_endline (Printf.sprintf "emo run: cannot create %s" build_dir);
          exit 70
        end;
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
          (* The program itself: how long it runs is the program's
             business, so this wait has no deadline. *)
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
    (Cmd.info "check"
       ~doc:"Check an Emo file, or a package.emo manifest, without running it.")
    Term.(const check $ file $ no_color $ error_limit)

(* `emo test`: the project's test convention — every `def test_*` under
   the test/ directory runs, each in its own scheduler run. A failing
   assertion (or any uncaught raise) fails its test; a runtime error
   errors it. Exit codes: 0 all pass, 1 any failure or error, 65 the
   tree's static stages failed. *)
let run_tests_cmd ~(color : bool) ~(error_limit : int) : int =
  let indent text =
    let text =
      (* A test's output already ends in a newline; the indentation
         wraps its lines, not the trailing blank. *)
      let n = String.length text in
      if n > 0 && text.[n - 1] = '\n' then String.sub text 0 (n - 1) else text
    in
    String.concat "\n"
      (List.map (fun line -> "  " ^ line) (String.split_on_char '\n' text))
  in
  let show_diagnostic color d =
    print_endline
      (indent (Emo_support.Render.render ~color ~source:(Sys.getcwd ()) d))
  in
  try
    let results = Emo_project.run_tests () in
    let total = List.length results in
    if total = 0 then begin
      print_endline "no tests found under test/";
      0
    end
    else begin
      let passed = ref 0 and failed = ref 0 and errored = ref 0 in
      List.iter
        (fun (r : Emo_project.test_result) ->
          let name =
            String.concat "." (r.Emo_project.t_module @ [ r.t_name ])
          in
          match r.t_outcome with
          | Emo_project.Passed ->
              incr passed;
              Printf.printf "ok %s\n" name
          | Emo_project.Failed d ->
              incr failed;
              Printf.printf "FAIL %s\n" name;
              show_diagnostic color d;
              if r.t_output <> "" then print_endline (indent r.t_output)
          | Emo_project.Errored d ->
              incr errored;
              Printf.printf "ERROR %s\n" name;
              show_diagnostic color d;
              if r.t_output <> "" then print_endline (indent r.t_output))
        results;
      let bucket word n = Printf.sprintf "%d %s" n word in
      let buckets =
        bucket "passed" !passed
        :: (if !failed > 0 then [ bucket "failed" !failed ] else [])
        @
        if !errored > 0 then
          [ bucket (if !errored = 1 then "error" else "errors") !errored ]
        else []
      in
      Printf.printf "%d test%s, %s\n" total
        (if total = 1 then "" else "s")
        (String.concat ", " buckets);
      if !failed + !errored > 0 then 1 else 0
    end
  with
  | Emo_project.Static_errors diagnostics ->
      render_errors ~color ~error_limit diagnostics;
      65
  | Emo_lexer.Error diagnostic ->
      render_errors ~color ~error_limit [ diagnostic ];
      65

let test_cmd =
  let no_color, error_limit = static_flags () in
  let test no_color error_limit =
    let color = (not no_color) && Unix.isatty Unix.stderr in
    match run_tests_cmd ~color ~error_limit with
    | 0 -> Cmd.Exit.ok
    | code -> exit code
  in
  Cmd.v
    (Cmd.info "test"
       ~doc:
         "Run the project's tests: every top-level `def test_*` in every \
          module under the test/ directory, each in its own scheduler run. \
          Assertions are the expect_equal / expect_true / expect_false / \
          expect_fail builtins; a failed assertion fails only its own test.")
    Term.(const test $ no_color $ error_limit)

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

(* `emo emoji publish`: pack the package rooted at the working directory and POST
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
   comes back as (R.error, reason); the program re-raises the reason so
   the host maps it to a plain error, exactly like before the failures
   became values. *)
let upload_program =
  {|require "http"

const resp = http.request("POST", __url, [("Authorization", "Bearer " + __token), ("Content-Type", "application/octet-stream")], __body, 120.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    println(ok.body)
  }
}
|}

(* The login step: email + password as JSON, no credentials header yet. *)
let login_program =
  {|require "http"

const resp = http.request("POST", __url, [("Content-Type", "application/json")], __body, 60.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    println(ok.body)
  }
}
|}

(* The token-minting step: HTTP basic auth — the account API's documented
   path for the CLI — in exchange for a fresh API token. *)
let token_program =
  {|require "http"

const resp = http.request("POST", __url, [("Authorization", "Basic " + __basic), ("Content-Type", "application/json")], __body, 60.0)
case resp {
  (R.error, why) -> { raise Exception.new(message: why) }
  (R.ok, ok)     -> {
    println(ok.status)
    println(ok.body)
  }
}
|}

(* The two origins an error in the registry flow can have: this CLI (a
   manifest problem, missing credentials, a transport failure) and the
   registry (a refusal it answered with). Each prints under its own
   highlighted label, so the scrollback shows at a glance who is
   complaining; color rides only on a terminal stderr. *)
let cli_error (message : string) : unit =
  let color = Unix.isatty Unix.stderr in
  prerr_endline
    (Emo_support.Render.styled color "31;1" "Emo CLI:" ^ " " ^ message)

let registry_error (message : string) : unit =
  let color = Unix.isatty Unix.stderr in
  prerr_endline
    (Emo_support.Render.styled color "35;1" "Registry Remote:" ^ " " ^ message)

(* POSTs [archive] to {registry}/api/v1/packages and returns the HTTP status
   and response body. The embedded-program machinery ([run_embedded],
   [parse_exchange], [registry_base]) lives in Emo_project — the HTTP
   registry's pull client rides the same transport. *)
let upload ~(registry : string) ~(token : string) ~(archive : string) :
    (int * string, string) result =
  match
    Emo_project.run_embedded ~tag:"publish" ~program:upload_program
      ~globals:
        [
          ( "__url",
            Emo_eval.String
              (Emo_project.registry_base registry ^ "/api/v1/packages") );
          ("__token", Emo_eval.String token);
          ("__body", Emo_eval.String archive);
        ]
  with
  | Error e -> Error e
  | Ok text -> Emo_project.parse_exchange text

(* Registry credentials — the login file's format, stored logins, read and
   write — live in Emo_project: the HTTP registry's pull client reads the
   same store, and a token is only ever sent to its own registry. *)

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
    match Emo_project.run_embedded ~tag:"login" ~program ~globals with
    | Error e -> Error e
    | Ok text -> Emo_project.parse_exchange text
  in
  match
    run login_program
      [
        ( "__url",
          Emo_eval.String (Emo_project.registry_base registry ^ "/api/v1/login")
        );
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
              Emo_eval.String
                (Emo_project.registry_base registry ^ "/api/v1/tokens") );
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
                  Emo_project.store_credentials ~file
                    ~registry:(Emo_project.registry_base registry)
                    ~token ~username ~expires_at
                with
                | Ok () -> Logged_in (username, token, expires_at)
                | Error m -> Not_stored m)
          | None -> Rejected "the token response carried no token")
      | None -> Rejected "the login response carried no username")
  | Ok (status, body, 0, _) -> Rejected (describe_refusal status body)
  | Ok (_, _, status, body) -> Rejected (describe_refusal status body)

(* Resolves publish's endpoint and token: the flags win, then the
   environment, then the manifest's `registry` field, then the stored
   `emo emoji login` entries — the manifest is the project's own committed
   choice, so it outranks the machine-local most-recent-login fallback, and
   a token is only ever taken from the entry belonging to the resolved
   registry, never another registry's. *)
let resolve_publish_auth ~(registry_opt : string option)
    ~(env_registry : string option) ~(manifest_registry : string option)
    ~(token_opt : string option) ~(env_token : string option)
    ~(stored : Emo_project.stored_login list) : (string * string, string) result
    =
  let registry =
    match (registry_opt, env_registry) with
    | Some r, _ -> Some r
    | None, Some r when r <> "" -> Some r
    | _ -> (
        match manifest_registry with
        | Some r -> Some r
        | None -> (
            match List.rev stored with
            | e :: _ -> Some e.Emo_project.c_registry
            | [] -> None))
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
                (fun e ->
                  Emo_project.registry_base e.Emo_project.c_registry
                  = Emo_project.registry_base r)
                stored
            with
            | Some e -> Some e.Emo_project.c_token
            | None -> None))
  in
  match (registry, token) with
  | None, _ ->
      Error
        "no registry configured — pass --registry, set EMO_REGISTRY, set \
         `registry` in package.emo, or run `emo emoji login`"
  | _, None ->
      Error
        "no API token — pass --token, set EMO_TOKEN, or run `emo emoji login`"
  | Some registry, Some token -> Ok (registry, token)

let publish ~(registry_opt : string option) ~(token_opt : string option)
    ~(dry_run : bool) : int =
  let dir = Sys.getcwd () in
  if not (Sys.file_exists (Filename.concat dir "package.emo")) then begin
    cli_error "no package.emo in the current directory";
    66
  end
  else
    match Emo_pkg.Publish.prepare ~dir with
    | Error message ->
        cli_error message;
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
          let manifest_registry = m.Emo_pkg.registry in
          let env_token =
            match Sys.getenv_opt "EMO_TOKEN" with
            | Some t when t <> "" -> Some t
            | _ -> None
          in
          (* The stored logins are consulted only when a fallback is
             actually needed; a damaged file then surfaces instead of
             being silently ignored. The manifest's field can satisfy the
             registry half, but the token may still have to come from the
             entry minted for it. *)
          match
            if
              registry_opt = None && env_registry = None
              && manifest_registry = None
              || (token_opt = None && env_token = None)
            then
              Emo_project.load_credentials
                ~file:(Emo_project.credentials_file ())
            else Ok []
          with
          | Error m ->
              cli_error m;
              65
          | Ok stored -> (
              match
                resolve_publish_auth ~registry_opt ~env_registry
                  ~manifest_registry ~token_opt ~env_token ~stored
              with
              | Error message ->
                  cli_error message;
                  65
              | Ok (registry, token) -> (
                  match upload ~registry ~token ~archive:p.p_archive with
                  | Error message ->
                      cli_error ("upload failed: " ^ message);
                      70
                  | Ok (201, _) ->
                      Printf.printf "published %s %s\n" m.Emo_pkg.name version;
                      Printf.printf "  %s/p/%s\n"
                        (Emo_project.registry_base registry)
                        m.Emo_pkg.name;
                      0
                  | Ok (status, body) -> (
                      let code = json_string_field "code" body in
                      let message = json_string_field "message" body in
                      match (code, message) with
                      | Some code, Some message ->
                          registry_error (code ^ ": " ^ message);
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
                                 (Emo_project.registry_base registry));
                          1
                      | _ ->
                          registry_error
                            (Printf.sprintf "HTTP %d: %s" status
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
             variable, then the manifest's `registry` field, then the most \
             recent `emo emoji login`).")
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

(* ---- `emo doctor`: the target-aware environment check (T24.5) ----

   One line per target: what it needs, what was found. The default
   target's health decides the exit code — the other targets are
   informational, and an unavailable one gets the honest fix named
   rather than a raw toolchain error. *)

let tool_version (name : string) : string =
  match probe_first_line (name ^ " --version 2>/dev/null") with
  | "" -> ""
  | line -> " (" ^ line ^ ")"

(* The c target's check: cc exists, compiles, and the result runs. Every
   step here is a probe — a smoke program is not a build — so a cc that
   hangs is reported broken instead of holding `emo doctor` for the
   length of a build deadline. *)
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
      match
        Emo_tool.run_status ~timeout:Emo_tool.probe_deadline
          (Printf.sprintf "cc -o %s %s" (Filename.quote bin) (Filename.quote c))
      with
      | 0 -> true
      | _ -> false
      | exception Emo_tool.Timeout _ -> false
    in
    if not compile then begin
      Emo_project.remove_tree dir;
      Error "cc failed to compile a smoke program"
    end
    else begin
      let out = probe_first_line (Filename.quote bin) in
      Emo_project.remove_tree dir;
      if out = "emo" then Ok () else Error "the cc smoke binary did not run"
    end

(* The ocaml target's check: ocamlfind with the unix and ssl packages
   the runtime itself uses — the same question on every installation
   shape, since the runtime rides the compiler (step 25). *)
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
  (match riscv_binutils_prefix () with
  | None ->
      line "riscv64:"
        "unavailable — the riscv64 target needs the GNU cross binutils on PATH \
         (riscv64-unknown-elf-as/-ld or riscv64-elf-as/-ld)"
  | Some _ ->
      if tool_exists "qemu-system-riscv64" then
        line "riscv64:" ("ok" ^ tool_version "qemu-system-riscv64")
      else
        line "riscv64:"
          "unavailable — qemu-system-riscv64 not found (the dev loop needs it)");
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
   main.emo with its test under test/, and .gitignore (T24.3). Strictness
   holds: an existing
   directory or clashing files refuse; nothing is ever overwritten. The
   manifest carries the plain name when no owner is given — running,
   checking, and building work at once, and `emo emoji publish` names the
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
       once, and `emo emoji publish` names the owner/name rule when it is
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
    Unix.mkdir (Filename.concat path "test") 0o755;
    write "package.emo"
      (Printf.sprintf
         {|package {
  // The package name. A plain name works while the project stays local;
  // publishing (`emo emoji publish`) asks for the owner/name form,
  // e.g. "acme/hello".
  name = "%s"
  // This package's own version: exact major.minor.patch.
  version = "0.1.0"
  // The backends this package runs and builds on. Known targets:
  // "ocaml", "c", "wasm", "typescript", "beam", "riscv64".
  targets = ["ocaml", "c"]
  // Optional: system libraries the c target links, as bare names.
  // link = ["sqlite3"]

  // Dependencies — one per line, as  "name" = "exact version".
  // Versions are exact major.minor.patch pins, never ranges. The name
  // is what `require` names in your .emo files: a standard-library
  // short name like "json" needs no entry (the compiler ships it); a
  // registry package's owner/name is pinned here. Either way the
  // package binds in code under its short name.
  deps {
    // "json" = "0.1.0"       then:  require "json"       binds `json`
    // "acme/leaf" = "1.0.0"  then:  require "acme/leaf"  binds `leaf`
  }
  // After editing deps: `emo deps resolve` writes package.lock,
  // `emo deps update <name>` regenerates it after one pin changes, and
  // `emo deps list` shows the locked versions — builds never rewrite
  // the lockfile silently.
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
    write "test/greet.emo"
      {|// Tests for main.emo's greet — run them with `emo test`.

def test_greet() {
  expect_equal("Hello, world!", main.greet("world"))
}
|};
    write ".gitignore" ".emo-build/\n";
    Printf.printf "created %s — next: cd %s && emo run main.emo, or emo test\n"
      path path;
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
  // The publishable package name: owner/name, each part a lowercase
  // identifier — a letter, then letters, digits or `_`.
  name = "%s/%s"
  // This package's own version: exact major.minor.patch. Publishing an
  // existing version is rejected — bump it before re-publishing.
  version = "0.1.0"
  // The backends this package runs and builds on. Known targets:
  // "ocaml", "c", "wasm", "typescript", "beam", "riscv64".
  targets = ["ocaml", "c"]
  // Optional: system libraries the c target links, as bare names.
  // link = ["sqlite3"]

  // Dependencies — one per line, as  "name" = "exact version".
  // Versions are exact major.minor.patch pins, never ranges. The name
  // is what `require` names in your .emo files: a standard-library
  // short name like "json" needs no entry (the compiler ships it); a
  // registry package's owner/name is pinned here. Either way the
  // package binds in code under its short name.
  deps {
    // "json" = "0.1.0"       then:  require "json"       binds `json`
    // "acme/leaf" = "1.0.0"  then:  require "acme/leaf"  binds `leaf`
  }
  // After editing deps: `emo deps resolve` writes package.lock,
  // `emo deps update <name>` regenerates it after one pin changes, and
  // `emo deps list` shows the locked versions — builds never rewrite
  // the lockfile silently.
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
            "The publishable package name — owner/name, each part a lowercase \
             identifier: a letter, then letters, digits or `_`. The directory \
             is named after the second part.")
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
        (* The package's own native inputs ride the build too — the
           pre-publish gate must link what the package's consumers will
           get: its tree's .c sources and its manifest's link
           libraries. The dependency mechanism in build_file covers a
           package's deps; the package itself is not its own dep. *)
        let own_csources =
          Emo_pkg.Registry.collect_files dir
          |> List.filter_map (fun (rel, _) ->
              if Filename.check_suffix rel ".c" then
                Some (Filename.concat dir rel)
              else None)
        in
        let results =
          List.map
            (fun target ->
              (* The output's stem is what names the BEAM module, so it
                 has to be an atom: `emoji_beam`, not `emoji-beam`. *)
              let output =
                Filename.concat dir
                  (Filename.concat ".emo-build" ("emoji_" ^ target))
              in
              let code =
                build_file ~entry ~output ~specialize:true
                  ~cclibs:(own_csources @ m.Emo_pkg.link)
                  ~target
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
   push/yank/read API token, and store it — afterwards `emo emoji publish`
   needs
   neither --token nor EMO_TOKEN. The email and password come from the
   terminal (the password read with the echo disabled) or, when stdin is
   piped, as two plain lines. *)

(* The endpoint the login authenticates against: the flag wins, then the
   environment, then the manifest's `registry` field — the same field
   `emo emoji publish` and dependency pulls read, so a project names its
   registry
   once. A damaged manifest is an error rather than a silent skip: the
   field cannot be read past it. *)
let resolve_login_registry ~(registry_opt : string option) :
    (string option, string) result =
  match registry_opt with
  | Some r -> Ok (Some r)
  | None -> (
      match Sys.getenv_opt "EMO_REGISTRY" with
      | Some r when r <> "" -> Ok (Some r)
      | _ -> (
          let path = Filename.concat (Sys.getcwd ()) "package.emo" in
          if not (Sys.file_exists path) then Ok None
          else
            match
              Emo_pkg.parse_manifest ~file:path
                ~source:(Emo_project.read_file path)
            with
            | exception Emo_pkg.Manifest_error d ->
                Error d.Emo_support.Diagnostic.message
            | m -> Ok m.Emo_pkg.registry))

let emoji_login ~(registry_opt : string option) ~(expires_in_days : int) : int =
  if expires_in_days < 0 then begin
    cli_error
      "--expires-in-days must not be negative (0 = the token never expires)";
    65
  end
  else
    match resolve_login_registry ~registry_opt with
    | Error message ->
        cli_error message;
        65
    | Ok None ->
        cli_error
          "no registry configured — pass --registry, set EMO_REGISTRY, or set \
           `registry` in package.emo";
        65
    | Ok (Some registry) -> (
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
            cli_error "expected an email and a password on stdin";
            65
        | Some (email, password) -> (
            if email = "" then begin
              cli_error "an email is required";
              65
            end
            else if password = "" then begin
              cli_error "a password is required";
              65
            end
            else
              let file = Emo_project.credentials_file () in
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
                    (cli_token_name ()) scope_note
                    (Emo_project.registry_base registry)
                    file;
                  0
              | Rejected message ->
                  registry_error message;
                  65
              | Unreachable message ->
                  cli_error message;
                  70
              | Not_stored message ->
                  cli_error message;
                  65))

let emoji_login_cmd =
  let registry =
    Arg.(
      value
      & opt (some string) None
      & info [ "registry" ] ~docv:"URL"
          ~doc:
            "Registry endpoint (default: the EMO_REGISTRY environment \
             variable, then the manifest's `registry` field).")
  in
  let expires_in_days =
    Arg.(
      value & opt int 0
      & info [ "expires-in-days" ] ~docv:"DAYS"
          ~doc:
            "Expire the minted token after this many days (default: 0, the \
             token never expires). The expiry is recorded alongside the token; \
             when it passes, the registry refuses the token and `emo emoji\n\
            \             publish` says to log in again.")
  in
  Cmd.v
    (Cmd.info "login"
       ~doc:
         "Sign in to a registry: verifies the account and stores a \
          push/yank/read API token, so `emo emoji publish` needs neither\n\
         \          --token nor EMO_TOKEN. With a terminal, asks for the email \
          and password; otherwise reads them as two lines from stdin.")
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
      test_cmd;
      build;
      deps;
      emoji;
      new_cmd;
      doctor_cmd;
      version_cmd;
    ]

(* A wait that ran out of time outside `emo build` — a package command,
   say — still has to name the command that hung and leave on the same
   code an external command's failure does, rather than print a
   backtrace. *)
let main () =
  match Cmd.eval' cmd with
  | code -> exit code
  | exception Emo_tool.Timeout { command; timeout } ->
      prerr_endline
        (Printf.sprintf "emo: %s did not finish within %.0fs and was killed"
           command timeout);
      exit 70
