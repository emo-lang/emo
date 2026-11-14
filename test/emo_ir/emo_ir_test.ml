let tc name f = Alcotest.test_case name `Quick f

(* Parses and checks each module, then lowers the whole program. *)
let lower_program (modules : (string list * string) list) ~(entry : string list)
    : Emo_ir.program =
  let paths = List.map fst modules in
  let prepared =
    List.map
      (fun (path, source) ->
        let items =
          match
            Emo_parser.parse_program ~file:(String.concat "." path) ~source
          with
          | items -> items
          | exception Emo_lexer.Error d ->
              Alcotest.fail
                (Printf.sprintf "lex: %s" d.Emo_support.Diagnostic.message)
          | exception Emo_parser.Error d ->
              Alcotest.fail
                (Printf.sprintf "parse: %s" d.Emo_support.Diagnostic.message)
        in
        let _diags, _refs, _requires, types =
          Emo_check.check_module_typed ~modules:paths ~current:path items
        in
        { Emo_ir.mpath = path; mitems = items; mtypes = types })
      modules
  in
  Emo_ir.lower { Emo_ir.modules = prepared; entry; packages = [] }

let find_func program name =
  match
    List.find_opt (fun f -> f.Emo_ir.fname = name) program.Emo_ir.pfuncs
  with
  | Some f -> f
  | None ->
      Alcotest.fail
        (Printf.sprintf "no func `%s` in %d funcs" name
           (List.length program.Emo_ir.pfuncs))

(* A Block parameter is Unknown — the dynamic region keeps the function
   out of Stage B's specialization, exactly the gradual story. *)
let higher_order_source =
  {|
def call_it(f Block, n Int64) Int64 {
  return n
}
|}

let fib_source =
  {|
def fib(n Int64) Int64 {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
|}

let typed_fib_source =
  {|
def fib(n Int64) Int64 {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
|}

let ir_tests =
  [
    tc "a def with an Unknown region stays unspecialized" (fun () ->
        let program = lower_program [ ([], higher_order_source) ] ~entry:[] in
        let f = find_func program "call_it" in
        Alcotest.(check bool) "unspecialized" false f.Emo_ir.fspecializable);
    tc "a def returning without a path keeps dynamic result" (fun () ->
        let program = lower_program [ ([], fib_source) ] ~entry:[] in
        let f = find_func program "fib" in
        Alcotest.(check bool) "specialized" true f.Emo_ir.fspecializable;
        Alcotest.(check int) "param count" 1 (List.length f.Emo_ir.fparams));
    tc "a fully type-declared def specializes (Stage B completeness)" (fun () ->
        let program = lower_program [ ([], typed_fib_source) ] ~entry:[] in
        let f = find_func program "fib" in
        Alcotest.(check bool) "specialized" true f.Emo_ir.fspecializable);
    tc "qualified calls resolve to mangled globals" (fun () ->
        let program =
          lower_program
            [
              ([ "helper" ], {|def double(n Int64) Int64 {
  return n * 2
}|});
              ([ "app" ], {|def run() Int64 {
  return helper.double(21)
}|});
            ]
            ~entry:[ "app" ]
        in
        let f = find_func program "app__run" in
        let rec contains_call (stmts : Emo_ir.stmt list) =
          List.exists
            (fun s ->
              match s with
              | Emo_ir.Return_stmt
                  { desc = Emo_ir.Call { func = "helper__double"; _ }; _ } ->
                  true
              | Emo_ir.If { then_; else_; _ } ->
                  contains_call then_ || contains_call else_
              | _ -> false)
            stmts
        in
        Alcotest.(check bool)
          "resolved call" true
          (contains_call f.Emo_ir.fbody);
        ignore program);
    tc "named arguments reorder to parameter order" (fun () ->
        let program =
          lower_program
            [
              ( [ "app" ],
                {|
def sub(a Int64, b Int64) Int64 {
  return a - b
}

def run() Int64 {
  return sub(b: 1, a: 5)
}
|}
              );
            ]
            ~entry:[ "app" ]
        in
        let f = find_func program "app__run" in
        let rec first_call_args (stmts : Emo_ir.stmt list) =
          List.concat_map
            (fun s ->
              match s with
              | Emo_ir.Return_stmt { desc = Emo_ir.Call { args; _ }; _ } ->
                  [ args ]
              | Emo_ir.If { then_; else_; _ } ->
                  first_call_args then_ @ first_call_args else_
              | _ -> [])
            stmts
        in
        (match first_call_args f.Emo_ir.fbody with
        | [ args ] -> (
            match List.map (fun a -> a.Emo_ir.desc) args with
            | [ Emo_ir.Const (L_int 5L); Emo_ir.Const (L_int 1L) ] -> ()
            | other ->
                Alcotest.fail
                  (Printf.sprintf "wrong order %s"
                     (Int.to_string (List.length other))))
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected one call, got %d" (List.length other)));
        ignore program);
    tc "a class lowers init and methods with self" (fun () ->
        let program =
          lower_program
            [
              ( [ "app" ],
                {|
class User {
  def init(name String) {
    self.name = name
  }

  def greet() String {
    return "hi"
  }
}
|}
              );
            ]
            ~entry:[ "app" ]
        in
        (match program.Emo_ir.pclasses with
        | [ c ] ->
            Alcotest.(check string) "class name" "app__User" c.Emo_ir.cname;
            (match c.Emo_ir.cinit with
            | Some init -> (
                match init.Emo_ir.fparams with
                | ("self", _) :: _ -> ()
                | _ -> Alcotest.fail "init takes self first")
            | None -> Alcotest.fail "expected an init");
            Alcotest.(check int)
              "method count" 1
              (List.length c.Emo_ir.cmethods)
        | other ->
            Alcotest.fail (Printf.sprintf "%d classes" (List.length other)));
        ignore program);
    tc "enum members lower to constructors" (fun () ->
        let program =
          lower_program
            [
              ( [ "app" ],
                {|
enum Color { red, green, blue }

def pick() Color {
  return Color.red
}
|}
              );
            ]
            ~entry:[ "app" ]
        in
        let f = find_func program "app__pick" in
        let rec is_make_enum (stmts : Emo_ir.stmt list) =
          List.exists
            (fun s ->
              match s with
              | Emo_ir.Return_stmt
                  {
                    desc =
                      Emo_ir.Make_enum
                        { enum_name = "app.Color"; member = "red" };
                    _;
                  } ->
                  true
              | _ -> false)
            stmts
        in
        Alcotest.(check bool) "make_enum" true (is_make_enum f.Emo_ir.fbody);
        ignore program);
    tc "the entry's top-level statements lower to pinit" (fun () ->
        let program =
          lower_program [ ([], {|println(1)
println(2)|}) ] ~entry:[]
        in
        Alcotest.(check int) "pinit length" 2 (List.length program.Emo_ir.pinit));
    tc "a destructured binding desugars to a one-arm case" (fun () ->
        let program =
          lower_program
            [
              ( [ "app" ],
                {|
def probe(t (R, Int64)) Int64 {
  const (R.ok, body) = t
  return body
}
|}
              );
            ]
            ~entry:[ "app" ]
        in
        let f = find_func program "app__probe" in
        (match f.Emo_ir.fbody with
        | [ Emo_ir.Case { scrutinee; branches = [ branch ]; _ } ] ->
            Alcotest.(check bool) "no guard" true (branch.Emo_ir.guard = None);
            Alcotest.(check int) "one arm" 1 (List.length branch.Emo_ir.body);
            (match branch.Emo_ir.body with
            | [ Emo_ir.Return_stmt { desc = Emo_ir.Var name; _ } ] ->
                Alcotest.(check string) "bound name" "body" name
            | other ->
                Alcotest.fail
                  (Printf.sprintf "expected the wrapped return, got %d stmts"
                     (List.length other)));
            Alcotest.(check string)
              "scrutinee" "t"
              (match scrutinee.Emo_ir.desc with
              | Emo_ir.Var name -> name
              | _ -> "other")
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected one Case stmt, got %d"
                 (List.length other)));
        ignore program);
    tc "a binding's name is in scope for its successors" (fun () ->
        let program =
          lower_program
            [
              ( [ "app" ],
                {|
def probe(n Int64) Int64 {
  const v = n + 1
  return v
}
|}
              );
            ]
            ~entry:[ "app" ]
        in
        let f = find_func program "app__probe" in
        (match List.rev f.Emo_ir.fbody with
        | Emo_ir.Return_stmt { desc = Emo_ir.Var name; _ } :: _ ->
            Alcotest.(check string) "reads the binding" "v" name
        | Emo_ir.Return_stmt _ :: _ ->
            Alcotest.fail "the trailing return does not read `v` directly"
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected a trailing return, got %d stmts"
                 (List.length other)));
        ignore program);
    tc "a def's value stays native when the target specializes" (fun () ->
        let program =
          lower_program
            [
              ( [],
                {|
def twice(x Int64) Int64 {
  return x * 2
}

def keep(n Int64) Int64 {
  const f = twice
  return n
}
|}
              );
            ]
            ~entry:[]
        in
        Alcotest.(check bool)
          "twice specialized" true
          (find_func program "twice").Emo_ir.fspecializable;
        Alcotest.(check bool)
          "keep specialized" true
          (find_func program "keep").Emo_ir.fspecializable);
    tc "a def's value of a dynamic def keeps the body dynamic" (fun () ->
        let program =
          lower_program
            [
              ( [],
                {|
def apply_it(f Block, n Int64) Int64 {
  return n
}

def keep(n Int64) Int64 {
  const f = apply_it
  return n
}
|}
              );
            ]
            ~entry:[]
        in
        Alcotest.(check bool)
          "apply_it dynamic" false
          (find_func program "apply_it").Emo_ir.fspecializable;
        Alcotest.(check bool)
          "keep dynamic" false (find_func program "keep").Emo_ir.fspecializable);
    tc "container literals keep a body dynamic" (fun () ->
        let program =
          lower_program
            [
              ( [],
                {|
def tuple_holder(n Int64) Int64 {
  const p = (n, n + 1)
  return n
}

def array_holder(n Int64) Int64 {
  const a = [n, n]
  return n
}
|}
              );
            ]
            ~entry:[]
        in
        Alcotest.(check bool)
          "tuple dynamic" false
          (find_func program "tuple_holder").Emo_ir.fspecializable;
        Alcotest.(check bool)
          "array dynamic" false
          (find_func program "array_holder").Emo_ir.fspecializable);
    tc "enum members and type values stay native" (fun () ->
        let program =
          lower_program
            [
              ( [],
                {|
enum Kind { fast, slow }

def pick(n Int64) String {
  const k = Kind.fast
  const t = Kind
  case k {
    Kind.fast -> { return "fast" }
    Kind.slow -> { return "slow" }
  }
}
|}
              );
            ]
            ~entry:[]
        in
        Alcotest.(check bool)
          "pick specialized" true
          (find_func program "pick").Emo_ir.fspecializable);
    tc "a non-tail if keeps its branch's trailing call as an effect" (fun () ->
        (* A Void body's tail rewrite keys on exit position: a bare call
           ending an `if` that is *not* the body's last statement is still
           an effect. Folding it into a return kills the rest of the block —
           the shape that turned the shell's fork child into a fork loop. *)
        let program =
          lower_program
            [
              ( [],
                {|
def note(n Int64) Void {
  return
}

def run(n Int64) Void {
  if n > 0 {
    note(n)
  }
  if n > 1 {
    note(n + 1)
  }
  note(n + 2)
}
|} );
            ]
            ~entry:[]
        in
        let f = find_func program "run" in
        let effect_call = function
          | [ Emo_ir.Effect { desc = Emo_ir.Call { func; _ }; _ } ] -> func
          | _ -> "not an effect call"
        in
        (match f.Emo_ir.fbody with
        | [ Emo_ir.If { then_; _ }; Emo_ir.If { then_ = then2; _ }; last ] ->
            Alcotest.(check string)
              "first branch keeps the effect" "note"
              (effect_call then_);
            Alcotest.(check string)
              "second branch keeps the effect" "note"
              (effect_call then2);
            (match last with
            | Emo_ir.Return_stmt { desc = Emo_ir.Call { func; _ }; _ } ->
                Alcotest.(check string) "the body's last call is a return" "note"
                  func
            | _ -> Alcotest.fail "expected the body's last call to be a return")
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected two ifs and a tail call, got %d stmts"
                 (List.length other)));
        ignore program);
    tc "a tail-position if returns from both branches" (fun () ->
        let program =
          lower_program
            [
              ( [],
                {|
def note(n Int64) Void {
  return
}

def pick(n Int64) Void {
  if n > 0 {
    note(n)
  } else {
    note(n + 1)
  }
}
|} );
            ]
            ~entry:[]
        in
        let f = find_func program "pick" in
        let is_return_call = function
          | [ Emo_ir.Return_stmt { desc = Emo_ir.Call _; _ } ] -> true
          | _ -> false
        in
        (match f.Emo_ir.fbody with
        | [ Emo_ir.If { then_; else_; _ } ] ->
            Alcotest.(check bool) "then branch is a tail return" true
              (is_return_call then_);
            Alcotest.(check bool) "else branch is a tail return" true
              (is_return_call else_)
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected one tail-position if, got %d stmts"
                 (List.length other)));
        ignore program);
    tc "a constructor's init keeps its exit call an effect" (fun () ->
        (* A ctor factory must return the instance, so init's
           exit-position bare call cannot lower as the return it is —
           the backends' return machinery would hand the factory the
           call's Void value instead of the instance (found 2026-11-14:
           crypto.sha2's Digest.new returned the void box, and the first
           self cast trapped). *)
        let program =
          lower_program
            [
              ( [],
                {|
def warm(x Int64) Void {
  const q = x + 1
}

class Thing {
  def init(n Int64) {
    self.n = n
    if n > 0 {
      warm(n)
    } else {
      warm(n + 1)
    }
  }

  def get() Int64 {
    return self.n
  }
}
|} );
            ]
            ~entry:[]
        in
        (match program.Emo_ir.pclasses with
        | [ c ] ->
            (match c.Emo_ir.cinit with
            | Some init -> (
                match init.Emo_ir.fbody with
                | [ _; Emo_ir.If { then_; else_; _ } ] ->
                    let effect_call = function
                      | [ Emo_ir.Effect { desc = Emo_ir.Call { func; _ }; _ } ] ->
                          func
                      | _ -> "not an effect call"
                    in
                    Alcotest.(check string)
                      "then branch keeps the effect" "warm"
                      (effect_call then_);
                    Alcotest.(check string)
                      "else branch keeps the effect" "warm"
                      (effect_call else_)
                | other ->
                    Alcotest.fail
                      (Printf.sprintf
                         "expected set-field and one if, got %d stmts"
                         (List.length other)))
            | None -> Alcotest.fail "expected an init")
        | other ->
            Alcotest.fail (Printf.sprintf "%d classes" (List.length other)));
        ignore program);
    tc "a def named like a runtime door is the program's call" (fun () ->
        (* The doors live below the program's symbols: `time_of` is a
           bare `time_`-prefixed name, and the call must answer the
           program's own def, not the time door the prefix matches
           (found 2026-11-14: uuid_demo's helper lowered as a runtime
           door, and the wasm build refused it). *)
        let program =
          lower_program
            [
              ( [],
                {|
def time_of(ms Int64) Int64 {
  return ms + 1
}

def use() Int64 {
  return time_of(5)
}
|} );
            ]
            ~entry:[]
        in
        let f = find_func program "use" in
        (match f.Emo_ir.fbody with
        | [ Emo_ir.Return_stmt { desc = Emo_ir.Call { func; _ }; _ } ] ->
            Alcotest.(check string) "the call is the program's def"
              "time_of" func
        | other ->
            Alcotest.fail
              (Printf.sprintf "expected one return call, got %d stmts"
                 (List.length other)));
        ignore program);
  ]

let () = Alcotest.run ~bail:true "emo_ir" [ ("ir", ir_tests) ]
