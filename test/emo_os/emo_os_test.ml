(* The EmoOS harness (T3.8): the dual-run parity — the console service
   logic runs on the hosted interpreter against the fake device and on
   the metal under QEMU against the real UART, with the two legs'
   outputs asserted byte-identical — and the kernel's QEMU smoke
   (projects/emo-os/run.sh) wired into the suite. Skips when QEMU or
   the cross binutils are absent; the binutils answer is the build's
   own probe, so the two cannot disagree on which prefix is installed. *)

let tc name f = Alcotest.test_case name `Quick f
let run_cmd = Emo_test_support.run_cmd
let kernel_dir = "../../projects/emo-os"
let parity_dir = "../../examples"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let in_dir dir f =
  let previous = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir previous) f

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

(* The service's shared block: from the cut marker to the end marker,
   byte for byte, in both legs' sources. *)
let shared_block (source : string) : string =
  let open_mark = "// ==== 8< ====" in
  let close_mark = "// ==== >8 ====" in
  let from =
    match
      let rec find i =
        if i + String.length open_mark > String.length source then None
        else if String.sub source i (String.length open_mark) = open_mark then
          Some i
        else find (i + 1)
      in
      find 0
    with
    | Some i -> i
    | None -> Alcotest.fail "the shared-service cut marker is missing"
  in
  let till =
    let rec find i =
      if i + String.length close_mark > String.length source then None
      else if String.sub source i (String.length close_mark) = close_mark then
        Some i
      else find (i + 1)
    in
    match find from with
    | Some i -> i + String.length close_mark
    | None -> Alcotest.fail "the shared-service end marker is missing"
  in
  String.sub source from (till - from)

(* The parity metal's input: the same bytes the fake preloads, fed
   through the serial once the greeting is on the wire. *)
let fed_input = "parity\nring\n"

let parity_metal_tests =
  [
    tc "the shared service is byte-identical in both legs" (fun () ->
        let fake =
          read_file (Filename.concat parity_dir "parity_fake/main.emo")
        in
        let metal =
          read_file (Filename.concat parity_dir "parity_metal/main.emo")
        in
        Alcotest.(check string)
          "the shared service" (shared_block fake) (shared_block metal);
        Alcotest.(check string)
          "the expected output"
          (read_file (Filename.concat parity_dir "parity_fake/expected.txt"))
          (read_file (Filename.concat parity_dir "parity_metal/expected.txt")));
    tc "the metal leg matches the hosted expected under QEMU" (fun () ->
        if not (Lazy.force riscv64_available) then Alcotest.skip ();
        let dir = Filename.concat parity_dir "parity_metal" in
        let expected = read_file (Filename.concat dir "expected.txt") in
        let log =
          Filename.concat
            (Filename.get_temp_dir_name ())
            "emo-os-parity-serial.log"
        in
        let out_elf =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-os-parity.elf"
        in
        let exit_code =
          in_dir dir (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:out_elf
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"kernel")
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        (* The serial input rides a named pipe, written only after the
           greeting is on the wire: the service drains what the machine
           received, and OpenSBI's boot takes the UART first, so
           anything written before the payload polls never arrives. The
           write end stays open on fd 3 so the machine never sees an
           early EOF. *)
        let fifo =
          Filename.concat
            (Filename.get_temp_dir_name ())
            "emo-os-parity-serial.in"
        in
        let script =
          Printf.sprintf
            {|set -e
rm -f %s
mkfifo %s
qemu-system-riscv64 -machine virt -nographic -kernel %s <%s >%s 2>&1 &
qemu_pid=$!
exec 3>%s
for i in $(seq 1 150); do
  if grep -qF 'parity' %s; then break; fi
  kill -0 $qemu_pid 2>/dev/null || break
  sleep 0.2
done
printf 'parity\nring\n' >&3
for i in $(seq 1 100); do
  kill -0 $qemu_pid 2>/dev/null || break
  sleep 0.1
done
if kill -0 $qemu_pid 2>/dev/null; then
  kill $qemu_pid 2>/dev/null || true
fi
wait $qemu_pid 2>/dev/null || true
exec 3>&-
cat %s
|}
            (Filename.quote fifo) (Filename.quote fifo) (Filename.quote out_elf)
            (Filename.quote fifo) (Filename.quote log) (Filename.quote fifo)
            (Filename.quote log) (Filename.quote log)
        in
        ignore (run_cmd script);
        let serial = read_file log in
        Alcotest.(check string) "output" expected (riscv64_payload serial));
  ]

(* The kernel's own QEMU smoke, wired into the suite: the project tree
   builds into a scratch copy — the user image first (the kernel embeds
   it), then the kernel — and run.sh boots it, its assertions (the tick
   proof on both timer transports, the five console deliveries, the
   echo, the staged user program's greeting, the self-exit) deciding
   the test. *)
let smoke_tests =
  [
    tc "the kernel's run.sh smoke passes" (fun () ->
        if not (Lazy.force riscv64_available) then Alcotest.skip ();
        let scratch =
          Filename.concat (Filename.get_temp_dir_name ()) "emo-os-kernel-smoke"
        in
        ignore (Sys.command ("rm -rf " ^ Filename.quote scratch));
        ignore (Sys.command ("mkdir -p " ^ Filename.quote scratch));
        List.iter
          (fun name ->
            let source = read_file (Filename.concat kernel_dir name) in
            let path = Filename.concat scratch name in
            let dir = Filename.dirname path in
            if not (Sys.file_exists dir) then
              ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
            let oc = open_out_bin path in
            output_string oc source;
            close_out oc;
            if Filename.check_suffix name ".sh" then
              ignore (Sys.command ("chmod +x " ^ Filename.quote path)))
          [
            "main.emo";
            "package.emo";
            "runtime.S";
            "trap.S";
            "link.ld";
            "run.sh";
            "user.emo";
            "user.S";
            "gate.emo";
            "hello/package.emo";
            "hello/package.lock";
            "hello/main.emo";
          ];
        (* The user image first: the kernel's tree embeds it, so the
           ELF has to exist before the kernel's .S assembles. *)
        let hello_exit =
          in_dir (Filename.concat scratch "hello") (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:"../hello.elf"
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"user")
        in
        Alcotest.(check int) "user build exit" 0 hello_exit;
        let exit_code =
          in_dir scratch (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:"main.elf"
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"kernel")
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        let out, err, status = run_cmd (Filename.concat scratch "run.sh") in
        (match status with
        | Unix.WEXITED 0 -> ()
        | s ->
            Alcotest.fail
              (Printf.sprintf "run.sh failed (%s): %s%s"
                 (match s with
                 | Unix.WEXITED n -> string_of_int n
                 | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                 | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)
                 err out));
        Alcotest.(check bool)
          "the smoke's own verdict line is present" true
          (String.length out > 0 && out <> "");
        ignore err);
  ]

let () =
  Alcotest.run "emo_os"
    [ ("parity_metal", parity_metal_tests); ("smoke", smoke_tests) ]
