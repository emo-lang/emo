(* The ocaml target's standalone runtime (step 26): fixtures compile
   against emo_ocaml_runtime.ml alone — extracted from the compiler's
   generated data into a bare directory and compiled by the target's own
   toolchain. Zero emo_* dependencies, nothing from the host build tree;
   the packages are the runtime's own dependency policy (unix, ssl).
   Scratch directories are never deleted (the repo's test convention). *)

let scratch_counter = ref 0

let fresh_scratch () =
  incr scratch_counter;
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "emo-ocaml-runtime-%d-%d"
       (int_of_float (Sys.time () *. 1000.))
       !scratch_counter)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* Runs a shell command, returning its exit status and combined output. *)
let run command =
  let ic = Unix.open_process_in (Printf.sprintf "exec 2>&1; %s" command) in
  let buffer = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buffer ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (status, Buffer.contents buffer)

let require_ok (status, output) what =
  match status with
  | Unix.WEXITED 0 -> ()
  | _ ->
      Alcotest.fail
        (Printf.sprintf "%s failed:\n%s" (String.escaped what) output)

(* Extracts the runtime from the compiler's generated data into [dir]:
   the directory then holds exactly the runtime source and whatever the
   fixture adds. *)
let extract_runtime dir =
  write_file
    (Filename.concat dir "emo_ocaml_runtime.ml")
    Emo_codegen.ocaml_runtime_ml

(* Compiles the extracted runtime, then [unit_names] against it —
   ocamlfind brings only the runtime's own packages (unix, ssl), never
   the repository. The -open makes the emitter's qualified paths
   (Emo_eval.value, Emo_runtime.run) resolve against the runtime's
   submodules without touching the emitted source. *)
let compile dir unit_names =
  require_ok
    (run
       (Printf.sprintf "cd %s && ocamlfind ocamlopt -package unix,ssl -c %s"
          (Filename.quote dir) "emo_ocaml_runtime.ml"))
    "ocamlfind ocamlopt -c";
  run
    (Printf.sprintf
       "cd %s && ocamlfind ocamlopt -package unix,ssl -linkpkg -open \
        Emo_ocaml_runtime emo_ocaml_runtime.cmx %s -o a.out"
       (Filename.quote dir)
       (String.concat " " (List.map Filename.quote unit_names)))

let compile_tests =
  [
    ( "the runtime compiles from the build directory alone",
      fun () ->
        let dir = fresh_scratch () in
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
        extract_runtime dir;
        require_ok (compile dir []) "ocamlfind ocamlopt" );
  ]

(* ---- Program fixtures ----

   Each writes a main.ml in the emitter's call shape, compiles it
   against the standalone runtime alone, runs it, and checks stdout and
   the exit code. [args] passes through to the program (the file
   fixture's scratch path). *)

let program ~(main : string) ~(expect_exit : int) ~(expect_out : string)
    ~(args : string list) : unit =
  let dir = fresh_scratch () in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
  extract_runtime dir;
  write_file (Filename.concat dir "main.ml") main;
  require_ok (compile dir [ "main.ml" ]) "ocamlfind ocamlopt";
  let status, out =
    run
      (Printf.sprintf "cd %s && ./a.out %s" (Filename.quote dir)
         (String.concat " " (List.map Filename.quote args)))
  in
  match status with
  | Unix.WEXITED code ->
      Alcotest.(check int) "exit code" expect_exit code;
      Alcotest.(check string) "output" expect_out out
  | _ -> Alcotest.fail (Printf.sprintf "the fixture program crashed:\n%s" out)

let values_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  p (Emo_eval.Int64 42L);
  p (Emo_eval.Int64 (-7L));
  p (Emo_eval.Byte 255);
  p (Emo_eval.Float 3.0);
  p (Emo_eval.Float 0.1);
  p (Emo_eval.Bool true);
  p (Emo_eval.Void);
  p (Emo_eval.Char 'x');
  p (Emo_eval.String "hi");
  p (Emo_eval.Tuple [ Emo_eval.Int64 1L; Emo_eval.String "a" ]);
  p (Emo_eval.Array [| Emo_eval.Int64 1L; Emo_eval.Int64 2L |]);
  p (Emo_eval.Bytes (Bytes.of_string "abc"));
  p (Emo_eval.Box (ref Emo_eval.Void));
  p (Emo_eval.EnumMember ("Color", "Red"));
  p (Emo_eval.TypeValue "Int64");
  ignore
    (Emo_eval.call_builtin "println"
       [ Emo_runtime.interpolate
           [ Emo_eval.String "n=";
             Emo_eval.Int64 5L;
             Emo_eval.String " f=";
             Emo_eval.Float 1.5
           ]
       ]);
  p (Emo_runtime.eq (Emo_eval.Int64 1L) (Emo_eval.Int64 1L));
  p (Emo_runtime.ne (Emo_eval.String "a") (Emo_eval.String "b"))
|}

let values_out =
  "42\n\
   -7\n\
   255\n\
   3.0\n\
   0.1\n\
   true\n\
   void\n\
   x\n\
   hi\n\
   (1, a)\n\
   [1, 2]\n\
   Bytes[3]\n\
   <box>\n\
   Red\n\
   Int64\n\
   n=5 f=1.5\n\
   true\n\
   true\n"

let arithmetic_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  p (Emo_runtime.add (Emo_eval.Int64 2L) (Emo_eval.Int64 3L));
  p (Emo_runtime.add (Emo_eval.Int64 Int64.max_int) (Emo_eval.Int64 1L));
  p (Emo_runtime.add (Emo_eval.Float 1.5) (Emo_eval.Int64 2L));
  p (Emo_runtime.add (Emo_eval.String "a") (Emo_eval.String "b"));
  p (Emo_runtime.add (Emo_eval.Byte 250) (Emo_eval.Byte 10));
  p (Emo_runtime.sub (Emo_eval.Int64 2L) (Emo_eval.Int64 5L));
  p (Emo_runtime.mul (Emo_eval.Int64 6L) (Emo_eval.Int64 7L));
  p (Emo_runtime.div (Emo_eval.Int64 7L) (Emo_eval.Int64 2L));
  p (Emo_runtime.div (Emo_eval.Float 7.0) (Emo_eval.Float 2.0));
  p (Emo_runtime.modulo (Emo_eval.Int64 7L) (Emo_eval.Int64 3L));
  p (Emo_runtime.negf (Emo_eval.Float 1.5));
  p (Emo_runtime.shl (Emo_eval.Int64 1L) (Emo_eval.Int64 10L));
  p (Emo_runtime.shr (Emo_eval.Int64 (-16L)) (Emo_eval.Int64 2L));
  p (Emo_runtime.bit_and (Emo_eval.Int64 12L) (Emo_eval.Int64 10L));
  p (Emo_runtime.bit_or (Emo_eval.Int64 12L) (Emo_eval.Int64 10L));
  p (Emo_runtime.bit_xor (Emo_eval.Int64 12L) (Emo_eval.Int64 10L));
  p (Emo_runtime.bit_not (Emo_eval.Int64 0L));
  p (Emo_runtime.lt (Emo_eval.Int64 1L) (Emo_eval.Float 1.5));
  p (Emo_runtime.le (Emo_eval.Int64 2L) (Emo_eval.Float 2.0));
  p (Emo_runtime.gt (Emo_eval.Byte 3) (Emo_eval.Byte 2));
  p (Emo_runtime.ge (Emo_eval.Int64 5L) (Emo_eval.Int64 5L));
  p (Emo_runtime.not_ (Emo_eval.Bool false));
  p (Emo_runtime.and_ (Emo_eval.Bool true) (Emo_eval.Bool false))
|}

let arithmetic_out =
  "5\n\
   -9223372036854775808\n\
   3.5\n\
   ab\n\
   4\n\
   -3\n\
   42\n\
   3\n\
   3.5\n\
   1\n\
   -1.5\n\
   1024\n\
   -4\n\
   8\n\
   14\n\
   6\n\
   -1\n\
   true\n\
   true\n\
   true\n\
   true\n\
   true\n\
   false\n"

let strings_main =
  {|let m r n a = Emo_runtime.method_call r n a
let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  let s = Emo_eval.String "Hello, Emo" in
  p (m s "length" []);
  p (m s "substring" [ Emo_eval.Int64 7L; Emo_eval.Int64 3L ]);
  p (m (Emo_eval.String "a,b,c") "split" [ Emo_eval.String "," ]);
  p (m (Emo_eval.String "  pad  ") "trim" []);
  p (m (Emo_eval.String "MiXeD") "lower" []);
  p (m s "index_of" [ Emo_eval.String "Emo" ]);
  p (m s "index_of" [ Emo_eval.String "zz" ]);
  p (m s "starts_with" [ Emo_eval.String "Hello" ]);
  p (m (Emo_eval.String "12") "to_int64" []);
  p (m s "to_bytes" []);
  let b = Emo_runtime.bytes_new (Emo_eval.Int64 4L) in
  ignore (m b "set" [ Emo_eval.Int64 0L; Emo_eval.Int64 65L ]);
  p (m b "get" [ Emo_eval.Int64 0L ]);
  p (m b "length" []);
  ignore (m b "set_u16_le" [ Emo_eval.Int64 2L; Emo_eval.Int64 258L ]);
  p (m b "get_u16_le" [ Emo_eval.Int64 2L ])
|}

let strings_out =
  "10\nEmo\n[a, b, c]\npad\nmixed\n7\n-1\ntrue\n12\nBytes[10]\n65\n4\n258\n"

let objects_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let greet (args : Emo_eval.value list) : Emo_eval.value =
  match args with
  | self :: _ ->
      Emo_eval.String
        ("hi, " ^ Emo_eval.to_string (Emo_runtime.field self "name"))
  | [] -> Emo_runtime.no_return ()

let () =
  let tbl = Hashtbl.create 8 in
  Hashtbl.replace tbl "greet" (0, greet);
  let obj = Emo_eval.Obj (Emo_runtime.new_obj "Person" tbl) in
  Emo_runtime.obj_set_field obj "name" (Emo_eval.String "Ada");
  p (Emo_runtime.method_call obj "greet" []);
  p obj;
  Emo_runtime.register_interface "Greeter" [ ("greet", 0) ];
  p (Emo_runtime.method_call obj "is" [ Emo_eval.TypeValue "Greeter" ]);
  p (Emo_runtime.method_call obj "is" [ Emo_eval.TypeValue "Person" ]);
  let e = Emo_runtime.exception_new (Emo_eval.String "boom") in
  p e;
  (try raise (Emo_eval.Emo_raise e) with
  | Emo_eval.Emo_raise v ->
      print_string ("uncaught exception: " ^ Emo_eval.to_string v ^ "\n");
      exit 1)
|}

let objects_out =
  "hi, Ada\n\
   #Person(name: \"Ada\")\n\
   true\n\
   true\n\
   boom\n\
   uncaught exception: boom\n"

let errors_main =
  {|let show label f =
  try ignore (f ()); print_string (label ^ ": no error\n")
  with Failure msg -> print_string (label ^ ": " ^ msg ^ "\n")

let () =
  show "case" (fun () -> Emo_runtime.case_error (Emo_eval.Int64 1L));
  show "noreturn" Emo_runtime.no_return;
  show "divzero" (fun () ->
      Emo_runtime.div (Emo_eval.Int64 1L) (Emo_eval.Int64 0L));
  show "tag" (fun () -> Emo_runtime.unbox_bool (Emo_eval.String "x"));
  show "index" (fun () ->
      Emo_runtime.index (Emo_eval.Array [| |]) (Emo_eval.Int64 0L));
  show "box" (fun () -> Emo_runtime.apply_value (Emo_eval.Int64 1L) []);
  (try ignore (Emo_runtime.arity_error "f" 2 1)
   with Emo_runtime.Arity_error msg -> print_string ("arity: " ^ msg ^ "\n"))
|}

let errors_out =
  "case: no `case` branch matched this Int64 value\n\
   noreturn: reached the end of a function without `return`\n\
   divzero: division by zero\n\
   tag: expected Bool, got String\n\
   index: index 0 is out of bounds\n\
   box: calling a non-function\n\
   arity: `f` expects 2 arguments, got 1\n"

(* The process program: a spawned child echoes a message back through
   the parent's receive, and halt unwinds the root. *)
let processes_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  let exit_code =
    Emo_runtime.run (fun () ->
        let child (args : Emo_eval.value list) : unit =
          match args with
          | [ parent ] ->
              Emo_runtime.send parent
                (Emo_eval.Tuple [ Emo_eval.String "pong"; Emo_eval.Int64 7L ])
          | _ -> ()
        in
        let me = Emo_eval.call_builtin "self_pid" [] in
        ignore (Emo_runtime.spawn_args [ me ] child);
        let _i, items =
          Emo_runtime.receive
            [
              (fun v ->
                match v with
                | Emo_eval.Tuple (Emo_eval.String "pong" :: rest) ->
                    Some (0, rest)
                | _ -> None);
            ]
        in
        ignore items;
        p (Emo_eval.Int64 7L);
        (* halt unwinds this process; the line below never prints *)
        ignore (Emo_eval.call_builtin "halt" []);
        p (Emo_eval.String "unreachable"))
  in
  if exit_code <> 0 then exit exit_code
|}

let processes_out = "7\n"

(* The HTTP roundtrip: a server process accepts, reads one request line,
   and answers it; the client reads the response back. *)
let http_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  let exit_code =
    Emo_runtime.run (fun () ->
        let listener =
          Emo_eval.call_builtin "net_listen"
            [ Emo_eval.String "127.0.0.1"; Emo_eval.Int64 0L ]
        in
        let port = Emo_runtime.method_call listener "port" [] in
        ignore
          (Emo_runtime.spawn (fun () ->
               let conn = Emo_runtime.method_call listener "accept" [] in
               let request = Emo_runtime.method_call conn "read_line" [] in
               let body =
                 Emo_eval.String ("hello " ^ Emo_eval.to_string request ^ "\n")
               in
               ignore (Emo_runtime.method_call conn "write" [ body ]);
               ignore (Emo_runtime.method_call conn "close" [])));
        let conn =
          Emo_eval.call_builtin "net_connect"
            [ Emo_eval.String "127.0.0.1"; port; Emo_eval.Float 5.0 ]
        in
        ignore
          (Emo_runtime.method_call conn "write" [ Emo_eval.String "emo\r\n" ]);
        p (Emo_runtime.method_call conn "read_line" []);
        ignore (Emo_runtime.method_call conn "close" []))
  in
  if exit_code <> 0 then exit exit_code
|}

let http_out = "hello emo\n"

(* File IO: write through the effect, then read the same bytes back. *)
let file_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  let path = Sys.argv.(1) in
  let exit_code =
    Emo_runtime.run (fun () ->
        p
          (Emo_eval.call_builtin "file_write"
             [ Emo_eval.String path; Emo_eval.String "emo file io\n" ]);
        p (Emo_eval.call_builtin "file_read" [ Emo_eval.String path ]))
  in
  if exit_code <> 0 then exit exit_code
|}

let file_out = "12\nemo file io\n\n"

(* UDP: one socket, one loopback datagram. *)
let udp_main =
  {|let p v = ignore (Emo_eval.call_builtin "println" [ v ])

let () =
  let exit_code =
    Emo_runtime.run (fun () ->
        let u =
          Emo_eval.call_builtin "net_udp_bind"
            [ Emo_eval.String "127.0.0.1"; Emo_eval.Int64 0L ]
        in
        let port = Emo_runtime.method_call u "port" [] in
        ignore
          (Emo_runtime.method_call u "send_to"
             [ Emo_eval.String "127.0.0.1"; port; Emo_eval.String "datagram" ]);
        match Emo_runtime.method_call u "recv_from" [] with
        | Emo_eval.Tuple (data :: _) -> p data
        | _ -> p (Emo_eval.String "unexpected"))
  in
  if exit_code <> 0 then exit exit_code
|}

let udp_out = "datagram\n"

let program_tests =
  [
    Alcotest.test_case "values render by the one stringification rule" `Quick
      (fun () ->
        program ~main:values_main ~expect_exit:0 ~expect_out:values_out ~args:[]);
    Alcotest.test_case "arithmetic and comparison dispatch by tag" `Quick
      (fun () ->
        program ~main:arithmetic_main ~expect_exit:0 ~expect_out:arithmetic_out
          ~args:[]);
    Alcotest.test_case "string and bytes methods dispatch" `Quick (fun () ->
        program ~main:strings_main ~expect_exit:0 ~expect_out:strings_out
          ~args:[]);
    Alcotest.test_case "objects, interfaces, and exceptions behave" `Quick
      (fun () ->
        program ~main:objects_main ~expect_exit:1 ~expect_out:objects_out
          ~args:[]);
    Alcotest.test_case "the error paths name what failed" `Quick (fun () ->
        program ~main:errors_main ~expect_exit:0 ~expect_out:errors_out ~args:[]);
    Alcotest.test_case "a spawned process echoes through receive, halt exits"
      `Quick (fun () ->
        program ~main:processes_main ~expect_exit:0 ~expect_out:processes_out
          ~args:[]);
    Alcotest.test_case "an http roundtrip rides the scheduler" `Quick (fun () ->
        program ~main:http_main ~expect_exit:0 ~expect_out:http_out ~args:[]);
    Alcotest.test_case "file io writes and reads back" `Quick (fun () ->
        program ~main:file_main ~expect_exit:0 ~expect_out:file_out
          ~args:[ "fixture.txt" ]);
    Alcotest.test_case "a udp datagram loops back" `Quick (fun () ->
        program ~main:udp_main ~expect_exit:0 ~expect_out:udp_out ~args:[]);
  ]

let () =
  Alcotest.run "emo_ocaml_runtime"
    [
      ( "compile",
        List.map (fun (n, f) -> Alcotest.test_case n `Quick f) compile_tests );
      ("program", program_tests);
    ]
