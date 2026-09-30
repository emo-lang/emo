module Ast = Emo_ast
module Tok = Emo_lexer.Token

exception Error of Emo_support.Diagnostic.t

let error code span ?hint message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

let op_spelling = function
  | Tok.LParen -> "("
  | Tok.RParen -> ")"
  | Tok.LBrace -> "{"
  | Tok.RBrace -> "}"
  | Tok.LBracket -> "["
  | Tok.RBracket -> "]"
  | Tok.Comma -> ","
  | Tok.Colon -> ":"
  | Tok.Dot -> "."
  | Tok.Arrow -> "->"
  | Tok.Send -> "<-"
  | Tok.Assign -> "="
  | Tok.Eq -> "=="
  | Tok.Ne -> "!="
  | Tok.Lt -> "<"
  | Tok.Le -> "<="
  | Tok.Gt -> ">"
  | Tok.Ge -> ">="
  | Tok.Plus -> "+"
  | Tok.Minus -> "-"
  | Tok.Star -> "*"
  | Tok.Slash -> "/"
  | Tok.Percent -> "%"
  | Tok.AndAnd -> "&&"
  | Tok.OrOr -> "||"
  | Tok.Not -> "!"

let keyword_spelling = function
  | Tok.Def -> "def"
  | Tok.Const -> "const"
  | Tok.Var -> "var"
  | Tok.Class -> "class"
  | Tok.Interface -> "interface"
  | Tok.Enum -> "enum"
  | Tok.If -> "if"
  | Tok.Else -> "else"
  | Tok.Case -> "case"
  | Tok.When -> "when"
  | Tok.Receive -> "receive"
  | Tok.Return -> "return"
  | Tok.Raise -> "raise"
  | Tok.Self -> "self"
  | Tok.Do -> "do"

let describe_kind (k : Tok.kind) =
  match k with
  | Int n -> Printf.sprintf "integer `%d`" n
  | Float f -> Printf.sprintf "float `%g`" f
  | Char c -> Printf.sprintf "character %C" c
  | String_chunk _ | String_end | Interp_open | Interp_close -> "a string"
  | True -> "`true`"
  | False -> "`false`"
  | Lower_ident s -> Printf.sprintf "identifier `%s`" s
  | Upper_ident s -> Printf.sprintf "type name `%s`" s
  | Keyword k -> "`" ^ keyword_spelling k ^ "`"
  | Op o -> "`" ^ op_spelling o ^ "`"
  | Eof -> "end of input"

type parser = { stream : Emo_lexer.Stream.t; file : string }

let peek st = Emo_lexer.Stream.peek st.stream
let advance st = Emo_lexer.Stream.advance st.stream
let at_eof st = Emo_lexer.Stream.at_eof st.stream
let newline_before st = Emo_lexer.Stream.newline_before st.stream
let kind st = (peek st).Tok.kind
let span st = (peek st).Tok.span
let describe_here st = describe_kind (kind st)
let at_op st op = kind st = Tok.Op op
let at_keyword st k = kind st = Tok.Keyword k

let expect_op st op what =
  if at_op st op then advance st |> ignore
  else
    error "E2001" (span st)
      (Printf.sprintf "expected %s, found %s" what (describe_here st))

let merge_span a b = Emo_support.Span.merge a b
let node span desc = { Ast.span; desc }
let stmt span desc = { Ast.stmt_span = span; stmt_desc = desc }

let comparison_binop = function
  | Tok.Eq -> Some Ast.Eq
  | Tok.Ne -> Some Ast.Ne
  | Tok.Lt -> Some Ast.Lt
  | Tok.Le -> Some Ast.Le
  | Tok.Gt -> Some Ast.Gt
  | Tok.Ge -> Some Ast.Ge
  | _ -> None

let is_comparison_op = function
  | Tok.Eq | Tok.Ne | Tok.Lt | Tok.Le | Tok.Gt | Tok.Ge -> true
  | _ -> false

let rec parse_expr st = parse_or st

and parse_or st =
  let left = ref (parse_and st) in
  while at_op st Tok.OrOr do
    let op_span = (advance st).Tok.span in
    let right = parse_and st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (Ast.Or, !left, right))
  done;
  !left

and parse_and st =
  let left = ref (parse_comparison st) in
  while at_op st Tok.AndAnd do
    let op_span = (advance st).Tok.span in
    let right = parse_comparison st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (Ast.And, !left, right))
  done;
  !left

and parse_comparison st =
  let left = parse_additive st in
  match kind st with
  | Tok.Op op when is_comparison_op op ->
      let binop =
        match comparison_binop op with Some b -> b | None -> assert false
      in
      let op_span = (advance st).Tok.span in
      let right = parse_additive st in
      (match kind st with
      | Tok.Op op2 when is_comparison_op op2 ->
          error "E2002" (span st) "comparisons do not chain"
            ~hint:"combine separate comparisons with `&&`"
      | _ -> ());
      node
        (merge_span (merge_span left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (binop, left, right))
  | _ -> left

and parse_additive st =
  let left = ref (parse_multiplicative st) in
  let step () =
    let op, op_span =
      match kind st with
      | Tok.Op Tok.Plus -> (Ast.Add, (advance st).Tok.span)
      | Tok.Op Tok.Minus -> (Ast.Sub, (advance st).Tok.span)
      | _ -> assert false
    in
    let right = parse_multiplicative st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (op, !left, right))
  in
  while at_op st Tok.Plus || at_op st Tok.Minus do
    step ()
  done;
  !left

and parse_multiplicative st =
  let left = ref (parse_unary st) in
  let step () =
    let op, op_span =
      match kind st with
      | Tok.Op Tok.Star -> (Ast.Mul, (advance st).Tok.span)
      | Tok.Op Tok.Slash -> (Ast.Div, (advance st).Tok.span)
      | Tok.Op Tok.Percent -> (Ast.Mod, (advance st).Tok.span)
      | _ -> assert false
    in
    let right = parse_unary st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (op, !left, right))
  in
  while at_op st Tok.Star || at_op st Tok.Slash || at_op st Tok.Percent do
    step ()
  done;
  !left

and parse_unary st =
  match kind st with
  | Tok.Op Tok.Not ->
      let op_span = (advance st).Tok.span in
      let operand = parse_unary st in
      node (merge_span op_span operand.Ast.span) (Ast.Unary (Ast.Not, operand))
  | Tok.Op Tok.Minus ->
      let op_span = (advance st).Tok.span in
      let operand = parse_unary st in
      node (merge_span op_span operand.Ast.span) (Ast.Unary (Ast.Neg, operand))
  | _ -> parse_postfix st

and parse_postfix st =
  let e = ref (parse_primary st) in
  let continue = ref true in
  while !continue do
    match kind st with
    | Tok.Op Tok.Dot when not (newline_before st) -> (
        advance st |> ignore;
        match kind st with
        | Tok.Lower_ident name ->
            let name_span = (advance st).Tok.span in
            e := node (merge_span !e.Ast.span name_span) (Ast.Member (!e, name))
        | t ->
            error "E2001" (span st)
              (Printf.sprintf "expected a member name after `.`, found %s"
                 (describe_kind t)))
    | Tok.Op Tok.LBracket when not (newline_before st) ->
        advance st |> ignore;
        let index = parse_expr st in
        let close_span = span st in
        expect_op st Tok.RBracket "`]`";
        e := node (merge_span !e.Ast.span close_span) (Ast.Index (!e, index))
    | Tok.Op Tok.LParen when not (newline_before st) -> (
        let lparen = peek st in
        if
          lparen.Tok.span.Emo_support.Span.start
          > !e.Ast.span.Emo_support.Span.stop
        then
          error "E2003" lparen.Tok.span "call parentheses must touch the callee"
            ~hint:"write `f(a)`, never `f (a)`";
        advance st |> ignore;
        let args = parse_args st in
        let close_span = span st in
        expect_op st Tok.RParen "`)`" |> ignore;
        let call =
          node (merge_span !e.Ast.span close_span) (Ast.Call (!e, args))
        in
        e :=
          match kind st with
          | Tok.Op Tok.LBrace when not (newline_before st) ->
              let lbrace_span = span st in
              let body, close_span = parse_block st in
              let block =
                node
                  (merge_span lbrace_span close_span)
                  (Ast.Arrow_block ([], body))
              in
              node
                (merge_span call.Ast.span close_span)
                (Ast.Call
                   (!e, args @ [ { Ast.arg_name = None; arg_value = block } ]))
          | _ -> call)
    | _ -> continue := false
  done;
  !e

and parse_primary st =
  let tok = peek st in
  match tok.Tok.kind with
  | Tok.Int n ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Int n)
  | Tok.Float f ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Float f)
  | Tok.Char c ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Char c)
  | Tok.True ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Bool true)
  | Tok.False ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Bool false)
  | Tok.Lower_ident s ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Ident s)
  | Tok.Upper_ident s ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Type_ident s)
  | Tok.Keyword Tok.Self ->
      advance st |> ignore;
      node tok.Tok.span Ast.Self
  | Tok.Op Tok.LParen -> parse_paren st
  | t ->
      error "E2001" (span st)
        (Printf.sprintf "expected an expression, found %s" (describe_kind t))

and parse_paren st =
  let open_span = (advance st).Tok.span in
  if at_op st Tok.RParen then
    let close_span = (advance st).Tok.span in
    node (merge_span open_span close_span) (Ast.Tuple [])
  else
    let first = parse_expr st in
    if at_op st Tok.Comma then (
      let elems = ref [ first ] in
      while at_op st Tok.Comma do
        advance st |> ignore;
        if at_op st Tok.RParen then
          error "E2004" (span st) "tuples do not take a trailing comma"
            ~hint:"the one-element tuple is written `(a)`";
        elems := parse_expr st :: !elems
      done;
      let close_span = span st in
      expect_op st Tok.RParen "`)`" |> ignore;
      node (merge_span open_span close_span) (Ast.Tuple (List.rev !elems)))
    else
      let close_span = span st in
      expect_op st Tok.RParen "`)`" |> ignore;
      match first.Ast.desc with
      | Binary _ | Unary _ -> first
      | _ -> node (merge_span open_span close_span) (Ast.Tuple [ first ])

and parse_args st =
  if at_op st Tok.RParen then []
  else
    let args = ref [] in
    let rec loop () =
      let name =
        match kind st with
        | Tok.Lower_ident n
          when (Emo_lexer.Stream.peek_ahead st.stream 1).Tok.kind
               = Tok.Op Tok.Colon ->
            advance st |> ignore;
            advance st |> ignore;
            Some n
        | _ -> None
      in
      let value = parse_expr st in
      args := { Ast.arg_name = name; arg_value = value } :: !args;
      if at_op st Tok.Comma then (
        advance st |> ignore;
        if at_op st Tok.RParen then
          error "E2003" (span st) "argument lists do not take a trailing comma";
        loop ())
    in
    loop ();
    List.rev !args

and parse_block st =
  advance st |> ignore;
  let stmts = ref [] in
  let rec loop () =
    if at_op st Tok.RBrace || at_eof st then ()
    else (
      stmts := parse_stmt st :: !stmts;
      loop ())
  in
  loop ();
  if at_eof st then error "E2001" (span st) "expected `}`, found end of input";
  let close_span = span st in
  expect_op st Tok.RBrace "`}`" |> ignore;
  (List.rev !stmts, close_span)

and parse_stmt st =
  let start_span = span st in
  match kind st with
  | Tok.Keyword Tok.Return ->
      advance st |> ignore;
      if at_op st Tok.RBrace || at_eof st || newline_before st then
        stmt start_span (Ast.Return None)
      else
        let e = parse_expr st in
        end_statement st;
        stmt start_span (Ast.Return (Some e))
  | _ ->
      let e = parse_expr st in
      end_statement st;
      stmt start_span (Ast.Expr_stmt e)

and end_statement st =
  match kind st with
  | Tok.Eof | Tok.Op Tok.RBrace -> ()
  | _ when newline_before st -> ()
  | _ ->
      error "E2002" (span st) "expressions cannot be juxtaposed"
        ~hint:"start a new statement on the next line"

(* Parses a source that holds exactly one expression. *)
let parse_expr_source ~file ~source =
  let stream = Emo_lexer.lex ~file ~source in
  let st = { stream; file } in
  let e = parse_expr st in
  if not (at_eof st) then
    error "E2001" (span st)
      (Printf.sprintf "unexpected %s after the expression" (describe_here st));
  e

(* Parses a file: a sequence of statements ended by newlines. *)
let parse_program ~file ~source =
  let stream = Emo_lexer.lex ~file ~source in
  let st = { stream; file } in
  let stmts = ref [] in
  let rec loop () =
    if at_eof st then ()
    else (
      stmts := parse_stmt st :: !stmts;
      loop ())
  in
  loop ();
  List.rev !stmts
