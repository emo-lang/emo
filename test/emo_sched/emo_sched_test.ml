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

(* Evaluates the single expression statement of [source] in [env]. *)
let eval_one source env =
  match Emo_parser.parse_program ~file:"<test>" ~source with
  | [
   {
     Emo_ast.item_desc =
       Emo_ast.Item_stmt { Emo_ast.stmt_desc = Emo_ast.Expr_stmt e; _ };
     _;
   };
  ] ->
      Emo_eval.eval_expr env e
  | _ -> failwith "expected one expression statement"

let isolation_tests =
  [
    tc "a process that raises dies alone; the parent continues" (fun () ->
        let output =
          run_source
            {|
def bomber() Int {
  receive {
    _ -> { raise Exception.new("boom") }
  }
}

const b = do bomber()
b <- "light the fuse"
print("still here")
|}
        in
        Alcotest.(check string) "output" "still here\n" output);
    tc "a runtime error kills only the offending process" (fun () ->
        let output =
          run_source
            {|
def divider() Int {
  receive {
    (_, 0) -> { return 1 / 0 }
    (_, n) -> { return 100 / n }
  }
}

const d = do divider()
d <- (self_pid(), 0)
print("main survives")
|}
        in
        Alcotest.(check string) "output" "main survives\n" output);
    tc "the root's uncaught raise is the program's outcome" (fun () ->
        match run_source {|raise Exception.new("root boom")|} with
        | _ -> Alcotest.fail "expected the root's raise to propagate"
        | exception Emo_eval.Emo_raise _ -> ());
    tc "exit hooks fire with the recorded exit" (fun () ->
        let events = Buffer.create 64 in
        Emo_sched_eio.run (fun () ->
            let env = Emo_eval.global_env () in
            List.iter (Emo_eval.eval_item env)
              (Emo_parser.parse_program ~file:"<test>"
                 ~source:
                   {|def quitter() Int {
  receive {
    _ -> { return halt() }
  }
}
|});
            match eval_one "do quitter()" env with
            | Emo_eval.Pid pid ->
                Emo_eval.on_exit pid (fun info ->
                    let name =
                      match info with
                      | Emo_eval.Exit_normal -> "normal"
                      | Emo_eval.Exit_raised _ -> "raised"
                      | Emo_eval.Exit_failed _ -> "failed"
                    in
                    Buffer.add_string events name);
                let span =
                  Emo_support.Span.make ~file:"<test>" ~line:1 ~col:1 ~start:0
                    ~stop:0
                in
                ignore
                  (Effect.perform
                     (Emo_eval.Send (pid, Emo_eval.String "bye", span)))
            | _ -> failwith "expected a pid");
        Alcotest.(check string) "exit signal" "normal" (Buffer.contents events));
  ]

let box_tests =
  [
    tc "sending a Box delivers a snapshot" (fun () ->
        let output =
          run_source
            {|
def reader(reply_to Pid) Int {
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
  v -> { print(v) }
}
print(box.read())
|}
        in
        (* The receiver saw the snapshot taken at send time; the sender's
           later mutation stays local. *)
        Alcotest.(check string) "output" "1\n99\n" output);
    tc "the receiver's mutations stay on its copy" (fun () ->
        let output =
          run_source
            {|
def mutator(reply_to Pid) Int {
  receive {
    b -> {
      b.replace(7)
      reply_to <- "mutated"
      return halt()
    }
  }
}

const box = Box.new(1)
const m = do mutator(self_pid())
m <- box
receive {
  _ -> { print(box.read()) }
}
|}
        in
        Alcotest.(check string) "output" "1\n" output);
    tc "a Box inside a tuple is snapshotted too" (fun () ->
        let output =
          run_source
            {|
def reader(reply_to Pid) Int {
  receive {
    (b, tag) -> {
      reply_to <- (b.read(), tag)
      return halt()
    }
  }
}

const r = do reader(self_pid())
r <- (Box.new(5), "deep")
receive {
  (v, tag) -> {
    print(tag)
    print(v)
  }
}
|}
        in
        Alcotest.(check string) "output" "deep\n5\n" output);
  ]

(* Runs a source program under the deterministic scheduler; returns the
   captured output and the event log. *)
let run_det ?seed source =
  let out = Buffer.create 256 in
  Emo_eval.set_output (Buffer.add_string out);
  Fun.protect
    ~finally:(fun () ->
      Emo_eval.set_output (fun s ->
          print_string s;
          flush stdout))
    (fun () ->
      let events =
        Emo_sched_det.run ?seed (fun () ->
            let items = Emo_parser.parse_program ~file:"<test>" ~source in
            let env = Emo_eval.global_env () in
            List.iter (Emo_eval.eval_item env) items)
      in
      (Buffer.contents out, events))

(* Two echo processes answer in either order depending on the schedule —
   the classic race the deterministic scheduler pins down. *)
let racy =
  {|
def echo(name String) Int {
  receive {
    reply_to -> {
      reply_to <- name
      return halt()
    }
  }
}

const a = do echo("a")
const b = do echo("b")
a <- self_pid()
b <- self_pid()
receive {
  m1 -> { print(m1) }
}
receive {
  m2 -> { print(m2) }
}
|}

let determinism_tests =
  [
    tc "the same seed replays the same schedule" (fun () ->
        let out1, log1 = run_det ~seed:7 racy in
        let out2, log2 = run_det ~seed:7 racy in
        Alcotest.(check string) "output" out1 out2;
        Alcotest.(check bool)
          "log" true
          (List.length log1 = List.length log2
          && List.for_all2
               (fun x y ->
                 match (x, y) with
                 | Emo_sched_det.Exited (a, _), Emo_sched_det.Exited (b, _) ->
                     a = b
                 | Emo_sched_det.Sent (a1, a2), Emo_sched_det.Sent (b1, b2) ->
                     (a1, a2) = (b1, b2)
                 | Emo_sched_det.Spawned a, Emo_sched_det.Spawned b -> a = b
                 | Emo_sched_det.Received a, Emo_sched_det.Received b -> a = b
                 | _ -> false)
               log1 log2));
    tc "the event log records the run" (fun () ->
        let _, log = run_det racy in
        let has event =
          List.exists
            (fun e ->
              match (e, event) with
              | Emo_sched_det.Spawned _, Emo_sched_det.Spawned _ -> true
              | Emo_sched_det.Sent (f, _), Emo_sched_det.Sent (f', _) -> f = f'
              | _ -> false)
            log
        in
        Alcotest.(check bool)
          "records a spawn" true
          (has (Emo_sched_det.Spawned 1));
        Alcotest.(check bool)
          "records a send" true
          (has (Emo_sched_det.Sent (0, 1)));
        Alcotest.(check bool)
          "records exits" true
          (List.exists
             (function
               | Emo_sched_det.Exited (_, "normal") -> true | _ -> false)
             log));
    tc "every seed agrees on the result set" (fun () ->
        List.iter
          (fun seed ->
            let out, _ = run_det ~seed racy in
            let lines =
              String.split_on_char '\n' out
              |> List.filter (fun l -> l <> "")
              |> List.sort compare
            in
            Alcotest.(check string)
              (Printf.sprintf "seed %d" seed)
              "a\nb" (String.concat "\n" lines))
          [ 0; 1; 2; 3; 4; 5; 6; 7; 8; 9 ]);
    tc "a system-wide deadlock is an error" (fun () ->
        match run_det {|receive {
  _ -> { print("never") }
}
|} with
        | _ -> Alcotest.fail "expected E3012"
        | exception Emo_eval.Error d ->
            Alcotest.(check string)
              "code" "E3012"
              (match d.Emo_support.Diagnostic.code with
              | Some c -> c
              | None -> "?"));
  ]

let () =
  Alcotest.run "emo_sched"
    [
      ("scheduler", scheduler_tests);
      ("isolation", isolation_tests);
      ("box", box_tests);
      ("determinism", determinism_tests);
    ]
