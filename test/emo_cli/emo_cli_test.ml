let tc name f = Alcotest.test_case name `Quick f

let contains hay needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length hay && (String.sub hay i n = needle || go (i + 1))
  in
  go 0

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
    "if_expr";
    "fib";
    "objects";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
    "bit_ops";
    "fixed_width";
  ]

let node_available = lazy (Sys.command "node --version >/dev/null 2>&1" = 0)

(* The BEAM goldens: Core Erlang text assembled by the pinned erlc,
   run under `erl -noshell`. Skips when Erlang is absent. *)
let beam_goldens =
  [
    "hello_world";
    "if_expr";
    "fib";
    "objects";
    "language_tour";
    "shop";
    "pipeline";
    "function_group";
    "showcase";
    "bit_ops";
    "fixed_width";
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

(* The C goldens: build with --target c through the system cc and run
   the standalone binary, byte-for-byte against expected.txt. Skips
   when cc is absent. The list names the backend's current support
   set; it grows task by task (T24.1: hello_world, T24.3: if_expr,
   T24.5: objects, language_tour — classes, interfaces, enums, case
   with guards, closures, and array append; T24.6: shop, function_group
   — multi-file modules, the internal/ subtree, const aliases, and
   `emo` groups; T24.7: bit_ops, bytes, fixed_width — the bitwise
   operators, Bytes with little-endian accessors, and Byte with
   explicit conversions; T24.9: pipeline, showcase — processes
   (do / <- / receive) on the cooperative fiber scheduler; T24.10:
   file_read, tcp_echo, http_roundtrip — hosted file and socket IO
   with the stdlib resolving for the c target). The full fib and
   numerics examples join when foreign defs land (T24.8) — their
   c_scalar / c_integer fixtures cover the same semantics. *)
let c_goldens =
  [
    "hello_world";
    "if_expr";
    "objects";
    "language_tour";
    "shop";
    "function_group";
    "bit_ops";
    "bytes";
    "fixed_width";
    "pipeline";
    "showcase";
    "file_read";
    "tcp_echo";
    "http_roundtrip";
  ]

let cc_available = lazy (Sys.command "cc --version >/dev/null 2>&1" = 0)

(* T24.2's integer core: fib's plain recursion, the 1M-deep tail
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
        (* its own directory: a build compiles every sibling .emo *)
        let dir = Filename.concat scratch "c-int-core" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc c_integer_core_source;
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false ~cclibs:[]
            ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd =
          Printf.sprintf "sh -c 'ulimit -s 1024; exec %s'"
            (Filename.quote out_bin)
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
        Alcotest.(check string)
          "output" c_integer_core_expected (Buffer.contents out);
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 (Buffer.contents err)));
  ]

(* T24.3's scalar runtime: Float64 rendering across the %g boundary
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
        let dir = Filename.concat scratch "c-scalar" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc c_scalar_core_source;
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false ~cclibs:[]
            ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        Unix.putenv "EMO_FFI_PROBE" "hello ffi";
        let cmd_stdout, _cmd_stdin, cmd_stderr =
          Unix.open_process_full (Filename.quote out_bin) (Unix.environment ())
        in
        let out = Buffer.create 512 in
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
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 (Buffer.contents err)));
  ]

(* T24.4's dynamic value model: the tagged word crossing native and
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

let c_dynamic_tests =
  [
    tc "an uncaught raise exits 1 with the interpreter's message" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-raise" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc {|raise "boom"
println("not reached")
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false ~cclibs:[]
            ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd_stdout, _cmd_stdin, cmd_stderr =
          Unix.open_process_full (Filename.quote out_bin) (Unix.environment ())
        in
        let err = Buffer.create 256 in
        (try
           while true do
             Buffer.add_channel err cmd_stderr 4096
           done
         with End_of_file -> ());
        let proc_status =
          Unix.close_process_full (cmd_stdout, _cmd_stdin, cmd_stderr)
        in
        Alcotest.(check bool)
          "message" true
          (contains (Buffer.contents err) "uncaught exception: boom");
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
        let dir = Filename.concat scratch "c-dynamic" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc c_dynamic_core_source;
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false ~cclibs:[]
            ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd_stdout, _cmd_stdin, cmd_stderr =
          Unix.open_process_full (Filename.quote out_bin) (Unix.environment ())
        in
        let out = Buffer.create 512 in
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
              (Printf.sprintf "the binary exited %s: %s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 (Buffer.contents err)));
  ]

let c_examples_tests =
  List.map
    (fun name ->
      tc (Printf.sprintf "%s compiles to c and runs standalone" name) (fun () ->
          if not (Lazy.force cc_available) then Alcotest.skip ();
          let dir = Filename.concat examples_dir name in
          let expected = read_file (Filename.concat dir "expected.txt") in
          let out_bin = Filename.concat scratch (name ^ "-c-bin") in
          let exit_code =
            Emo_cli.build_file
              ~entry:(Filename.concat dir "main.emo")
              ~output:out_bin ~specialize:false ~cclibs:[] ~target:"c"
          in
          Alcotest.(check int) "build exit" 0 exit_code;
          let cmd_stdout, _cmd_stdin, cmd_stderr =
            Unix.open_process_full (Filename.quote out_bin)
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
                (Printf.sprintf "the binary exited %s: %s"
                   (match s with
                   | Unix.WEXITED n -> string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                   (Buffer.contents err))))
    c_goldens

(* T24.8: the c target's direct C ABI. A foreign def declares the C
   symbol and calls it — no wrapper generator. Strings cross with a
   NUL terminator; opaque handles ride pointer-sized Int64s behind a
   tiny library compiled into the scratch dir. Skips without cc. *)
let c_foreign_tests =
  [
    tc "the c target links foreign defs through the direct C ABI" (fun () ->
        if not (Lazy.force cc_available) then Alcotest.skip ();
        let dir = Filename.concat scratch "c-ffi" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|
foreign def sqrt(x Float64) Float64 = "sqrt"
foreign def llabs(x Int64) Int64 = "llabs"
foreign def getenv(name String) String = "getenv"
foreign def strspn(s String, accept String) Int64 = "strspn"

println(sqrt(4.0))
println(llabs(0 - 42))
const probed = getenv("EMO_FFI_PROBE")
println(probed)
println(strspn(probed, "hello"))
|};
        close_out oc;
        let out_bin = Filename.concat dir "main-c-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false
            ~cclibs:[ "m" ] ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd_stdout, _cmd_stdin, cmd_stderr =
          Unix.open_process_full (Filename.quote out_bin) (Unix.environment ())
        in
        let out = Buffer.create 256 in
        (try
           while true do
             Buffer.add_channel out cmd_stdout 4096
           done
         with End_of_file -> ());
        let proc_status =
          Unix.close_process_full (cmd_stdout, _cmd_stdin, cmd_stderr)
        in
        Alcotest.(check string)
          "output" "2.0\n42\nhello ffi\n5\n" (Buffer.contents out);
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
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false
            ~cclibs:[ lib_a ] ~target:"c"
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let cmd_stdout, _cmd_stdin, cmd_stderr =
          Unix.open_process_full (Filename.quote out_bin) (Unix.environment ())
        in
        let out = Buffer.create 256 in
        (try
           while true do
             Buffer.add_channel out cmd_stdout 4096
           done
         with End_of_file -> ());
        let proc_status =
          Unix.close_process_full (cmd_stdout, _cmd_stdin, cmd_stderr)
        in
        Alcotest.(check string) "output" "42\n42\n" (Buffer.contents out);
        match proc_status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "exited %d"
                 (match s with Unix.WEXITED n -> n | _ -> -1)));
    tc "the native target still refuses Int64 foreign defs" (fun () ->
        let dir = Filename.concat scratch "c-ffi-refuse" in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let entry = Filename.concat dir "main.emo" in
        let oc = open_out_bin entry in
        output_string oc
          {|foreign def ident(x Int64) Int64 = "ident"
println(ident(1))
|};
        close_out oc;
        let out_bin = Filename.concat dir "native-bin" in
        let exit_code =
          Emo_cli.build_file ~entry ~output:out_bin ~specialize:false ~cclibs:[]
            ~target:"ocaml"
        in
        Alcotest.(check int) "refused" 65 exit_code);
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
    match Unix.select [ srv ] [] [] 10.0 with
    | [], _, _ -> () (* the client never connected; the test failed earlier *)
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
  ]

let () =
  Alcotest.run "emo_cli"
    [
      ("smoke", smoke_tests);
      ("run", run_tests);
      ("repl", repl_tests);
      ("examples", examples_tests);
      ("wasm_examples", wasm_examples_tests);
      ("beam_examples", beam_examples_tests);
      ("c_examples", c_examples_tests);
      ("c_integer", c_integer_tests);
      ("c_scalar", c_scalar_tests);
      ("c_dynamic", c_dynamic_tests);
      ("c_foreign", c_foreign_tests);
      ("publish", publish_tests);
    ]
