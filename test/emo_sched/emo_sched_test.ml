let tc name f = Alcotest.test_case name `Quick f

(* Runs a source program under the Eio scheduler with output captured. *)
let run_source source =
  let out = Buffer.create 256 in
  Emo_eval.set_output (Buffer.add_string out);
  Fun.protect
    ~finally:(fun () ->
      Emo_eval.set_output (fun s ->
          print_string s;
          flush stdout))
    (fun () ->
      Emo_sched_eio.run (fun () ->
          let items = Emo_parser.parse_program ~file:"<test>" ~source in
          let env = Emo_eval.global_env () in
          List.iter (Emo_eval.eval_item env) items));
  Buffer.contents out

let contains_substring hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.equal (String.sub hay i n) needle then true
    else go (i + 1)
  in
  go 0

let scheduler_tests =
  [
    tc "a spawned process answers through its pid" (fun () ->
        let output =
          run_source
            {|
def worker() Int {
  receive {
    (sender, n) -> {
      sender <- (self_pid(), n * 2)
      return worker()
    }
  }
}

const pid = do worker()
pid <- (self_pid(), 21)
receive {
  (_who, result) -> { print(result) }
  _ -> { print("unmatched") }
}
print("done")
|}
        in
        Alcotest.(check string) "output" "42\ndone\n" output);
    tc "pids render as <pid N> and compare by identity" (fun () ->
        let output =
          run_source
            {|
def echo() Int {
  receive {
    reply_to -> {
      reply_to <- self_pid()
      return halt()
    }
  }
}

const pid = do echo()
pid <- self_pid()
receive {
  theirs -> {
    print(pid)
    print(theirs == pid)
    print(pid == self_pid())
  }
}
|}
        in
        Alcotest.(check string) "output" "<pid 1>\ntrue\nfalse\n" output);
    tc "selective receive keeps non-matching messages queued" (fun () ->
        let output =
          run_source
            {|
self_pid() <- "later"
self_pid() <- ("now", 7)
receive {
  ("now", n) -> { print(n) }
}
receive {
  msg -> { print(msg) }
}
|}
        in
        Alcotest.(check string) "output" "7\nlater\n" output);
    tc "a receive blocks until a message arrives" (fun () ->
        let output =
          run_source
            {|
def slow(reply_to Pid) Int {
  const a = 1
  const b = 2
  const c = a + b
  reply_to <- c
  return halt()
}

const pid = do slow(self_pid())
receive {
  n -> { print(n) }
}
print("after")
|}
        in
        Alcotest.(check string) "output" "3\nafter\n" output);
    tc "halt ends only the halting process" (fun () ->
        let output =
          run_source
            {|
def quitter() Int {
  receive {
    _ -> { return halt() }
  }
}

const q = do quitter()
q <- "bye"
print("main continues")
|}
        in
        Alcotest.(check bool)
          "main continues" true
          (contains_substring output "main continues"));
    tc "process operations are refused without a scheduler" (fun () ->
        let diagnostic =
          match
            Emo_eval.run_without_scheduler (fun () ->
                let items =
                  Emo_parser.parse_program ~file:"<test>" ~source:{|do halt()|}
                in
                let env = Emo_eval.global_env () in
                List.iter (Emo_eval.eval_item env) items)
          with
          | () -> None
          | exception Emo_eval.Error d -> Some d
        in
        match diagnostic with
        | None -> Alcotest.fail "expected E3009"
        | Some d ->
            Alcotest.(check string)
              "code" "E3009"
              (match d.Emo_support.Diagnostic.code with
              | Some c -> c
              | None -> "?"));
  ]

let () = Alcotest.run "emo_sched" [ ("scheduler", scheduler_tests) ]
