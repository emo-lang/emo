(* The ocaml target's standalone runtime (step 26): fixtures compile
   against emo_ocaml_runtime.ml alone — extracted from the compiler's
   generated data into a bare directory and compiled by the target's own
   toolchain. Zero emo_* dependencies, nothing from the host build tree.
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
  let ic =
    Unix.open_process_in (Printf.sprintf "exec 2>&1; %s" command)
  in
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
   the directory then holds exactly one file, the runtime source. *)
let extract_runtime dir =
  write_file
    (Filename.concat dir "emo_ocaml_runtime.ml")
    Emo_codegen.ocaml_runtime_ml

(* Compiles [unit_names] against the extracted runtime with plain
   ocamlopt — no findlib, no -I into the repository. *)
let compile dir unit_names =
  run
    (Printf.sprintf "cd %s && ocamlopt %s" (Filename.quote dir)
       (String.concat " " (List.map Filename.quote unit_names)))

let compile_tests =
  [
    ( "the skeleton compiles with plain ocamlopt from the build directory \
       alone",
      fun () ->
        let dir = fresh_scratch () in
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
        extract_runtime dir;
        require_ok (compile dir [ "emo_ocaml_runtime.ml" ]) "ocamlopt") ;
  ]

let () =
  Alcotest.run "emo_ocaml_runtime"
    [ ("compile", List.map (fun (n, f) -> Alcotest.test_case n `Quick f) compile_tests) ]
