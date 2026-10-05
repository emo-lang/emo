let tc name f = Alcotest.test_case name `Quick f

(* A scratch directory for fixture programs; files persist for the run. *)
let scratch =
  Filename.concat (Filename.get_temp_dir_name ()) "emo-cli-test-fixtures"

let fixture name source =
  if not (Sys.file_exists scratch) then Unix.mkdir scratch 0o755;
  let path = Filename.concat scratch name in
  let oc = open_out_bin path in
  output_string oc source;
  close_out oc;
  path

let run_tests =
  [
    tc "a successful program exits 0" (fun () ->
        let file = fixture "ok.emo" "const x = 1\nprintln(x + 1)\n" in
        Alcotest.(check int)
          "exit" 0
          (Emo_cli.run_file ~file ~color:false ~error_limit:20));
    tc "a parse error exits 65" (fun () ->
        let file = fixture "parse.emo" "const x =\n1\n" in
        Alcotest.(check int)
          "exit" 65
          (Emo_cli.run_file ~file ~color:false ~error_limit:20));
    tc "a runtime type error exits 70" (fun () ->
        (* The element type is Unknown to the checker; the runtime hits it. *)
        let file = fixture "runtime.emo" {|println([1, "a"][1] + 1)|} in
        Alcotest.(check int)
          "exit" 70
          (Emo_cli.run_file ~file ~color:false ~error_limit:20));
    tc "a certain type error exits 65 before running" (fun () ->
        let file = fixture "checked.emo" {|println(1 + "a")|} in
        Alcotest.(check int)
          "exit" 65
          (Emo_cli.run_file ~file ~color:false ~error_limit:20));
    tc "an uncaught exception exits 1" (fun () ->
        let file = fixture "raise.emo" {|raise "boom"|} in
        Alcotest.(check int)
          "exit" 1
          (Emo_cli.run_file ~file ~color:false ~error_limit:20));
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
                 "def double(n Int) Int {";
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
          ~input:(queue_input [ {|raise "boom"|}; "2 * 3"; "exit" ])
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

(* A directory with its own package.emo is a package project — it runs
   through resolution and the scheduler in test/emo_project, not here. *)
let example_names () =
  Sys.readdir examples_dir |> Array.to_list |> List.sort compare
  |> List.filter (fun name ->
      Sys.file_exists (Filename.concat examples_dir (name ^ "/main.emo"))
      && not
           (Sys.file_exists
              (Filename.concat examples_dir (name ^ "/package.emo"))))

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

(* The WasmGC goldens: compile each subset example with --target wasm
   and run it under Node's WasmGC, byte-for-byte against expected.txt.
   Skips when Node is absent — the runtime is the only WasmGC
   validator in the toolchain (T16.1, T16.2). *)
let wasm_goldens =
  [
    "hello_world";
    "fib";
    "objects";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
  ]

let node_available = lazy (Sys.command "node --version >/dev/null 2>&1" = 0)

(* The BEAM goldens: Core Erlang text assembled by the pinned erlc,
   run under `erl -noshell`. Skips when Erlang is absent. *)
let beam_goldens =
  [
    "hello_world";
    "fib";
    "objects";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
  ]

let erl_available =
  lazy (Sys.command "erl -noshell -eval 'halt().' >/dev/null 2>&1" = 0)

let beam_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to beam and runs on erl" name) (fun () ->
          if not (Lazy.force erl_available) then Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out_core =
            Filename.concat scratch (name ^ "-beam-emo_main.core")
          in
          let exit_code =
            Emo_cli.build_file
              ~entry:(Filename.concat dir "main.emo")
              ~output:out_core ~specialize:false ~cclibs:[] ~target:"beam"
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let cmd =
            Printf.sprintf
              "erl -noshell -pa %s -eval 'emo_main:main(), erlang:halt(0).'"
              (Filename.quote (Filename.dirname out_core))
          in
          let cmd_stdout, _cmd_stdin, cmd_stderr =
            Unix.open_process_full cmd (Unix.environment ())
          in
          let out = Buffer.create 256 in
          (try
             while true do
               Buffer.add_channel out cmd_stdout 4096
             done
           with End_of_file -> ());
          let err = Buffer.create 256 in
          (try
             while true do
               Buffer.add_channel err cmd_stderr 4096
             done
           with End_of_file -> ());
          let proc_status =
            Unix.close_process_full (cmd_stdout, _cmd_stdin, cmd_stderr)
          in
          Alcotest.(check string) "output" expected (Buffer.contents out);
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "erl exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   (Buffer.contents err))))
    beam_goldens

(* The host boundary: println forwards to stdout, abort exits nonzero
   with the message, float_str renders into the scratch area at
   60000 (matching the runtime's convention). *)
let wasm_runner_source =
  {|
import { readFile } from "node:fs/promises";
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
    const encoded = new TextEncoder().encode(String(f));
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
            Emo_cli.build_file
              ~entry:(Filename.concat dir "main.emo")
              ~output:out_wasm ~specialize:false ~cclibs:[] ~target:"wasm"
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let cmd_stdout, _cmd_stdin, cmd_stderr =
            Unix.open_process_full
              (Printf.sprintf "node %s %s"
                 (Filename.quote (Lazy.force wasm_runner_path))
                 (Filename.quote out_wasm))
              (Unix.environment ())
          in
          let out = Buffer.create 256 in
          (try
             while true do
               Buffer.add_channel out cmd_stdout 4096
             done
           with End_of_file -> ());
          let err = Buffer.create 256 in
          (try
             while true do
               Buffer.add_channel err cmd_stderr 4096
             done
           with End_of_file -> ());
          let proc_status =
            Unix.close_process_full (cmd_stdout, _cmd_stdin, cmd_stderr)
          in
          Alcotest.(check string) "output" expected (Buffer.contents out);
          match proc_status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "node exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   (Buffer.contents err))))
    wasm_goldens

let () =
  Alcotest.run "emo_cli"
    [
      ("smoke", smoke_tests);
      ("run", run_tests);
      ("repl", repl_tests);
      ("examples", examples_tests);
      ("wasm_examples", wasm_examples_tests);
      ("beam_examples", beam_examples_tests);
    ]
