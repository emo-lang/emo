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
def worker() Int64 {
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
  (_who, result) -> { println(result) }
  _ -> { println("unmatched") }
}
println("done")
|}
        in
        Alcotest.(check string) "output" "42\ndone\n" output);
    tc "pids render as <pid N> and compare by identity" (fun () ->
        let output =
          run_source
            {|
def echo() Int64 {
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
    println(pid)
    println(theirs == pid)
    println(pid == self_pid())
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
  ("now", n) -> { println(n) }
}
receive {
  msg -> { println(msg) }
}
|}
        in
        Alcotest.(check string) "output" "7\nlater\n" output);
    tc "a receive blocks until a message arrives" (fun () ->
        let output =
          run_source
            {|
def slow(reply_to Pid) Int64 {
  const a = 1
  const b = 2
  const c = a + b
  reply_to <- c
  return halt()
}

const pid = do slow(self_pid())
receive {
  n -> { println(n) }
}
println("after")
|}
        in
        Alcotest.(check string) "output" "3\nafter\n" output);
    tc "halt ends only the halting process" (fun () ->
        let output =
          run_source
            {|
def quitter() Int64 {
  receive {
    _ -> { return halt() }
  }
}

const q = do quitter()
q <- "bye"
println("main continues")
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
def bomber() Int64 {
  receive {
    _ -> { raise Exception.new("boom") }
  }
}

const b = do bomber()
b <- "light the fuse"
println("still here")
|}
        in
        Alcotest.(check string) "output" "still here\n" output);
    tc "a runtime error kills only the offending process" (fun () ->
        let output =
          run_source
            {|
def divider() Int64 {
  receive {
    (_, 0) -> { return 1 / 0 }
    (_, n) -> { return 100 / n }
  }
}

const d = do divider()
d <- (self_pid(), 0)
println("main survives")
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
                   {|def quitter() Int64 {
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
        in
        (* The receiver saw the snapshot taken at send time; the sender's
           later mutation stays local. *)
        Alcotest.(check string) "output" "1\n99\n" output);
    tc "the receiver's mutations stay on its copy" (fun () ->
        let output =
          run_source
            {|
def mutator(reply_to Pid) Int64 {
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
  _ -> { println(box.read()) }
}
|}
        in
        Alcotest.(check string) "output" "1\n" output);
    tc "a Box inside a tuple is snapshotted too" (fun () ->
        let output =
          run_source
            {|
def reader(reply_to Pid) Int64 {
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
    println(tag)
    println(v)
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
        try
          Emo_sched_det.run ?seed (fun () ->
              let items = Emo_parser.parse_program ~file:"<test>" ~source in
              let env = Emo_eval.global_env () in
              List.iter (Emo_eval.eval_item env) items)
        with Emo_eval.Emo_raise (v, _span, _trace) ->
          Alcotest.fail
            (Printf.sprintf "root raised: %s" (Emo_eval.to_string v))
        (* A runtime diagnostic (E3012 deadlock, ...) escapes unchanged for
           tests that expect it. *)
      in
      (Buffer.contents out, events))

(* Two echo processes answer in either order depending on the schedule —
   the classic race the deterministic scheduler pins down. *)
let racy =
  {|
def echo(name String) Int64 {
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
  m1 -> { println(m1) }
}
receive {
  m2 -> { println(m2) }
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
    tc "both schedulers agree on a concurrent program" (fun () ->
        let sorted_out out =
          String.split_on_char '\n' out
          |> List.filter (fun l -> l <> "")
          |> List.sort compare |> String.concat ";"
        in
        let eio_out, _ = run_source racy |> fun out -> (out, ()) in
        let own_out, _ = run_det racy in
        (* The two schedulers may interleave differently, but the program's
           observable result set is the same. *)
        Alcotest.(check string)
          "result set" (sorted_out eio_out) (sorted_out own_out));
    tc "the root exiting cancels a parked process instead of deadlocking"
      (fun () ->
        let output, _ =
          run_det
            {|def parked() Int64 {
  receive {
    _ -> { return 0 }
  }
}

do parked()
println("root done")
|}
        in
        Alcotest.(check string) "output" "root done\n" output);
    tc "the root exiting drops a runnable process" (fun () ->
        let output, _ =
          run_det
            {|def work(n Int64) Int64 {
  for var i = 0; i < n; i = i + 1 { println(i) }
  return 0
}

do work(5)
println("root done")
|}
        in
        Alcotest.(check string) "output" "root done\n" output);
    tc "a system-wide deadlock is an error" (fun () ->
        match run_det {|receive {
  _ -> { println("never") }
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

(* ---- Stress: the acceptance volumes, under both schedulers. ---- *)

(* 500k round trips = 1M messages between two processes. *)
let ping_pong =
  {|
def pong(n Int64) Int64 {
  receive {
    ("ping", reply_to) -> {
      reply_to <- "pong"
      return pong(n + 1)
    }
    ("done", report_to) -> {
      report_to <- n
      return halt()
    }
  }
}

const p = do pong(0)
const me = self_pid()
def round(i Int64) Int64 {
  if i == 0 {
    p <- ("done", me)
    return 0
  } else {
    p <- ("ping", me)
    receive {
      _ -> { return round(i - 1) }
    }
  }
}

round(500000)
receive {
  n -> { println(n) }
}
|}

(* 1000 workers, each answering once; the main process folds the answers. *)
let fan_out =
  {|
def worker(reply_to Pid) Int64 {
  receive {
    n -> {
      reply_to <- n * 2
      return halt()
    }
  }
}

const me = self_pid()
def launch(i Int64) Int64 {
  if i == 0 {
    return 0
  } else {
    const w = do worker(me)
    w <- i
    return launch(i - 1)
  }
}

launch(1000)

def collect(n Int64, sum Int64) Int64 {
  if n == 0 {
    return sum
  } else {
    receive {
      v -> { return collect(n - 1, sum + v) }
    }
  }
}

println(collect(1000, 0))
|}

(* A receive loop recursing a million times — the native stack stays flat. *)
let deep_loop =
  {|
def looper(n Int64) Int64 {
  receive {
    ("stop", report_to) -> {
      report_to <- n
      return halt()
    }
    _ -> {
      return looper(n + 1)
    }
  }
}

const l = do looper(0)
const me = self_pid()
def feed(i Int64) Int64 {
  if i == 0 {
    l <- ("stop", me)
    return 0
  } else {
    l <- "tick"
    return feed(i - 1)
  }
}

feed(1000000)
receive {
  n -> { println(n) }
}
|}

let stress_tests =
  [
    tc "ping-pong 1M messages on the own scheduler" (fun () ->
        let output, _ = run_det ping_pong in
        Alcotest.(check string) "output" "500000\n" output);
    tc "ping-pong 1M messages on Eio" (fun () ->
        let output = run_source ping_pong in
        Alcotest.(check string) "output" "500000\n" output);
    tc "fan-out/fan-in 1000 workers on the own scheduler" (fun () ->
        let output, _ = run_det fan_out in
        Alcotest.(check string) "output" "1001000\n" output);
    tc "fan-out/fan-in 1000 workers on Eio" (fun () ->
        let output = run_source fan_out in
        Alcotest.(check string) "output" "1001000\n" output);
    tc "a million receive-loop iterations on the own scheduler" (fun () ->
        let output, _ = run_det deep_loop in
        Alcotest.(check string) "output" "1000000\n" output);
    tc "receive-loop iterations keep the Eio stack flat" (fun () ->
        (* On Eio the feeder alternates with the looper — the property
           under test (a receive loop recursing without growing the
           native stack) is the same. *)
        let output =
          run_source
            {|
def looper(n Int64) Int64 {
  receive {
    ("stop", report_to) -> {
      report_to <- n
      return halt()
    }
    ("tick", reply_to) -> {
      reply_to <- "ack"
      return looper(n + 1)
    }
  }
}

const l = do looper(0)
const me = self_pid()
def feed(i Int64, who Pid) Int64 {
  if i == 0 {
    who <- ("stop", me)
    return 0
  } else {
    who <- ("tick", me)
    receive {
      _ -> { return feed(i - 1, who) }
    }
  }
}

feed(100000, l)
receive {
  n -> { println(n) }
}
|}
        in
        Alcotest.(check string) "output" "100000\n" output);
  ]

(* ---- Networking: the TCP surface (T13.1) ----

   Every test runs on the own scheduler over real loopback sockets: a
   listener on port 0, a spawned server process, and a client in the root
   — the process-per-connection shape, in direct style. *)

(* A fresh unix-socket path per call: test socket files are never
   deleted, so names must not collide within or across runs. The path is
   deliberately short — macOS limits a unix socket's path to 104 bytes,
   and dune's per-action temp dirs are too long to bind under. *)
let unix_counter = ref 0

let unix_test_path kind =
  incr unix_counter;
  Printf.sprintf "/tmp/emo-%s-%d-%d.sock" kind (Unix.getpid ()) !unix_counter

(* Finds a port with no listener; connecting there is refused. *)
let closed_port () =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match (Unix.getsockname fd : Unix.sockaddr) with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  Unix.close fd;
  port

(* Runs a source program under the deterministic scheduler and returns the
   message the root died with: an Emo exception's rendered value, or a
   runtime diagnostic's message. "no raise" when the program survives. *)
let run_det_raised ?seed source =
  let raised = ref "no raise" in
  (try
     ignore
       (Emo_sched_det.run ?seed (fun () ->
            let items = Emo_parser.parse_program ~file:"<test>" ~source in
            let env = Emo_eval.global_env () in
            List.iter (Emo_eval.eval_item env) items))
   with
  | Emo_eval.Emo_raise (v, _span, _trace) -> raised := Emo_eval.to_string v
  | Emo_eval.Error diagnostic ->
      raised := diagnostic.Emo_support.Diagnostic.message);
  !raised

let net_tests =
  [
    tc "an echo server round-trips over TCP" (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write(line + "\n")
          serve(listener)
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do serve(listener)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("ping\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "ping\ndone\n" output);
    tc "a listener on port 0 reports its assigned port" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, listener) = net_listen("127.0.0.1", 0)
println(listener.port() > 0)
println(listener.port() < 65536)
|}
        in
        Alcotest.(check string) "output" "true\ntrue\n" output);
    tc "graceful close delivers pending data before EOF" (fun () ->
        let output, _events =
          run_det
            {|
def once(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      conn.write("bye")
      conn.close()
    }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do once(listener)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    case conn.read_all() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, text)   -> { println(text) }
    }
    case conn.read_all() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, text)   -> { println(text) }
    }
    println("after")
  }
}
|}
        in
        Alcotest.(check string) "output" "bye\n\nafter\n" output);
    tc "connecting to a closed port answers a precise reason" (fun () ->
        let port = closed_port () in
        let output, _events =
          run_det
            (Printf.sprintf
               {|
const result = net_connect("127.0.0.1", %d, 0.0)
case result {
  (R.error, why) -> { println(why) }
  (R.ok, _)      -> { println("connected?!") }
}
|}
               port)
        in
        Alcotest.(check string)
          "output"
          (Printf.sprintf "connection refused to 127.0.0.1:%d\n" port)
          output);
    tc "a read deadline answers a precise reason" (fun () ->
        let output, _events =
          run_det
            {|
def silent(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> { halt() }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do silent(listener)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.set_timeout(0.2)
    case conn.read_line() {
      (R.error, why) -> { println(why) }
      (R.ok, line)   -> { println(line) }
    }
  }
}
|}
        in
        let expected_prefix = "timed out reading a line from 127.0.0.1:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
        in
        Alcotest.(check bool) "timeout reason names the peer" true ok);
    tc "reading a closed connection answers the reason" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, listener) = net_listen("127.0.0.1", 0)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.close()
    case conn.read_line() {
      (R.error, why) -> { println(why) }
      (R.ok, line)   -> { println(line) }
    }
  }
}
|}
        in
        let expected_prefix = "the connection to 127.0.0.1:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
        in
        Alcotest.(check bool) "closed-connection reason" true ok);
    tc "closing a connection twice answers the reason" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, listener) = net_listen("127.0.0.1", 0)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.close()
    case conn.close() {
      (R.error, why) -> { println(why) }
      (R.ok, _)      -> { println("closed again?!") }
    }
  }
}
|}
        in
        let expected_prefix = "the connection to 127.0.0.1:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
        in
        Alcotest.(check bool) "double-close reason" true ok);
    tc "a close mid-line surfaces as a precise reason" (fun () ->
        let output, _events =
          run_det
            {|
def cut(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      conn.write("half")
      conn.close()
    }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do cut(listener)
case net_connect("127.0.0.1", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    case conn.read_line() {
      (R.error, why) -> { println(why) }
      (R.ok, line)   -> { println(line) }
    }
  }
}
|}
        in
        let expected_prefix = "the connection to 127.0.0.1:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
          && contains_substring output "closed mid-line"
        in
        Alcotest.(check bool) "mid-line close reason" true ok);
    tc "udp sockets exchange datagrams both ways" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, a) = net_udp_bind("127.0.0.1", 0)
const (R.ok, b) = net_udp_bind("127.0.0.1", 0)
a.send_to("127.0.0.1", b.port(), "datagram")
case b.recv_from() {
  (R.ok, (data, host, port)) -> {
    println(data)
    println(host == "127.0.0.1")
    println(port == a.port())
  }
  (R.error, why) -> { println("recv failed: ${why}") }
}
|}
        in
        Alcotest.(check string) "output" "datagram\ntrue\ntrue\n" output);
    tc "a udp receive deadline answers a precise reason" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, a) = net_udp_bind("127.0.0.1", 0)
a.set_timeout(0.1)
case a.recv_from() {
  (R.ok, _)      -> { println("received") }
  (R.error, why) -> { println(why) }
}
|}
        in
        let expected_prefix = "timed out waiting to receive on 127.0.0.1:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
        in
        Alcotest.(check bool) "udp timeout reason names the socket" true ok);
    tc "unix-domain sockets echo over the connection surface" (fun () ->
        let path = unix_test_path "echo" in
        let output, _events =
          run_det
            (Printf.sprintf
               {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write(line + "\n")
          serve(listener)
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_unix("%s")
do serve(listener)
case net_connect_unix("%s", 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello unix\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    println("done")
  }
}
|}
               path path)
        in
        Alcotest.(check string) "output" "hello unix\ndone\n" output);
    tc "a unix-domain listener has no port" (fun () ->
        let path = unix_test_path "port" in
        let message =
          run_det_raised
            (Printf.sprintf
               {|
const (R.ok, listener) = net_listen_unix("%s")
listener.port()
|}
               path)
        in
        Alcotest.(check string)
          "message"
          (Printf.sprintf "a unix-domain listener (unix socket %s) has no port"
             path)
          message);
    tc "connecting to an absent unix path answers a precise reason" (fun () ->
        let path = unix_test_path "absent" in
        let output, _events =
          run_det
            (Printf.sprintf
               {|case net_connect_unix("%s", 0.0) {
  (R.error, why) -> { println(why) }
  (R.ok, _)      -> { println("connected?!") }
}
|}
               path)
        in
        let expected_prefix = "cannot connect to unix socket " in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
        in
        Alcotest.(check bool) "absent-path reason" true ok);
    tc "resolution reaches addresses by name" (fun () ->
        let output, _events =
          run_det
            {|
const (R.ok, addrs) = net_resolve("localhost")
println(addrs.length() > 0)
|}
        in
        Alcotest.(check string) "output" "true\n" output);
    tc "connecting through a name resolves via the same path" (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write(line + "\n")
          serve(listener)
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen("127.0.0.1", 0)
do serve(listener)
case net_connect("localhost", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("by name\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "by name\ndone\n" output);
    tc "an unresolvable host answers a precise reason" (fun () ->
        let output, _events =
          run_det
            {|
case net_resolve("definitely not a host") {
  (R.error, why) -> { println(why) }
  (R.ok, _)      -> { println("resolved?!") }
}
|}
        in
        Alcotest.(check string)
          "output" "cannot resolve host `definitely not a host`\n" output);
    tc "udp sends resolve the peer by name" (fun () ->
        let output, _events =
          run_det
            {|
// Both sockets and the send resolve `localhost` the same way, so the
// first resolved address serves bind and send alike.
const (R.ok, a) = net_udp_bind("localhost", 0)
const (R.ok, b) = net_udp_bind("localhost", 0)
a.send_to("localhost", b.port(), "named")
case b.recv_from() {
  (R.ok, (data, _host, _port)) -> { println(data) }
  (R.error, why)               -> { println("recv failed: ${why}") }
}
|}
        in
        Alcotest.(check string) "output" "named\n" output);
    tc "a TLS handshake to a self-signed certificate fails closed" (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write(line + "\n")
          serve(listener)
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-cert.pem", "fixtures/tls-key.pem")
do serve(listener)
case net_tls_connect("localhost", listener.port(), 0.0) {
  (R.error, why) -> { println(why) }
  (R.ok, conn)   -> {
    conn.write("no\n")
    println("handshook?!")
  }
}
|}
        in
        let expected_prefix = "the TLS handshake with localhost:" in
        let ok =
          String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix
          && contains_substring output "verify"
        in
        Alcotest.(check bool) "verification fails closed" true ok);
    tc "TLS round-trips when verification is explicitly skipped" (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write(line + "\n")
          serve(listener)
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-cert.pem", "fixtures/tls-key.pem")
do serve(listener)
case net_tls_connect_insecure("localhost", listener.port(), 0.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("secret over tls\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "secret over tls\ndone\n" output);
    tc "a verified TLS handshake rides SSL_CERT_FILE's CA" (fun () ->
        (* The fixture CA signs fixtures/tls-server-cert.pem (SAN:
           localhost, 127.0.0.1), so the default verify paths — pointed
           at the CA by the environment — verify the handshake that the
           self-signed pair above can never pass. The same fixture
           serves the c binary from T51.5. *)
        let old = Sys.getenv_opt "SSL_CERT_FILE" in
        Unix.putenv "SSL_CERT_FILE" "fixtures/tls-ca.pem";
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("verified: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem")
do serve(listener)
case net_tls_connect("localhost", listener.port(), 0.0) {
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
        (match old with
        | Some v -> Unix.putenv "SSL_CERT_FILE" v
        | None -> Unix.unsetenv "SSL_CERT_FILE");
        Alcotest.(check string) "output" "verified: hello\ndone\n" output);
    tc "a TLS echo server and client meet in one process" (fun () ->
        (* Both ends handshake through one scheduler: the client parks
           on WANT_READ/WANT_WRITE while the server's accept parks on
           the same fd, and the loopback makes progress from both
           sides. This is also the shape of the c target's loopback
           test (emo_cli_test). *)
        let old = Sys.getenv_opt "SSL_CERT_FILE" in
        Unix.putenv "SSL_CERT_FILE" "fixtures/tls-ca.pem";
        let output, _events =
          run_det
            {|
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

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem")
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
        in
        (match old with
        | Some v -> Unix.putenv "SSL_CERT_FILE" v
        | None -> Unix.unsetenv "SSL_CERT_FILE");
        Alcotest.(check string) "output" "echo: loopback\ndone\n" output);
    tc "a TLS listener with a missing certificate answers a precise reason"
      (fun () ->
        let output, _events =
          run_det
            {|
case net_listen_tls("127.0.0.1", 0, "fixtures/absent-cert.pem", "fixtures/absent-key.pem") {
  (R.error, why) -> { println(why) }
  (R.ok, _)      -> { println("listening?!") }
}
|}
        in
        let expected_prefix =
          "cannot load the TLS certificate for 127.0.0.1:0"
        in
        Alcotest.(check bool)
          "missing-certificate reason" true
          (String.length output >= String.length expected_prefix
          && String.sub output 0 (String.length expected_prefix)
             = expected_prefix));
    tc "a TLS client trusts its own CA file" (fun () ->
        (* The same handshake as the SSL_CERT_FILE test, with the trust
           store named per connection instead of by the environment. *)
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("own ca: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem")
do serve(listener)
case net_tls_connect_with("localhost", listener.port(), 5.0, "fixtures/tls-ca.pem", "", "", "", false) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("client read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "own ca: hello\ndone\n" output);
    tc "server_name lets an IP connect verify against a DNS name" (fun () ->
        (* The fixture's SAN is DNS:localhost, so connecting to the IP
           verifies only when server_name names the certificate. *)
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("named: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem")
do serve(listener)
case net_tls_connect_with("127.0.0.1", listener.port(), 5.0, "fixtures/tls-ca.pem", "", "", "localhost", false) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("client read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "named: hello\ndone\n" output);
    tc "a server_name the certificate does not name fails verification"
      (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      conn.write("unexpected\n")
      conn.close()
    }
  }
}

const (R.ok, listener) = net_listen_tls("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem")
do serve(listener)
case net_tls_connect_with("127.0.0.1", listener.port(), 5.0, "fixtures/tls-ca.pem", "", "", "wrong.example", false) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    println("unexpected success")
    conn.close()
  }
}
|}
        in
        Alcotest.(check bool)
          "client refused the certificate" true
          (contains_substring output
             "connect failed: the TLS handshake with 127.0.0.1:");
        Alcotest.(check bool)
          "no response crossed the failed handshake" false
          (contains_substring output "unexpected"));
    tc "verifying an IP literal is refused with an actionable reason" (fun () ->
        (* X509_VERIFY_PARAM_set1_host, which ocaml-ssl's set_host uses,
           checks DNS names only; silently skipping verification for an
           address would make the same call verify on one target and not
           on another, so every target refuses it up front. *)
        let output, _events =
          run_det
            {|
case net_tls_connect("127.0.0.1", 9, 1.0) {
  (R.error, why) -> { println(why) }
  (R.ok, _)      -> { println("connected?!") }
}
|}
        in
        Alcotest.(check string)
          "output"
          "tls: cannot verify a certificate for the IP address `127.0.0.1`; \
           pass server_name with the certificate's DNS name\n"
          output);
    tc "mutual TLS admits a client whose certificate the server trusts"
      (fun () ->
        (* fixtures/tls-cert.pem is self-signed, so it doubles as the
           client certificate and the server's one-entry client CA. *)
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("mutual: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls_with("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem", "fixtures/tls-cert.pem", true)
do serve(listener)
case net_tls_connect_with("localhost", listener.port(), 5.0, "fixtures/tls-ca.pem", "fixtures/tls-cert.pem", "fixtures/tls-key.pem", "", false) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("client read failed: ${why}") }
      (R.ok, line)   -> { println(line) }
    }
    conn.close()
    println("done")
  }
}
|}
        in
        Alcotest.(check string) "output" "mutual: hello\ndone\n" output);
    tc "mutual TLS rejects a client that presents no certificate" (fun () ->
        let output, _events =
          run_det
            {|
def serve(listener TcpListener) Void {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("unexpected: " + line + "\n")
          conn.close()
        }
      }
    }
  }
}

const (R.ok, listener) = net_listen_tls_with("127.0.0.1", 0, "fixtures/tls-server-cert.pem", "fixtures/tls-server-key.pem", "fixtures/tls-cert.pem", true)
do serve(listener)
case net_tls_connect_with("localhost", listener.port(), 5.0, "fixtures/tls-ca.pem", "", "", "", false) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    case conn.read_line() {
      (R.error, why) -> { println("client read failed: ${why}") }
      (R.ok, line)   -> { println("unexpected: ${line}") }
    }
    conn.close()
  }
}
|}
        in
        Alcotest.(check bool)
          "the connection failed somewhere" true
          (contains_substring output "failed");
        Alcotest.(check bool)
          "no request reached the handler" false
          (contains_substring output "unexpected"));
    tc "networking is refused outside a scheduler" (fun () ->
        let diagnostic =
          match
            Emo_eval.run_without_scheduler (fun () ->
                let items =
                  Emo_parser.parse_program ~file:"<test>"
                    ~source:{|const c = net_connect("127.0.0.1", 1, 0.0)|}
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
              | None -> "no code"));
  ]

let () =
  Alcotest.run "emo_sched"
    [
      ("scheduler", scheduler_tests);
      ("isolation", isolation_tests);
      ("box", box_tests);
      ("determinism", determinism_tests);
      ("stress", stress_tests);
      ("net", net_tests);
    ]
