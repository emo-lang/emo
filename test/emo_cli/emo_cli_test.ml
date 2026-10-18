let tc name f = Alcotest.test_case name `Quick f
let run_cmd = Emo_test_support.run_cmd

let contains hay needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length hay && (String.sub hay i n = needle || go (i + 1))
  in
  go 0

(* A scratch directory for fixture programs; files persist for the run. *)
let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-cli-test-fixtures"

(* The registry arrives relative to the directory dune runs the tests in,
   and a fixture resolves its dependencies from inside its own project
   directory, so pin the path before anything else runs. *)
let () =
  match Sys.getenv_opt "EMO_REGISTRY" with
  | Some dir when dir <> "" -> Unix.putenv "EMO_REGISTRY" (Unix.realpath dir)
  | _ -> ()

(* The manifest every scratch project carries: without a package.emo in
   the working directory there is no project at all (E5010). *)
let default_manifest =
  {|package {
  name = "local/scratch"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {}
}
|}

let write_file path source =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
  let oc = open_out_bin path in
  output_string oc source;
  close_out oc

let in_dir dir f =
  let previous = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir previous) f

(* A fixture lives in a project of its own: its own directory, its own
   package.emo. Discovery reads the whole rooted tree, so fixtures sharing
   a root would let one broken file poison every sibling. The manifest is
   overridable for a snippet whose own package declares dependencies. *)
let fixture ?(manifest = default_manifest) name source =
  let dir = Filename.concat scratch (Filename.remove_extension name) in
  let path = Filename.concat dir name in
  write_file (Filename.concat dir "package.emo") manifest;
  write_file path source;
  path

(* The commands root themselves where they stand, so every call runs from
   the fixture's own project directory. *)
let run_fixture file =
  in_dir (Filename.dirname file) (fun () ->
      Emo_cli.run_file ~file ~color:false ~error_limit:20)

let run_tests =
  [
    tc "a successful program exits 0" (fun () ->
        let file = fixture "ok.emo" "const x = 1\nprintln(x + 1)\n" in
        Alcotest.(check int) "exit" 0 (run_fixture file));
    tc "a parse error exits 65" (fun () ->
        let file = fixture "parse.emo" "const x =\n1\n" in
        Alcotest.(check int) "exit" 65 (run_fixture file));
    tc "a runtime type error exits 70" (fun () ->
        (* The element type is Unknown to the checker; the runtime hits it. *)
        let file = fixture "runtime.emo" {|println([1, "a"][1] + 1)|} in
        Alcotest.(check int) "exit" 70 (run_fixture file));
    tc "a certain type error exits 65 before running" (fun () ->
        let file = fixture "checked.emo" {|println(1 + "a")|} in
        Alcotest.(check int) "exit" 65 (run_fixture file));
    tc "an uncaught exception exits 1" (fun () ->
        let file =
          fixture "raise.emo" {|raise Exception.new(message: "boom")|}
        in
        Alcotest.(check int) "exit" 1 (run_fixture file));
    tc "an unreadable file exits 66" (fun () ->
        Alcotest.(check int)
          "exit" 66
          (Emo_cli.run_file
             ~file:(Filename.concat scratch "missing.emo")
             ~color:false ~error_limit:20));
  ]

let contains hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

let queue_input lines =
  let q = ref lines in
  fun () ->
    match !q with
    | [] -> None
    | line :: rest ->
        q := rest;
        Some line

let repl_tests =
  [
    tc "expression lines echo their value" (fun () ->
        let out = Buffer.create 64 in
        Emo_cli.repl_loop ~prompt:false
          ~input:(queue_input [ "1 + 2"; "exit" ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= 3\n" (Buffer.contents out));
    tc "definitions register and the environment persists" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:
            (queue_input
               [
                 "def double(n Int64) Int64 {";
                 "  return n * 2";
                 "}";
                 "double(21)";
                 "exit";
               ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= 42\n" (Buffer.contents out));
    tc "runtime errors print and the environment survives" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:(queue_input [ "println(nope)"; "40 + 2"; "exit" ])
          ~output:(Buffer.add_string out);
        let text = Buffer.contents out in
        Alcotest.(check bool) "error reported" true (contains text "E3002");
        Alcotest.(check bool) "env survives" true (contains text "= 42"));
    tc "an uncaught raise prints and the repl survives" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:
            (queue_input
               [ {|raise Exception.new(message: "boom")|}; "2 * 3"; "exit" ])
          ~output:(Buffer.add_string out);
        let text = Buffer.contents out in
        Alcotest.(check bool) "raise reported" true (contains text "E3010");
        Alcotest.(check bool) "env survives" true (contains text "= 6"));
    tc "classes register in the repl" (fun () ->
        let out = Buffer.create 128 in
        Emo_cli.repl_loop ~prompt:false
          ~input:
            (queue_input
               [
                 "class Greeter {";
                 "  def init() {}";
                 "";
                 "  def greet() String {";
                 "    return \"hi\"";
                 "  }";
                 "}";
                 "Greeter.new().greet()";
                 "exit";
               ])
          ~output:(Buffer.add_string out);
        Alcotest.(check string) "output" "= hi\n" (Buffer.contents out));
  ]

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let smoke_tests =
  [
    tc "library links" (fun () ->
        let module M = Emo_cli in
        ());
    tc "version matches the VERSION file" (fun () ->
        let expected = String.trim (read_file "../../VERSION") in
        Alcotest.(check string) "version" expected Emo_cli.version);
  ]

(* Every examples/<name>/ runs end to end and prints its expected.txt. *)
let examples_dir = "../../examples"

(* A program that requires nothing needs no project resolution, so it runs
   through the bare interpreter; one that requires a package runs through
   the rooted tree in test/emo_project, not here. *)
let requires_nothing source =
  not
    (String.split_on_char '\n' source
    |> List.exists (fun line ->
        String.length (String.trim line) >= 7
        && String.sub (String.trim line) 0 7 = "require"))

(* The bare interpreter resolves no package, links no C symbol, and runs
   no scheduler, so three examples cannot go through it: `numerics` binds
   the C math library, `file_read` writes and reads a file, and
   `pipeline` runs four processes. Each runs end to end in test/emo_project
   instead, compiled and interpreted. *)
let beyond_the_interpreter = [ "numerics"; "file_read"; "pipeline" ]

(* Every examples/<name>/ holding one self-contained program runs end to
   end through the bare interpreter and prints its expected.txt. A
   directory holding .emo submodules is a multi-module tree — it runs
   through project semantics in test/emo_project, not here. The two are
   told apart by what sits beside main.emo: a second .emo file (a
   sibling module — a package.emo is a manifest, not a module) or a real
   subdirectory. A dot-directory is the compiler's own scratch
   (.emo-build) and does not count. *)
let example_names () =
  Sys.readdir examples_dir |> Array.to_list |> List.sort compare
  |> List.filter (fun name ->
      let dir = Filename.concat examples_dir name in
      Sys.is_directory dir
      && Sys.file_exists (Filename.concat dir "main.emo")
      && (not (List.mem name beyond_the_interpreter))
      && requires_nothing (read_file (Filename.concat dir "main.emo"))
      &&
      let entries = Sys.readdir dir |> Array.to_list in
      let modules =
        List.filter
          (fun e -> Filename.check_suffix e ".emo" && not (e = "package.emo"))
          entries
      in
      List.length modules = 1
      && not
           (List.exists
              (fun e ->
                String.length e > 0
                && e.[0] <> '.'
                && Sys.is_directory (Filename.concat dir e))
              entries))

let examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s runs with its expected output" name) (fun () ->
          let dir = Filename.concat examples_dir name in
          let source = read_file (Filename.concat dir "main.emo") in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out = Buffer.create 256 in
          Emo_eval.set_output (Buffer.add_string out);
          Fun.protect
            ~finally:(fun () ->
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout))
            (fun () -> Emo_eval.run_program ~file:(name ^ "/main.emo") ~source);
          Alcotest.(check string) "output" expected (Buffer.contents out)))
    (example_names ())

(* The README's error-handling snippets, verbatim, through the real
   `emo run` pipeline: check first, then evaluate. The examples carry no
   main.emo, so the automatic interpreter golden skips them — matching
   and binding exit 0, and the violation's raise is the E3010 crash
   report, exit 1. Each snippet runs from a scratch copy so the project
   scan never sees the examples tree — carrying the errors package's own
   manifest, whose `file` dependency the snippets require. *)
let errors_examples_tests =
  let errors_manifest =
    read_file (Filename.concat examples_dir "errors/package.emo")
  in
  let snippet_source name =
    read_file (Filename.concat examples_dir ("errors/" ^ name ^ ".emo"))
  in
  let run_snippet name =
    let file =
      fixture ~manifest:errors_manifest (name ^ ".emo") (snippet_source name)
    in
    let out = Buffer.create 256 in
    Emo_eval.set_output (Buffer.add_string out);
    let exit_code =
      Fun.protect
        ~finally:(fun () ->
          Emo_eval.set_output (fun s ->
              print_string s;
              flush stdout))
        (fun () -> run_fixture file)
    in
    (exit_code, Buffer.contents out)
  in
  [
    tc "the matching snippet runs verbatim" (fun () ->
        let exit_code, out = run_snippet "matching" in
        Alcotest.(check int) "exit" 0 exit_code;
        Alcotest.(check string) "output" "payload line\n" out);
    tc "the assert-match binding runs verbatim" (fun () ->
        let exit_code, out = run_snippet "binding" in
        Alcotest.(check int) "exit" 0 exit_code;
        Alcotest.(check string) "output" "13\n" out);
    tc "the violation raises and the crash report carries the data" (fun () ->
        let file =
          fixture ~manifest:errors_manifest "errors-violation.emo"
            (snippet_source "violation")
        in
        match
          in_dir (Filename.dirname file) (fun () ->
              Emo_project.run_entry ~entry_file:file ~check:true
                ~sched:Emo_project.Own ())
        with
        | _ -> Alcotest.fail "expected the raise to end the program"
        | exception Emo_project.Static_errors [ diagnostic ] ->
            Alcotest.(check string)
              "code" "E3010"
              (match diagnostic.Emo_support.Diagnostic.code with
              | Some c -> c
              | None -> "");
            Alcotest.(check bool)
              "data rides along" true
              (contains diagnostic.Emo_support.Diagnostic.message
                 "(data: {\"op\": \"connect\", \"peer\": \"10.0.0.1:443\"})")
        | exception e -> raise e);
  ]

(* The WasmGC goldens: compile each subset example with --target wasm
   and run it under Node's WasmGC, byte-for-byte against expected.txt.
   Skips when Node is absent — the runtime is the only WasmGC
   validator in the toolchain (T16.1, T16.2). *)
let wasm_goldens =
  [
    "hello_world";
    "if_expr";
    "fib";
    "objects";
    "field_types";
    "length_method";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
    "bit_ops";
    "fixed_width";
    "list";
    "array_builder";
    "base64_demo";
    "csv_demo";
    "json_demo";
    "yaml_demo";
    "xml_demo";
    "sync_demo";
    "loops";
    "error_matching";
    "float_methods";
    "math_demo";
    "branch_var";
    "plot_demo";
    "sql_demo";
    "sql_edge";
  ]

let node_available = lazy (Sys.command "node --version >/dev/null 2>&1" = 0)

(* The browser target's bundling step: Node's own type stripper, which
   landed in 22.13. The browser tests skip where it is missing, like the
   BEAM and riscv64 groups skip without their toolchains. *)
let node_strip_available =
  lazy
    (Sys.command
       "node --no-warnings -e 'process.exit(typeof \
        require(\"node:module\").stripTypeScriptTypes === \"function\" ? 0 : \
        1)' >/dev/null 2>&1"
     = 0)

(* The BEAM goldens: Core Erlang text assembled by the pinned erlc,
   run under `erl -noshell`. Skips when Erlang is absent. *)
let beam_goldens =
  [
    "hello_world";
    "if_expr";
    "fib";
    "objects";
    "field_types";
    "length_method";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
    "bit_ops";
    "fixed_width";
    "list";
    "array_builder";
    "base64_demo";
    "csv_demo";
    "json_demo";
    "yaml_demo";
    "xml_demo";
    "sync_demo";
    "printf_demo";
    "loops";
    "error_matching";
    "float_methods";
    "math_demo";
    "branch_var";
    "plot_demo";
    "sql_demo";
    "sql_edge";
  ]

let erl_available =
  lazy (Sys.command "erl -noshell -eval 'halt().' >/dev/null 2>&1" = 0)

(* The build path needs the compiler, not just the runtime: `emo build
   --target beam` assembles its Core Erlang with `erlc`, so a test that
   builds for beam has to skip where `erlc` is absent rather than fail. *)
let erlc_available = lazy (Sys.command "erlc -v >/dev/null 2>&1" = 0)

(* An example builds and runs from its own directory: that directory is
   its project root, so the entry is `main.emo` there and the manifest
   the build reads is the example's own. *)
let in_example name f = in_dir (Filename.concat examples_dir name) f

let beam_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to beam and runs on erl" name) (fun () ->
          if not (Lazy.force erl_available) then Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          (* The output asks for the module, and the file stem has to be
             the module atom, so each example builds under its own name. *)
          let out = Filename.concat scratch name in
          let exit_code =
            in_example name (fun () ->
                Emo_cli.build_file ~entry:"main.emo" ~output:out
                  ~specialize:false ~cclibs:[]
                  ~native:Emo_project.no_native_inputs ~target:"beam")
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let cmd =
            Printf.sprintf
              "erl -noshell -pa %s -eval '%s:main(), erlang:halt(0).'"
              (Filename.quote (Filename.dirname out))
              name
          in
          let out, err, proc_status = run_cmd cmd in
          Alcotest.(check string) "output" expected out;
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "erl exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   err)))
    beam_goldens

(* The host boundary: println forwards to stdout, abort exits nonzero
   with the message, float_str renders into the scratch area at
   60000 (matching the runtime's convention). *)
let wasm_runner_source =
  {|
import { readFile } from "node:fs/promises";

// OCaml's %g — the rule the interpreter's `emo_to_string` follows, and
// the same one the TS runtime's `g6` implements: six significant
// digits, exponent form below 1e-4 or at 1e6 and above, exponent
// spelled with a sign and two digits.
const g6 = (x) => {
  const exp = Math.floor(Math.log10(Math.abs(x)));
  if (exp < -4 || exp >= 6) {
    let r = Number((x / Math.pow(10, exp)).toFixed(5));
    let e = exp;
    if (Math.abs(r) >= 10) {
      r = Number((r / 10).toFixed(5));
      e += 1;
    }
    let ms = r.toFixed(5);
    if (ms.includes(".")) ms = ms.replace(/0+$/, "").replace(/\.$/, "");
    return ms + "e" + (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0");
  }
  const decimals = Math.max(0, 5 - exp);
  let s = x.toFixed(decimals);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
};
const floatStr = (f) => (Number.isInteger(f) && Math.abs(f) < 1e16 ? f.toFixed(1) : g6(f));
const bytes = await readFile(process.argv[2]);
let mem = null;
const dec = new TextDecoder();
const module = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(module, { emo: {
  println: (ptr, len) => {
    process.stdout.write(dec.decode(new Uint8Array(mem.buffer, ptr, len)) + "\n");
  },
  abort: (ptr, len) => {
    const msg = len ? dec.decode(new Uint8Array(mem.buffer, ptr, len)) : "";
    console.error("ABORT: " + msg);
    process.exit(1);
  },
  float_str: (f) => {
    const encoded = new TextEncoder().encode(floatStr(f));
    const view = new Uint8Array(mem.buffer, 60000, encoded.length);
    view.set(encoded);
    return [60000, encoded.length];
  },
}});
mem = instance.exports.mem;
instance.exports.main();
|}

let wasm_runner_path =
  lazy
    (let path =
       Filename.concat (Filename.get_temp_dir_name ()) "emo-wasm-golden.mjs"
     in
     let oc = open_out_bin path in
     output_string oc wasm_runner_source;
     close_out oc;
     path)

let wasm_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to wasm and runs on Node" name) (fun () ->
          if not (Lazy.force node_available) then Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out_wasm = Filename.concat scratch (name ^ "-wasm-main.wasm") in
          let exit_code =
            in_example name (fun () ->
                Emo_cli.build_file ~entry:"main.emo" ~output:out_wasm
                  ~specialize:false ~cclibs:[]
                  ~native:Emo_project.no_native_inputs ~target:"wasm")
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let out, err, proc_status =
            run_cmd
              (Printf.sprintf "node %s %s"
                 (Filename.quote (Lazy.force wasm_runner_path))
                 (Filename.quote out_wasm))
          in
          Alcotest.(check string) "output" expected out;
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "node exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   err)))
    wasm_goldens

(* The C goldens: build with --target c through the system cc and run
   the standalone binary, byte-for-byte against expected.txt. Skips
   when cc is absent. The list names the backend's current support
   set; it grows task by task (T23.1: hello_world, T23.3: if_expr,
   T23.5: objects, language_tour — classes, interfaces, enums, case
   with guards, closures, and array append; T23.6: shop, function_group
   — multi-file modules, the internal/ subtree, const aliases, and
   `emo` groups; T23.7: bit_ops, bytes, fixed_width — the bitwise
   operators, Bytes with little-endian accessors, and Byte with
   explicit conversions; T23.9: pipeline, showcase — processes
   (do / <- / receive) on the cooperative fiber scheduler; T23.10:
   file_read, tcp_echo, http_roundtrip — hosted file and socket IO
   with the stdlib resolving for the c target). The full fib and
   numerics examples join when foreign defs land (T23.8) — their
   c_scalar / c_integer fixtures cover the same semantics. *)
let c_goldens =
  [
    "hello_world";
    "if_expr";
    "objects";
    "field_types";
    "length_method";
    "language_tour";
    "shop";
    "function_group";
    "bit_ops";
    "bytes";
    "fixed_width";
    "map";
    "pipeline";
    "showcase";
    "file_read";
    "tcp_echo";
    "http_roundtrip";
    "https_roundtrip";
    "list";
    "array_builder";
    "os_demo";
    "base64_demo";
    "math_native";
    "csv_demo";
    "json_demo";
    "yaml_demo";
    "xml_demo";
    "sync_demo";
    "slog_demo";
    "bufio_demo";
    "printf_demo";
    "loops";
    "error_matching";
    "float_methods";
    "math_demo";
    "branch_var";
    "plot_demo";
    (* sqlite3_demo: the package's manifest `link` field and its
       package-carried C shim do the whole native link — the build here
       passes cclibs:[] on purpose *)
    "sqlite3_demo";
    "sql_demo";
    "sql_edge";
    "term_demo";
  ]

let cc_available = lazy (Sys.command "cc --version >/dev/null 2>&1" = 0)

(* sqlite3_demo additionally needs the system sqlite3 development
   library — probe once with a tiny link. *)
let sqlite3_available =
  lazy
    (Lazy.force cc_available
    && Sys.command
         "echo 'int main(void){return 0;}' | cc -x c - -lsqlite3 -o /dev/null \
          >/dev/null 2>&1"
       = 0)

(* The goldens whose reachable code genuinely reaches the TLS builtins
   (http_roundtrip's https branch; https_roundtrip's whole wire) need
   the TLS libraries linked: the CLI's gate flips on them, and the
   build runs the pre-flight probe. This probe mirrors the fix message
   the CLI prints — bare -lssl first, the Linux dev-package shape,
   then the Homebrew kegs. None means the machine has neither, and
   those goldens skip like sqlite3_demo does. *)
let tls_goldens = [ "http_roundtrip"; "https_roundtrip" ]

let tls_cclibs =
  lazy
    (let probe flags =
       Lazy.force cc_available
       && Sys.command
            (Printf.sprintf
               "echo 'int main(void){return 0;}' | cc -x c - %s -lssl -lcrypto \
                -o /dev/null >/dev/null 2>&1"
               flags)
          = 0
     in
     if probe "" then Some []
     else if probe "-L/opt/homebrew/opt/openssl@3/lib" then
       Some [ "-L/opt/homebrew/opt/openssl@3/lib" ]
     else if probe "-L/opt/homebrew/opt/openssl@4/lib" then
       Some [ "-L/opt/homebrew/opt/openssl@4/lib" ]
     else if probe "-L/usr/local/opt/openssl@3/lib" then
       Some [ "-L/usr/local/opt/openssl@3/lib" ]
     else None)

(* The root process is the program, on every target. Both programs
   below spawn work and let the root end without waiting for it; the
   work must never print. Which program a target runs depends on when
   it dispatches a process a send made runnable: the c runtime wakes
   it while the root still runs, so the child has to be busy work
   instead (and a child parked across a send would print before the
   root ends there), while wasm and typescript only dispatch from
   their driver, where a parked child woken by a send is the case that
   used to run past the root. Beam is genuinely concurrent — a spawned
   process may print before or after the root — so it asserts the
   language-level guarantee itself instead: after 'main'/0 returns,
   nothing it spawned is alive. That needs a child that never prints,
   so its child parks in receive and is never sent to. *)
let root_end_runnable =
  {|def work(n Int64) Int64 {
  for var i = 0; i < n; i = i + 1 { println(i) }
  return 0
}

do work(5)
println("root done")
|}

let root_end_woken =
  {|def child() {
  receive {
    "go" -> { println("child ran") }
  }
}

const c = do child()
c <- "go"
println("root done")
|}

let root_end_parked =
  {|def child() {
  receive {
    "go" -> { println("child ran") }
  }
}

do child()
println("root done")
|}

(* Each program gets its own directory and its own manifest: a build
   compiles every sibling .emo, and the emitters write their artifacts
   beside the entry. The manifest makes the directory the package the
   build roots itself in (E5010). *)
let scratch_entry name source =
  let dir = Filename.concat scratch name in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let entry = Filename.concat dir "main.emo" in
  write_file (Filename.concat dir "package.emo") default_manifest;
  write_file entry source;
  entry

(* Builds a scratch entry from the project directory that holds it: the
   directory is the package root, so the build has to stand there. *)
let build_entry ~target ?(specialize = false) ?(cclibs = []) entry output =
  in_dir (Filename.dirname entry) (fun () ->
      Emo_cli.build_file ~entry ~output ~specialize ~cclibs
        ~native:Emo_project.no_native_inputs ~target)

let check_run what (out, err, status) expected =
  Alcotest.(check string) (what ^ " output") expected out;
  match status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      Alcotest.fail (Printf.sprintf "%s exited %d: %s" what n err)
  | Unix.WSIGNALED n ->
      Alcotest.fail (Printf.sprintf "%s died on signal %d: %s" what n err)
  | Unix.WSTOPPED n ->
      Alcotest.fail (Printf.sprintf "%s stopped on signal %d" what n)

(* `-o` names the artifact on every target, and on beam it names the
   module too: erlc loads a .beam only when the file stem equals the
   module atom, so the two are decided together. *)
let beam_naming_tests =
  [
    tc "the beam module is named after -o" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let entry = scratch_entry "beam-naming" "println(\"hello\")\n" in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry (Filename.concat dir "app"));
        let exists name = Sys.file_exists (Filename.concat dir name) in
        Alcotest.(check bool) "app.core" true (exists "app.core");
        Alcotest.(check bool) "app.beam" true (exists "app.beam");
        Alcotest.(check bool)
          "no artifact named after the old fixed module" false
          (exists "emo_main.beam");
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'app:main(), erlang:halt(0).'"
                (Filename.quote dir)))
          "hello\n");
    tc "a module name that is not a BEAM atom is refused" (fun () ->
        let entry = scratch_entry "beam-bad-name" "println(\"hello\")\n" in
        let dir = Filename.dirname entry in
        (* The stem would be `my-app`, which erlc can never load. *)
        Alcotest.(check int)
          "build exit" 65
          (build_entry ~target:"beam" entry (Filename.concat dir "my-app"));
        Alcotest.(check bool)
          "nothing was written" false
          (Sys.file_exists (Filename.concat dir "my-app.core")));
  ]

(* A bare def is a value, and until this regression a `fun 'mod':'name'/a`
   literal named a function the module does not export, so the emitted
   module loaded with `main/0` uncallable. The fun has to be local. *)
let beam_block_tests =
  [
    tc "a bare def crosses as a Block and runs on erl" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let source =
          {|
def apply2(f Block, a Int64, b Int64) Int64 {
  return f(a, b)
}

def add(a Int64, b Int64) Int64 {
  return a + b
}

def main() {
  const r = apply2(add, 20, 22)
  println(r)
}
main()
|}
        in
        let entry = scratch_entry "beam-block" source in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry (Filename.concat dir "app"));
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'app:main(), erlang:halt(0).'"
                (Filename.quote dir)))
          "42\n");
  ]

(* A `var` set inside a `case` that sits inside a loop body has to
   thread back out of the loop: without it a `while` never sees the
   exit its branch sets, and a loop's accumulation is dropped. *)
let beam_var_tests =
  [
    tc "a var set in a case inside a loop leaves the loop" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let source =
          {|
def stops_at_three() Int64 {
  var i = 0
  var more = true
  while more {
    i = i + 1
    case i {
      3 -> { more = false }
      _ -> { }
    }
  }
  return i
}

def weighted(n Int64) Int64 {
  var acc = 0
  for var i = 0; i < n; i = i + 1 {
    case i {
      2 -> { acc = acc + 100 }
      _ -> { acc = acc + i }
    }
  }
  return acc
}

def main() {
  println(stops_at_three())
  println(weighted(4))
}
main()
|}
        in
        let entry = scratch_entry "beam-var" source in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry (Filename.concat dir "app"));
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'app:main(), erlang:halt(0).'"
                (Filename.quote dir)))
          "3\n104\n");
  ]

let root_end_tests =
  [
    tc "the c root ending drops a runnable process" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry = scratch_entry "root-end-c" root_end_runnable in
        let bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        Alcotest.(check int) "build exit" 0 (build_entry ~target:"c" entry bin);
        check_run "c" (run_cmd (Filename.quote bin)) "root done\n");
    tc "the wasm root ending drops a woken process" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let entry = scratch_entry "root-end-wasm" root_end_woken in
        let out_wasm = Filename.concat (Filename.dirname entry) "main.wasm" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"wasm" entry out_wasm);
        check_run "wasm"
          (run_cmd
             (Printf.sprintf "node %s %s"
                (Filename.quote (Lazy.force wasm_runner_path))
                (Filename.quote out_wasm)))
          "root done\n");
    tc "the typescript root ending drops a woken process" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let entry = scratch_entry "root-end-ts" root_end_woken in
        let out_ts = Filename.concat (Filename.dirname entry) "main" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"typescript" entry out_ts);
        check_run "typescript"
          (run_cmd ("node " ^ Filename.quote (out_ts ^ ".ts")))
          "root done\n");
    tc "the beam root ending leaves nothing it spawned alive" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let entry = scratch_entry "root-end-beam" root_end_parked in
        let out_core =
          Filename.concat (Filename.dirname entry) "emo_main.core"
        in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry out_core);
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'emo_main:main(), L = \
                 ets:tab2list(emo_procs), io:format(\"~p~n\", \
                 [[erlang:is_process_alive(element(1, X)) || X <- L]]), \
                 erlang:halt(0).'"
                (Filename.quote (Filename.dirname out_core))))
          "root done\n[false]\n");
  ]

(* A bare def named as a value is a `ref.func`, and the validator
   requires every `ref.func` target to appear in the declarative element
   segment. Only the hidden closures were declared, so a program def
   handed over as a `Block` — the shape `ui.run` takes, here across a
   module boundary — failed to compile. *)
let wasm_block_tests =
  [
    tc "a bare def crosses as a Block and runs on Node" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let source =
          {|
def apply2(f Block, a Int64, b Int64) Int64 {
  return f(a, b)
}

def main() {
  const r = apply2(lib.add, 20, 22)
  println(r)
}
main()
|}
        in
        let entry = scratch_entry "wasm-block" source in
        let dir = Filename.dirname entry in
        write_file
          (Filename.concat dir "lib.emo")
          "def add(a Int64, b Int64) Int64 {\n  return a + b\n}\n";
        let out_wasm = Filename.concat dir "main.wasm" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"wasm" entry out_wasm);
        check_run "wasm"
          (run_cmd
             (Printf.sprintf "node %s %s"
                (Filename.quote (Lazy.force wasm_runner_path))
                (Filename.quote out_wasm)))
          "42\n");
  ]

(* T23.2's integer core: fib's plain recursion, the 1M-deep tail
   count_down, a mutual-tail ping/pong cluster, wrap-around Int64
   (INT64_MIN formatting, division and remainder by -1, overflow on
   plus and times), and var assignment under if/else — all run under
   a 1MB C stack, so a missing trampoline would segfault rather than
   pass. *)
let c_integer_core_source =
  {|def fib(n Int64) Int64 {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

def count_down(n Int64) Int64 {
  if n == 0 {
    return 0
  }
  return count_down(n - 1)
}

def ping(n Int64) Int64 {
  if n == 0 {
    return 0
  }
  return pong(n - 1)
}

def pong(n Int64) Int64 {
  if n == 0 {
    return 1
  }
  return ping(n - 1)
}

def min_i64() Int64 {
  return (0 - 9223372036854775807) - 1
}

def sums(n Int64) Int64 {
  var total = 0
  total = n + 1
  if total > 10 {
    return total - 1
  }
  return total
}

println(fib(20))
println(count_down(1000000))
println(ping(1000001))
println(min_i64())
println(min_i64() / (0 - 1))
println(min_i64() % (0 - 1))
println(9223372036854775807 + 1)
println(4611686018427387904 * 2)
println(sums(20))
println(sums(5))
|}

let c_integer_core_expected =
  "6765\n\
   0\n\
   1\n\
   -9223372036854775808\n\
   -9223372036854775808\n\
   0\n\
   -9223372036854775808\n\
   -9223372036854775808\n\
   20\n\
   6\n"

let c_integer_tests =
  [
    tc "the c integer core: fib, flat 1M tails, wrap-around Int64" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry = scratch_entry "c-int-core" c_integer_core_source in
        let out_bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd =
          Printf.sprintf "sh -c 'ulimit -s 1024; exec %s'"
            (Filename.quote out_bin)
        in
        let out, err, proc_status = run_cmd cmd in
        Alcotest.(check string) "output" c_integer_core_expected out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 err));
  ]

(* T23.3's scalar runtime: Float64 rendering across the %g boundary
   (integral magnitudes below 1e16 keep one decimal, 1e-4 and 1e+06
   flip to exponent form), Bool/Char printing, string concatenation
   and content equality, interpolation, and to_string. The expected
   output is the interpreter's own rendering of the same program —
   the printing rules are cross-checked, not hand-copied. *)
let c_scalar_core_source =
  {|def half(x Float64) Float64 {
  return x / 2.0
}

def label(ok Bool) String {
  if ok {
    return "yes"
  }
  return "no"
}

println(2.0)
println(1000000.0)
println(999999.5)
println(0.0001)
println(0.00001)
println(1000000000000000.0)
println(10000000000000000.0)
println(0.1 + 0.2)
println(1.0 / 3.0)
println(-2.5)
println(half(7.0))
println(-0.5)
println(3.14159265358979)
println(true)
println(false)
println(label(true))
println(label(false))
println('a')
println('~')
println(1 == 1)
println('a' == 'a')
println('a' == 'b')
println("foo" == "foo")
println("foo" == "bar")
println("foo" != "bar")
const s = "ab" + "cd"
println(s)
println("n=${42}")
println("f=${2.0} b=${true} c=${'x'} s=${"in"}")
println("".to_string())
|}

let c_scalar_tests =
  [
    tc "the c scalar runtime matches the interpreter's rendering" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let expected =
          let out = Buffer.create 512 in
          Emo_eval.set_output (Buffer.add_string out);
          Fun.protect
            ~finally:(fun () ->
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout))
            (fun () ->
              Emo_eval.run_program ~file:"c-scalar/main.emo"
                ~source:c_scalar_core_source);
          Buffer.contents out
        in
        let entry = scratch_entry "c-scalar" c_scalar_core_source in
        let out_bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        Unix.putenv "EMO_FFI_PROBE" "hello ffi";
        let out, err, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" expected out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 err));
  ]

(* T23.4's dynamic value model: the tagged word crossing native and
   dynamic code — a heterogeneous array (elements Unknown), tuples,
   Box identity and replacement, structural equality, dynamic
   arithmetic and to_string over runtime kinds, and indexing with
   regime conversions at every boundary. The expected output is the
   interpreter's own rendering of the same program. *)
let c_dynamic_core_source =
  {|
def first(xs Array[Int64]) Int64 {
  return xs[0]
}

def len_of(xs Array[Int64]) Int64 {
  return xs.length()
}

def picksecond(xs Array[Int64], use_first Bool) Int64 {
  if use_first {
    return xs[0]
  }
  return xs[1]
}

const vals = [1, "a", 2.5, true]
const arr = [10, 20, 30]
const b = Box.new(41)
const t = (1, "a")
const t2 = ("x", 3)
const nested = (t, t2)

println(vals[0])
println(vals[1])
println(vals[2])
println(vals[3])
println(vals[0] + 5)
println(vals[2] + 1.0)
println(first(arr))
println(len_of(arr))
println(picksecond(arr, true))
println(picksecond(arr, false))
b.replace(b.read() + 1)
println(b.read())
println(b)
println(vals[1].to_string())
println(vals.to_string())
println(t[1])
println(t.length())
println(nested[0][1])
println(nested[1][0])
println(t == (1, "a"))
println(t == ("x", 3))
println(arr == [10, 20, 30])
println(arr == [10, 20, 31])
println(vals == [1, "a", 2.5, true])
println(Box.new(5) == Box.new(5))
println(b == Box.new(41))
var total = 0
total = arr[1] + arr[2]
println(total)
const dyn_sum = vals[0] + 5
println(dyn_sum)
println("n=" + vals[0].to_string())
|}

(* The two cross-target invariants the interpreter already keeps and the
   `c` target used to break (M17): an uncaught raise in a spawned process
   ends only that process, and a message reaches the receiver as a
   snapshot. The programs are the scheduler suite's own fixtures, run
   here through the `c` target. *)
let c_child_raise_source =
  {|
def bomber() Int64 {
  receive {
    _ -> { raise Exception.new(message: "boom") }
  }
}

const b = do bomber()
b <- "light the fuse"
println("still here")
|}

let c_send_snapshot_source =
  {|
def reader(reply_to Pid) Int64 {
  receive {
    b -> {
      reply_to <- b.read()
      return halt()
    }
  }
}

const box = Box.new(1)
const r = do reader(self_pid())
r <- box
box.replace(99)
receive {
  v -> { println(v) }
}
println(box.read())
|}

let c_dynamic_tests =
  [
    tc "an uncaught raise exits 1 with the interpreter's message" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry =
          scratch_entry "c-raise"
            {|raise Exception.new(message: "boom")
println("not reached")
|}
        in
        let out_bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let _, err, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check bool)
          "message" true
          (contains err "uncaught exception: boom");
        match proc_status with
        | Unix.WEXITED 1 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "the binary exited %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)));
    tc "the c dynamic world matches the interpreter" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let expected =
          let out = Buffer.create 512 in
          Emo_eval.set_output (Buffer.add_string out);
          Fun.protect
            ~finally:(fun () ->
              Emo_eval.set_output (fun s ->
                  print_string s;
                  flush stdout))
            (fun () ->
              Emo_eval.run_program ~file:"c-dynamic/main.emo"
                ~source:c_dynamic_core_source);
          Buffer.contents out
        in
        let entry = scratch_entry "c-dynamic" c_dynamic_core_source in
        let out_bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, err, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" expected out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 err));
    tc "a spawned process that raises dies alone; the parent continues"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry = scratch_entry "c-child-raise" c_child_raise_source in
        let bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        Alcotest.(check int) "build exit" 0 (build_entry ~target:"c" entry bin);
        check_run "c" (run_cmd (Filename.quote bin)) "still here\n");
    tc "a sent Box reaches the receiver as a snapshot" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry = scratch_entry "c-send-snapshot" c_send_snapshot_source in
        let bin = Filename.concat (Filename.dirname entry) "main-c-bin" in
        Alcotest.(check int) "build exit" 0 (build_entry ~target:"c" entry bin);
        check_run "c" (run_cmd (Filename.quote bin)) "1\n99\n");
  ]

let c_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to c and runs standalone" name) (fun () ->
          if not (Lazy.force cc_available) then Alcotest.skip ();
          if name = "sqlite3_demo" && not (Lazy.force sqlite3_available) then
            Alcotest.skip ();
          let tls_needed = List.mem name tls_goldens in
          if tls_needed && not (Option.is_some (Lazy.force tls_cclibs)) then
            Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out_bin = Filename.concat scratch (name ^ "-c-bin") in
          let cclibs =
            if tls_needed then Option.value (Lazy.force tls_cclibs) ~default:[]
            else []
          in
          let exit_code =
            in_example name (fun () ->
                Emo_cli.build_file ~entry:"main.emo" ~output:out_bin
                  ~specialize:false ~cclibs ~native:Emo_project.no_native_inputs
                  ~target:"c")
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          (* A TLS golden runs from its own directory: the program
             opens its checked-in fixtures by their relative names and
             the client verifies against the CA through
             SSL_CERT_FILE. *)
          let run_it =
            if tls_needed then
              Printf.sprintf "cd %s && env SSL_CERT_FILE=fixtures/tls-ca.pem %s"
                (Filename.quote dir) (Filename.quote out_bin)
            else Filename.quote out_bin
          in
          let out, err, proc_status = run_cmd run_it in
          Alcotest.(check string) "output" expected out;
          (* The TLS gate pin (step 51): a program that never touches
             TLS links with no SSL_ symbol undefined, so the
             conditional linkage cannot silently rot into
             always-linked. A TLS golden links the libraries by
             design, so the pin is theirs to skip. *)
          if not tls_needed then begin
            let nm_out, _, _ =
              run_cmd (Printf.sprintf "nm -u %s" (Filename.quote out_bin))
            in
            Alcotest.(check bool)
              "no SSL_ symbol undefined" false (contains nm_out "SSL_")
          end;
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "the binary exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   err)))
    c_goldens

(* T51.4: the c runtime's own TLS server and client in one binary —
   the loopback handshake parks both ends through one scheduler. The
   fixtures ride the sched suite's checked-in CA; the build skips
   where the machine has no TLS libraries, like the TLS goldens. *)
let c_tls_tests =
  [
    tc "a TLS loopback runs inside one c binary" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let cclibs =
          match Lazy.force tls_cclibs with
          | Some libs -> libs
          | None -> Alcotest.skip ()
        in
        let dir = Filename.concat scratch "c-tls-loopback" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file
          (Filename.concat dir "package.emo")
          {|
package {
  name = "emo/scratch_c_tls"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    "net" = "0.1.0"
  }
}
|};
        let fixture = "../../test/emo_sched/fixtures/" in
        let entry = Filename.concat dir "main.emo" in
        write_file entry
          (Printf.sprintf
             {|require "net"

def echo_lines(conn TcpConn) Void {
  case conn.read_line() {
    (R.error, why) -> {
      println("server read failed: ${why}")
      conn.close()
    }
    (R.ok, line)   -> {
      conn.write("echo: " + line + "\n")
      echo_lines(conn)
    }
  }
}

def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> { echo_lines(conn) }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "%stls-server-cert.pem", "%stls-server-key.pem")
do serve(listener)
case net_tls_connect("localhost", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("loopback\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
             fixture fixture);
        let bin = Filename.concat dir "main-c-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"c" ~cclibs entry bin);
        let ca = fixture ^ "tls-ca.pem" in
        check_run "c loopback"
          (run_cmd
             (Printf.sprintf "env SSL_CERT_FILE=%s %s" (Filename.quote ca)
                (Filename.quote bin)))
          "echo: loopback\ndone\n");
    tc "the verify-fail pin and the insecure roundtrip hold on c" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let cclibs =
          match Lazy.force tls_cclibs with
          | Some libs -> libs
          | None -> Alcotest.skip ()
        in
        let dir = Filename.concat scratch "c-tls-pins" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file
          (Filename.concat dir "package.emo")
          {|
package {
  name = "emo/scratch_c_tls_pins"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    "net" = "0.1.0"
  }
}
|};
        let fixture = "../../test/emo_sched/fixtures/" in
        let entry = Filename.concat dir "main.emo" in
        (* One program, both pins: the verified connect to the
           self-signed listener fails closed (the interp suite's pin),
           and the insecure variant to the same listener round-trips. *)
        write_file entry
          (Printf.sprintf
             {|require "net"

def echo_lines(conn TcpConn) Void {
  case conn.read_line() {
    (R.error, why) -> {
      println("server read failed: ${why}")
      conn.close()
    }
    (R.ok, line)   -> {
      conn.write("echo: " + line + "\n")
      echo_lines(conn)
    }
  }
}

def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, _)  -> { serve(listener) }
    (R.ok, conn)  -> { echo_lines(conn) }
  }
}

const (R.ok, ca_listener) = net_listen_tls("127.0.0.1", 0, "%stls-server-cert.pem", "%stls-server-key.pem")
const (R.ok, self_listener) = net_listen_tls("127.0.0.1", 0, "%stls-cert.pem", "%stls-key.pem")
do serve(ca_listener)
do serve(self_listener)
case net_tls_connect("127.0.0.1", self_listener.port(), 5.0) {
  (R.error, why) -> { println("verify failed as expected") }
  (R.ok, conn)   -> { println("handshook?!") }
}
case net_tls_connect_insecure("127.0.0.1", self_listener.port(), 5.0) {
  (R.error, why) -> { println("insecure failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("insecure\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
  }
}
|}
             fixture fixture fixture fixture);
        let bin = Filename.concat dir "main-c-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"c" ~cclibs entry bin);
        let ca = fixture ^ "tls-ca.pem" in
        check_run "c tls pins"
          (run_cmd
             (Printf.sprintf "env SSL_CERT_FILE=%s %s" (Filename.quote ca)
                (Filename.quote bin)))
          "verify failed as expected\necho: insecure\n");
    tc "the per-connection TLS policy holds on c" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let cclibs =
          match Lazy.force tls_cclibs with
          | Some libs -> libs
          | None -> Alcotest.skip ()
        in
        let dir = Filename.concat scratch "c-tls-policy" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file
          (Filename.concat dir "package.emo")
          {|
package {
  name = "emo/scratch_c_tls_policy"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    "net" = "0.1.0"
  }
}
|};
        (* Mutual TLS, a private CA, and server_name pinning through the
           option objects: the client trusts the fixture CA, presents
           fixtures/tls-cert.pem as its own certificate, and verifies
           the certificate's DNS name while connecting to the IP. The
           server trusts that self-signed certificate as its client CA
           and requires one. *)
        let fixture = "../../test/emo_sched/fixtures/" in
        let entry = Filename.concat dir "main.emo" in
        write_file entry
          (Printf.sprintf
             {|require "net"

def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("policy: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const server_options = net.tls_server_options().with_client_ca("%stls-cert.pem").with_required_client_cert(true)
const (R.ok, listener) = net.listen_tls_with("127.0.0.1", 0, "%stls-server-cert.pem", "%stls-server-key.pem", server_options)
do serve(listener)
const client_options = net.tls_client_options().with_ca_file("%stls-ca.pem").with_client_certificate("%stls-cert.pem", "%stls-key.pem").with_server_name("localhost")
case net.tls_connect_with("127.0.0.1", listener.port(), 5.0, client_options) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
             fixture fixture fixture fixture fixture fixture);
        let bin = Filename.concat dir "main-c-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"c" ~cclibs entry bin);
        check_run "c tls policy"
          (run_cmd (Filename.quote bin))
          "policy: hello\ndone\n");
  ]

(* T23.8: the c target's direct C ABI. A foreign def declares the C
   symbol and calls it — no wrapper generator. Strings cross with a
   NUL terminator; opaque handles ride pointer-sized Int64s behind a
   tiny library compiled into the scratch dir. Skips without cc. *)
let c_foreign_tests =
  [
    tc "the c target links foreign defs through the direct C ABI" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-ffi" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        (* A stale defs header would survive a broken build, so the
           assertion below starts from nothing. The build stands in
           [dir], so that is where its .emo-build lands. *)
        let defs_h = Filename.concat dir ".emo-build/emo_defs.h" in
        (try Sys.remove defs_h with Sys_error _ -> ());
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
foreign def sqrt(x Float64) Float64 = "sqrt"
foreign def llabs(x Int64) Int64 = "llabs"
foreign def getenv(name String) String = "getenv"
foreign def strspn(s String, accept String) Int64 = "strspn"
foreign def srand(seed Int64) Void = "srand"

def triple(x Int64) Int64 {
  return x * 3
}

println(sqrt(4.0))
println(llabs(0 - 42))
const probed = getenv("EMO_FFI_PROBE")
println(probed)
println(strspn(probed, "hello"))
srand(42)
println(triple(14))
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code = build_entry ~target:"c" ~cclibs:[ "m" ] entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        (* The defs header declares the program's def and the foreign
           symbols — the contract an FFI shim compiles against. *)
        let lines =
          let ic = open_in_bin defs_h in
          let rec go acc =
            match input_line ic with
            | line -> go (line :: acc)
            | exception End_of_file ->
                close_in ic;
                List.rev acc
          in
          go []
        in
        (* `main.emo` in the package root is the module `main`, so the
           def it declares is spelled `main__triple` in the header. *)
        Alcotest.(check bool)
          "defs header has the def"
          (List.exists (String.equal "int64_t main__triple(int64_t x);") lines)
          true;
        Alcotest.(check bool)
          "defs header has the void foreign"
          (List.exists (String.equal "extern void srand(int64_t);") lines)
          true;
        let out, _, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" "2.0\n42\nhello ffi\n5\n42\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %d"
                 (match s with Unix.WEXITED n -> n | _ -> -1)));
    tc "the c target passes an opaque handle across the C ABI" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-ffi-handle" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        let c_src = Filename.concat dir "emo_handle.c" in
        let oc = open_out_bin c_src in
        output_string oc
          {|
/* A tiny C library for the opaque-handle FFI fixture: an externally
   owned counter behind a pointer, explicitly closed. */
#include <stdlib.h>
typedef struct { long long v; } emo_counter;
emo_counter *counter_new(long long start) {
  emo_counter *c = malloc(sizeof(emo_counter));
  if (c == NULL) return 0;
  c->v = start;
  return c;
}
long long counter_bump(emo_counter *c, long long by) {
  if (c == 0) return -1;
  c->v += by;
  return c->v;
}
long long counter_close(emo_counter *c) {
  if (c == 0) return -1;
  long long last = c->v;
  free(c);
  return last;
}
|};
        close_out oc;
        let lib_a = Filename.concat dir "libemo_handle.a" in
        let obj = Filename.concat dir "emo_handle.o" in
        let cc =
          Printf.sprintf "cc -O2 -std=c11 -Wall -c %s -o %s && ar rcs %s %s"
            (Filename.quote c_src) (Filename.quote obj) (Filename.quote lib_a)
            (Filename.quote obj)
        in
        if Sys.command cc <> 0 then
          Alcotest.fail "the handle library did not compile";
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
foreign def counter_new(start Int64) Int64 = "counter_new"
foreign def counter_bump(c Int64, by Int64) Int64 = "counter_bump"
foreign def counter_close(c Int64) Int64 = "counter_close"

const c = counter_new(40)
println(counter_bump(c, 2))
println(counter_close(c))
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          build_entry ~target:"c" ~cclibs:[ lib_a ] entry out_bin
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, _, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" "42\n42\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %d"
                 (match s with Unix.WEXITED n -> n | _ -> -1)));
    tc "the native target still refuses Int64 foreign defs" (fun () ->
        let entry =
          scratch_entry "c-ffi-refuse"
            {|foreign def ident(x Int64) Int64 = "ident"
println(ident(1))
|}
        in
        let out_bin = Filename.concat (Filename.dirname entry) "native-bin" in
        let exit_code = build_entry ~target:"ocaml" entry out_bin in
        Alcotest.(check int) "refused" 65 exit_code);
  ]

(* The callback contract (CHECK.md, 2026-10-11): a foreign parameter
   whose type names a single-method interface crosses as the pair
   (trampoline, userdata). The C side stores both and invokes the
   callback later — two different objects prove the userdata carries
   the right receiver per call. Skips without cc. *)
let c_callback_tests =
  [
    tc "the c target dispatches an interface callback through userdata"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-callback" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        let c_src = Filename.concat dir "emo_greet.c" in
        let oc = open_out_bin c_src in
        output_string oc
          {|
/* The C side of the callback fixture: it stores the pair the Emo call
   passed and invokes the callback per round — the shape every
   C callback API (the user_data idiom) expects of a host. */
#include <stdio.h>
#include <stdint.h>
void emo_test_run_greet(const char *(*cb)(const char *name, int64_t n, void *userdata),
                        void *userdata, int64_t times) {
  for (int64_t i = 0; i < times; i = i + 1) {
    const char *s = cb("world", i, userdata);
    printf("greet: %s\n", s);
  }
}
|};
        close_out oc;
        let obj = Filename.concat dir "emo_greet.o" in
        let cc =
          Printf.sprintf "cc -O2 -std=c11 -Wall -c %s -o %s"
            (Filename.quote c_src) (Filename.quote obj)
        in
        if Sys.command cc <> 0 then
          Alcotest.fail "the callback shim did not compile";
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
interface Greeter {
  def greet(name String, n Int64) String
}

class Loud {
  def greet(name String, n Int64) String {
    return "LOUD " + name + " x" + n.to_string()
  }
}

class Polite {
  def greet(name String, n Int64) String {
    return "hi " + name
  }
}

foreign def run_greet(g Greeter, times Int64) Void = "emo_test_run_greet"

run_greet(Loud.new(), 2)
run_greet(Polite.new(), 1)
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code = build_entry ~target:"c" ~cclibs:[ obj ] entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, err, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string)
          "output"
          "greet: LOUD world x0\ngreet: LOUD world x1\ngreet: hi world\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | _ -> "signal")
                 err));
  ]

(* The struct shapes (CHECK.md, 2026-10-11): a tuple or a carrier class
   crosses the C ABI as a struct by value, and a struct result returns
   as a tuple — the typedefs land in emo_defs.h, so the shim compiles
   against the real layouts, and cc owns the ABI classification. The
   fixture exercises all three directions: a tuple by value, a class
   in and a struct out, and a nested-tuple shape. Skips without cc. *)

(* The reclamation gate (CHECK.md, the T23.5 discipline): the runtime
   exposes its live-identity counter, and a loop that drops every
   object it makes must return the count to where it started —
   reclamation observed, not assumed. A second phase keeps one object
   reachable through a List and asserts it stays live. Skips without
   cc. *)
let c_recycle_tests =
  [
    tc "the c target reclaims dropped instances and keeps reachable ones"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-recycle" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
foreign def live() Int64 = "emo_identity_live_count"

class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }
}

def churn(n Int64, acc Int64) Int64 {
  if n == 0 {
    return acc
  }
  const p = Point.new(x: n, y: n)
  return churn(n - 1, acc + p.x)
}

const keep = [Point.new(x: 7, y: 8)]

const base = live()
churn(10000, 0)
println(live() - base)
println(keep.length())
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, _, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" "0\n1\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | _ -> "signal")));
  ]

(* The flat-working-set gate (T49.4; the arena-scope spike's render
   ladder, checked in). A render-shaped loop — view() rebuilds the
   tree per event, style maps, append-built children, a layout walk —
   must leave the process where it found it: every dropped frame
   reclaims its bytes and its cells. Before step 49 both deltas rose
   per render (~1 MB and ~820 identities at 400 nodes); the gate pins
   them at exactly zero, two rungs, and so fails on any regression.
   Skips without cc. *)
let c_flat_working_set_tests =
  [
    tc "the render loop holds a flat working set" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-flat-set" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
foreign def live() Int64 = "emo_identity_live_count"
foreign def arena() Int64 = "emo_arena_bytes"

interface VNode {
  def kind() String
  def text() String
  def style() Map[String, Float64]
}

class VLeaf {
  def init(kind String, text String, style Map[String, Float64]) {
    self.kind = kind
    self.text = text
    self.style = style
  }

  def kind() String {
    return self.kind
  }

  def text() String {
    return self.text
  }

  def style() Map[String, Float64] {
    return self.style
  }
}

class VColumn {
  def init(style Map[String, Float64], children Array[VNode]) {
    self.style = style
    self.children = children
  }

  def kind() String {
    return "column"
  }

  def text() String {
    return ""
  }

  def style() Map[String, Float64] {
    return self.style
  }

  def children() Array[VNode] {
    return self.children
  }
}

def label(text String) VNode {
  return VLeaf.new(kind: "label", text: text,
    style: Map.new(("height", 24.0)))
}

def column(children Array[VNode]) VNode {
  return VColumn.new(style: Map.new(("gap", 4.0), ("padding", 8.0)),
    children: children)
}

def leaves(into Array[VNode], i Int64, per Int64) Array[VNode] {
  if i == per {
    return into
  }
  return leaves(into.append(label("row ${i}")), i + 1, per)
}

def panels(into Array[VNode], i Int64, count Int64, per Int64) Array[VNode] {
  if i == count {
    return into
  }
  return panels(into.append(column(leaves([], 0, per))), i + 1, count, per)
}

def view(nodes Int64) VNode {
  return column(panels([], 0, nodes / 20, 20))
}

class Draw {
  def init(kind String, text String, y Float64) {
    self.kind = kind
    self.text = text
    self.y = y
  }
}

class Laid {
  def init(cmds Array[Draw], cursor Float64) {
    self.cmds = cmds
    self.cursor = cursor
  }
}

def style_num(style Map[String, Float64], key String, fallback Float64) Float64 {
  if style.has(key) {
    return style.get(key)
  }
  return fallback
}

def layout_step(kids Array[VNode], i Int64, cmds Array[Draw],
                cursor Float64, gap Float64) Laid {
  if i == kids.length() {
    return Laid.new(cmds: cmds, cursor: cursor)
  }
  const r = layout_node(kids[i], cmds, cursor, gap)
  return layout_step(kids, i + 1, r.cmds, r.cursor + gap, gap)
}

def layout_node(node VNode, cmds Array[Draw], y Float64, gap Float64) Laid {
  const style = node.style()
  const pad = style_num(style, "padding", 0.0)
  if node.is(VColumn) {
    const kids = node.children()
    return layout_step(kids, 0, cmds, y + pad, style_num(style, "gap", gap))
  }
  const h = style_num(style, "height", 24.0)
  return Laid.new(
    cmds: cmds.append(Draw.new(kind: node.kind(), text: node.text(), y: y)),
    cursor: y + h)
}

def paint(root VNode, width Float64) Float64 {
  const r = layout_node(root, [], 0.0, 12.0)
  return r.cursor + width * 0.0
}

def on_event(nodes Int64, tag Int64, count Int64) Int64 {
  const cursor = paint(view(nodes), 480.0)
  if cursor < 0.0 {
    return count - 1
  }
  return count + 1
}

// One rung of the ladder: sample, render, print the two deltas. Both
// are zero — the dropped frame reclaims every byte and every cell.
def rung(nodes Int64, renders Int64) Int64 {
  const b0 = arena()
  const l0 = live()
  var count = 0
  for var i = 0; i < renders; i = i + 1 {
    count = on_event(nodes, 1, count)
  }
  println(arena() - b0)
  println(live() - l0)
  return count
}

const c1 = rung(40, 40)
const c2 = rung(80, 40)
if c1 == c2 {
  println("model stable")
}
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code = build_entry ~target:"c" entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, _, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" "0\n0\n0\n0\nmodel stable\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | _ -> "signal")));
  ]

let c_shape_tests =
  [
    tc "the c target marshals struct shapes by value both ways" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-shape" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        write_file (Filename.concat dir "package.emo") default_manifest;
        let c_src = Filename.concat dir "emo_shape.c" in
        let oc = open_out_bin c_src in
        output_string oc
          {|
/* The C side of the shape fixture: the struct definitions mirror what
   emo_defs.h declares (a real shim includes the header instead). */
#include <math.h>
#include <stdint.h>
typedef struct { double __f0, __f1; } emo_shape1;
typedef struct { double x, y; } emo_shape2;
typedef struct { emo_shape2 __f0; double __f1; } emo_shape3;
double emo_test_dist(emo_shape1 p) {
  return sqrt((p.__f0 * p.__f0) + (p.__f1 * p.__f1));
}
typedef struct { double lo, hi; } emo_test_range;
emo_test_range emo_test_summarize(emo_shape2 p) {
  emo_test_range r = { p.x < p.y ? p.x : p.y, p.x < p.y ? p.y : p.x };
  return r;
}
emo_shape2 emo_test_stretch(emo_shape3 s) {
  emo_shape2 r = { s.__f0.x * s.__f1, s.__f0.y * s.__f1 };
  return r;
}
|};
        close_out oc;
        let obj = Filename.concat dir "emo_shape.o" in
        let cc =
          Printf.sprintf "cc -O2 -std=c11 -Wall -c %s -o %s"
            (Filename.quote c_src) (Filename.quote obj)
        in
        if Sys.command cc <> 0 then
          Alcotest.fail "the shape shim did not compile";
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
class Point {
  def init(x Float64, y Float64) {
    self.x = x
    self.y = y
  }
}

foreign def dist(p (Float64, Float64)) Float64 = "emo_test_dist"
foreign def summarize(p Point) (Float64, Float64) = "emo_test_summarize"
foreign def stretch(r ((Float64, Float64), Float64)) (Float64, Float64) = "emo_test_stretch"

println(dist((3.0, 4.0)))
println(summarize(Point.new(x: 1.5, y: 2.5)))
println(stretch(((1.0, 2.0), 3.0)))
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code = build_entry ~target:"c" ~cclibs:[ obj ] entry out_bin in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, err, proc_status = run_cmd (Filename.quote out_bin) in
        Alcotest.(check string) "output" "5.0\n(1.5, 2.5)\n(3.0, 6.0)\n" out;
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | _ -> "signal")
                 err));
  ]

(* ---- publish: the upload is dogfooded through the stdlib http client ----

   A captive HTTP server on loopback (a raw socket in a helper thread)
   records exactly what the embedded uploader sends and answers with a
   canned response. *)

let find_sub hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then None
    else if String.equal (String.sub hay i n) needle then Some i
    else go (i + 1)
  in
  go 0

(* Reads one HTTP/1.1 request: the head up to the blank line, then the
   Content-Length body — the client's exact bytes, captured raw. *)
let read_request conn =
  let buf = Buffer.create 512 in
  let chunk = Bytes.create 4096 in
  let complete text =
    match find_sub text "\r\n\r\n" with
    | None -> false
    | Some header_end -> (
        match find_sub text "Content-Length: " with
        | None -> true
        | Some rel_start -> (
            let start = rel_start + String.length "Content-Length: " in
            let rest = String.sub text start (String.length text - start) in
            match find_sub rest "\r\n" with
            | None -> false
            | Some rel ->
                let len = int_of_string (String.sub rest 0 rel) in
                String.length text >= header_end + 4 + len))
  in
  let rec loop () =
    let text = Buffer.contents buf in
    if complete text then text
    else
      match Unix.select [ conn ] [] [] 10.0 with
      | [], _, _ -> failwith "captive server: timed out reading the request"
      | _ -> (
          match Unix.read conn chunk 0 (Bytes.length chunk) with
          | 0 -> text
          | n ->
              Buffer.add_subbytes buf chunk 0 n;
              loop ())
  in
  loop ()

(* Runs [f port] against a one-shot server that captures the request and
   replies with [status]/[body]; returns the raw captured request. *)
let with_captive_server ~status ~body f =
  let srv = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt srv Unix.SO_REUSEADDR true;
  Unix.bind srv (Unix.ADDR_INET (Unix.inet_addr_of_string "127.0.0.1", 0));
  Unix.listen srv 1;
  let port =
    match Unix.getsockname srv with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  let captured = ref "" in
  let serve () =
    (* A select in a multithreaded process can transiently fail on
       Linux (EAGAIN and friends); retry a bounded number of times
       rather than kill the server thread. *)
    let rec await tries =
      match Unix.select [ srv ] [] [] 10.0 with
      | [], _, _ -> () (* the client never connected; the test failed earlier *)
      | exception Unix.Unix_error _ when tries > 0 -> await (tries - 1)
      | _ ->
          let conn, _ = Unix.accept srv in
          captured := read_request conn;
          let head =
            Printf.sprintf "HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n" status
              (String.length body)
          in
          let bytes = Bytes.of_string (head ^ body) in
          ignore (Unix.write conn bytes 0 (Bytes.length bytes));
          Unix.close conn
    in
    await 5
  in
  let th = Thread.create serve () in
  Fun.protect
    ~finally:(fun () ->
      Thread.join th;
      Unix.close srv)
    (fun () -> f port);
  !captured

let publish_tests =
  [
    tc "the upload posts the raw archive through the stdlib http client"
      (fun () ->
        let archive = "\x1f\x8b\x08\x00emo \x00\xff binary" in
        let body = {|{"version":"0.1.0"}|} in
        let captured =
          with_captive_server ~status:201 ~body (fun port ->
              match
                Emo_cli.upload
                  ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                  ~token:"emo_test_token" ~archive
              with
              | Error m -> Alcotest.fail m
              | Ok (status, response_body) ->
                  Alcotest.(check int) "status" 201 status;
                  Alcotest.(check string) "body" body response_body)
        in
        Alcotest.(check bool)
          "posts to the publish endpoint" true
          (contains captured "POST /api/v1/packages HTTP/1.1\r\n");
        Alcotest.(check bool)
          "bearer token" true
          (contains captured "Authorization: Bearer emo_test_token");
        Alcotest.(check bool)
          "octet stream" true
          (contains captured "Content-Type: application/octet-stream");
        (* the gzip body arrives byte-for-byte, NULs and all *)
        match find_sub captured "\r\n\r\n" with
        | None -> Alcotest.fail "no header terminator"
        | Some i ->
            Alcotest.(check string)
              "binary body intact" archive
              (String.sub captured (i + 4) (String.length captured - i - 4)));
    tc "a refused connection is an upload error" (fun () ->
        match
          Emo_cli.upload ~registry:"http://127.0.0.1:1" ~token:"emo_test_token"
            ~archive:"x"
        with
        | Ok _ -> Alcotest.fail "expected a transport error"
        | Error m ->
            Alcotest.(check bool)
              "the failure is named" true
              (String.length m > 0));
    tc "an error response keeps its status and body" (fun () ->
        let body =
          {|{"error":{"code":"version_exists","message":"acme/hello 0.1.0 already published"}}|}
        in
        ignore
          (with_captive_server ~status:409 ~body (fun port ->
               match
                 Emo_cli.upload
                   ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                   ~token:"emo_test_token" ~archive:"x"
               with
               | Error m -> Alcotest.fail m
               | Ok (status, response_body) ->
                   Alcotest.(check int) "status" 409 status;
                   Alcotest.(check string) "body" body response_body;
                   Alcotest.(check (option string))
                     "error code" (Some "version_exists")
                     (Emo_cli.json_string_field "code" response_body))));
    tc "publish reads the endpoint from the manifest's registry field"
      (fun () ->
        let dir = Filename.concat scratch "publish-manifest-registry" in
        let old_registry = Sys.getenv_opt "EMO_REGISTRY" in
        let old_token = Sys.getenv_opt "EMO_TOKEN" in
        let set var = function
          | Some v -> Unix.putenv var v
          | None -> Unix.putenv var ""
        in
        set "EMO_REGISTRY" None;
        set "EMO_TOKEN" (Some "emo_manifest_token");
        let captured =
          with_captive_server ~status:201 ~body:"{}" (fun port ->
              write_file
                (Filename.concat dir "package.emo")
                (Printf.sprintf
                   {|package {
  name = "acme/probe"
  version = "0.1.0"
  targets = ["ocaml"]
  registry = "http://127.0.0.1:%d"

  deps {}
}
|}
                   port);
              write_file
                (Filename.concat dir "probe.emo")
                "def one() Int64 {\n  return 1\n}\n";
              in_dir dir (fun () ->
                  Alcotest.(check int)
                    "publish exits 0" 0
                    (Emo_cli.publish ~registry_opt:None ~token_opt:None
                       ~dry_run:false)))
        in
        set "EMO_REGISTRY" old_registry;
        set "EMO_TOKEN" old_token;
        Alcotest.(check bool)
          "posts to the manifest's endpoint" true
          (contains captured "POST /api/v1/packages HTTP/1.1\r\n");
        Alcotest.(check bool)
          "the env token rides along" true
          (contains captured "Authorization: Bearer emo_manifest_token"));
  ]

(* ---- login: the account exchange behind `emo emoji login` ----

   The same captive-server trick as publish, extended to a sequence: each
   incoming connection is answered with the next canned response, because
   the stdlib http client opens one connection per request. *)

let with_captive_server_seq ~(responses : (int * string) list) (f : int -> unit)
    : string list =
  let srv = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt srv Unix.SO_REUSEADDR true;
  Unix.bind srv (Unix.ADDR_INET (Unix.inet_addr_of_string "127.0.0.1", 0));
  Unix.listen srv 1;
  let port =
    match Unix.getsockname srv with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  let captured = ref [] in
  let serve () =
    List.iter
      (fun (status, body) ->
        match Unix.select [ srv ] [] [] 10.0 with
        | [], _, _ -> () (* the client never connected *)
        | _ ->
            let conn, _ = Unix.accept srv in
            captured := read_request conn :: !captured;
            let head =
              Printf.sprintf "HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n"
                status (String.length body)
            in
            let bytes = Bytes.of_string (head ^ body) in
            ignore (Unix.write conn bytes 0 (Bytes.length bytes));
            Unix.close conn)
      responses
  in
  let th = Thread.create serve () in
  Fun.protect
    ~finally:(fun () ->
      Thread.join th;
      Unix.close srv)
    (fun () -> f port);
  List.rev !captured

(* A scratch filename unique to this run, so repeated test runs never
   collide and nothing ever needs deleting. *)
let unique (name : string) : string =
  Printf.sprintf "%s-%d-%d" name (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1e6) land 0xFFFFFF)

let login_body = {|{"username":"alice","email":"alice@example.com"}|}

let token_body =
  {|{"id":7,"name":"emo CLI","scopes":["push","yank","read"],"expires_at":"2026-10-19T00:00:00Z","last_used_at":null,"created_at":"2026-10-09T00:00:00Z","token":"emo_secret_token"}|}

let token_body_no_expiry =
  {|{"id":8,"name":"emo CLI","scopes":["push","yank","read"],"expires_at":null,"last_used_at":null,"created_at":"2026-10-09T00:00:00Z","token":"emo_eternal_token"}|}

let unauthorized_body =
  {|{"error":{"code":"unauthorized","message":"invalid email or password"}}|}

let login_tests =
  [
    tc "base64 pads per RFC 4648" (fun () ->
        List.iter
          (fun (plain, encoded) ->
            Alcotest.(check string)
              (Printf.sprintf "%S" plain)
              encoded (Emo_cli.base64 plain))
          [
            ("", "");
            ("f", "Zg==");
            ("fo", "Zm8=");
            ("foo", "Zm9v");
            ("foob", "Zm9vYg==");
            ("fooba", "Zm9vYmE=");
            ("foobar", "Zm9vYmFy");
          ]);
    tc "the exchange posts JSON, then basic auth for the token" (fun () ->
        let captured =
          with_captive_server_seq
            ~responses:[ (200, login_body); (201, token_body) ]
            (fun port ->
              match
                Emo_cli.login
                  ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                  ~email:"alice@example.com" ~password:"pass word"
                  ~token_name:"emo CLI" ~expires_in_days:30
              with
              | Error m -> Alcotest.fail m
              | Ok (s1, b1, s2, b2) ->
                  Alcotest.(check int) "login status" 200 s1;
                  Alcotest.(check string) "login body" login_body b1;
                  Alcotest.(check int) "token status" 201 s2;
                  Alcotest.(check string) "token body" token_body b2)
        in
        (match captured with
        | [ login_req; token_req ] ->
            Alcotest.(check bool)
              "posts to the login endpoint" true
              (contains login_req "POST /api/v1/login HTTP/1.1\r\n");
            Alcotest.(check bool)
              "the login body is JSON" true
              (contains login_req "Content-Type: application/json");
            Alcotest.(check bool)
              "the login body carries the credentials" true
              (contains login_req
                 {|{"email":"alice@example.com","password":"pass word"}|});
            Alcotest.(check bool)
              "the token step posts to the tokens endpoint" true
              (contains token_req "POST /api/v1/tokens HTTP/1.1\r\n");
            Alcotest.(check bool)
              "the token step authenticates with basic auth" true
              (contains token_req
                 (Printf.sprintf "Authorization: Basic %s"
                    (Emo_cli.base64 "alice@example.com:pass word")));
            Alcotest.(check bool)
              "the token request names the scopes" true
              (contains token_req {|"scopes":["push","yank","read"]|});
            Alcotest.(check bool)
              "the token request carries the ledger name" true
              (contains token_req {|"name":"emo CLI"|});
            Alcotest.(check bool)
              "the token request carries the expiry" true
              (contains token_req {|"expires_in_days":30|})
        | _ ->
            Alcotest.fail
              (Printf.sprintf "got %d requests" (List.length captured)));
        ());
    tc "a quote in the password is escaped in the JSON body" (fun () ->
        let captured =
          with_captive_server_seq
            ~responses:[ (200, login_body); (201, token_body) ]
            (fun port ->
              ignore
                (Emo_cli.login
                   ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                   ~email:"alice@example.com" ~password:{|pa"ss\wrd|}
                   ~token_name:"emo CLI" ~expires_in_days:0))
        in
        (match captured with
        | [ login_req; _ ] ->
            Alcotest.(check bool)
              "the body stays one JSON string" true
              (contains login_req {|"password":"pa\"ss\\wrd"|})
        | _ -> Alcotest.fail "expected two captured requests");
        ());
    tc "a failed login stops before the token step" (fun () ->
        let captured =
          with_captive_server_seq
            ~responses:[ (401, unauthorized_body) ]
            (fun port ->
              match
                Emo_cli.login
                  ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                  ~email:"alice@example.com" ~password:"wrong"
                  ~token_name:"emo CLI" ~expires_in_days:0
              with
              | Error m -> Alcotest.fail m
              | Ok (s1, b1, s2, b2) ->
                  Alcotest.(check int) "login status" 401 s1;
                  Alcotest.(check string) "login body" unauthorized_body b1;
                  Alcotest.(check int) "token step skipped" 0 s2;
                  Alcotest.(check string) "no token body" "" b2)
        in
        Alcotest.(check int) "one request only" 1 (List.length captured));
    tc "a refused connection is a transport error" (fun () ->
        match
          Emo_cli.login ~registry:"http://127.0.0.1:1" ~email:"a@b.c"
            ~password:"x" ~token_name:"emo CLI" ~expires_in_days:0
        with
        | Ok _ -> Alcotest.fail "expected a transport error"
        | Error m ->
            Alcotest.(check bool)
              "the failure is named" true
              (String.length m > 0));
    tc "apply_login stores the token for its own registry" (fun () ->
        let file = Filename.concat scratch (unique "credentials") in
        let registry_ref = ref "" in
        let outcome = ref (Emo_cli.Rejected "not run") in
        ignore
          (with_captive_server_seq
             ~responses:[ (200, login_body); (201, token_body) ]
             (fun port ->
               (* a trailing slash on purpose: storage normalizes it *)
               let registry = Printf.sprintf "http://127.0.0.1:%d/" port in
               registry_ref := registry;
               outcome :=
                 Emo_cli.apply_login ~file ~registry ~email:"alice@example.com"
                   ~password:"pass word" ~expires_in_days:30;
               ()));
        (match !outcome with
        | Logged_in (username, token, expires_at) ->
            Alcotest.(check string) "username" "alice" username;
            Alcotest.(check string) "token" "emo_secret_token" token;
            Alcotest.(check string) "expiry" "2026-10-19T00:00:00Z" expires_at
        | _ -> Alcotest.fail "expected a successful login");
        Alcotest.(check bool) "the file exists" true (Sys.file_exists file);
        Alcotest.(check int)
          "the file is 0600" 0o600 (Unix.stat file).Unix.st_perm;
        match Emo_project.load_credentials ~file with
        | Error e -> Alcotest.fail e
        | Ok
            [
              {
                Emo_project.c_registry;
                Emo_project.c_token;
                Emo_project.c_username;
                Emo_project.c_expires_at;
              };
            ] ->
            Alcotest.(check string)
              "the stored registry keeps no trailing slash" c_registry
              (Emo_project.registry_base !registry_ref);
            Alcotest.(check string)
              "the stored token" "emo_secret_token" c_token;
            Alcotest.(check string) "the stored username" "alice" c_username;
            Alcotest.(check string)
              "the stored expiry" "2026-10-19T00:00:00Z" c_expires_at
        | Ok _ -> Alcotest.fail "expected exactly one stored entry");
    tc "apply_login records a never-expiring token as empty" (fun () ->
        let file = Filename.concat scratch (unique "credentials-noexpiry") in
        let outcome = ref (Emo_cli.Rejected "not run") in
        ignore
          (with_captive_server_seq
             ~responses:[ (200, login_body); (201, token_body_no_expiry) ]
             (fun port ->
               outcome :=
                 Emo_cli.apply_login ~file
                   ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                   ~email:"alice@example.com" ~password:"pass word"
                   ~expires_in_days:0;
               ()));
        (match !outcome with
        | Logged_in (_, token, expires_at) ->
            Alcotest.(check string) "token" "emo_eternal_token" token;
            Alcotest.(check string) "no expiry" "" expires_at
        | _ -> Alcotest.fail "expected a successful login");
        match Emo_project.load_credentials ~file with
        | Error e -> Alcotest.fail e
        | Ok [ { Emo_project.c_expires_at; _ } ] ->
            Alcotest.(check string)
              "the stored expiry stays empty" "" c_expires_at
        | Ok _ -> Alcotest.fail "expected exactly one stored entry");
    tc "apply_login surfaces a refusal" (fun () ->
        let file = Filename.concat scratch (unique "credentials-refused") in
        let outcome = ref (Emo_cli.Logged_in ("", "", "")) in
        ignore
          (with_captive_server_seq
             ~responses:[ (401, unauthorized_body) ]
             (fun port ->
               outcome :=
                 Emo_cli.apply_login ~file
                   ~registry:(Printf.sprintf "http://127.0.0.1:%d" port)
                   ~email:"alice@example.com" ~password:"wrong"
                   ~expires_in_days:0;
               ()));
        match !outcome with
        | Rejected m ->
            Alcotest.(check bool)
              "the refusal names the cause" true
              (contains m "invalid email or password");
            Alcotest.(check bool)
              "nothing was stored" true
              (not (Sys.file_exists file))
        | _ -> Alcotest.fail "expected a refusal");
    tc "the credentials parser is strict" (fun () ->
        match
          Emo_project.parse_credentials
            {|
registry = "http://a.example"
# a comment line
token = "emo_one"
username = "alice"
|}
        with
        | Error e -> Alcotest.fail e
        | Ok entries -> (
            (match entries with
            | [
             {
               Emo_project.c_registry;
               Emo_project.c_token;
               Emo_project.c_username;
             };
            ] ->
                Alcotest.(check string) "registry" "http://a.example" c_registry;
                Alcotest.(check string) "token" "emo_one" c_token;
                Alcotest.(check string) "username" "alice" c_username
            | _ -> Alcotest.fail "expected exactly one entry");
            match
              Emo_project.parse_credentials
                {|
registry = "http://a.example"
surprise = "x"
|}
            with
            | Ok _ -> Alcotest.fail "expected an unknown-key error"
            | Error e -> (
                Alcotest.(check bool)
                  "names the unknown key" true (contains e "surprise");
                match
                  Emo_project.parse_credentials
                    {|
registry = "http://a.example"
token = "emo_one"
|}
                with
                | Ok _ -> Alcotest.fail "expected a missing-username error"
                | Error e ->
                    Alcotest.(check bool)
                      "names the incomplete block" true (contains e "username"))
            ));
    tc "a file without a trailing newline parses completely" (fun () ->
        match
          Emo_project.parse_credentials
            {|registry = "http://n.example"
token = "emo_n"
username = "u"|}
        with
        | Error e -> Alcotest.fail e
        | Ok entries -> (
            match entries with
            | [
             {
               Emo_project.c_registry;
               Emo_project.c_token;
               Emo_project.c_username;
             };
            ] ->
                Alcotest.(check string) "registry" "http://n.example" c_registry;
                Alcotest.(check string) "token" "emo_n" c_token;
                Alcotest.(check string) "username" "u" c_username
            | _ -> Alcotest.fail "expected exactly one entry"));
    tc "store replaces a registry's block in place" (fun () ->
        let file = Filename.concat scratch (unique "credentials-order") in
        let store r t u x =
          match
            Emo_project.store_credentials ~file ~registry:r ~token:t ~username:u
              ~expires_at:x
          with
          | Error e -> Alcotest.fail e
          | Ok () -> ()
        in
        store "http://a.example" "emo_a" "alice" "2026-10-19T00:00:00Z";
        store "http://b.example" "emo_b" "bob" "";
        store "http://a.example" "emo_a2" "alice2" "";
        match Emo_project.load_credentials ~file with
        | Error e -> Alcotest.fail e
        | Ok entries -> (
            Alcotest.(check int) "two blocks" 2 (List.length entries);
            match entries with
            | [ first; second ] ->
                Alcotest.(check string)
                  "first registry" "http://a.example"
                  first.Emo_project.c_registry;
                Alcotest.(check string)
                  "first token" "emo_a2" first.Emo_project.c_token;
                Alcotest.(check string)
                  "first expiry replaced" "" first.Emo_project.c_expires_at;
                Alcotest.(check string)
                  "second registry" "http://b.example"
                  second.Emo_project.c_registry;
                Alcotest.(check string)
                  "second token" "emo_b" second.Emo_project.c_token
            | _ -> Alcotest.fail "expected two entries"));
    tc "publish resolves flags, then env, then the manifest, then logins"
      (fun () ->
        let stored =
          [
            {
              Emo_project.c_registry = "http://a.example";
              Emo_project.c_token = "emo_a";
              Emo_project.c_username = "alice";
              Emo_project.c_expires_at = "2026-10-19T00:00:00Z";
            };
            {
              Emo_project.c_registry = "http://b.example/";
              Emo_project.c_token = "emo_b";
              Emo_project.c_username = "bob";
              Emo_project.c_expires_at = "";
            };
          ]
        in
        let resolve ~registry_opt ~env_registry ~manifest_registry ~token_opt
            ~env_token =
          Emo_cli.resolve_publish_auth ~registry_opt ~env_registry
            ~manifest_registry ~token_opt ~env_token ~stored
        in
        (match
           resolve ~registry_opt:(Some "http://f.example")
             ~env_registry:(Some "http://e.example")
             ~manifest_registry:(Some "http://a.example")
             ~token_opt:(Some "emo_f") ~env_token:(Some "emo_e")
         with
        | Ok got ->
            Alcotest.(check (pair string string))
              "flags win"
              ("http://f.example", "emo_f")
              got
        | Error e -> Alcotest.fail e);
        (match
           resolve ~registry_opt:None ~env_registry:(Some "http://b.example")
             ~manifest_registry:(Some "http://a.example") ~token_opt:None
             ~env_token:None
         with
        | Ok got ->
            Alcotest.(check (pair string string))
              "the env registry outranks the manifest and picks its own token"
              ("http://b.example", "emo_b")
              got
        | Error e -> Alcotest.fail e);
        (match
           resolve ~registry_opt:None ~env_registry:None
             ~manifest_registry:(Some "http://a.example") ~token_opt:None
             ~env_token:None
         with
        | Ok got ->
            Alcotest.(check (pair string string))
              "the manifest's registry outranks the most recent login and \
               picks its own token"
              ("http://a.example", "emo_a")
              got
        | Error e -> Alcotest.fail e);
        (match
           resolve ~registry_opt:None ~env_registry:None
             ~manifest_registry:(Some "http://c.example") ~token_opt:None
             ~env_token:None
         with
        | Ok _ -> Alcotest.fail "expected a missing-token error"
        | Error e ->
            Alcotest.(check bool)
              "a manifest registry with no stored token refuses" true
              (contains e "no API token"));
        (match
           resolve ~registry_opt:None ~env_registry:None ~manifest_registry:None
             ~token_opt:None ~env_token:None
         with
        | Ok got ->
            Alcotest.(check (pair string string))
              "with nothing set, the most recent login answers"
              ("http://b.example/", "emo_b")
              got
        | Error e -> Alcotest.fail e);
        (match
           resolve ~registry_opt:None ~env_registry:(Some "http://c.example")
             ~manifest_registry:None ~token_opt:None ~env_token:None
         with
        | Ok _ -> Alcotest.fail "expected a missing-token error"
        | Error e ->
            Alcotest.(check bool)
              "a registry with no stored token refuses" true
              (contains e "no API token"));
        match
          Emo_cli.resolve_publish_auth ~registry_opt:None ~env_registry:None
            ~manifest_registry:None ~token_opt:None ~env_token:None ~stored:[]
        with
        | Ok _ -> Alcotest.fail "expected a no-registry error"
        | Error e ->
            Alcotest.(check bool)
              "nothing configured names the registry" true
              (contains e "no registry"));
    tc "login resolves the flag, then the env, then the manifest" (fun () ->
        let dir = Filename.concat scratch "login-registry-resolution" in
        let old_registry = Sys.getenv_opt "EMO_REGISTRY" in
        let restore = function
          | Some v -> Unix.putenv "EMO_REGISTRY" v
          | None -> Unix.putenv "EMO_REGISTRY" ""
        in
        Unix.putenv "EMO_REGISTRY" "";
        Fun.protect
          ~finally:(fun () -> restore old_registry)
          (fun () ->
            (* No manifest here: nothing configured is an error. *)
            write_file (Filename.concat dir "placeholder.emo") "const x = 1\n";
            in_dir dir (fun () ->
                match Emo_cli.resolve_login_registry ~registry_opt:None with
                | Ok None -> ()
                | Ok (Some _) -> Alcotest.fail "expected no registry"
                | Error e -> Alcotest.fail e);
            write_file
              (Filename.concat dir "package.emo")
              {|package {
  name = "acme/hello"
  version = "0.1.0"
  targets = ["ocaml"]
  registry = "http://manifest.example"

  deps {}
}
|};
            in_dir dir (fun () ->
                (match
                   Emo_cli.resolve_login_registry
                     ~registry_opt:(Some "http://flag.example")
                 with
                | Ok (Some r) ->
                    Alcotest.(check string)
                      "the flag wins" "http://flag.example" r
                | _ -> Alcotest.fail "expected the flag's registry");
                Unix.putenv "EMO_REGISTRY" "http://env.example";
                (match Emo_cli.resolve_login_registry ~registry_opt:None with
                | Ok (Some r) ->
                    Alcotest.(check string)
                      "the env outranks the manifest" "http://env.example" r
                | _ -> Alcotest.fail "expected the env's registry");
                Unix.putenv "EMO_REGISTRY" "";
                (match Emo_cli.resolve_login_registry ~registry_opt:None with
                | Ok (Some r) ->
                    Alcotest.(check string)
                      "the manifest answers last" "http://manifest.example" r
                | _ -> Alcotest.fail "expected the manifest's registry");
                (* A damaged manifest is an error, not a silent skip —
                   asserted while EMO_REGISTRY is still unset, or the
                   environment would answer before the file is read. *)
                write_file
                  (Filename.concat dir "package.emo")
                  {|package { name = "acme/hello"|};
                match Emo_cli.resolve_login_registry ~registry_opt:None with
                | Ok _ -> Alcotest.fail "expected a manifest error"
                | Error e ->
                    Alcotest.(check bool)
                      "the manifest error is named" true
                      (String.length e > 0))));
  ]

(* ---- The riscv64 goldens (T19.1): the freestanding ELF boots under
   QEMU and the payload's output matches the interpreter byte for byte.
   Two transport facts belong to the harness, not the target: OpenSBI
   (QEMU's default BIOS) prints its banner on the same serial stream —
   the payload starts after the banner's last Boot HART line — and the
   SBI console renders every newline as CRLF. Skips when QEMU or the
   cross binutils are absent; the binutils answer is the build's own
   probe, so the two cannot disagree on which prefix is installed. ---- *)

let riscv64_available =
  lazy
    (Sys.command "qemu-system-riscv64 --version >/dev/null 2>&1" = 0
    && Emo_cli.riscv_binutils_prefix () <> None)

(* The payload's serial output: everything after OpenSBI's banner, with
   the console's CRLF rendered back to LF. Without a banner (a bare-metal
   boot) the stream is the payload's already. *)
let riscv64_payload (serial : string) : string =
  let strip_cr s =
    let n = String.length s in
    if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
  in
  let lines = Array.of_list (String.split_on_char '\n' serial) in
  let n = Array.length lines in
  let rec last_banner i found =
    if i >= n then found
    else
      last_banner (i + 1)
        (if String.starts_with ~prefix:"Boot HART " lines.(i) then Some i
         else found)
  in
  let from = match last_banner 0 None with Some i -> i + 1 | None -> 0 in
  let out = Buffer.create 1024 in
  for j = from to n - 1 do
    Buffer.add_string out (strip_cr lines.(j));
    if j < n - 1 then Buffer.add_char out '\n'
  done;
  Buffer.contents out

let riscv64_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to riscv64 and boots under QEMU" name)
        (fun () ->
          if not (Lazy.force riscv64_available) then Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out_elf = Filename.concat scratch (name ^ "-riscv64.elf") in
          let exit_code =
            in_example name (fun () ->
                Emo_cli.build_file ~entry:"main.emo" ~output:out_elf
                  ~specialize:false ~cclibs:[]
                  ~native:Emo_project.no_native_inputs ~target:"riscv64")
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let cmd =
            Printf.sprintf
              "qemu-system-riscv64 -machine virt -nographic -kernel %s"
              (Filename.quote out_elf)
          in
          let serial, err, proc_status = run_cmd cmd in
          Alcotest.(check string) "output" expected (riscv64_payload serial);
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "the image exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   err)))
    [
      "hello_world";
      "fib";
      "objects";
      "language_tour";
      "loops";
      "error_matching";
      "floats";
    ]

(* T19.4's honest refusals: a program the checker admits but the
   freestanding backend cannot honor yet exits 65 with a message that
   names the construct — the check itself rides the emitter's
   Lower_error, so the text is asserted directly. *)
let riscv64_refusal_tests =
  [
    tc "a map literal refuses with a clear diagnostic" (fun () ->
        let entry = scratch_entry "riscv-map" {|println({ "a": 1 })|} in
        Alcotest.(check int)
          "exit" 65
          (build_entry ~target:"riscv64" entry
             (Filename.concat (Filename.dirname entry) "out")));
    tc "spawn refuses with a clear diagnostic" (fun () ->
        let entry =
          scratch_entry "riscv-spawn"
            {|
def work() {
  println("nope")
}
do work()|}
        in
        Alcotest.(check int)
          "exit" 65
          (build_entry ~target:"riscv64" entry
             (Filename.concat (Filename.dirname entry) "out")));
    tc "the refusals name the construct" (fun () ->
        let refusal src =
          let items, parse_diags =
            Emo_parser.parse_program_with_diagnostics ~file:"main.emo"
              ~source:src
          in
          (match parse_diags with
          | [] -> ()
          | _ -> Alcotest.fail "parse errors");
          let diags, _refs, _requires, types =
            Emo_check.check_module_typed ~modules:[] ~current:[]
              ~target:"riscv64" items
          in
          match diags with
          | _ :: _ -> Alcotest.fail "unexpected check errors"
          | [] -> (
              let program =
                Emo_ir.lower
                  {
                    Emo_ir.modules =
                      [ { Emo_ir.mpath = []; mitems = items; mtypes = types } ];
                    entry = [];
                    packages = [];
                  }
              in
              match
                try
                  ignore (Emo_codegen.Riscv.emit program);
                  None
                with Emo_ir.Lower_error message -> Some message
              with
              | None -> None
              | Some message -> Some message)
        in
        List.iter
          (fun (name, src, fragment) ->
            match refusal src with
            | None ->
                Alcotest.fail (Printf.sprintf "%s: expected a refusal" name)
            | Some message ->
                Alcotest.(check bool)
                  name true
                  (contains message "does not support"
                  && contains message fragment))
          [
            ( "processes",
              {|def work() {
  println("nope")
}
do work()|},
              "spawn" );
            ("bytes", {|println(Bytes.new(4))|}, "Bytes");
            ("raise", {|raise Exception.new(message: "boom")|}, "raise");
          ]);
  ]

(* A `foreign def` binds a host symbol on `c` and `ocaml`. On the other
   targets the definition is inert: the checker admits the declaration —
   its FFI types are legal on every target — the emitter skips the
   binding, and only a call to it refuses through the emitter's own
   Lower_error, which the CLI renders as exit 65 (the shape riscv64's
   refusals above take). *)
let foreign_decl_source =
  {|
foreign def host_floor(x Float64) Float64 = "floor"

println("ok")
|}

let foreign_call_source =
  {|
foreign def host_floor(x Float64) Float64 = "floor"

println(host_floor(2.5))
|}

let foreign_value_source =
  {|
foreign def host_floor(x Float64) Float64 = "floor"

const f = host_floor

println("ok")
|}

let foreign_tests =
  let build source target suffix =
    let entry = scratch_entry ("foreign-" ^ suffix ^ "-" ^ target) source in
    build_entry ~target entry (Filename.concat (Filename.dirname entry) suffix)
  in
  let refusal target source emit =
    let items, parse_diags =
      Emo_parser.parse_program_with_diagnostics ~file:"main.emo" ~source
    in
    (match parse_diags with [] -> () | _ -> Alcotest.fail "parse errors");
    let diags, _refs, _requires, types =
      Emo_check.check_module_typed ~modules:[] ~current:[] ~target items
    in
    match diags with
    | _ :: _ -> Alcotest.fail "unexpected check errors"
    | [] -> (
        let program =
          Emo_ir.lower
            {
              Emo_ir.modules =
                [ { Emo_ir.mpath = []; mitems = items; mtypes = types } ];
              entry = [];
              packages = [];
            }
        in
        try
          ignore (emit program);
          None
        with Emo_ir.Lower_error message -> Some message)
  in
  [
    (* A declaration reaches an emitter as an ordinary `func` record
       with an empty body. Emitting a real function for it would be a
       silent stub, so the target must either bind the host symbol or
       leave the name unbound — and only a call may refuse. *)
    tc "a foreign declaration alone is inert off the native targets" (fun () ->
        List.iter
          (fun (target, emit) ->
            match refusal target foreign_decl_source emit with
            | None -> ()
            | Some message ->
                Alcotest.fail (target ^ ": unexpected refusal: " ^ message))
          [
            ("wasm", fun p -> ignore (Emo_codegen.Wasm.assemble p));
            ( "beam",
              fun p -> ignore (Emo_codegen.Beam.emit ~module_name:"emo_main" p)
            );
            ("typescript", fun p -> ignore (Emo_codegen.Ts.emit_ts p));
            ("riscv64", fun p -> ignore (Emo_codegen.Riscv.emit p));
          ]);
    tc "the c and ocaml targets build a declaration-only program" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        List.iter
          (fun target ->
            Alcotest.(check int)
              (target ^ " build exit") 0
              (build foreign_decl_source target "main-decl"))
          [ "c"; "ocaml" ]);
    tc "a call to a foreign definition refuses off the native targets"
      (fun () ->
        let build_call target = build foreign_call_source target "main-call" in
        List.iter
          (fun (target, emit) ->
            Alcotest.(check int) (target ^ " build exit") 65 (build_call target);
            match refusal target foreign_call_source emit with
            | None -> Alcotest.fail (target ^ ": expected a refusal")
            | Some message ->
                Alcotest.(check bool)
                  target true
                  (contains message "does not support"
                  && contains message "foreign def"
                  && contains message "host_floor"))
          [
            ("wasm", fun p -> ignore (Emo_codegen.Wasm.assemble p));
            ( "beam",
              fun p -> ignore (Emo_codegen.Beam.emit ~module_name:"emo_main" p)
            );
            ("typescript", fun p -> ignore (Emo_codegen.Ts.emit_ts p));
            ("riscv64", fun p -> ignore (Emo_codegen.Riscv.emit p));
          ]);
    tc "taking a foreign definition's value refuses off the native targets"
      (fun () ->
        List.iter
          (fun target ->
            Alcotest.(check int)
              (target ^ " build exit") 65
              (build foreign_value_source target "main-value"))
          [ "wasm"; "beam"; "typescript"; "riscv64" ]);
    tc "the c and ocaml targets really call through" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let entry = scratch_entry "foreign-call-c" foreign_call_source in
        let bin = Filename.concat (Filename.dirname entry) "main-call" in
        Alcotest.(check int)
          "c build exit" 0
          (build_entry ~target:"c" entry bin);
        check_run "c" (run_cmd (Filename.quote bin)) "2.0\n";
        Alcotest.(check int)
          "ocaml build exit" 0
          (build foreign_call_source "ocaml" "main-call"));
  ]

(* Stage B's native emitter lowers an enum `case`'s member and a def
   taken as a value; a body it cannot model — container literals, or a
   value of a def that stays dynamic — keeps its dynamic lowerer instead
   of refusing at emit time. `examples/specialize_shapes` carries the
   shapes on the ocaml target; the interpreter half runs through the
   ordinary examples suite. *)
let specialization_tests =
  [
    tc "the shapes example specializes and runs on the ocaml target" (fun () ->
        let expected =
          read_file
            (Filename.concat examples_dir "specialize_shapes/expected.txt")
        in
        let bin = Filename.concat scratch "specialize-shapes-bin" in
        let exit_code =
          in_example "specialize_shapes" (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:bin ~specialize:true
                ~cclibs:[] ~target:"ocaml")
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        check_run "ocaml" (run_cmd (Filename.quote bin)) expected);
    tc "a body with container literals stays dynamic and runs" (fun () ->
        let entry =
          scratch_entry "specialize-containers"
            {|def pair(n Int64) Int64 {
  const p = (n, n + 1)
  return n
}

def arr(n Int64) Int64 {
  const a = [n, n]
  return n
}

println(pair(7))
println(arr(8))
|}
        in
        let bin = Filename.concat (Filename.dirname entry) "main-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"ocaml" ~specialize:true entry bin);
        check_run "ocaml" (run_cmd (Filename.quote bin)) "7\n8\n");
    tc "a value of a dynamic def keeps the body dynamic" (fun () ->
        let entry =
          scratch_entry "specialize-dynamic-value"
            {|def apply_it(f Block, n Int64) Int64 {
  return n
}

def keep(n Int64) Int64 {
  const f = apply_it
  return n
}

println(keep(5))
|}
        in
        let bin = Filename.concat (Filename.dirname entry) "main-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"ocaml" ~specialize:true entry bin);
        check_run "ocaml" (run_cmd (Filename.quote bin)) "5\n");
  ]

(* ---- HTTP registry pull: `registry = "..."` in the manifest ----

   A routing captive server answers Protocol B requests by path — one
   connection per request, as the stdlib http client sends Connection:
   close. The project under test names the server in its manifest's
   `registry` field, so the whole pull path (embedded fetch programs, JSON
   parsing, archive unpack, digest pinning, the lockfile and the cache) is
   exercised over a real socket. *)

let with_registry_server ~(handler : string -> int * string) (f : int -> unit) :
    string list =
  let srv = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt srv Unix.SO_REUSEADDR true;
  Unix.bind srv (Unix.ADDR_INET (Unix.inet_addr_of_string "127.0.0.1", 0));
  Unix.listen srv 8;
  let port =
    match Unix.getsockname srv with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  let captured = ref [] in
  let stop = ref false in
  let rec serve () =
    if !stop then ()
    else
      (* A select in a multithreaded process can transiently fail on
         Linux (EAGAIN and friends); the loop itself absorbs it. *)
      match
        match Unix.select [ srv ] [] [] 0.2 with
        | r -> Some r
        | exception Unix.Unix_error _ -> None
      with
      | Some ([], _, _) | None -> serve ()
      | Some (_, _, _) ->
          let conn, _ = Unix.accept srv in
          let request = read_request conn in
          captured := request :: !captured;
          let path =
            let line =
              match find_sub request "\r\n" with
              | Some i -> String.sub request 0 i
              | None -> request
            in
            match String.split_on_char ' ' line with
            | _ :: path :: _ -> path
            | _ -> ""
          in
          let status, body = handler path in
          let head =
            Printf.sprintf "HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n" status
              (String.length body)
          in
          let bytes = Bytes.of_string (head ^ body) in
          let written = ref 0 in
          while !written < Bytes.length bytes do
            written :=
              !written
              + Unix.write conn bytes !written (Bytes.length bytes - !written)
          done;
          Unix.close conn;
          serve ()
  in
  let th = Thread.create serve () in
  Fun.protect
    ~finally:(fun () ->
      stop := true;
      Thread.join th;
      Unix.close srv)
    (fun () -> f port);
  List.rev !captured

(* Environment plumbing for the pull tests: the suite runs with
   EMO_REGISTRY pointing at the filesystem stdlib, which would override the
   manifest field under test; the cache and credentials go to scratch so
   the user's real ~/.cache/emo and login store stay untouched. *)
let with_pull_env f =
  let old_registry = Sys.getenv_opt "EMO_REGISTRY" in
  let old_cache = Sys.getenv_opt "EMO_CACHE_DIR" in
  let old_config = Sys.getenv_opt "EMO_CONFIG_DIR" in
  let restore var = function
    | Some v -> Unix.putenv var v
    | None -> Unix.putenv var ""
  in
  Unix.putenv "EMO_REGISTRY" "";
  Unix.putenv "EMO_CACHE_DIR" (Filename.concat scratch "pull-cache");
  Unix.putenv "EMO_CONFIG_DIR" (Filename.concat scratch "pull-config");
  Fun.protect
    ~finally:(fun () ->
      restore "EMO_REGISTRY" old_registry;
      restore "EMO_CACHE_DIR" old_cache;
      restore "EMO_CONFIG_DIR" old_config)
    f

let http_pull_tests =
  let p_files =
    [
      ( "package.emo",
        "package {\n\
        \  name = \"acme/p\"\n\
        \  version = \"1.0.0\"\n\
        \  targets = [\"c\"]\n\
        \  deps {}\n\
         }\n" );
      ("p.emo", "def one() Int64 {\n  return 1\n}\n");
    ]
  in
  let p_checksum = Emo_pkg.Registry.digest p_files in
  let p_archive = Emo_pkg.Archive.build p_files in
  let handler path =
    if path = "/api/v1/packages/acme/p/versions" then
      ( 200,
        Printf.sprintf
          {|{"package":"acme/p","versions":[{"version":"1.0.0","checksum":"%s","archive_sha256":"","targets":["c"],"yanked":false,"published_at":"2026-10-16T00:00:00Z"}]}|}
          p_checksum )
    else if path = "/api/v1/dependencies?packages=acme/p" then
      (200, {|{"acme/p":[{"version":"1.0.0","deps":{},"yanked":false}]}|})
    else if path = "/downloads/acme-p-1.0.0.emoji" then (200, p_archive)
    else (404, {|{"error":{"code":"not_found","message":"not found"}}|})
  in
  let write_project dir ~registry_url =
    ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
    let write rel content =
      let oc = open_out_bin (Filename.concat dir rel) in
      output_string oc content;
      close_out oc
    in
    write "package.emo"
      (Printf.sprintf
         {|package {
  name = "acme/app"
  version = "0.1.0"
  targets = ["c"]
  registry = "%s"

  deps {
    "acme/p" = "1.0.0"
  }
}
|}
         registry_url);
    write "main.emo"
      {|require "acme/p"

def main() Int64 {
  return p.one()
}

main()
|}
  in
  [
    tc "a manifest registry field resolves, locks, and runs" (fun () ->
        with_pull_env (fun () ->
            ignore
              (with_registry_server ~handler (fun port ->
                   let dir = Filename.concat scratch (unique "pull-app") in
                   write_project dir
                     ~registry_url:(Printf.sprintf "http://127.0.0.1:%d" port);
                   in_dir dir (fun () ->
                       Alcotest.(check int)
                         "resolve exits 0" 0
                         (Emo_cli.deps_resolve ~name:None);
                       let lock = read_file "package.lock" in
                       Alcotest.(check string)
                         "the lockfile pins the digest"
                         (Printf.sprintf "acme/p 1.0.0 %s\n" p_checksum)
                         lock;
                       Alcotest.(check int)
                         "the program runs against the pulled package" 0
                         (Emo_cli.run_file ~file:"main.emo" ~color:false
                            ~error_limit:20);
                       Alcotest.(check bool)
                         "the package materialized in the cache" true
                         (Sys.file_exists
                            (Filename.concat
                               (Filename.concat scratch "pull-cache")
                               (Printf.sprintf "acme/p-1.0.0-%s/p.emo"
                                  p_checksum))))))));
    tc "a missing package reports 65 with the registry's answer" (fun () ->
        with_pull_env (fun () ->
            ignore
              (with_registry_server ~handler (fun port ->
                   let dir = Filename.concat scratch (unique "pull-missing") in
                   write_project dir
                     ~registry_url:(Printf.sprintf "http://127.0.0.1:%d" port);
                   let oc = open_out_bin (Filename.concat dir "package.emo") in
                   output_string oc
                     (Printf.sprintf
                        {|package {
  name = "acme/app"
  version = "0.1.0"
  targets = ["c"]
  registry = "http://127.0.0.1:%d"

  deps {
    "acme/missing" = "9.9.9"
  }
}
|}
                        port);
                   close_out oc;
                   in_dir dir (fun () ->
                       Alcotest.(check int)
                         "resolve exits 65" 65
                         (Emo_cli.deps_resolve ~name:None))))));
  ]

(* ---- --locked: the recorded resolution is a prerequisite ---- *)

let locked_tests =
  let app ~deps =
    let dir = Filename.concat scratch (unique "locked-app") in
    ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
    let write rel content =
      let oc = open_out_bin (Filename.concat dir rel) in
      output_string oc content;
      close_out oc
    in
    write "package.emo"
      (Printf.sprintf
         {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["c"]

  deps {%s}
}
|}
         deps);
    write "main.emo" "require \"base64\"\n";
    dir
  in
  let with_deps = " \"base64\" = \"0.1.0\" " in
  [
    tc "--locked refuses a project with dependencies and no lockfile" (fun () ->
        let dir = app ~deps:with_deps in
        in_dir dir (fun () ->
            Alcotest.(check (option int))
              "refused with 66" (Some 66)
              (Emo_cli.locked_guard ~locked:true)));
    tc "--locked passes once the lockfile exists" (fun () ->
        let dir = app ~deps:with_deps in
        let oc = open_out_bin (Filename.concat dir Emo_pkg.Lockfile.filename) in
        output_string oc "";
        close_out oc;
        in_dir dir (fun () ->
            Alcotest.(check (option int))
              "passes" None
              (Emo_cli.locked_guard ~locked:true)));
    tc "a project without dependencies owes no lockfile" (fun () ->
        let dir = app ~deps:"" in
        in_dir dir (fun () ->
            Alcotest.(check (option int))
              "passes" None
              (Emo_cli.locked_guard ~locked:true)));
    tc "without --locked nothing is refused" (fun () ->
        let dir = app ~deps:with_deps in
        in_dir dir (fun () ->
            Alcotest.(check (option int))
              "passes" None
              (Emo_cli.locked_guard ~locked:false)));
  ]

(* ---- new: the project scaffold (T24.3) ---- *)

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let contains_sub text sub =
  let n = String.length text and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub text i m = sub then true
    else go (i + 1)
  in
  m = 0 || go 0

(* ---- `emo deps add`: pin in the manifest, lock the resolution ---- *)

let deps_add_tests =
  let write dir rel content =
    let oc = open_out_bin (Filename.concat dir rel) in
    output_string oc content;
    close_out oc
  in
  let with_env var value f =
    let old = Sys.getenv_opt var in
    Unix.putenv var value;
    Fun.protect
      ~finally:(fun () ->
        match old with
        | Some v -> Unix.putenv var v
        | None -> Unix.putenv var "")
      f
  in
  let app ?(deps_block = "  deps {}\n") () =
    let dir = Filename.concat scratch (unique "add-app") in
    ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
    write dir "package.emo"
      (Printf.sprintf
         {|package {
  name = "local/app"
  version = "0.1.0"
  targets = ["c"]

%s}
|}
         deps_block);
    write dir "main.emo" "println(1)\n";
    dir
  in
  let fixture_registry f =
    let dir = Filename.concat scratch (unique "add-registry") in
    let pkg = Filename.concat dir "david/hack_it/0.2.3" in
    ignore (Sys.command ("mkdir -p " ^ Filename.quote pkg));
    write pkg "package.emo"
      {|package {
  name = "david/hack_it"
  version = "0.2.3"
  targets = ["c"]

  deps {}
}
|};
    write pkg "hack_it.emo" "def boom() Int64 {\n  return 7\n}\n";
    with_env "EMO_REGISTRY" dir (fun () ->
        with_env "EMO_CACHE_DIR" (Filename.concat dir "cache") f)
  in
  [
    tc "add pins a standard-library package and locks its closure" (fun () ->
        let dir = app () in
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 0" 0
              (Emo_cli.deps_add ~name:"json" ~version:"0.1.0");
            let manifest = read_file "package.emo" in
            Alcotest.(check bool)
              "the manifest carries the pin" true
              (contains_sub manifest "\"json\" = \"0.1.0\"");
            Alcotest.(check bool)
              "the manifest around it is untouched" true
              (contains_sub manifest "name = \"local/app\""
              && contains_sub manifest "targets = [\"c\"]");
            let lock = read_file "package.lock" in
            Alcotest.(check bool)
              "the lockfile carries the closure" true
              (contains_sub lock "json 0.1.0 "
              && contains_sub lock "float 0.1.0 ")));
    tc "add pins a scoped package from the registry" (fun () ->
        fixture_registry (fun () ->
            let dir = app () in
            in_dir dir (fun () ->
                Alcotest.(check int)
                  "exits 0" 0
                  (Emo_cli.deps_add ~name:"david/hack_it" ~version:"0.2.3");
                Alcotest.(check bool)
                  "the manifest carries the pin" true
                  (contains_sub (read_file "package.emo")
                     "\"david/hack_it\" = \"0.2.3\"");
                Alcotest.(check bool)
                  "the lockfile carries it" true
                  (contains_sub (read_file "package.lock")
                     "david/hack_it 0.2.3 "))));
    tc "a manifest with no deps block gains one" (fun () ->
        let dir = app ~deps_block:"  link = []\n" () in
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 0" 0
              (Emo_cli.deps_add ~name:"json" ~version:"0.1.0");
            Alcotest.(check bool)
              "a deps block is born" true
              (contains_sub (read_file "package.emo") "deps {")));
    tc "an already-pinned package is refused, manifest untouched" (fun () ->
        let dir = app () in
        in_dir dir (fun () ->
            ignore (Emo_cli.deps_add ~name:"json" ~version:"0.1.0");
            let before = read_file "package.emo" in
            Alcotest.(check int)
              "second add exits 65" 65
              (Emo_cli.deps_add ~name:"json" ~version:"0.2.0");
            Alcotest.(check string)
              "the manifest is unchanged" before (read_file "package.emo")));
    tc "a version the registry does not publish is refused" (fun () ->
        let dir = app () in
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 65" 65
              (Emo_cli.deps_add ~name:"json" ~version:"9.9.9");
            Alcotest.(check bool)
              "no lockfile is written" false
              (Sys.file_exists "package.lock")));
    tc "a malformed version is refused" (fun () ->
        let dir = app () in
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 65" 65
              (Emo_cli.deps_add ~name:"json" ~version:"latest");
            Alcotest.(check bool)
              "no lockfile is written" false
              (Sys.file_exists "package.lock")));
    tc "a one-line deps block is refused, manifest untouched" (fun () ->
        let dir = app ~deps_block:"  deps { \"json\" = \"0.1.0\" }\n" () in
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 65" 65
              (Emo_cli.deps_add ~name:"base64" ~version:"0.1.0");
            Alcotest.(check bool)
              "no second deps block" false
              (contains_sub (read_file "package.emo") "deps {\n")));
    tc "no manifest in the directory exits 66" (fun () ->
        let dir = Filename.concat scratch (unique "add-empty") in
        ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
        in_dir dir (fun () ->
            Alcotest.(check int)
              "exits 66" 66
              (Emo_cli.deps_add ~name:"json" ~version:"0.1.0")));
  ]

let new_tests =
  [
    tc "the scaffold is green the moment it exists" (fun () ->
        let dir = Filename.concat scratch "scaffold-hello" in
        if Sys.file_exists dir then Emo_project.remove_tree dir
        else if Sys.file_exists scratch then ()
        else Unix.mkdir scratch 0o755;
        Alcotest.(check int) "exit" 0 (Emo_cli.scaffold ~path:dir);
        let manifest = read_file (Filename.concat dir "package.emo") in
        Alcotest.(check bool)
          "manifest names the package" true
          (contains manifest {|name = "scaffold-hello"|});
        Alcotest.(check bool)
          "manifest declares the default targets" true
          (contains manifest {|targets = ["ocaml", "c"]|});
        let main_src = read_file (Filename.concat dir "main.emo") in
        Alcotest.(check bool) "main greets" true (contains main_src "greet");
        Alcotest.(check bool)
          "gitignore ignores the build dir" true
          (contains
             (read_file (Filename.concat dir ".gitignore"))
             ".emo-build/");
        (* checked, built, and run the moment it exists — from the
           scaffolded directory, which is the package root *)
        let entry = Filename.concat dir "main.emo" in
        let bin = Filename.concat dir "scaffold-bin" in
        Alcotest.(check int)
          "check exit" 0
          (in_dir dir (fun () ->
               Emo_cli.check_file ~file:entry ~color:false ~error_limit:20));
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"c" ~specialize:true entry bin);
        let out, _, _ = run_cmd (Filename.quote bin) in
        let first_line = List.hd (String.split_on_char '\n' out) in
        Alcotest.(check string) "binary output" "Hello, world!" first_line);
    tc "an owner/name argument names the package fully" (fun () ->
        let old_cwd = Sys.getcwd () in
        Sys.chdir scratch;
        Fun.protect
          ~finally:(fun () -> Sys.chdir old_cwd)
          (fun () ->
            Alcotest.(check int) "exit" 0 (Emo_cli.scaffold ~path:"acme/owned");
            let manifest = read_file "acme/owned/package.emo" in
            Alcotest.(check bool)
              "owner/name manifest" true
              (contains manifest {|name = "acme/owned"|});
            Emo_project.remove_tree "acme"));
    tc "an existing directory refuses" (fun () ->
        let dir = Filename.concat scratch "scaffold-clash" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        Alcotest.(check int) "exit" 65 (Emo_cli.scaffold ~path:dir));
  ]

(* ---- emoji: the shared-package lifecycle ---- *)

let emoji_tests =
  [
    tc "emoji new scaffolds a publishable package" (fun () ->
        let dir = Filename.concat scratch "emojihello" in
        if Sys.file_exists dir then Emo_project.remove_tree dir
        else if Sys.file_exists scratch then ()
        else Unix.mkdir scratch 0o755;
        Alcotest.(check int)
          "exit" 0
          (Emo_cli.scaffold_package ~name:"acme/emojihello" ~path:dir);
        let manifest = read_file (Filename.concat dir "package.emo") in
        Alcotest.(check bool)
          "manifest names the package owner/name" true
          (contains manifest {|name = "acme/emojihello"|});
        let module_src = read_file (Filename.concat dir "emojihello.emo") in
        Alcotest.(check bool)
          "the public module greets" true
          (contains module_src "hello");
        Alcotest.(check bool)
          "a README rides along" true
          (Sys.file_exists (Filename.concat dir "README.md")));
    tc "emoji new refuses a plain name" (fun () ->
        let old_cwd = Sys.getcwd () in
        Sys.chdir scratch;
        Fun.protect
          ~finally:(fun () -> Sys.chdir old_cwd)
          (fun () ->
            let exit_code =
              try Emo_cli.scaffold_package ~name:"plainname" ~path:"plainname"
              with _ -> 65
            in
            Alcotest.(check int) "exit" 65 exit_code));
    tc "emoji new refuses an existing directory" (fun () ->
        let dir = Filename.concat scratch "emoji-clash" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        Alcotest.(check int)
          "exit" 65
          (Emo_cli.scaffold_package ~name:"acme/emoji-clash" ~path:dir));
    tc "emoji build passes the scaffolded package" (fun () ->
        let old_cwd = Sys.getcwd () in
        let dir = Filename.concat scratch "emojihello" in
        Sys.chdir dir;
        Fun.protect
          ~finally:(fun () -> Sys.chdir old_cwd)
          (fun () ->
            Alcotest.(check int)
              "exit" 0
              (Emo_cli.emoji_build ~dir:(Sys.getcwd ()))));
    tc "emoji build fails on a broken module" (fun () ->
        let old_cwd = Sys.getcwd () in
        let dir = Filename.concat scratch "emojihello" in
        let module_file = Filename.concat dir "emojihello.emo" in
        let good = read_file module_file in
        let oc = open_out_bin module_file in
        output_string oc "def broken( {\n";
        close_out oc;
        Sys.chdir dir;
        Fun.protect
          ~finally:(fun () ->
            let oc = open_out_bin module_file in
            output_string oc good;
            close_out oc;
            Sys.chdir old_cwd)
          (fun () ->
            Alcotest.(check int)
              "exit" 65
              (Emo_cli.emoji_build ~dir:(Sys.getcwd ()))));
    tc "emoji build honors every target the manifest declares" (fun () ->
        (* The engine picks the output's stem, and the stem names the BEAM
           module — so the gate has to build under a name a module can
           carry, on all five targets, not the two the scaffold declares.
           The beam half of that needs `erlc`, which the scaffold's two
           targets never did. *)
        if not (Lazy.force erlc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "emojitargets" in
        if Sys.file_exists dir then Emo_project.remove_tree dir;
        Unix.mkdir dir 0o755;
        let write name contents =
          let oc = open_out_bin (Filename.concat dir name) in
          output_string oc contents;
          close_out oc
        in
        write "package.emo"
          {|package {
  name = "acme/emojitargets"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {}
}
|};
        write "emojitargets.emo" "def greet() String {\n  return \"hi\"\n}\n";
        let old_cwd = Sys.getcwd () in
        Sys.chdir dir;
        Fun.protect
          ~finally:(fun () -> Sys.chdir old_cwd)
          (fun () ->
            Alcotest.(check int)
              "exit" 0
              (Emo_cli.emoji_build ~dir:(Sys.getcwd ()))));
  ]

(* ---- doctor: the target-aware environment check (T24.5) ---- *)

let doctor_tests =
  [
    tc "doctor reports every target and exits healthy" (fun () ->
        let buf = Buffer.create 512 in
        let code = Emo_cli.doctor ~emit:(Buffer.add_string buf) in
        let text = Buffer.contents buf in
        Alcotest.(check int) "exit" 0 code;
        Alcotest.(check bool)
          "embedded stdlib" true
          (contains text "stdlib: embedded");
        List.iter
          (fun name ->
            Alcotest.(check bool) ("reports " ^ name) true (contains text name))
          [ "c:"; "ocaml:"; "typescript:"; "browser:"; "beam:"; "wasm:" ];
        Alcotest.(check bool)
          "the ocaml line names the toolchain, not the installation shape" true
          (contains text "ok — ocamlfind" || contains text "unavailable");
        Alcotest.(check bool)
          "wasm needs nothing" true
          (contains text "no external tools"));
  ]

(* ---- browser: the page bundle (T48.10) ---- *)

(* A stub page — just enough of document and window for the dom family.
   The bundle is a plain script with no imports, so require runs it; the
   timeout lets the root's microtasks and the event's promise settle
   before the harness reports what the page now holds. *)
let browser_page_harness =
  {|const body = {
  children: [],
  firstChild: null,
  appendChild(c) {
    this.children.push(c);
    this.firstChild = this.children[0];
  },
  removeChild(c) {
    this.children = this.children.filter((x) => x !== c);
    this.firstChild = this.children[0] || null;
  },
};
global.document = {
  title: "",
  body,
  getElementById: (id) => (id === "emo-root" ? body : null),
  createElement: (tag) => ({
    tagName: tag,
    children: [],
    style: { props: {}, setProperty(n, v) { this.props[n] = v; } },
    addEventListener(ev, fn) {
      this.listeners = this.listeners || {};
      (this.listeners[ev] = this.listeners[ev] || []).push(fn);
    },
    appendChild(c) { this.children.push(c); },
    removeChild(c) { this.children = this.children.filter((x) => x !== c); },
  }),
  createTextNode: (text) => ({ data: text }),
};
global.window = { innerWidth: 800, innerHeight: 600 };
require("./app.js");
setTimeout(() => {
  console.log(
    "title=" +
      document.title +
      " children=" +
      body.children.map((c) => c.data ?? c.tagName).join(",")
  );
}, 10);
|}

let browser_event_harness =
  {|const body = {
  children: [],
  firstChild: null,
  appendChild(c) {
    this.children.push(c);
    this.firstChild = this.children[0];
  },
  removeChild(c) {
    this.children = this.children.filter((x) => x !== c);
    this.firstChild = this.children[0] || null;
  },
};
global.document = {
  title: "",
  body,
  getElementById: (id) => (id === "emo-root" ? body : null),
  createElement: (tag) => ({
    tagName: tag,
    children: [],
    style: { props: {}, setProperty() {} },
    addEventListener(ev, fn) {
      this.listeners = this.listeners || {};
      (this.listeners[ev] = this.listeners[ev] || []).push(fn);
    },
    appendChild(c) { this.children.push(c); },
    removeChild(c) { this.children = this.children.filter((x) => x !== c); },
  }),
  createTextNode: (text) => ({ data: text }),
};
global.window = { innerWidth: 800, innerHeight: 600 };
require("./app.js");
setTimeout(() => {
  body.children[0].listeners.click[0]();
  setTimeout(() => console.log("fired"), 10);
}, 10);
|}

(* The emitter's refusals are checked by name, like the foreign-def
   matrix: the build exit alone would not say which rule fired. *)
let browser_emit_refusal source emit =
  let items, parse_diags =
    Emo_parser.parse_program_with_diagnostics ~file:"main.emo" ~source
  in
  (match parse_diags with [] -> () | _ -> Alcotest.fail "parse errors");
  let diags, _refs, _requires, types =
    Emo_check.check_module_typed ~modules:[] ~current:[] ~target:"browser"
      items
  in
  (match diags with _ :: _ -> Alcotest.fail "unexpected check errors" | [] -> ());
  let program =
    Emo_ir.lower
      {
        Emo_ir.modules =
          [ { Emo_ir.mpath = []; mitems = items; mtypes = types } ];
        entry = [];
        packages = [];
      }
  in
  try
    ignore (emit program);
    None
  with Emo_ir.Lower_error message -> Some message

let browser_tests =
  [
    tc "browser: one bundle with no host imports, run against a page"
      (fun () ->
        if not (Lazy.force node_strip_available) then Alcotest.skip ();
        let entry =
          scratch_entry "browser-page"
            {|const root = dom_root()
const label = dom_text("hello")
dom_append(root, label)
dom_title("Page title")
println("ready")
|}
        in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"browser" entry (Filename.concat dir "app"));
        let bundle = Filename.concat dir "app.js" in
        Alcotest.(check bool) "one bundle" true (Sys.file_exists bundle);
        let text = read_file bundle in
        List.iter
          (fun marker ->
            Alcotest.(check bool)
              ("bundle contains no `" ^ marker ^ "`") false
              (contains text marker))
          [ "require("; "from \"node:"; "process."; "_als" ];
        write_file (Filename.concat dir "run.js") browser_page_harness;
        check_run "browser"
          (run_cmd
             ("node " ^ Filename.quote (Filename.concat dir "run.js")))
          "ready\ntitle=Page title children=hello\n");
    tc "browser: an event reaches the sink with its tag" (fun () ->
        if not (Lazy.force node_strip_available) then Alcotest.skip ();
        let entry =
          scratch_entry "browser-event"
            {|const root = dom_root()
const button = dom_element("button")
dom_set_text(button, "press")
dom_append(root, button)
dom_connect(button, "click", 7)
dom_sink() -> (tag Int64) { println("event ${tag}") }
|}
        in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"browser" entry (Filename.concat dir "app"));
        write_file (Filename.concat dir "run.js") browser_event_harness;
        check_run "browser event"
          (run_cmd
             ("node " ^ Filename.quote (Filename.concat dir "run.js")))
          "event 7\nfired\n");
    tc "browser refuses Node's runtime capabilities by name" (fun () ->
        match
          browser_emit_refusal
            "const x = file_read(\"a\")\nprintln(x)\n"
            Emo_codegen.Ts.emit_browser
        with
        | None -> Alcotest.fail "expected a refusal"
        | Some message ->
            Alcotest.(check bool)
              "names the capability and the target" true
              (contains message
                 "`file_read` runtime implementation is not available on the \
                  browser target"));
    tc "typescript refuses the DOM capabilities by name" (fun () ->
        match
          browser_emit_refusal "const root = dom_root()\n" Emo_codegen.Ts.emit_ts
        with
        | None -> Alcotest.fail "expected a refusal"
        | Some message ->
            Alcotest.(check bool)
              "names the capability and points at the browser target" true
              (contains message
                 "`dom_root` runtime implementation is not available on the \
                  typescript target; build for the browser target"));
    tc "browser refuses a spawned process by name" (fun () ->
        match
          browser_emit_refusal
            {|def worker() {
  println("w")
}
do worker()
|}
            Emo_codegen.Ts.emit_browser
        with
        | None -> Alcotest.fail "expected a refusal"
        | Some message ->
            Alcotest.(check bool)
              "names the construct and the target" true
              (contains message
                 "a spawned process (`do`) is not available on the browser \
                  target"));
  ]

(* ---- test: the `emo test` subcommand (step 46) ---- *)

(* The manifest comes first, so a caller that supplies its own still
   wins. *)
let write_fixture_project name files =
  let dir = Filename.concat scratch name in
  if Sys.file_exists dir then Emo_project.remove_tree dir;
  Unix.mkdir dir 0o755;
  List.iter
    (fun (rel, source) ->
      let path = Filename.concat dir rel in
      let parent = Filename.dirname path in
      if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
      let oc = open_out_bin path in
      output_string oc source;
      close_out oc)
    (("package.emo", default_manifest) :: files);
  dir

let add_main =
  ("main.emo", "def add(a Int64, b Int64) Int64 {\n  return a + b\n}\n")

let test_cmd_tests =
  [
    tc "a passing project exits 0" (fun () ->
        let dir =
          write_fixture_project "test-cmd-pass"
            [
              add_main;
              ( "test/arith.emo",
                "def test_add() {\n  expect_equal(3, main.add(1, 2))\n}\n" );
            ]
        in
        Alcotest.(check int)
          "exit" 0
          (in_dir dir (fun () ->
               Emo_cli.run_tests_cmd ~color:false ~error_limit:20)));
    tc "a failing assertion exits 1" (fun () ->
        let dir =
          write_fixture_project "test-cmd-fail"
            [
              add_main;
              ( "test/arith.emo",
                "def test_add() {\n  expect_equal(4, main.add(1, 2))\n}\n" );
            ]
        in
        Alcotest.(check int)
          "exit" 1
          (in_dir dir (fun () ->
               Emo_cli.run_tests_cmd ~color:false ~error_limit:20)));
    tc "a static error in a test module exits 65" (fun () ->
        let dir =
          write_fixture_project "test-cmd-static"
            [
              add_main;
              ("test/broken.emo", "def test_x() {\n  println(nope)\n}\n");
            ]
        in
        Alcotest.(check int)
          "exit" 65
          (in_dir dir (fun () ->
               Emo_cli.run_tests_cmd ~color:false ~error_limit:20)));
    tc "a project without test/ exits 0" (fun () ->
        let dir = write_fixture_project "test-cmd-none" [ add_main ] in
        Alcotest.(check int)
          "exit" 0
          (in_dir dir (fun () ->
               Emo_cli.run_tests_cmd ~color:false ~error_limit:20)));
    tc "the scaffold's own test passes" (fun () ->
        let dir = Filename.concat scratch "scaffold-tested" in
        if Sys.file_exists dir then Emo_project.remove_tree dir;
        Alcotest.(check int) "scaffold" 0 (Emo_cli.scaffold ~path:dir);
        Alcotest.(check bool)
          "the scaffold ships a test" true
          (Sys.file_exists (Filename.concat dir "test/greet.emo"));
        Alcotest.(check int)
          "emo test" 0
          (in_dir dir (fun () ->
               Emo_cli.run_tests_cmd ~color:false ~error_limit:20)));
  ]

let check_tests =
  [
    tc "a manifest is checked as a manifest, not as a module" (fun () ->
        let dir =
          write_fixture_project "check-manifest"
            [
              ( "package.emo",
                {|package {
  name = "local/demo"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    "float" = "0.1.0"
  }
}|}
              );
            ]
        in
        Alcotest.(check int)
          "exit" 0
          (in_dir dir (fun () ->
               Emo_cli.check_file ~file:"package.emo" ~color:false
                 ~error_limit:20)));
    tc "a malformed manifest reports its manifest error" (fun () ->
        let dir =
          write_fixture_project "check-manifest-bad"
            [
              ( "package.emo",
                {|package {
  name = "local/demo"
  version = "0.1.0"
  targets = ["ocaml"]

  deps {
    float = "0.1.0"
  }
}|}
              );
            ]
        in
        Alcotest.(check int)
          "exit" 65
          (in_dir dir (fun () ->
               Emo_cli.check_file ~file:"package.emo" ~color:false
                 ~error_limit:20)));
  ]

(* ---- manifest as an entry: run and build refuse it (step 11) ---- *)

let manifest_entry_tests =
  let project name =
    write_fixture_project name
      [
        ( "package.emo",
          {|package {
  name = "local/demo"
  version = "0.1.0"
  targets = ["ocaml"]
  deps {}
}|}
        );
        ("main.emo", "println(\"hello\")\n");
      ]
  in
  [
    tc "run refuses a manifest, and runs the module beside it" (fun () ->
        let dir = project "entry-manifest-run" in
        Alcotest.(check int)
          "exit" 66
          (Emo_cli.run_file
             ~file:(Filename.concat dir "package.emo")
             ~color:false ~error_limit:20);
        Alcotest.(check int)
          "exit" 0
          (in_dir dir (fun () ->
               Emo_cli.run_file ~file:"main.emo" ~color:false ~error_limit:20)));
    tc "build refuses a manifest, and builds the module beside it" (fun () ->
        let dir = project "entry-manifest-build" in
        Alcotest.(check int)
          "exit" 66
          (in_dir dir (fun () ->
               Emo_cli.build_file ~entry:"package.emo" ~output:"manifest-entry"
                 ~specialize:false ~cclibs:[]
                 ~native:Emo_project.no_native_inputs ~target:"wasm"));
        Alcotest.(check int)
          "exit" 0
          (in_dir dir (fun () ->
               Emo_cli.build_file ~entry:"main.emo" ~output:"manifest-entry"
                 ~specialize:false ~cclibs:[]
                 ~native:Emo_project.no_native_inputs ~target:"wasm")));
  ]

(* The defects CHECK.md recorded and their fixes: a message sent on
   typescript arrives as a snapshot, an Int64 pattern literal compares as
   a big integer, a `for` loop in a class `init` keeps its value on beam,
   a module-level `var` is refused cleanly where it is not implemented,
   and `ocaml` evaluates operands in source order. *)
let cross_target_tests =
  [
    tc "a message on typescript arrives as a snapshot" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let entry = scratch_entry "cross-ts-send" c_send_snapshot_source in
        let out_ts = Filename.concat (Filename.dirname entry) "main" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"typescript" entry out_ts);
        check_run "typescript"
          (run_cmd ("node " ^ Filename.quote (out_ts ^ ".ts")))
          "1\n99\n");
    tc "typescript compares Int64 case patterns as big integers" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let entry =
          scratch_entry "cross-ts-int64-case"
            {|def bucket(n Int64) Int64 {
  var out = 0
  for var i = 0; i < n; i = i + 1 {
    case i {
      0 -> { out = out + 10 }
      1 -> { out = out + 20 }
      _ -> { out = out + 30 }
    }
  }
  return out
}

def main() {
  println(bucket(3))
}
main()
|}
        in
        let out_ts = Filename.concat (Filename.dirname entry) "main" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"typescript" entry out_ts);
        check_run "typescript"
          (run_cmd ("node " ^ Filename.quote (out_ts ^ ".ts")))
          "60\n");
    tc "a direct builtin net call resolves on typescript" (fun () ->
        if not (Lazy.force node_available) then Alcotest.skip ();
        let entry =
          scratch_entry "cross-ts-net-builtin"
            {|def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("echo: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do serve(listener)
case net_connect("127.0.0.1", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
        in
        let out_ts = Filename.concat (Filename.dirname entry) "main" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"typescript" entry out_ts);
        check_run "typescript"
          (run_cmd ("node " ^ Filename.quote (out_ts ^ ".ts")))
          "echo: hello\ndone\n");
    tc "a for loop in a class init keeps its value on beam" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let entry =
          scratch_entry "beam-init-loop"
            {|class Grid {
  def init(n Int64) {
    self.n = n
    const out = ArrayBuilder.new()
    for var y = 0; y < n; y = y + 1 {
      out.push(y)
    }
    self.rows = Box.new(out.to_array())
  }
}

def main() {
  const g = Grid.new(3)
  println(g.rows.read())
}
main()
|}
        in
        let dir = Filename.dirname entry in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry (Filename.concat dir "app"));
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'app:main(), erlang:halt(0).'"
                (Filename.quote dir)))
          "[0, 1, 2]\n");
    tc "a compiled build leaves the test/ tree out" (fun () ->
        if not (Lazy.force erl_available) then Alcotest.skip ();
        let entry =
          scratch_entry "beam-excludes-tests"
            {|def main() {
  println("built")
}
main()
|}
        in
        let dir = Filename.dirname entry in
        let test_dir = Filename.concat dir "test" in
        if not (Sys.file_exists test_dir) then Unix.mkdir test_dir 0o755;
        write_file
          (Filename.concat test_dir "arithmetic.emo")
          {|def test_add() {
  expect_equal(2, 1 + 1)
}
|};
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"beam" entry (Filename.concat dir "app"));
        check_run "beam"
          (run_cmd
             (Printf.sprintf
                "erl -noshell -pa %s -eval 'app:main(), erlang:halt(0).'"
                (Filename.quote dir)))
          "built\n");
    tc "a module-level var is refused with exit 65, not an internal error"
      (fun () ->
        let entry =
          scratch_entry "module-var-refusal"
            {|def main() {
  println(counter.bump())
}
main()
|}
        in
        write_file
          (Filename.concat (Filename.dirname entry) "counter.emo")
          {|var count = 0

def bump() Int64 {
  count = count + 1
  return count
}
|};
        (* Exit 65 is the CLI's rendering of Lower_error; a `failwith`
           escaping the emitter would exit 125. *)
        List.iter
          (fun target ->
            let out =
              Filename.concat (Filename.dirname entry) ("out-" ^ target)
            in
            Alcotest.(check int)
              (target ^ " build exit") 65
              (build_entry ~target entry out))
          [ "typescript"; "wasm"; "beam" ]);
    tc "ocaml evaluates operands left to right" (fun () ->
        let entry =
          scratch_entry "ocaml-eval-order"
            {|def note(trace Box[String], i Int64) Int64 {
  trace.replace(trace.read() + "${i}")
  return i
}

def two(a Int64, b Int64) Int64 {
  return a + b
}

def main() {
  const trace = Box.new("")
  const sum = two(note(trace, 1), note(trace, 2))
  println("${trace.read()} = ${sum}")
}
main()
|}
        in
        let bin = Filename.concat (Filename.dirname entry) "main-ocaml-bin" in
        Alcotest.(check int)
          "build exit" 0
          (build_entry ~target:"ocaml" entry bin);
        check_run "ocaml" (run_cmd (Filename.quote bin)) "12 = 3\n");
  ]

(* The term package (T48.5): line input and key decoding need no
   terminal to be checked — a pipe carries the bytes and the program
   reads them exactly as it would read a keyboard. Raw mode itself is
   the one terminal-only path; this group pins its refusal off a tty,
   and the mode was exercised over a pty while the package was built. *)
let term_manifest =
  {|package {
  name = "local/term_probe"
  version = "0.1.0"
  targets = ["c"]

  deps {
    "term" = "0.1.0"
  }
}
|}

let term_entry name source =
  let entry = fixture ~manifest:term_manifest (name ^ ".emo") source in
  let bin = Filename.concat (Filename.dirname entry) (name ^ "-c-bin") in
  (entry, bin)

let term_tests =
  let build_term name source =
    let entry, bin = term_entry name source in
    Alcotest.(check int) "build exit" 0 (build_entry ~target:"c" entry bin);
    bin
  in
  let run_with_input bin input =
    let input_path = Filename.concat (Filename.dirname bin) "stdin" in
    write_file input_path input;
    run_cmd
      (Printf.sprintf "%s < %s" (Filename.quote bin)
         (Filename.quote input_path))
  in
  [
    tc "term keeps the line terminator, so an empty line is not end of input"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let bin =
          build_term "term-lines"
            {|require "term"

def show(r (R, String)) {
  case r {
    (R.ok, line) -> { println("ok[${line}]") }
    (R.error, why) -> { println("err[${why}]") }
  }
}

def main() {
  show(term.read_line())
  show(term.read_line())
  show(term.read_line())
  show(term.read_line())
}
main()
|}
        in
        check_run "term lines"
          (run_with_input bin "alpha\n\nbeta")
          "ok[alpha\n]\nok[\n]\nok[beta]\nok[]\n");
    tc "term decodes keys, escape sequences, and UTF-8 from the byte stream"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let bin =
          build_term "term-keys"
            {|require "term"

def name_of(k term.Key) String {
  if k == term.Key.char {
    return "char"
  }
  if k == term.Key.ctrl {
    return "ctrl"
  }
  if k == term.Key.enter {
    return "enter"
  }
  if k == term.Key.tab {
    return "tab"
  }
  if k == term.Key.backspace {
    return "backspace"
  }
  if k == term.Key.escape {
    return "escape"
  }
  if k == term.Key.up {
    return "up"
  }
  if k == term.Key.delete {
    return "delete"
  }
  if k == term.Key.f1 {
    return "f1"
  }
  if k == term.Key.alt {
    return "alt"
  }
  if k == term.Key.eof {
    return "eof"
  }
  return "other"
}

def main() {
  var more = true
  while more {
    const (R.ok, key) = term.read_key()
    println("${name_of(key[0])} ${key[1]}")
    if key[0] == term.Key.eof {
      more = false
    }
  }
}
main()
|}
        in
        check_run "term keys"
          (run_with_input bin
             "a\r\t\127\001\027[A\027[3~\027OP\u{00e9}\027x\027")
          "char 97\n\
           enter 0\n\
           tab 0\n\
           backspace 0\n\
           ctrl 1\n\
           up 0\n\
           delete 0\n\
           f1 0\n\
           char 233\n\
           alt 120\n\
           escape 0\n\
           eof 0\n");
    tc "term reports data failures as values and refuses raw mode off a tty"
      (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let bin =
          build_term "term-errors"
            {|require "term"

def say(label String, r (R, Int64)) {
  case r {
    (R.ok, n) -> { println("${label} ok ${n}") }
    (R.error, why) -> { println("${label} ${why}") }
  }
}

def main() {
  println("tty ${term.is_tty()}")
  say("raw", term.enable_raw())
  say("restore", term.restore())
  case term.size() {
    (R.ok, dims) -> { println("size ${dims[0]}x${dims[1]}") }
    (R.error, why) -> { println("size ${why.starts_with("term: size:")}") }
  }
  const (R.ok, key) = term.read_key()
  println("key ${key[0] == term.Key.eof}")
}
main()
|}
        in
        check_run "term errors" (run_with_input bin "")
          "tty false\n\
           raw term: enable_raw: not a terminal\n\
           restore ok 0\n\
           size true\n\
           key true\n");
  ]

let () =
  Alcotest.run "emo_cli"
    [
      ("smoke", smoke_tests);
      ("run", run_tests);
      ("repl", repl_tests);
      ("examples", examples_tests);
      ("errors_examples", errors_examples_tests);
      ("wasm_examples", wasm_examples_tests);
      ("beam_examples", beam_examples_tests);
      ("beam_naming", beam_naming_tests);
      ("beam_block", beam_block_tests);
      ("beam_var", beam_var_tests);
      ("c_examples", c_examples_tests);
      ("c_tls", c_tls_tests);
      ("root_end", root_end_tests);
      ("wasm_block", wasm_block_tests);
      ("cross_target", cross_target_tests);
      ("c_integer", c_integer_tests);
      ("c_scalar", c_scalar_tests);
      ("c_dynamic", c_dynamic_tests);
      ("c_foreign", c_foreign_tests);
      ("term", term_tests);
      ("c_callback", c_callback_tests);
      ("c_shape", c_shape_tests);
      ("c_recycle", c_recycle_tests);
      ("c_flat_working_set", c_flat_working_set_tests);
      ("riscv64_examples", riscv64_examples_tests);
      ("riscv64_refusal", riscv64_refusal_tests);
      ("foreign", foreign_tests);
      ("specialization", specialization_tests);
      ("publish", publish_tests);
      ("login", login_tests);
      ("http_pull", http_pull_tests);
      ("locked", locked_tests);
      ("deps_add", deps_add_tests);
      ("new", new_tests);
      ("test_cmd", test_cmd_tests);
      ("check", check_tests);
      ("manifest_entry", manifest_entry_tests);
      ("emoji", emoji_tests);
      ("doctor", doctor_tests);
      ("browser", browser_tests);
    ]
