open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let render pp v =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  Format.pp_set_margin fmt 10000;
  pp fmt v;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let pp_list pp fmt xs =
  Format.pp_print_list
    ~pp_sep:(fun f () -> Format.pp_print_char f ' ')
    pp fmt xs

let binop_spelling = function
  | Emo_ast.Eq -> "=="
  | Emo_ast.Ne -> "!="
  | Emo_ast.Lt -> "<"
  | Emo_ast.Le -> "<="
  | Emo_ast.Gt -> ">"
  | Emo_ast.Ge -> ">="
  | Emo_ast.Add -> "+"
  | Emo_ast.Sub -> "-"
  | Emo_ast.Mul -> "*"
  | Emo_ast.Div -> "/"
  | Emo_ast.Mod -> "%"
  | Emo_ast.And -> "&&"
  | Emo_ast.Or -> "||"

let rec pp_expr fmt (e : Emo_ast.expr) =
  match e.Emo_ast.desc with
  | Int n -> Format.pp_print_int fmt n
  | Float f -> Format.fprintf fmt "%g" f
  | Char c -> Format.fprintf fmt "%C" c
  | Bool b -> Format.fprintf fmt "%b" b
  | String s -> Format.fprintf fmt "%S" s
  | Interpolated parts ->
      Format.fprintf fmt "(string @[<hov>%a@])" (pp_list pp_part) parts
  | Ident s -> Format.pp_print_string fmt s
  | Type_ident s -> Format.fprintf fmt "(type %s)" s
  | Self -> Format.pp_print_string fmt "self"
  | Member (e, n) -> Format.fprintf fmt "(%a.%s)" pp_expr e n
  | Index (e, i) -> Format.fprintf fmt "(%a[%a])" pp_expr e pp_expr i
  | Call (callee, ([] as args)) ->
      Format.fprintf fmt "(%a call%a)" pp_expr callee (pp_list pp_arg) args
  | Call (callee, args) ->
      Format.fprintf fmt "(%a call @[<hov>%a@])" pp_expr callee (pp_list pp_arg)
        args
  | Arrow_block (params, body) ->
      Format.fprintf fmt "(block @[<hov>%a|%a@])" (pp_list pp_param) params
        (pp_list pp_stmt) body
  | Tuple ([] as es) -> Format.fprintf fmt "(tuple%a)" (pp_list pp_expr) es
  | Tuple es -> Format.fprintf fmt "(tuple @[<hov>%a@])" (pp_list pp_expr) es
  | Unary (op, e) ->
      Format.fprintf fmt "(%s %a)"
        (match op with Emo_ast.Not -> "!" | Emo_ast.Neg -> "-")
        pp_expr e
  | Binary (op, l, r) ->
      Format.fprintf fmt "(%s %a %a)" (binop_spelling op) pp_expr l pp_expr r
  | Do e -> Format.fprintf fmt "(do %a)" pp_expr e

and pp_part fmt = function
  | Emo_ast.Literal_text s -> Format.fprintf fmt "%S" s
  | Emo_ast.Part_expr e -> Format.fprintf fmt "(interp %a)" pp_expr e

and pp_arg fmt { Emo_ast.arg_name; arg_value } =
  match arg_name with
  | Some n -> Format.fprintf fmt "%s: %a" n pp_expr arg_value
  | None -> pp_expr fmt arg_value

and pp_param fmt { Emo_ast.param_name; param_type } =
  Format.fprintf fmt "(param %s %a)" param_name pp_type_ann param_type

and pp_type_ann fmt { Emo_ast.type_desc; _ } =
  match type_desc with
  | Emo_ast.Named_type s -> Format.pp_print_string fmt s
  | Emo_ast.Applied_type (s, args) ->
      Format.fprintf fmt "%s[%a]" s (pp_list pp_type_ann) args
  | Emo_ast.Tuple_type ts ->
      Format.fprintf fmt "(tuple_type @[<hov>%a@])" (pp_list pp_type_ann) ts

and pp_stmt fmt (s : Emo_ast.stmt) =
  match s.Emo_ast.stmt_desc with
  | Emo_ast.Expr_stmt e -> pp_expr fmt e
  | Emo_ast.Binding { mutable_; name; init } ->
      Format.fprintf fmt "(%s %s %a)"
        (if mutable_ then "var" else "const")
        name pp_expr init
  | Emo_ast.Assign { target; value } ->
      Format.fprintf fmt "(= %a %a)" pp_expr target pp_expr value
  | Emo_ast.Return None -> Format.pp_print_string fmt "return"
  | Emo_ast.Return (Some e) -> Format.fprintf fmt "(return %a)" pp_expr e
  | Emo_ast.If { cond; then_body; else_body } -> (
      Format.fprintf fmt "(if %a then @[<hov>%a@]" pp_expr cond
        (pp_list pp_stmt) then_body;
      match else_body with
      | None -> Format.fprintf fmt "@])"
      | Some body ->
          Format.fprintf fmt " else @[<hov>%a@])" (pp_list pp_stmt) body)
  | Emo_ast.Case { scrutinee; branches } ->
      Format.fprintf fmt "(case %a @[<hov>%a@])" pp_expr scrutinee
        (pp_list pp_branch) branches
  | Emo_ast.Receive branches ->
      Format.fprintf fmt "(receive @[<hov>%a@])" (pp_list pp_branch) branches
  | Emo_ast.Send { target; message } ->
      Format.fprintf fmt "(<- %a %a)" pp_expr target pp_expr message

and pp_branch fmt { Emo_ast.pattern; guard; body } =
  Format.fprintf fmt "(branch %a%a |@[<hov>%a@])" pp_pattern pattern
    (fun fmt g ->
      match g with
      | None -> ()
      | Some e -> Format.fprintf fmt " when %a" pp_expr e)
    guard (pp_list pp_stmt) body

and pp_pattern fmt (p : Emo_ast.pattern) =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Enum_member (t, m) -> Format.fprintf fmt "%s.%s" t m
  | Emo_ast.Pattern_literal l -> pp_literal fmt l
  | Emo_ast.Pattern_binding s -> Format.pp_print_string fmt s
  | Emo_ast.Wildcard -> Format.pp_print_string fmt "_"
  | Emo_ast.Tuple_pattern ps ->
      Format.fprintf fmt "(tuple @[<hov>%a@])" (pp_list pp_pattern) ps

and pp_literal fmt = function
  | Emo_ast.L_int n -> Format.pp_print_int fmt n
  | Emo_ast.L_float f -> Format.fprintf fmt "%g" f
  | Emo_ast.L_char c -> Format.fprintf fmt "%C" c
  | Emo_ast.L_string s -> Format.fprintf fmt "%S" s
  | Emo_ast.L_bool b -> Format.fprintf fmt "%b" b

and pp_item fmt (i : Emo_ast.item) =
  match i.Emo_ast.item_desc with
  | Emo_ast.Item_stmt s -> pp_stmt fmt s
  | Emo_ast.Item_def d -> pp_fun_def fmt d
  | Emo_ast.Item_class c -> pp_class_def fmt c
  | Emo_ast.Item_interface i -> pp_interface_def fmt i
  | Emo_ast.Item_enum e -> pp_enum_def fmt e

and pp_params fmt = function
  | [] -> Format.pp_print_string fmt "()"
  | ps -> pp_list pp_param fmt ps

and pp_fun_def fmt (d : Emo_ast.fun_def) =
  match d.Emo_ast.def_return with
  | None ->
      Format.fprintf fmt "(init %a|@[<hov>%a@])" pp_params d.Emo_ast.def_params
        (pp_list pp_stmt) d.Emo_ast.def_body
  | Some ret ->
      Format.fprintf fmt "(def %s %a %a |@[<hov>%a@])" d.Emo_ast.def_name
        pp_params d.Emo_ast.def_params pp_type_ann ret (pp_list pp_stmt)
        d.Emo_ast.def_body

and pp_method_sig fmt (s : Emo_ast.method_sig) =
  Format.fprintf fmt "(sig %s @[<hov>%a@] %a)" s.Emo_ast.sig_name pp_params
    s.Emo_ast.sig_params pp_type_ann s.Emo_ast.sig_return

and pp_field fmt (f : Emo_ast.field) =
  Format.fprintf fmt "(field %s)" f.Emo_ast.field_name

and pp_class_def fmt (c : Emo_ast.class_def) =
  Format.fprintf fmt
    "(class %s @[<hov>(fields @[<hov>%a@]) (init %a|@[<hov>%a@]) %a@])"
    c.Emo_ast.class_name (pp_list pp_field) c.Emo_ast.class_fields pp_params
    c.Emo_ast.class_init.Emo_ast.def_params (pp_list pp_stmt)
    c.Emo_ast.class_init.Emo_ast.def_body (pp_list pp_fun_def)
    c.Emo_ast.class_methods

and pp_interface_def fmt (i : Emo_ast.interface_def) =
  match i.Emo_ast.interface_methods with
  | [] -> Format.fprintf fmt "(interface %s)" i.Emo_ast.interface_name
  | methods ->
      Format.fprintf fmt "(interface %s @[<hov>%a@])" i.Emo_ast.interface_name
        (pp_list pp_method_sig) methods

and pp_enum_def fmt (e : Emo_ast.enum_def) =
  Format.fprintf fmt "(enum %s @[<hov>%a@])" e.Emo_ast.enum_name
    (pp_list (fun fmt m -> Format.pp_print_string fmt m.Emo_ast.member_name))
    e.Emo_ast.enum_members

let expr : Emo_ast.expr Alcotest.testable =
  Alcotest.testable pp_expr (fun a b ->
      String.equal (render pp_expr a) (render pp_expr b))

let stmt : Emo_ast.stmt Alcotest.testable =
  Alcotest.testable pp_stmt (fun a b ->
      String.equal (render pp_stmt a) (render pp_stmt b))

let pattern : Emo_ast.pattern Alcotest.testable =
  Alcotest.testable pp_pattern (fun a b ->
      String.equal (render pp_pattern a) (render pp_pattern b))

let parse_expr source = Emo_parser.parse_expr_source ~file:"test.emo" ~source

let parse_err source =
  match parse_expr source with
  | _ -> Alcotest.fail "expected a parse error"
  | exception Emo_parser.Error diagnostic -> diagnostic

let code_of diagnostic =
  match diagnostic.Diagnostic.code with Some c -> c | None -> ""

let expression_tests =
  [
    tc "multiplication binds tighter than addition" (fun () ->
        Alcotest.check expr "shape" (parse_expr "1 + 2 * 3")
          (parse_expr "1 + (2 * 3)"));
    tc "and binds tighter than or" (fun () ->
        Alcotest.check expr "shape"
          (parse_expr "a && b || !c")
          (parse_expr "(a && b) || (! c)"));
    tc "unary binds tighter than multiplication" (fun () ->
        Alcotest.check expr "shape" (parse_expr "-a * b")
          (parse_expr "(-a) * b"));
    tc "postfix binds tighter than unary" (fun () ->
        Alcotest.(check string)
          "shape" "(- (a.b))"
          (render pp_expr (parse_expr "-a.b")));
    tc "comparisons do not chain" (fun () ->
        let diagnostic = parse_err "a < b < c" in
        Alcotest.(check string) "code" "E2002" (code_of diagnostic));
    tc "binary operators are left-associative" (fun () ->
        Alcotest.check expr "shape" (parse_expr "a - b - c")
          (parse_expr "(a - b) - c"));
    tc "member and index chain postfix" (fun () ->
        Alcotest.(check string)
          "shape" "(((a.b)[0]).c)"
          (render pp_expr (parse_expr "a.b[0].c")));
    tc "single operator-free parens make one-element tuples" (fun () ->
        Alcotest.(check string)
          "shape" "(tuple a)"
          (render pp_expr (parse_expr "(a)")));
    tc "operator parens are groupings" (fun () ->
        Alcotest.check expr "shape" (parse_expr "(a + b)") (parse_expr "a + b"));
    tc "empty parens are the empty tuple" (fun () ->
        Alcotest.(check string)
          "shape" "(tuple)"
          (render pp_expr (parse_expr "()")));
    (* the printer emits a trailing space for empty lists *)
    tc "trailing comma in a tuple is rejected" (fun () ->
        let diagnostic = parse_err "(a,)" in
        Alcotest.(check string) "code" "E2004" (code_of diagnostic));
    tc "spans cover the whole expression" (fun () ->
        let e = parse_expr "1 + 2" in
        Alcotest.(check int) "start" 0 e.Emo_ast.span.Emo_support.Span.start;
        Alcotest.(check int) "stop" 5 e.Emo_ast.span.Emo_support.Span.stop);
  ]

let parse_program source = Emo_parser.parse_program ~file:"test.emo" ~source

let program_err source =
  match parse_program source with
  | _ -> Alcotest.fail "expected a parse error"
  | exception Emo_parser.Error diagnostic -> diagnostic

let call_tests =
  [
    tc "positional and named arguments mix" (fun () ->
        Alcotest.(check string)
          "shape" "(f call a b k: c)"
          (render pp_expr (parse_expr "f(a, b, k: c)")));
    tc "named arguments come first in the shape" (fun () ->
        Alcotest.(check string)
          "shape" "(hello call name: world)"
          (render pp_expr (parse_expr "hello(name: world)")));
    tc "call parens must touch the callee" (fun () ->
        let diagnostic = program_err "f (a)" in
        Alcotest.(check string) "code" "E2003" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:3"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "trailing block sugar adds a final block argument" (fun () ->
        Alcotest.(check string)
          "shape" "(page call title: home (block |(render call)))"
          (render pp_expr (parse_expr "page(title: home) { render() }")));
    tc "a trailing block must follow on the same line" (fun () ->
        let diagnostic = program_err "page(title: home)\n{ render() }" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "argument lists reject trailing commas" (fun () ->
        let diagnostic = parse_err "f(a,)" in
        Alcotest.(check string) "code" "E2003" (code_of diagnostic));
    tc "a block holds one statement per line" (fun () ->
        Alcotest.(check string)
          "shape" "(f call a (block |x y))"
          (render pp_expr (parse_expr "f(a) {\n  x\n  y\n}")));
    tc "return may omit its value at the end of a block" (fun () ->
        Alcotest.(check string)
          "shape" "(f call (block |return))"
          (render pp_expr (parse_expr "f() {\n  return\n}")));
    tc "same-line statements are rejected" (fun () ->
        let diagnostic = program_err "f() { a b }" in
        Alcotest.(check string) "code" "E2002" (code_of diagnostic));
    tc "programs are newline-separated statements" (fun () ->
        match parse_program "a\nb" with
        | [ first; second ] ->
            Alcotest.(check string) "first" "a" (render pp_item first);
            Alcotest.(check string) "second" "b" (render pp_item second)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 2 statements, got %d"
                 (List.length stmts)));
  ]

let control_tests =
  [
    tc "an arrow block takes annotated parameters" (fun () ->
        Alcotest.(check string)
          "shape" "(block (param x Int) (param y Float)|(return x))"
          (render pp_expr (parse_expr "-> (x Int, y Float) {\n  return x\n}")));
    tc "an arrow block may omit its parameters" (fun () ->
        Alcotest.(check string)
          "shape" "(block |(return 1))"
          (render pp_expr (parse_expr "-> {\n  return 1\n}")));
    tc "arrow block parameters need annotations" (fun () ->
        let diagnostic = parse_err "-> (x) { x }" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "if without else" (fun () ->
        match parse_program "if a {\n  b\n}" with
        | [ if_stmt ] ->
            Alcotest.(check string)
              "shape" "(if a then b)" (render pp_item if_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "if with else" (fun () ->
        match parse_program "if a {\n  b\n} else {\n  c\n}" with
        | [ if_stmt ] ->
            Alcotest.(check string)
              "shape" "(if a then b else c)" (render pp_item if_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "else must stay on the closing brace's line" (fun () ->
        let diagnostic = program_err "if a {\n  b\n}\nelse {\n  c\n}" in
        Alcotest.(check string) "code" "E2005" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:4:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "else-if chaining does not exist" (fun () ->
        let diagnostic = program_err "if a {\n  b\n} else if c {\n  d\n}" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "a further test is an if nested in the else block" (fun () ->
        match
          parse_program "if a {\n  b\n} else {\n  if c {\n    d\n  }\n}"
        with
        | [ if_stmt ] ->
            Alcotest.(check string)
              "shape" "(if a then b else (if c then d))"
              (render pp_item if_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "the if body opens on the condition's line" (fun () ->
        let diagnostic = program_err "if a\n{ b }" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "if works as a statement inside blocks" (fun () ->
        Alcotest.(check string)
          "shape" "(f call (block |(if done then return) return))"
          (render pp_expr
             (parse_expr "f() {\n  if done {\n    return\n  }\n  return\n}")));
  ]

let stmt_tests =
  [
    tc "const and var bindings" (fun () ->
        match parse_program "const x = 1\nvar y = x + 2" with
        | [ x; y ] ->
            Alcotest.(check string) "const" "(const x 1)" (render pp_item x);
            Alcotest.(check string) "var" "(var y (+ x 2))" (render pp_item y)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 2 statements, got %d"
                 (List.length stmts)));
    tc "a binding name cannot end in a question mark" (fun () ->
        let diagnostic = program_err "const is_x? = true" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
    tc "the initializer stays on the = line" (fun () ->
        let diagnostic = program_err "const x =\n1" in
        Alcotest.(check string) "code" "E2002" (code_of diagnostic));
    tc "send statements carry target and message" (fun () ->
        match parse_program "pid <- message" with
        | [ send_stmt ] ->
            Alcotest.(check string)
              "shape" "(<- pid message)" (render pp_item send_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "send targets may be member paths" (fun () ->
        match parse_program "box.value <- 1" with
        | [ send_stmt ] ->
            Alcotest.(check string)
              "shape" "(<- (box.value) 1)" (render pp_item send_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "do wraps a call and yields the pid" (fun () ->
        Alcotest.(check string)
          "shape" "(do (worker call x))"
          (render pp_expr (parse_expr "do worker(x)")));
    tc "do accepts an immediately invoked block" (fun () ->
        Alcotest.(check string)
          "shape" "(do ((block |(return 1)) call))"
          (render pp_expr (parse_expr "do -> {\n  return 1\n}()")));
    tc "do rejects a non-call operand" (fun () ->
        let diagnostic = parse_err "do x" in
        Alcotest.(check string) "code" "E2008" (code_of diagnostic));
    tc "case matches enum members and wildcard" (fun () ->
        match
          parse_program
            "case c {\n  Color.red -> { return 1 }\n  _ -> { return 2 }\n}"
        with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape"
              "(case c (branch Color.red |(return 1)) (branch _ |(return 2)))"
              (render pp_item case_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "case branches may carry guards" (fun () ->
        match
          parse_program
            "case c {\n\
            \  Color.red when loud -> { return 1 }\n\
            \  _ -> { return 2 }\n\
             }"
        with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape"
              "(case c (branch Color.red when loud |(return 1)) (branch _ \
               |(return 2)))"
              (render pp_item case_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "tuple patterns destructure by position" (fun () ->
        match
          parse_program "case p {\n  (Color.red, count) -> { return count }\n}"
        with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape"
              "(case p (branch (tuple Color.red count) |(return count)))"
              (render pp_item case_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "a bare type name is not a pattern" (fun () ->
        let diagnostic = program_err "case c {\n  Red -> { return 1 }\n}" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
    tc "a bare lowercase name is a binding pattern" (fun () ->
        match parse_program "case c {\n  other -> { return 1 }\n}" with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape" "(case c (branch other |(return 1)))"
              (render pp_item case_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "branches are separated by newlines" (fun () ->
        let diagnostic =
          program_err "case c { Color.red -> { return 1 } _ -> { return 2 } }"
        in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
    tc "receive reuses the case branch shape" (fun () ->
        match parse_program "receive {\n  (from, msg) -> { return msg }\n}" with
        | [ receive_stmt ] ->
            Alcotest.(check string)
              "shape" "(receive (branch (tuple from msg) |(return msg)))"
              (render pp_item receive_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
  ]

let string_tests =
  [
    tc "a plain string is a string literal" (fun () ->
        Alcotest.(check string)
          "shape" "\"hello\""
          (render pp_expr (parse_expr "\"hello\"")));
    tc "an empty string is empty" (fun () ->
        Alcotest.(check string)
          "shape" "\"\""
          (render pp_expr (parse_expr "\"\"")));
    tc "interpolation reassembles the parts" (fun () ->
        Alcotest.(check string)
          "shape" "(string \"a \" (interp x) \" b\")"
          (render pp_expr (parse_expr "\"a ${x} b\"")));
    tc "consecutive interpolations keep their order" (fun () ->
        Alcotest.(check string)
          "shape" "(string (interp a) (interp b))"
          (render pp_expr (parse_expr "\"${a}${b}\"")));
    tc "a string may be interpolation only" (fun () ->
        Alcotest.(check string)
          "shape" "(string (interp x))"
          (render pp_expr (parse_expr "\"${x}\"")));
    tc "interpolation holds full expressions" (fun () ->
        Alcotest.(check string)
          "shape" "(string (interp (f call 1)))"
          (render pp_expr (parse_expr "\"${f(1)}\"")));
    tc "nested strings interpolate correctly" (fun () ->
        Alcotest.(check string)
          "shape" "(string \"a \" (interp \"b\") \" c\")"
          (render pp_expr (parse_expr "\"a ${ \"b\" } c\"")));
    tc "plain string patterns match" (fun () ->
        match parse_program "case s {\n  \"red\" -> { return 1 }\n}" with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape" "(case s (branch \"red\" |(return 1)))"
              (render pp_item case_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "interpolated strings are not patterns" (fun () ->
        let diagnostic =
          program_err "case s {\n  \"a${b}c\" -> { return 1 }\n}"
        in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
  ]

let golden_tests =
  [
    tc "the full postfix chain pins precedence" (fun () ->
        Alcotest.(check string)
          "shape" "(((((x.foo) call 1)[i]).bar?) call)"
          (render pp_expr (parse_expr "x.foo(1)[i].bar?()")));
    tc "dangling operators continue the expression" (fun () ->
        Alcotest.check expr "plus" (parse_expr "1 +\n2") (parse_expr "1 + 2");
        Alcotest.check expr "and-or"
          (parse_expr "a &&\n  b ||\n  c")
          (parse_expr "a && b || c"));
    tc "call arguments span lines" (fun () ->
        Alcotest.(check string)
          "shape" "(f call a b)"
          (render pp_expr (parse_expr "f(\n  a,\n  b\n)")));
    tc "README: raising an exception" (fun () ->
        Alcotest.(check string)
          "shape"
          "(((type Exception).new) call message: \"something went wrong\")"
          (render pp_expr
             (parse_expr "Exception.new(message: \"something went wrong\")")));
    tc "README: narrowing with is" (fun () ->
        Alcotest.(check string)
          "shape" "((u.is) call (type Greeter))"
          (render pp_expr (parse_expr "u.is(Greeter)")));
    tc "README: greeting interpolation" (fun () ->
        Alcotest.(check string)
          "shape" "(string \"hello, \" (interp name))"
          (render pp_expr (parse_expr "\"hello, ${name}\"")));
    tc "README: a component tree is nested calls" (fun () ->
        Alcotest.(check string)
          "shape"
          "(page call title: \"Home\" (block |(navbar call (block |(logo \
           call)))))"
          (render pp_expr
             (parse_expr
                "page(title: \"Home\") {\n  navbar() {\n    logo()\n  }\n}")));
    tc "README: tuples bind to names" (fun () ->
        match parse_program "const point = (x, y)\nmove_to(point)" with
        | [ binding; call ] ->
            Alcotest.(check string)
              "binding" "(const point (tuple x y))" (render pp_item binding);
            Alcotest.(check string)
              "call" "(move_to call point)" (render pp_item call)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 2 statements, got %d"
                 (List.length stmts)));
    tc "README: qualified enum members are member access" (fun () ->
        Alcotest.(check string)
          "shape" "((type Color).red)"
          (render pp_expr (parse_expr "Color.red")));
    tc "malformed input reports the first missing token" (fun () ->
        List.iter
          (fun source ->
            let diagnostic = parse_err source in
            Alcotest.(check string)
              ("code of " ^ source) "E2001" (code_of diagnostic))
          [ "1 +"; "x."; ")"; "if"; "-> { return 1" ]);
    tc "unclosed calls report at end of input" (fun () ->
        let diagnostic = program_err "f(" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:3"
          (Span.to_string diagnostic.Diagnostic.span));
  ]

let item_tests =
  [
    tc "the empty program holds no items" (fun () ->
        Alcotest.(check int) "count" 0 (List.length (parse_program "")));
    tc "statements come back as top-level items" (fun () ->
        match parse_program "const x = 1\nx + 2\nif x {\n  y\n}" with
        | [ binding; expr; if_stmt ] ->
            Alcotest.(check string)
              "binding" "(const x 1)" (render pp_item binding);
            Alcotest.(check string) "expression" "(+ x 2)" (render pp_item expr);
            Alcotest.(check string)
              "if" "(if x then y)" (render pp_item if_stmt)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 3 items, got %d" (List.length items)));
    tc "items carry their spans" (fun () ->
        match parse_program "const x = 1" with
        | [ item ] ->
            Alcotest.(check int) "start" 0 item.Emo_ast.item_span.Span.start;
            Alcotest.(check int) "stop" 5 item.Emo_ast.item_span.Span.stop
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
  ]

let def_err source =
  match parse_program source with
  | _ -> Alcotest.fail "expected a parse error"
  | exception Emo_parser.Error diagnostic -> diagnostic

let def_tests =
  [
    tc "a def parses with params and return type" (fun () ->
        match
          parse_program "def add(a Int, b Int) Int {\n  return a + b\n}"
        with
        | [ def_item ] ->
            Alcotest.(check string)
              "shape"
              "(def add (param a Int) (param b Int) Int |(return (+ a b)))"
              (render pp_item def_item)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "a def may take no parameters" (fun () ->
        match parse_program "def greet() String {\n  return \"hi\"\n}" with
        | [ def_item ] ->
            Alcotest.(check string)
              "shape" "(def greet () String |(return \"hi\"))"
              (render pp_item def_item)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "predicate defs end their name in ?" (fun () ->
        match parse_program "def is_older?() Bool {\n  return true\n}" with
        | [ def_item ] ->
            Alcotest.(check string)
              "shape" "(def is_older? () Bool |(return true))"
              (render pp_item def_item)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "a def's span covers the whole declaration" (fun () ->
        match parse_program "def f() Int {\n  return 1\n}" with
        | [ def_item ] ->
            Alcotest.(check int) "start" 0 def_item.Emo_ast.item_span.Span.start;
            Alcotest.(check int) "stop" 26 def_item.Emo_ast.item_span.Span.stop
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "init cannot be defined at top level" (fun () ->
        let diagnostic = def_err "def init(x Int) {\n  self.x = x\n}" in
        Alcotest.(check string) "code" "E2010" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:5"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a def must declare its return type" (fun () ->
        let diagnostic = def_err "def f(a Int) {\n  return a\n}" in
        Alcotest.(check string) "code" "E2012" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:14"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "the return type stays on the signature's line" (fun () ->
        let diagnostic = def_err "def f()\nInt {\n  return 1\n}" in
        Alcotest.(check string) "code" "E2012" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "the def body opens on the signature's line" (fun () ->
        let diagnostic = def_err "def f() Int\n{\n  return 1\n}" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "a def needs a name" (fun () ->
        let diagnostic = def_err "def () Int {\n  return 1\n}" in
        Alcotest.(check string) "code" "E2009" (code_of diagnostic));
  ]

let class_tests =
  [
    tc "the README User class parses to its golden shape" (fun () ->
        match
          parse_program
            {|class User {
  def init(name String, age Int) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " " + self.age.to_string()
  }

  def is_older?() Bool {
    return self.age > 35
  }
}|}
        with
        | [ user ] ->
            Alcotest.(check string)
              "shape"
              "(class User (fields (field name) (field age)) (init (param name \
               String) (param age Int)|(= (self.name) name) (= (self.age) \
               age)) (def full_name () String |(return (+ (+ (self.name) \" \
               \") (((self.age).to_string) call)))) (def is_older? () Bool \
               |(return (> (self.age) 35))))"
              (render pp_item user)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "fields are collected in first-assignment order and deduped" (fun () ->
        match
          parse_program
            {|class P {
  def init() {
    self.y = 1
    self.x = 2
    self.y = 3
  }
}|}
        with
        | [ p ] -> (
            match p.Emo_ast.item_desc with
            | Emo_ast.Item_class c ->
                Alcotest.(check string)
                  "fields" "(field y) (field x)"
                  (render (pp_list pp_field) c.Emo_ast.class_fields)
            | _ -> Alcotest.fail "expected a class")
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "field assignment may sit in nested blocks inside init" (fun () ->
        match
          parse_program
            "class C {\n\
            \  def init(flag Bool) {\n\
            \    if flag {\n\
            \      self.x = 1\n\
            \    }\n\
            \  }\n\
             }"
        with
        | [ c ] -> (
            match c.Emo_ast.item_desc with
            | Emo_ast.Item_class cl ->
                Alcotest.(check string)
                  "fields" "(field x)"
                  (render (pp_list pp_field) cl.Emo_ast.class_fields)
            | _ -> Alcotest.fail "expected a class")
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "duplicate init is rejected at the second one" (fun () ->
        let diagnostic =
          program_err "class D {\n  def init() {}\n  def init(x Int) {}\n}"
        in
        Alcotest.(check string) "code" "E2014" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:3:3"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a class without init is rejected" (fun () ->
        let diagnostic =
          program_err
            "class Empty {\n  def greet() String {\n    return \"hi\"\n  }\n}"
        in
        Alcotest.(check string) "code" "E2013" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:7"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "init takes no return annotation" (fun () ->
        let diagnostic = program_err "class A {\n  def init() A {}\n}" in
        Alcotest.(check string) "code" "E2011" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:14"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "self.x is assigned only inside init" (fun () ->
        let diagnostic = program_err "self.x = 1" in
        Alcotest.(check string) "code" "E2016" (code_of diagnostic);
        let diagnostic =
          program_err
            "class M {\n\
            \  def init() {\n\
            \    self.x = 1\n\
            \  }\n\
            \  def bump() Int {\n\
            \    self.x = 2\n\
            \    return self.x\n\
            \  }\n\
             }"
        in
        Alcotest.(check string) "code" "E2016" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:6:5"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "variables can be rebound with =" (fun () ->
        match parse_program "var x = 1\nx = 2" with
        | [ _; assign ] ->
            Alcotest.(check string) "shape" "(= x 2)" (render pp_item assign)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 2 items, got %d" (List.length items)));
    tc "only variables and self fields are assignment targets" (fun () ->
        let diagnostic = program_err "a.b = 1" in
        Alcotest.(check string) "code" "E2015" (code_of diagnostic);
        let diagnostic = program_err "1 = 2" in
        Alcotest.(check string) "code" "E2015" (code_of diagnostic));
    tc "a class needs an UpperCamel name" (fun () ->
        let diagnostic = program_err "class user {\n  def init() {}\n}" in
        Alcotest.(check string) "code" "E2017" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:7"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "class members are separated by newlines" (fun () ->
        let diagnostic =
          program_err "class C { def init() {} def m() Int { return 1 } }"
        in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "the class body opens on the class's line" (fun () ->
        let diagnostic = program_err "class C\n{\n  def init() {}\n}" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
  ]

let interface_tests =
  [
    tc "the README Greeter interface parses to its golden shape" (fun () ->
        match parse_program "interface Greeter {\n  def greet() String\n}" with
        | [ greeter ] ->
            Alcotest.(check string)
              "shape" "(interface Greeter (sig greet () String))"
              (render pp_item greeter)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "signatures carry annotated parameters" (fun () ->
        match
          parse_program "interface Teller {\n  def total(cart Cart) Int\n}"
        with
        | [ teller ] ->
            Alcotest.(check string)
              "shape" "(interface Teller (sig total (param cart Cart) Int))"
              (render pp_item teller)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "an interface may be empty" (fun () ->
        match parse_program "interface Marker {}" with
        | [ marker ] ->
            Alcotest.(check string)
              "shape" "(interface Marker)" (render pp_item marker)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "an interface method takes no body" (fun () ->
        let diagnostic =
          program_err
            "interface Bad {\n  def greet() String {\n    return \"hi\"\n  }\n}"
        in
        Alcotest.(check string) "code" "E2018" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:22"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "an interface cannot declare init" (fun () ->
        let diagnostic = program_err "interface Bad {\n  def init()\n}" in
        Alcotest.(check string) "code" "E2019" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:7"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a signature must declare its return type" (fun () ->
        let diagnostic = program_err "interface Bad {\n  def greet()\n}" in
        Alcotest.(check string) "code" "E2012" (code_of diagnostic));
    tc "an interface needs an UpperCamel name" (fun () ->
        let diagnostic = program_err "interface greeter {}" in
        Alcotest.(check string) "code" "E2017" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:11"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "interface members are separated by newlines" (fun () ->
        let diagnostic =
          program_err "interface B { def a() Int def b() Int }"
        in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
  ]

let () =
  Alcotest.run "emo_parser"
    [
      ( "smoke",
        [
          tc "library links" (fun () ->
              let module M = Emo_parser in
              ());
        ] );
      ("expression", expression_tests);
      ("call", call_tests);
      ("control", control_tests);
      ("stmt", stmt_tests);
      ("string", string_tests);
      ("item", item_tests);
      ("def", def_tests);
      ("class", class_tests);
      ("interface", interface_tests);
      ("golden", golden_tests);
    ]
