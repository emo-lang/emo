open Emo_support

let tc name f = Alcotest.test_case name `Quick f

let render pp v =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
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
  Format.fprintf fmt "(branch %a%a @[<hov>%a@])" pp_pattern pattern
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
            Alcotest.(check string) "first" "a" (render pp_stmt first);
            Alcotest.(check string) "second" "b" (render pp_stmt second)
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
              "shape" "(if a then b)" (render pp_stmt if_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "if with else" (fun () ->
        match parse_program "if a {\n  b\n} else {\n  c\n}" with
        | [ if_stmt ] ->
            Alcotest.(check string)
              "shape" "(if a then b else c)" (render pp_stmt if_stmt)
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
              (render pp_stmt if_stmt)
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
    ]
