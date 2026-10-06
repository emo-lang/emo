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
  Emo_ir.lower { Emo_ir.modules = prepared; entry }

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
let higher_order_source = {|
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
    tc "a fully annotated def specializes (Stage B completeness)" (fun () ->
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
                      Emo_ir.Make_enum { enum_name = "Color"; member = "red" };
                    _;
                  } ->
                  true
              | _ -> false)
            stmts
        in
        Alcotest.(check bool) "make_enum" true (is_make_enum f.Emo_ir.fbody);
        ignore program);
    tc "the entry's top-level statements lower to pinit" (fun () ->
        let program = lower_program [ ([], {|println(1)
println(2)|}) ] ~entry:[] in
        Alcotest.(check int) "pinit length" 2 (List.length program.Emo_ir.pinit));
  ]

let () = Alcotest.run "emo_ir" [ ("ir", ir_tests) ]
