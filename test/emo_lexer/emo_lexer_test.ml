open Emo_support
open Emo_lexer

let tc name f = Alcotest.test_case name `Quick f

let pp_kind fmt (k : Token.kind) =
  let text =
    match k with
    | Token.Int n -> Printf.sprintf "Int %d" n
    | Token.Float f -> Printf.sprintf "Float %g" f
    | Token.Char c -> Printf.sprintf "Char %C" c
    | Token.String_chunk s -> Printf.sprintf "String_chunk %S" s
    | Token.String_end -> "String_end"
    | Token.Interp_open -> "Interp_open"
    | Token.Interp_close -> "Interp_close"
    | Token.True -> "True"
    | Token.False -> "False"
    | Token.Lower_ident s -> "Lower_ident " ^ s
    | Token.Upper_ident s -> "Upper_ident " ^ s
    | Token.Keyword k -> (
        "Keyword "
        ^
        match k with
        | Def -> "def"
        | Const -> "const"
        | Var -> "var"
        | Class -> "class"
        | Interface -> "interface"
        | Enum -> "enum"
        | If -> "if"
        | Else -> "else"
        | Case -> "case"
        | When -> "when"
        | Receive -> "receive"
        | Return -> "return"
        | Raise -> "raise"
        | Self -> "self"
        | Do -> "do")
    | Token.Op o -> (
        "Op "
        ^
        match o with
        | LParen -> "("
        | RParen -> ")"
        | LBrace -> "{"
        | RBrace -> "}"
        | LBracket -> "["
        | RBracket -> "]"
        | Comma -> ","
        | Colon -> ":"
        | Dot -> "."
        | Arrow -> "->"
        | Send -> "<-"
        | Assign -> "="
        | Eq -> "=="
        | Ne -> "!="
        | Lt -> "<"
        | Le -> "<="
        | Gt -> ">"
        | Ge -> ">="
        | Plus -> "+"
        | Minus -> "-"
        | Star -> "*"
        | Slash -> "/"
        | Percent -> "%"
        | AndAnd -> "&&"
        | OrOr -> "||"
        | Not -> "!")
    | Token.Eof -> "Eof"
  in
  Format.pp_print_string fmt text

let kind : Token.kind Alcotest.testable =
  Alcotest.testable pp_kind (fun a b -> compare a b = 0)

let lex_all source = Stream.to_list (lex ~file:"test.emo" ~source)
let kinds toks = List.map (fun tok -> tok.Token.kind) toks
let token_span tok = Span.to_string tok.Token.span

let lex_err source =
  match lex ~file:"test.emo" ~source with
  | _ -> Alcotest.fail "expected a lexical error"
  | exception Error diagnostic -> diagnostic

let foundation_tests =
  [
    tc "empty source lexes to a positioned eof" (fun () ->
        match lex_all "" with
        | [ eof ] ->
            Alcotest.check kind "eof kind" Token.Eof eof.Token.kind;
            Alcotest.(check string) "eof span" "test.emo:1:1" (token_span eof);
            Alcotest.(check bool)
              "no newline before eof" false eof.Token.newline_before
        | toks ->
            Alcotest.fail
              (Printf.sprintf "expected one token, got %d" (List.length toks)));
    tc "punctuation tokens carry exact positions" (fun () ->
        let toks = lex_all "( ) , :" in
        Alcotest.(check (list kind))
          "kinds"
          [ Op LParen; Op RParen; Op Comma; Op Colon; Eof ]
          (kinds toks);
        Alcotest.(check (list string))
          "spans"
          [
            "test.emo:1:1";
            "test.emo:1:3";
            "test.emo:1:5";
            "test.emo:1:7";
            "test.emo:1:8";
          ]
          (List.map token_span toks));
    tc "newlines are visible on the following token" (fun () ->
        match lex_all "(\n)" with
        | [ lparen; rparen; eof ] ->
            Alcotest.check kind "lparen" (Op LParen) lparen.Token.kind;
            Alcotest.(check bool)
              "lparen at line start" false lparen.Token.newline_before;
            Alcotest.(check bool)
              "rparen follows a newline" true rparen.Token.newline_before;
            Alcotest.(check bool) "eof does not" false eof.Token.newline_before
        | toks ->
            Alcotest.fail
              (Printf.sprintf "expected 3 tokens, got %d" (List.length toks)));
    tc "the stream cursor walks to eof and stays" (fun () ->
        let stream = lex ~file:"test.emo" ~source:"()" in
        let first = Stream.advance stream in
        Alcotest.check kind "first" (Op LParen) first.Token.kind;
        let second = Stream.advance stream in
        Alcotest.check kind "second" (Op RParen) second.Token.kind;
        let last = Stream.advance stream in
        Alcotest.check kind "eof" Eof last.Token.kind;
        let past = Stream.advance stream in
        Alcotest.check kind "still eof" Eof past.Token.kind;
        Alcotest.(check bool) "at_eof" true (Stream.at_eof stream));
  ]

let () = Alcotest.run "emo_lexer" [ ("foundation", foundation_tests) ]
