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
  | Emo_ast.Bit_and -> "&"
  | Emo_ast.Bit_or -> "|"
  | Emo_ast.Bit_xor -> "^"
  | Emo_ast.Shl -> "<<"
  | Emo_ast.Shr -> ">>"
  | Emo_ast.And -> "&&"
  | Emo_ast.Or -> "||"

let rec pp_expr fmt (e : Emo_ast.expr) =
  match e.Emo_ast.desc with
  | Int64 n -> Format.fprintf fmt "%Ld" n
  | Byte n -> Format.fprintf fmt "%dB" n
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
  | Array_literal ([] as es) ->
      Format.fprintf fmt "(array%a)" (pp_list pp_expr) es
  | Array_literal es ->
      Format.fprintf fmt "(array @[<hov>%a@])" (pp_list pp_expr) es
  | Map_literal ([] as es) -> Format.fprintf fmt "(map%a)" (pp_list pp_entry) es
  | Map_literal es ->
      Format.fprintf fmt "(map @[<hov>%a@])" (pp_list pp_entry) es
  | Unary (op, e) ->
      Format.fprintf fmt "(%s %a)"
        (match op with
        | Emo_ast.Not -> "!"
        | Emo_ast.Neg -> "-"
        | Emo_ast.Bit_not -> "~")
        pp_expr e
  | Binary (op, l, r) ->
      Format.fprintf fmt "(%s %a %a)" (binop_spelling op) pp_expr l pp_expr r
  | If_expr { cond; then_expr; else_expr } ->
      Format.fprintf fmt "(if %a %a %a)" pp_expr cond pp_expr then_expr pp_expr
        else_expr
  | Do e -> Format.fprintf fmt "(do %a)" pp_expr e

and pp_part fmt = function
  | Emo_ast.Literal_text s -> Format.fprintf fmt "%S" s
  | Emo_ast.Part_expr e -> Format.fprintf fmt "(interp %a)" pp_expr e

and pp_arg fmt { Emo_ast.arg_name; arg_value } =
  match arg_name with
  | Some n -> Format.fprintf fmt "%s: %a" n pp_expr arg_value
  | None -> pp_expr fmt arg_value

and pp_entry fmt (k, v) = Format.fprintf fmt "(%a %a)" pp_expr k pp_expr v

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
  | Emo_ast.Raise e -> Format.fprintf fmt "(raise %a)" pp_expr e
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
  | Emo_ast.L_int n -> Format.fprintf fmt "%Ld" n
  | Emo_ast.L_byte n -> Format.fprintf fmt "%dB" n
  | Emo_ast.L_float f -> Format.fprintf fmt "%g" f
  | Emo_ast.L_char c -> Format.fprintf fmt "%C" c
  | Emo_ast.L_string s -> Format.fprintf fmt "%S" s
  | Emo_ast.L_bool b -> Format.fprintf fmt "%b" b

and pp_item fmt (i : Emo_ast.item) =
  match i.Emo_ast.item_desc with
  | Emo_ast.Item_stmt s -> pp_stmt fmt s
  | Emo_ast.Item_foreign _ -> ignore fmt
  | Emo_ast.Item_def d -> pp_fun_def fmt d
  | Emo_ast.Item_class c -> pp_class_def fmt c
  | Emo_ast.Item_interface i -> pp_interface_def fmt i
  | Emo_ast.Item_enum e -> pp_enum_def fmt e
  | Emo_ast.Item_emo_group g ->
      Format.fprintf fmt "(emo group %s)" g.Emo_ast.group_name
  | Emo_ast.Item_require name -> Format.fprintf fmt "(require %s)" name

and pp_params fmt = function
  | [] -> Format.pp_print_string fmt "()"
  | ps -> pp_list pp_param fmt ps

and pp_fun_def fmt (d : Emo_ast.fun_def) =
  if d.Emo_ast.def_name = "init" && Option.is_none d.Emo_ast.def_return then
    Format.fprintf fmt "(init %a|@[<hov>%a@])" pp_params d.Emo_ast.def_params
      (pp_list pp_stmt) d.Emo_ast.def_body
  else
    match d.Emo_ast.def_return with
    | None ->
        Format.fprintf fmt "(def %s %a Void |@[<hov>%a@])" d.Emo_ast.def_name
          pp_params d.Emo_ast.def_params (pp_list pp_stmt) d.Emo_ast.def_body
    | Some ret ->
        Format.fprintf fmt "(def %s %a %a |@[<hov>%a@])" d.Emo_ast.def_name
          pp_params d.Emo_ast.def_params pp_type_ann ret (pp_list pp_stmt)
          d.Emo_ast.def_body

and pp_method_sig fmt (s : Emo_ast.method_sig) =
  Format.fprintf fmt "(sig %s @[<hov>%a@] %a)" s.Emo_ast.sig_name pp_params
    s.Emo_ast.sig_params pp_type_ann s.Emo_ast.sig_return

and pp_field fmt (f : Emo_ast.field) =
  Format.fprintf fmt "(field %s)" f.Emo_ast.field_name

and pp_fields fmt = function
  | [] -> Format.pp_print_string fmt "(fields)"
  | fs -> Format.fprintf fmt "(fields @[<hov>%a@])" (pp_list pp_field) fs

and pp_class_def fmt (c : Emo_ast.class_def) =
  match c.Emo_ast.class_init with
  | Some init ->
      Format.fprintf fmt "(class %s @[<hov>%a (init %a|@[<hov>%a@]) %a@])"
        c.Emo_ast.class_name pp_fields c.Emo_ast.class_fields pp_params
        init.Emo_ast.def_params (pp_list pp_stmt) init.Emo_ast.def_body
        (pp_list pp_fun_def) c.Emo_ast.class_methods
  | None ->
      Format.fprintf fmt "(class %s @[<hov>%a %a@])" c.Emo_ast.class_name
        pp_fields c.Emo_ast.class_fields (pp_list pp_fun_def)
        c.Emo_ast.class_methods

and pp_interface_def fmt (i : Emo_ast.interface_def) =
  match i.Emo_ast.interface_methods with
  | [] -> Format.fprintf fmt "(interface %s)" i.Emo_ast.interface_name
  | methods ->
      Format.fprintf fmt "(interface %s @[<hov>%a@])" i.Emo_ast.interface_name
        (pp_list pp_method_sig) methods

and pp_enum_def fmt (e : Emo_ast.enum_def) =
  match e.Emo_ast.enum_members with
  | [] -> Format.fprintf fmt "(enum %s)" e.Emo_ast.enum_name
  | members ->
      Format.fprintf fmt "(enum %s @[<hov>%a@])" e.Emo_ast.enum_name
        (pp_list (fun fmt m -> Format.pp_print_string fmt m.Emo_ast.member_name))
        members

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
    tc "the if expression parses with one-expression branches" (fun () ->
        Alcotest.check expr "shape"
          (parse_expr "if a { 1 } else { 2 }")
          (parse_expr "if a { 1 } else { 2 }");
        Alcotest.(check string)
          "shape" "(if a 1 2)"
          (render pp_expr (parse_expr "if a { 1 } else { 2 }")));
    tc "a parenthesized if expression stays unwrapped" (fun () ->
        Alcotest.(check string)
          "shape" "(if a 1 2)"
          (render pp_expr (parse_expr "(if a { 1 } else { 2 })")));
    tc "an if expression must fit on one line" (fun () ->
        let diagnostic = parse_err "if a {\n  1\n} else { 2 }" in
        Alcotest.(check string) "code" "E2024" (code_of diagnostic));
    tc "an if expression requires an else branch" (fun () ->
        let diagnostic = parse_err "if a { 1 }" in
        Alcotest.(check string) "code" "E2024" (code_of diagnostic));
    tc "an if expression branch holds exactly one expression" (fun () ->
        let diagnostic = parse_err "if a { 1 2 } else { 3 }" in
        Alcotest.(check string) "code" "E2024" (code_of diagnostic));
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
    tc "fixed-width literals parse with their width" (fun () ->
        Alcotest.(check string) "int64" "1" (render pp_expr (parse_expr "1"));
        Alcotest.(check string)
          "byte" "255B"
          (render pp_expr (parse_expr "255B"));
        Alcotest.(check string)
          "in arithmetic" "(+ 1 2)"
          (render pp_expr (parse_expr "1 + 2")));
    tc "array literals parse with elements" (fun () ->
        Alcotest.(check string)
          "shape" "(array 1 2 3)"
          (render pp_expr (parse_expr "[1, 2, 3]"));
        Alcotest.(check string)
          "nested" "(array 1 (array 2))"
          (render pp_expr (parse_expr "[1, [2]]")));
    tc "the empty array literal" (fun () ->
        Alcotest.(check string)
          "shape" "(array)"
          (render pp_expr (parse_expr "[]")));
    tc "arrays reject a trailing comma" (fun () ->
        let diagnostic = parse_err "[1,]" in
        Alcotest.(check string) "code" "E2004" (code_of diagnostic));
    tc "map literals parse key-value entries" (fun () ->
        Alcotest.(check string)
          "shape" {|(map ("a" 1) ("b" 2))|}
          (render pp_expr (parse_expr {|{ "a": 1, "b": 2 }|}));
        Alcotest.(check string)
          "non-string keys" {|(map (x 1) (2 "y"))|}
          (render pp_expr (parse_expr {|{ x: 1, 2: "y" }|})));
    tc "the empty map literal" (fun () ->
        Alcotest.(check string)
          "shape" "(map)"
          (render pp_expr (parse_expr "{}")));
    tc "maps reject a trailing comma" (fun () ->
        let diagnostic = parse_err {|{ "a": 1, }|} in
        Alcotest.(check string) "code" "E2004" (code_of diagnostic));
    tc "a map entry requires the colon" (fun () ->
        let diagnostic = parse_err {|{ "a" 1 }|} in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "a paren directly opening onto a paren is refused" (fun () ->
        let diagnostic = parse_err "((a))" in
        Alcotest.(check string) "code" "E1009" (code_of diagnostic));
    tc "pair tuples parse as call arguments" (fun () ->
        Alcotest.(check string)
          "shape" {|(f call (tuple "a" 1))|}
          (render pp_expr (parse_expr {|f(("a", 1))|})));
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
    tc "an arrow block takes type-declared parameters" (fun () ->
        Alcotest.(check string)
          "shape" "(block (param x Int64) (param y Float64)|(return x))"
          (render pp_expr
             (parse_expr "-> (x Int64, y Float64) {\n  return x\n}")));
    tc "an arrow block may omit its parameters" (fun () ->
        Alcotest.(check string)
          "shape" "(block |(return 1))"
          (render pp_expr (parse_expr "-> {\n  return 1\n}")));
    tc "arrow block parameters need type declarations" (fun () ->
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
    tc "fixed-width literals are patterns" (fun () ->
        match
          parse_program
            "case n {\n  10B -> { return 1 }\n  2 -> { return 2 }\n}"
        with
        | [ case_stmt ] ->
            Alcotest.(check string)
              "shape" "(case n (branch 10B |(return 1)) (branch 2 |(return 2)))"
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
    tc "raise carries the README exception expression" (fun () ->
        match
          parse_program {|raise Exception.new(message: "something went wrong")|}
        with
        | [ raise_stmt ] ->
            Alcotest.(check string)
              "shape"
              "(raise (((type Exception).new) call message: \"something went \
               wrong\"))"
              (render pp_item raise_stmt)
        | stmts ->
            Alcotest.fail
              (Printf.sprintf "expected 1 statement, got %d" (List.length stmts)));
    tc "raise works inside a def body" (fun () ->
        match
          parse_program
            {|def fail() Int64 {
  raise Exception.new(message: "boom")
}|}
        with
        | [ fail ] ->
            Alcotest.(check string)
              "shape"
              "(def fail () Int64 |(raise (((type Exception).new) call \
               message: \"boom\")))"
              (render pp_item fail)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "bare raise is rejected" (fun () ->
        let diagnostic = program_err "def f() Int64 {\n  raise\n}" in
        Alcotest.(check string) "code" "E2023" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:3:1"
          (Span.to_string diagnostic.Diagnostic.span));
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
    tc "README: the duck-typed greeting program parses as a whole" (fun () ->
        match
          parse_program
            {|interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

def welcome(g Greeter) String {
  return g.greet()
}|}
        with
        | [ greeter; english; welcome ] ->
            Alcotest.(check string)
              "shape"
              "(interface Greeter (sig greet () String)) (class English \
               (fields) (def greet () String |(return \"Hello\"))) (def \
               welcome (param g Greeter) String |(return ((g.greet) call)))"
              (String.concat " "
                 (List.map (render pp_item) [ greeter; english; welcome ]))
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 3 items, got %d" (List.length items)));
    tc "a call takes a parameterized trailing block after ->" (fun () ->
        Alcotest.(check string)
          "shape"
          "(list call users (block (param user User)|(render call user)))"
          (render pp_expr
             (parse_expr "list(users) -> (user User) {\n  render(user)\n}")));
    tc "a newline puts the following arrow block in a new statement" (fun () ->
        match
          parse_program "list(users)\n-> (user User) {\n  render(user)\n}"
        with
        | [ call; block ] ->
            Alcotest.(check string)
              "call" "(list call users)" (render pp_item call);
            Alcotest.(check string)
              "block" "(block (param user User)|(render call user))"
              (render pp_item block)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 2 items, got %d" (List.length items)));
    tc "README: module aliases and qualified calls parse" (fun () ->
        match
          parse_program
            {|const order = shop.order

def checkout(cart Cart) Decimal {
  const total = order.total(cart)
  return total
}|}
        with
        | [ alias; checkout ] ->
            Alcotest.(check string)
              "alias" "(const order (shop.order))" (render pp_item alias);
            Alcotest.(check string)
              "checkout"
              "(def checkout (param cart Cart) Decimal |(const total \
               ((order.total) call cart)) (return total))"
              (render pp_item checkout)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 2 items, got %d" (List.length items)));
    tc "README: a component tree is nested calls with blocks" (fun () ->
        match
          parse_program
            {|page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}|}
        with
        | [ tree ] ->
            Alcotest.(check string)
              "shape"
              "(page call title: \"Home\" (block |(navbar call (block |(logo \
               call) (menu call routes))) (list call users (block (param user \
               User)|(card call user (block |(text call (user.name)) (text \
               call (user.bio))))))))"
              (render pp_item tree)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
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
          parse_program "def add(a Int64, b Int64) Int64 {\n  return a + b\n}"
        with
        | [ def_item ] ->
            Alcotest.(check string)
              "shape"
              "(def add (param a Int64) (param b Int64) Int64 |(return (+ a \
               b)))"
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
        match parse_program "def f() Int64 {\n  return 1\n}" with
        | [ def_item ] ->
            Alcotest.(check int) "start" 0 def_item.Emo_ast.item_span.Span.start;
            Alcotest.(check int) "stop" 28 def_item.Emo_ast.item_span.Span.stop
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "init cannot be defined at top level" (fun () ->
        let diagnostic = def_err "def init(x Int64) {\n  self.x = x\n}" in
        Alcotest.(check string) "code" "E2010" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:5"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a def without a return type declaration returns Void" (fun () ->
        match parse_program "def log(msg String) {\n  println(msg)\n}" with
        | [ def_item ] -> (
            match def_item.Emo_ast.item_desc with
            | Emo_ast.Item_def d ->
                Alcotest.(check bool)
                  "no return type declaration" false
                  (Option.is_some d.Emo_ast.def_return)
            | _ -> Alcotest.fail "expected a def")
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "the return type stays on the signature's line" (fun () ->
        let diagnostic = def_err "def f()\nInt {\n  return 1\n}" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "the def body opens on the signature's line" (fun () ->
        let diagnostic = def_err "def f() Int64\n{\n  return 1\n}" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "a def needs a name" (fun () ->
        let diagnostic = def_err "def () Int64 {\n  return 1\n}" in
        Alcotest.(check string) "code" "E2009" (code_of diagnostic));
  ]

let class_tests =
  [
    tc "the README User class parses to its golden shape" (fun () ->
        match
          parse_program
            {|class User {
  def init(name String, age Int64) {
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
               String) (param age Int64)|(= (self.name) name) (= (self.age) \
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
          program_err "class D {\n  def init() {}\n  def init(x Int64) {}\n}"
        in
        Alcotest.(check string) "code" "E2014" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:3:3"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a stateless class without init parses" (fun () ->
        match
          parse_program
            {|class English {
  def greet() String {
    return "Hello"
  }
}|}
        with
        | [ english ] ->
            Alcotest.(check string)
              "shape"
              "(class English (fields) (def greet () String |(return \
               \"Hello\")))"
              (render pp_item english)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "init takes no return type declaration" (fun () ->
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
            \  def bump() Int64 {\n\
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
          program_err "class C { def init() {} def m() Int64 { return 1 } }"
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
    tc "signatures carry type-declared parameters" (fun () ->
        match
          parse_program "interface Teller {\n  def total(cart Cart) Int64\n}"
        with
        | [ teller ] ->
            Alcotest.(check string)
              "shape" "(interface Teller (sig total (param cart Cart) Int64))"
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
          program_err "interface B { def a() Int64 def b() Int64 }"
        in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
  ]

let enum_tests =
  [
    tc "the README Color enum parses to its golden shape" (fun () ->
        match parse_program "enum Color { red, green, blue }" with
        | [ color ] ->
            Alcotest.(check string)
              "shape" "(enum Color red green blue)" (render pp_item color)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "members may span lines between commas" (fun () ->
        match parse_program "enum Color {\n  red,\n  green,\n  blue\n}" with
        | [ color ] ->
            Alcotest.(check string)
              "shape" "(enum Color red green blue)" (render pp_item color)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "an enum may be empty" (fun () ->
        match parse_program "enum Void {}" with
        | [ void_enum ] ->
            Alcotest.(check string)
              "shape" "(enum Void)" (render pp_item void_enum)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "members carry their spans" (fun () ->
        match parse_program "enum T { one }" with
        | [ t ] -> (
            match t.Emo_ast.item_desc with
            | Emo_ast.Item_enum e -> (
                match e.Emo_ast.enum_members with
                | [ one ] ->
                    Alcotest.(check string)
                      "span" "test.emo:1:10"
                      (Span.to_string one.Emo_ast.member_span)
                | ms ->
                    Alcotest.fail
                      (Printf.sprintf "expected 1 member, got %d"
                         (List.length ms)))
            | _ -> Alcotest.fail "expected an enum")
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "enums do not take payloads" (fun () ->
        let diagnostic = program_err "enum Color(String, Int64) { red }" in
        Alcotest.(check string) "code" "E2020" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:11"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "members are snake_case" (fun () ->
        let diagnostic = program_err "enum Color { redGreen }" in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:14"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "member names cannot end in ?" (fun () ->
        let diagnostic = program_err "enum Color { red? }" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
    tc "members are declared once" (fun () ->
        let diagnostic = program_err "enum Color { red, red }" in
        Alcotest.(check string) "code" "E2021" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:19"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "enums reject a trailing comma" (fun () ->
        let diagnostic = program_err "enum Color { red, }" in
        Alcotest.(check string) "code" "E2004" (code_of diagnostic));
    tc "members are comma-separated" (fun () ->
        let diagnostic = program_err "enum Color { red green }" in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "an enum needs an UpperCamel name" (fun () ->
        let diagnostic = program_err "enum color { red }" in
        Alcotest.(check string) "code" "E2017" (code_of diagnostic));
  ]

let parse_program_with_diagnostics source =
  Emo_parser.parse_program_with_diagnostics ~file:"test.emo" ~source

let naming_tests =
  [
    tc "camelCase def names are rejected" (fun () ->
        let diagnostic = program_err "def getUser() Int64 {\n  return 1\n}" in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:5"
          (Span.to_string diagnostic.Diagnostic.span);
        Alcotest.(check string)
          "message" "def names are snake_case; `getUser` is camelCase"
          diagnostic.Diagnostic.message);
    tc "camelCase interface signatures are rejected" (fun () ->
        let diagnostic =
          program_err "interface G {\n  def sayHello() String\n}"
        in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:2:7"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "camelCase bindings are rejected" (fun () ->
        let diagnostic = program_err "const totalCount = 3" in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:7"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "UPPER bindings are rejected with a naming hint" (fun () ->
        let diagnostic = program_err "const Total = 2" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:7"
          (Span.to_string diagnostic.Diagnostic.span);
        Alcotest.(check string)
          "hint" "variable names are lower_snake; type names are UpperCamel"
          (match diagnostic.Diagnostic.hint with
          | Some h -> h
          | None -> Alcotest.fail "expected a hint"));
    tc "camelCase parameters are rejected" (fun () ->
        let diagnostic =
          program_err "def f(cartItem Int64) Int64 {\n  return cartItem\n}"
        in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic));
    tc "camelCase pattern bindings are rejected" (fun () ->
        let diagnostic =
          program_err "case c {\n  otherValue -> { return 1 }\n}"
        in
        Alcotest.(check string) "code" "E2022" (code_of diagnostic));
    tc "question-mark names stay exclusive to defs" (fun () ->
        let diagnostic = program_err "const ready? = true" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic);
        let diagnostic =
          program_err "def f(ready? Int64) Int64 {\n  return ready?\n}"
        in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic);
        let diagnostic = program_err "case c {\n  ready? -> { return 1 }\n}" in
        Alcotest.(check string) "code" "E2007" (code_of diagnostic));
    tc "snake_case names with digits and underscores pass" (fun () ->
        match
          parse_program
            "def is_ready_2?(flag_1 Bool) Bool {\n  return flag_1\n}"
        with
        | [ def_item ] ->
            Alcotest.(check string)
              "shape"
              "(def is_ready_2? (param flag_1 Bool) Bool |(return flag_1))"
              (render pp_item def_item)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
  ]

let recovery_tests =
  [
    tc "recovery reports every top-level error in one pass" (fun () ->
        let _, diagnostics =
          parse_program_with_diagnostics
            {|def getUser() Int64 {
  return 1
}

const Total = 2

enum Bad(String) { red }

def ok() Int64 {
  return 3
}|}
        in
        Alcotest.(check int) "error count" 3 (List.length diagnostics);
        Alcotest.(check string)
          "first" "E2022"
          (code_of (List.nth diagnostics 0));
        Alcotest.(check string)
          "second" "E2007"
          (code_of (List.nth diagnostics 1));
        Alcotest.(check string)
          "third" "E2020"
          (code_of (List.nth diagnostics 2)));
    tc "valid items between errors still parse" (fun () ->
        let items, diagnostics =
          parse_program_with_diagnostics
            "const Total = 1\nenum Color { red, green, blue }\nconst other = 2"
        in
        Alcotest.(check int) "error count" 1 (List.length diagnostics);
        Alcotest.(check int) "item count" 2 (List.length items);
        Alcotest.(check string)
          "survivor" "(enum Color red green blue)"
          (render pp_item (List.nth items 0)));
    tc "resync lands on the next line-start keyword" (fun () ->
        let _, diagnostics =
          parse_program_with_diagnostics
            "enum C { red, redGreen, blue }\ndef ok() Int64 {\n  return 1\n}"
        in
        Alcotest.(check int) "error count" 1 (List.length diagnostics);
        Alcotest.(check string)
          "code" "E2022"
          (code_of (List.nth diagnostics 0)));
  ]

let require_tests =
  [
    tc "require parses with the package name" (fun () ->
        match
          parse_program
            {|require "acme/json_tools"
println(json_tools.parse("{}"))|}
        with
        | [ req; call ] ->
            Alcotest.(check string)
              "require" "(require acme/json_tools)" (render pp_item req);
            Alcotest.(check string)
              "call" "(println call ((json_tools.parse) call \"{}\"))"
              (render pp_item call)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 2 items, got %d" (List.length items)));
    tc "a scoped deps key folds into one ident" (fun () ->
        match parse_program {|acme/json_tools = "2.3.1"|} with
        | [ item ] -> (
            match item.Emo_ast.item_desc with
            | Emo_ast.Item_stmt
                {
                  stmt_desc =
                    Emo_ast.Assign
                      { target = { Emo_ast.desc = Emo_ast.Ident name }; _ };
                } ->
                Alcotest.(check string) "key" "acme/json_tools" name
            | _ -> Alcotest.fail "expected a scoped assignment")
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "a scoped name keeps owner/name shape" (fun () ->
        match parse_program {|require "a/b/c"|} with
        | [ req ] ->
            Alcotest.(check string)
              "shape" "(require a/b/c)" (render pp_item req)
        | items ->
            Alcotest.fail
              (Printf.sprintf "expected 1 item, got %d" (List.length items)));
    tc "duplicate requires in one file are errors" (fun () ->
        try
          ignore (parse_program {|require "a/b"
require "a/b"|});
          Alcotest.fail "expected a duplicate-require error"
        with Emo_parser.Error d ->
          Alcotest.(check string) "code" "E2010" (code_of d));
    tc "require is file-level only" (fun () ->
        let diagnostic =
          program_err {|def f() Int64 {
  require "a/b"
  return 1
}|}
        in
        Alcotest.(check string) "code" "E2001" (code_of diagnostic));
    tc "require takes a plain string" (fun () ->
        let diagnostic = program_err {|require "a/${"b"}"|} in
        Alcotest.(check string) "code" "E2009" (code_of diagnostic));
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
      ("enum", enum_tests);
      ("naming", naming_tests);
      ("recovery", recovery_tests);
      ("golden", golden_tests);
      ("require", require_tests);
    ]
