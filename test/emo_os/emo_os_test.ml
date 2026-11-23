(* The EmoOS harness (T3.8): the dual-run parity — the console service
   logic runs on the hosted interpreter against the fake device and on
   the metal under QEMU against the real UART, with the two legs'
   outputs asserted byte-identical — and the kernel's QEMU smoke
   (projects/emo-os/run.sh) wired into the suite. Skips when QEMU or
   the cross binutils are absent; the binutils answer is the build's
   own probe, so the two cannot disagree on which prefix is installed.
   The suite rides the @emo_os alias, not @runtest, so plain
   `dune runtest` stays free of the QEMU legs; run it with
   `dune build @emo_os`. *)

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

(* The C door (EmoOS plan B, M0): the kernel's smoke builds the C app
   before the kernel embeds it, so the suite needs a cross C compiler
   beside the binutils. EMO_CC names it, the build script's own
   variable; riscv64-elf-gcc is the default. *)
let emos_c_compiler =
  match Sys.getenv_opt "EMO_CC" with Some c -> c | None -> "riscv64-elf-gcc"

let c_compiler_available =
  lazy (Sys.command (emos_c_compiler ^ " --version >/dev/null 2>&1") = 0)

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
                ~profile:"kernel" ~wasi:false)
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
   it), then the kernel — and run.sh boots it, its assertions (the Sv39
   line — the kernel paged on the table it built — the tick proof on
   both timer transports, the five console deliveries, the echo, the
   staged user program's greeting, the frame allocator's account, the
   self-exit) deciding the test. *)
let smoke_tests =
  [
    tc "the kernel's run.sh smoke passes" (fun () ->
        if
          not (Lazy.force riscv64_available && Lazy.force c_compiler_available)
        then Alcotest.skip ();
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
            "notify.emo";
            "frames.emo";
            "sv39.emo";
            "sv39.S";
            "space.emo";
            "fs.emo";
            "exec.emo";
            "hello/package.emo";
            "hello/package.lock";
            "hello/main.emo";
            "hello/shell.emo";
            "hello/console_ui.emo";
            "c/crt0.s";
            "c/emo_syscall.h";
            "c/emo_posix.c";
            "c/emo_posix.h";
            "c/hello.c";
            "c/chello.ld";
            "c/build.sh";
          ];
        (* The apps' programs (emo-desktop A11.1, T8.21 added the
           spinner): each its own build root in the scratch tree — the
           boot image execs them by name, the kernel embeds the four
           ELFs. *)
        let apps_dir = "../../projects/emo-desktop/fb/apps" in
        List.iter
          (fun app ->
            List.iter
              (fun name ->
                let source =
                  read_file
                    (Filename.concat (Filename.concat apps_dir app) name)
                in
                let path = Filename.concat (Filename.concat scratch app) name in
                let dir = Filename.dirname path in
                if not (Sys.file_exists dir) then
                  ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
                let oc = open_out_bin path in
                output_string oc source;
                close_out oc)
              [ "package.emo"; "main.emo" ])
          [ "counter"; "files"; "editor"; "spin" ];
        (* The user image requires the desktop's packages beside the
           syscall stub (emo-desktop A7.2): EmoUI's core, the fb
           backend's core with its rasterizer and the two faces' outlines
           (A17.1–A17.4, the bitmap font's successors) and pointer sprite
           (A8.2), the first frame with the counter the screen pass
           runs through the Elm loop (A8.3), the window shell's
           windows (A9.1), the desktop shell's dock (A10.2), the apps'
           corpus (A10.3) and the window buffer's metal side (A11.1).
           They are staged into a
           registry in the scratch tree — the files start.sh stages,
           from the same trees — and the build reads it through
           EMO_REGISTRY, which names the one registry a build resolves
           from, so the stub is staged beside them. The kernel's own
           package has no dependencies, so the setting is nothing to
           its build. *)
        let registry = Filename.concat scratch "registry" in
        List.iter
          (fun (src, dst, names) ->
            let dir = Filename.concat registry dst in
            ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
            List.iter
              (fun name ->
                (match Filename.dirname name with
                | "." | "" -> ()
                | sub ->
                    ignore
                      (Sys.command
                         (Printf.sprintf "mkdir -p %s"
                            (Filename.quote (Filename.concat dir sub)))));
                let source = read_file (Filename.concat src name) in
                let oc = open_out_bin (Filename.concat dir name) in
                output_string oc source;
                close_out oc)
              names)
          [
            ( "../../stdlib/registry/syscall/0.1.0",
              "syscall/0.1.0",
              [ "package.emo"; "syscall.emo" ] );
            ( "../../stdlib/registry/hash/0.1.0",
              "hash/0.1.0",
              [
                "package.emo";
                "hash.emo";
                "sha2.emo";
                "internal/sha256.emo";
                "internal/word.emo";
                "internal/sha512.emo";
              ] );
            ( "../../projects/emo-ui",
              "emo/ui/0.1.0",
              [ "package.emo"; "ui.emo"; "debug.emo" ] );
            ( "../../projects/emo-desktop/fb",
              "emo/ui_fb/0.1.0",
              [
                "package.emo";
                "ui_fb.emo";
                "raster.emo";
                "face_inter.emo";
                "face_mono.emo";
                "pointer.emo";
              ] );
            ( "../../projects/emo-desktop/fb/frame",
              "emo/ui_fb_frame/0.1.0",
              [ "package.emo"; "ui_fb_frame.emo"; "counter.emo" ] );
            ( "../../projects/emo-desktop/fb/win",
              "emo/ui_fb_win/0.1.0",
              [ "package.emo"; "ui_fb_win.emo" ] );
            ( "../../projects/emo-desktop/fb/desktop",
              "emo_desktop/0.1.0",
              [
                "package.emo";
                "emo_desktop.emo";
                "emo_icons.emo";
                "emo_motion.emo";
              ] );
            ( "../../projects/emo-desktop/fb/apps",
              "emo/ui_apps/0.1.0",
              [
                "package.emo";
                "ui_apps.emo";
                "counter.emo";
                "files.emo";
                "editor.emo";
              ] );
            ( "../../projects/emo-desktop/fb/winbuf",
              "emo/ui_fb_winbuf/0.1.0",
              [ "package.emo"; "ui_fb_winbuf.emo" ] );
            ( "../../projects/emo-desktop/fb/notify",
              "emo_notify/0.1.0",
              [ "package.emo"; "emo_notify.emo" ] );
          ];
        Unix.putenv "EMO_REGISTRY" registry;
        (* The user image first: the kernel's tree embeds it, so the
           ELF has to exist before the kernel's .S assembles. The four
           apps' images (emo-desktop A11.1, T8.21 the spinner's) ride
           beside it — the boot image execs them by name, the kernel
           embeds them. *)
        let hello_exit =
          in_dir (Filename.concat scratch "hello") (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:"../hello.elf"
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"user" ~wasi:false)
        in
        Alcotest.(check int) "user build exit" 0 hello_exit;
        let app_build name =
          let exit_code =
            in_dir (Filename.concat scratch name) (fun () ->
                (* The app profile (emo-desktop A12.1): the disk ELF's
                   smaller heap, the image run's span off the allocator's
                   back. *)
                Emo_cli.build_file ~entry:"main.emo"
                  ~output:(Filename.concat scratch (name ^ ".elf"))
                  ~specialize:false ~cclibs:[]
                  ~native:Emo_project.no_native_inputs ~target:"riscv64"
                  ~profile:"app" ~wasi:false)
          in
          Alcotest.(check int) (name ^ " build exit") 0 exit_code
        in
        app_build "counter";
        app_build "files";
        app_build "editor";
        app_build "spin";
        (* The C door (EmoOS plan B, M0): the cross compiler builds
           chello.elf in the scratch tree before the kernel embeds it —
           the same script start.sh runs, so the two builds cannot
           disagree on the contract. *)
        let c_exit =
          Sys.command
            (Printf.sprintf "bash %s"
               (Filename.quote (Filename.concat scratch "c/build.sh")))
        in
        Alcotest.(check int) "the C app build exit" 0 c_exit;
        (* The wallpaper's bytes (emo-desktop M31, A31.1): user.S embeds
           the volume's art the assembler reads beside the sources — the
           fixture mints it the way start.sh does, from the generator
           the desktop package ships. *)
        ignore
          (Sys.command
             (Printf.sprintf "python3 %s --out %s"
                (Filename.quote
                   "../../projects/emo-desktop/fb/desktop/gen-wallpaper.py")
                (Filename.quote (Filename.concat scratch "wallpaper.rle"))));
        let exit_code =
          in_dir scratch (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:"main.elf"
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"kernel" ~wasi:false)
        in
        Alcotest.(check int) "build exit" 0 exit_code;
        (* The corpus leg (emo-desktop A7.3, A8.3): run.sh asserts the
           loop's four frame digests out of the fb frame golden's
           `expected.txt` — the file the fb gate pins across every
           hosted target, the first line the first frame's — and the
           scratch tree carries no fb tree, so the run is pointed at
           the repository's file, absolute because run.sh changes into
           its own directory first. *)
        let frame_expected =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/frame/golden/expected.txt"
        in
        Alcotest.(check bool)
          "the first frame's corpus file is in the tree" true
          (Sys.file_exists frame_expected);
        (* The pointer's drawing (emo-desktop A8.2): run.sh's model of
           the display composites the sprite out of `pointer.emo`'s
           rows — the same file the user image writes into the carve —
           and is pointed at the repository's the same way. *)
        let pointer_sprite =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/pointer.emo"
        in
        Alcotest.(check bool)
          "the pointer sprite's drawing is in the tree" true
          (Sys.file_exists pointer_sprite);
        (* The window shell's twin (emo-desktop A9.1): run.sh asserts
           the shell pass's nine frame digests out of the fb window
           golden's `expected.txt` and folds the display's windows to
           its lines — pointed at the repository's file the same way. *)
        let win_expected =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/win/golden/expected.txt"
        in
        Alcotest.(check bool)
          "the window shell's corpus file is in the tree" true
          (Sys.file_exists win_expected);
        (* The desktop shell's dock (emo-desktop A10.2): run.sh asserts
           the strip's three state digests out of the dock golden's
           `expected.txt` and folds the display's strip to its lines —
           pointed at the repository's file the same way. *)
        let dock_expected =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/desktop/golden/expected.txt"
        in
        Alcotest.(check bool)
          "the dock's corpus file is in the tree" true
          (Sys.file_exists dock_expected);
        (* The first apps' twin (emo-desktop A10.3): run.sh asserts the
           three sessions' ten frame digests out of the apps golden's
           `expected.txt` and folds each app's rectangle to its lines —
           pointed at the repository's file the same way. *)
        let apps_expected =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/apps/golden/expected.txt"
        in
        Alcotest.(check bool)
          "the apps' corpus file is in the tree" true
          (Sys.file_exists apps_expected);
        (* The type's rasterizer (emo-desktop A17.4, the bitmap font's
           successor): run.sh's model of the display inks the header's
           wordmark and the icons' names through `glyphs/reference.py` —
           the reference the strikes' raster pins are checked against —
           and is pointed at the repository's directory the same way. *)
        let glyphs_dir =
          Filename.concat (Sys.getcwd ()) "../../projects/emo-desktop/fb/glyphs"
        in
        Alcotest.(check bool)
          "the type's rasterizer is in the tree" true
          (Sys.file_exists (Filename.concat glyphs_dir "reference.py"));
        (* The notification center's surfaces (emo-desktop M25): run.sh
           asserts the center's four frame digests out of its golden and
           folds each panel's rectangle to its lines — pointed at the
           repository's file the same way. *)
        let notify_expected =
          Filename.concat (Sys.getcwd ())
            "../../projects/emo-desktop/fb/notify/golden/expected.txt"
        in
        Alcotest.(check bool)
          "the notification center's corpus file is in the tree" true
          (Sys.file_exists notify_expected);
        (* The budget (2026-11-11, re-read 2026-11-20): one run is two
           boots, each a whole session — the spinner's loop alone
           measured 170 s a boot when its bytes straddle a page boundary
           under TCG, 18 s when they do not — and the choreography has
           grown since (M24–M32's beats), the whole run now measured
           past twenty-five minutes; the budget holds the measured
           reality with room, the deadline still the hung runner's kill. *)
        let out, err, status =
          run_cmd ~timeout:2400.0
            (Printf.sprintf
               "FRAME_EXPECTED=%s POINTER_SPRITE=%s WIN_EXPECTED=%s \
                DOCK_EXPECTED=%s APPS_EXPECTED=%s GLYPHS_DIR=%s \
                NOTIFY_EXPECTED=%s %s"
               (Filename.quote frame_expected)
               (Filename.quote pointer_sprite)
               (Filename.quote win_expected)
               (Filename.quote dock_expected)
               (Filename.quote apps_expected)
               (Filename.quote glyphs_dir)
               (Filename.quote notify_expected)
               (Filename.quote (Filename.concat scratch "run.sh")))
        in
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

(* ---- the GC heap's metal golden (step 91, M52) ----

   The GC demo's 24 gold lines (examples/gc_demo/expected.txt) walk
   the kernel's metal: the demo package builds for the riscv64 user
   profile from the compiler's own registry, the scratch kernel embeds
   the image as its user program (user.S's incbin, the four desktop
   apps riding beside it), and the boot's proof chain — the checksum
   line the kernel prints, the five bytes the boot reads — hands the
   machine to the demo, whose lines come through the gate. Three boots
   compare against expected.txt byte for byte. The parity case pins
   the metal demo's source to the gc demo's own, so the interpreter,
   the c host and the metal answer the same program. The scratch trees
   live under a fresh timestamped directory per run: no cleanup, no
   stale build caches — the tree's own `.emo-build` cache carries no
   compiler hash, so a reused tree could answer from a stale one. *)

let gc_examples_dir = "../../examples"

(* The demo's gold: the 24 lines from the demo's first line on — the
   kernel's own boot lines ride before it and the REPL's prompt after,
   and neither may interleave. The serial stream's CRLF renders back
   where the SBI console added it. *)
let gc_gold (serial : string) : string option =
  let strip_cr s =
    let n = String.length s in
    if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
  in
  let lines = Array.of_list (String.split_on_char '\n' serial) in
  let n = Array.length lines in
  let rec first i =
    if i >= n then None
    else if String.starts_with ~prefix:"heap words with garbage" lines.(i) then
      Some i
    else first (i + 1)
  in
  match first 0 with
  | None -> None
  | Some from when n - from >= 24 ->
      Some
        (String.concat "\n" (List.init 24 (fun k -> strip_cr lines.(from + k)))
        ^ "\n")
  | Some _ -> None

let gc_metal_tests =
  [
    tc "the metal demo is the gc demo's own source" (fun () ->
        Alcotest.(check string)
          "the demo's source"
          (read_file (Filename.concat gc_examples_dir "gc_demo/main.emo"))
          (read_file (Filename.concat gc_examples_dir "gc_metal/main.emo")));
    tc "the demo's 24 gold lines walk the kernel's metal" (fun () ->
        if
          not (Lazy.force riscv64_available && Lazy.force c_compiler_available)
        then Alcotest.skip ();
        let expected =
          read_file (Filename.concat gc_examples_dir "gc_demo/expected.txt")
        in
        let root =
          Filename.concat
            (Filename.get_temp_dir_name ())
            (Printf.sprintf "emo-gc-metal-%d"
               (int_of_float (Unix.gettimeofday ())))
        in
        let demo_dir = Filename.concat root "demo" in
        let kernel = Filename.concat root "kernel" in
        ignore (Sys.command ("mkdir -p " ^ Filename.quote demo_dir));
        ignore (Sys.command ("mkdir -p " ^ Filename.quote kernel));
        (* The demo's package: the sources and the lock the build
           resolves against — the gc package the lock pins comes from
           the compiler's own registry, so the build runs without the
           desktop registry the apps below need. Whatever EMO_REGISTRY
           an earlier leg left behind would point the resolution at a
           tree without the gc package. *)
        List.iter
          (fun name ->
            let source =
              read_file
                (Filename.concat
                   (Filename.concat gc_examples_dir "gc_metal")
                   name)
            in
            let oc = open_out_bin (Filename.concat demo_dir name) in
            output_string oc source;
            close_out oc)
          [ "main.emo"; "package.emo"; "package.lock" ];
        Unix.unsetenv "EMO_REGISTRY";
        let demo_elf = Filename.concat root "gc-demo.elf" in
        let demo_exit =
          in_dir demo_dir (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:demo_elf
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"user" ~wasi:false)
        in
        Alcotest.(check int) "the demo's build exit" 0 demo_exit;
        (* The kernel's tree: the smoke leg's file list without run.sh
           (this leg drives the boot itself) and without hello's
           sources (the user image is the demo). *)
        List.iter
          (fun name ->
            let source = read_file (Filename.concat kernel_dir name) in
            let oc = open_out_bin (Filename.concat kernel name) in
            output_string oc source;
            close_out oc)
          [
            "package.emo";
            "main.emo";
            "user.emo";
            "gate.emo";
            "notify.emo";
            "frames.emo";
            "sv39.emo";
            "space.emo";
            "fs.emo";
            "exec.emo";
            "runtime.S";
            "trap.S";
            "sv39.S";
            "user.S";
            "link.ld";
          ];
        (* The wallpaper's bytes (emo-desktop M31, A31.1): user.S embeds
           the volume's art the assembler reads beside the sources — the
           fixture mints it the way start.sh does, from the generator
           the desktop package ships. *)
        ignore
          (Sys.command
             (Printf.sprintf "python3 %s --out %s"
                (Filename.quote
                   "../../projects/emo-desktop/fb/desktop/gen-wallpaper.py")
                (Filename.quote (Filename.concat kernel "wallpaper.rle"))));
        ignore
          (Sys.command
             (Printf.sprintf "cp %s %s" (Filename.quote demo_elf)
                (Filename.quote (Filename.concat kernel "hello.elf"))));
        (* The apps' programs: each its own build root in the scratch
           tree — user.S embeds the four ELFs, the boot installs them
           on the disk. *)
        let apps_dir = "../../projects/emo-desktop/fb/apps" in
        List.iter
          (fun app ->
            List.iter
              (fun name ->
                let source =
                  read_file
                    (Filename.concat (Filename.concat apps_dir app) name)
                in
                let path = Filename.concat (Filename.concat kernel app) name in
                let dir = Filename.dirname path in
                if not (Sys.file_exists dir) then
                  ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
                let oc = open_out_bin path in
                output_string oc source;
                close_out oc)
              [ "package.emo"; "main.emo" ])
          [ "counter"; "files"; "editor"; "spin" ];
        (* The desktop's packages beside the syscall stub, staged the
           way every gate stages one — the apps' builds resolve from
           this registry through EMO_REGISTRY. *)
        let registry = Filename.concat kernel "registry" in
        List.iter
          (fun (src, dst, names) ->
            let dir = Filename.concat registry dst in
            ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
            List.iter
              (fun name ->
                let source = read_file (Filename.concat src name) in
                let oc = open_out_bin (Filename.concat dir name) in
                output_string oc source;
                close_out oc)
              names)
          [
            ( "../../stdlib/registry/syscall/0.1.0",
              "syscall/0.1.0",
              [ "package.emo"; "syscall.emo" ] );
            ( "../../projects/emo-ui",
              "emo/ui/0.1.0",
              [ "package.emo"; "ui.emo"; "debug.emo" ] );
            ( "../../projects/emo-desktop/fb",
              "emo/ui_fb/0.1.0",
              [
                "package.emo";
                "ui_fb.emo";
                "raster.emo";
                "face_inter.emo";
                "face_mono.emo";
                "pointer.emo";
              ] );
            ( "../../projects/emo-desktop/fb/frame",
              "emo/ui_fb_frame/0.1.0",
              [ "package.emo"; "ui_fb_frame.emo"; "counter.emo" ] );
            ( "../../projects/emo-desktop/fb/win",
              "emo/ui_fb_win/0.1.0",
              [ "package.emo"; "ui_fb_win.emo" ] );
            ( "../../projects/emo-desktop/fb/desktop",
              "emo_desktop/0.1.0",
              [
                "package.emo";
                "emo_desktop.emo";
                "emo_icons.emo";
                "emo_motion.emo";
              ] );
            ( "../../projects/emo-desktop/fb/apps",
              "emo/ui_apps/0.1.0",
              [
                "package.emo";
                "ui_apps.emo";
                "counter.emo";
                "files.emo";
                "editor.emo";
              ] );
            ( "../../projects/emo-desktop/fb/winbuf",
              "emo/ui_fb_winbuf/0.1.0",
              [ "package.emo"; "ui_fb_winbuf.emo" ] );
            ( "../../projects/emo-desktop/fb/notify",
              "emo_notify/0.1.0",
              [ "package.emo"; "emo_notify.emo" ] );
          ];
        Unix.putenv "EMO_REGISTRY" registry;
        let app_build name =
          let exit_code =
            in_dir (Filename.concat kernel name) (fun () ->
                Emo_cli.build_file ~entry:"main.emo"
                  ~output:(Filename.concat kernel (name ^ ".elf"))
                  ~specialize:false ~cclibs:[]
                  ~native:Emo_project.no_native_inputs ~target:"riscv64"
                  ~profile:"app" ~wasi:false)
          in
          Alcotest.(check int) (name ^ " build exit") 0 exit_code
        in
        app_build "counter";
        app_build "files";
        app_build "editor";
        app_build "spin";
        (* The C door's image (EmoOS plan B, M0): user.S embeds it in
           this leg too; the cross compiler builds it in the scratch
           tree, the same script the smoke leg runs. *)
        List.iter
          (fun name ->
            let source = read_file (Filename.concat kernel_dir name) in
            let path = Filename.concat kernel name in
            let dir = Filename.dirname path in
            if not (Sys.file_exists dir) then
              ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
            let oc = open_out_bin path in
            output_string oc source;
            close_out oc)
          [
            "c/crt0.s";
            "c/emo_syscall.h";
            "c/emo_posix.c";
            "c/emo_posix.h";
            "c/hello.c";
            "c/chello.ld";
            "c/build.sh";
          ];
        let c_exit =
          Sys.command
            (Printf.sprintf "bash %s"
               (Filename.quote (Filename.concat kernel "c/build.sh")))
        in
        Alcotest.(check int) "the C app build exit" 0 c_exit;
        let kernel_exit =
          in_dir kernel (fun () ->
              Emo_cli.build_file ~entry:"main.emo" ~output:"main.elf"
                ~specialize:false ~cclibs:[]
                ~native:Emo_project.no_native_inputs ~target:"riscv64"
                ~profile:"kernel" ~wasi:false)
        in
        Alcotest.(check int) "the kernel's build exit" 0 kernel_exit;
        (* The boot: the machine takes the devices the kernel's own
           services speak to — the disk the apps install onto, the
           display the desktop's frame composes to, the input pair the
           input service scans — and the serial carries both the boot's
           proof chain and the demo's gold. The feed waits for the
           checksum line (the kernel reads the five bytes there), the
           gold waits for the demo's last line. *)
        let boot i =
          let log = Filename.concat root (Printf.sprintf "boot%d.log" i) in
          let blk = Filename.concat root (Printf.sprintf "blk%d.img" i) in
          let fifo = Filename.concat root (Printf.sprintf "in%d.fifo" i) in
          let script =
            Printf.sprintf
              {|
set -e
mkfifo %s
dd if=/dev/zero of=%s bs=4194304 count=1 status=none
qemu-system-riscv64 -machine virt -nographic -display none -global virtio-mmio.force-legacy=false -drive file=%s,format=raw,if=none,id=emoos-blk -device virtio-blk-device,drive=emoos-blk -device virtio-gpu-device,xres=1920,yres=1080 -device virtio-keyboard-device -device virtio-tablet-device -kernel %s <%s >%s 2>&1 &
qemu_pid=$!
exec 3>%s
for i in $(seq 1 300); do
  if grep -qF '4999999950000000' %s 2>/dev/null; then break; fi
  kill -0 $qemu_pid 2>/dev/null || break
  sleep 0.2
done
printf 'abcde' >&3 || true
for i in $(seq 1 900); do
  if grep -qF 'chain after compact' %s 2>/dev/null; then break; fi
  kill -0 $qemu_pid 2>/dev/null || break
  sleep 0.2
done
if kill -0 $qemu_pid 2>/dev/null; then kill $qemu_pid 2>/dev/null || true; fi
wait $qemu_pid 2>/dev/null || true
|}
              (Filename.quote fifo) (Filename.quote blk) (Filename.quote blk)
              (Filename.quote (Filename.concat kernel "main.elf"))
              (Filename.quote fifo) (Filename.quote log) (Filename.quote fifo)
              (Filename.quote log) (Filename.quote log)
          in
          let _, _, status = run_cmd ~timeout:420.0 script in
          (match status with
          | Unix.WEXITED 0 -> ()
          | s ->
              Alcotest.fail
                (Printf.sprintf "the boot did not drive through (run %d, %s)" i
                   (match s with
                   | Unix.WEXITED n -> "exit " ^ string_of_int n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                   | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n)));
          let serial = read_file log in
          match gc_gold serial with
          | Some got ->
              Alcotest.(check string)
                (Printf.sprintf "the gold's 24 lines (run %d)" i)
                expected got
          | None ->
              let n = String.length serial in
              let from = if n > 900 then n - 900 else 0 in
              Alcotest.fail
                (Printf.sprintf
                   "the demo's gold never arrived (run %d); the boot's tail:\n\
                    %s"
                   i
                   (String.sub serial from (n - from)))
        in
        boot 1;
        boot 2;
        boot 3;
        (* the leg's registry leaves with it: the suites after this one
           resolve from their own staging, not this scratch tree *)
        Unix.unsetenv "EMO_REGISTRY");
  ]

let () =
  Alcotest.run ~bail:true "emo_os"
    [
      ("gc_metal", gc_metal_tests);
      ("parity_metal", parity_metal_tests);
      ("smoke", smoke_tests);
    ]
