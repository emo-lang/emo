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

let code_of diagnostic =
  match diagnostic.Diagnostic.code with Some c -> c | None -> ""

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

let ident_tests =
  [
    tc "lower and upper identifiers lex to their classes" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Lower_ident "user"; Upper_ident "Color"; Lower_ident "_tmp"; Eof ]
          (kinds (lex_all "user Color _tmp")));
    tc "true and false are literal tokens" (fun () ->
        Alcotest.(check (list kind))
          "kinds" [ True; False; Eof ]
          (kinds (lex_all "true false")));
    tc "a trailing question mark joins the name" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Lower_ident "is_older?"; Op LParen; Op RParen; Eof ]
          (kinds (lex_all "is_older?()")));
    tc "keyword prefixes and camelCase stay one lower token" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Lower_ident "doing"; Lower_ident "classX"; Eof ]
          (kinds (lex_all "doing classX")));
    tc "every keyword lexes" (fun () ->
        let source =
          "def const var class interface enum if else case when receive return \
           raise self do"
        in
        let expected =
          [
            Token.Keyword Token.Def;
            Token.Keyword Token.Const;
            Token.Keyword Token.Var;
            Token.Keyword Token.Class;
            Token.Keyword Token.Interface;
            Token.Keyword Token.Enum;
            Token.Keyword Token.If;
            Token.Keyword Token.Else;
            Token.Keyword Token.Case;
            Token.Keyword Token.When;
            Token.Keyword Token.Receive;
            Token.Keyword Token.Return;
            Token.Keyword Token.Raise;
            Token.Keyword Token.Self;
            Token.Keyword Token.Do;
            Token.Eof;
          ]
        in
        Alcotest.(check (list kind)) "kinds" expected (kinds (lex_all source)));
  ]

let operator_tests =
  [
    tc "every operator lexes in sequence" (fun () ->
        let source =
          "( ) { } [ ] , : . -> <- = == != < <= > >= + - * / % && || !"
        in
        let expected =
          [
            Token.Op Token.LParen;
            Token.Op Token.RParen;
            Token.Op Token.LBrace;
            Token.Op Token.RBrace;
            Token.Op Token.LBracket;
            Token.Op Token.RBracket;
            Token.Op Token.Comma;
            Token.Op Token.Colon;
            Token.Op Token.Dot;
            Token.Op Token.Arrow;
            Token.Op Token.Send;
            Token.Op Token.Assign;
            Token.Op Token.Eq;
            Token.Op Token.Ne;
            Token.Op Token.Lt;
            Token.Op Token.Le;
            Token.Op Token.Gt;
            Token.Op Token.Ge;
            Token.Op Token.Plus;
            Token.Op Token.Minus;
            Token.Op Token.Star;
            Token.Op Token.Slash;
            Token.Op Token.Percent;
            Token.Op Token.AndAnd;
            Token.Op Token.OrOr;
            Token.Op Token.Not;
            Token.Eof;
          ]
        in
        Alcotest.(check (list kind)) "kinds" expected (kinds (lex_all source)));
    tc "send requires whitespace on both sides" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Lower_ident "a"; Op Send; Lower_ident "b"; Eof ]
          (kinds (lex_all "a <- b")));
    tc "a < -b lexes as less-than then unary minus" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Lower_ident "a"; Op Lt; Op Minus; Lower_ident "b"; Eof ]
          (kinds (lex_all "a < -b")));
    tc "a single ampersand is rejected toward &&" (fun () ->
        let diagnostic = lex_err "&" in
        Alcotest.(check string)
          "code" "E1001"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> "");
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a single bar is rejected toward ||" (fun () ->
        let diagnostic = lex_err "|" in
        Alcotest.(check string)
          "code" "E1001"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> "");
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
  ]

let literal_tests =
  [
    tc "integers lex with their values" (fun () ->
        Alcotest.(check (list kind))
          "kinds" [ Int 0; Int 42; Eof ]
          (kinds (lex_all "0 42")));
    tc "floats require digits around the dot" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Float 1.0; Float 2.5; Eof ]
          (kinds (lex_all "1.0 2.5")));
    tc "a trailing dot is member access on an integer" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Int 1; Op Dot; Lower_ident "to_string"; Op LParen; Op RParen; Eof ]
          (kinds (lex_all "1.to_string()")));
    tc "an underscore directly after a number is a lexical error" (fun () ->
        let diagnostic = lex_err "1_a" in
        Alcotest.(check string)
          "code" "E1006"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> "");
        Alcotest.(check string)
          "span" "test.emo:1:2"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "integer literals beyond machine range are rejected" (fun () ->
        let diagnostic = lex_err "99999999999999999999999999" in
        Alcotest.(check string)
          "code" "E1006"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> "");
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "character literals carry their value" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ Char 'a'; Char '\n'; Char '\''; Eof ]
          (kinds (lex_all "'a' '\\n' '\\''")));
    tc "character literals must hold exactly one character" (fun () ->
        let diagnostic = lex_err "'ab'" in
        Alcotest.(check string)
          "code" "E1005"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> "");
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "empty character literals are rejected" (fun () ->
        let diagnostic = lex_err "''" in
        Alcotest.(check string)
          "code" "E1005"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> ""));
    tc "unterminated character literals are rejected" (fun () ->
        let diagnostic = lex_err "'a" in
        Alcotest.(check string)
          "code" "E1005"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> ""));
    tc "unknown escapes are rejected with the supported set" (fun () ->
        let diagnostic = lex_err "'\\q'" in
        Alcotest.(check string)
          "code" "E1004"
          (match diagnostic.Diagnostic.code with Some c -> c | None -> ""));
  ]

let string_tests =
  [
    tc "a plain string lexes as one chunk plus string_end" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ String_chunk "hello"; String_end; Eof ]
          (kinds (lex_all "\"hello\"")));
    tc "an empty string is just string_end" (fun () ->
        Alcotest.(check (list kind))
          "kinds" [ String_end; Eof ]
          (kinds (lex_all "\"\"")));
    tc "interpolation opens and closes with braces" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [
            String_chunk "a ";
            Interp_open;
            Lower_ident "x";
            Interp_close;
            String_chunk " b";
            String_end;
            Eof;
          ]
          (kinds (lex_all "\"a ${x} b\"")));
    tc "nested interpolation keeps brace depth" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [
            String_chunk "a ";
            Interp_open;
            String_chunk "b ";
            Interp_open;
            Lower_ident "x";
            Interp_close;
            String_end;
            Interp_close;
            String_chunk " c";
            String_end;
            Eof;
          ]
          (kinds (lex_all "\"a ${ \"b ${x}\" } c\"")));
    tc "a block brace inside an interpolation stays a block" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [
            Interp_open;
            Op LBrace;
            Lower_ident "x";
            Op RBrace;
            Interp_close;
            String_end;
            Eof;
          ]
          (kinds (lex_all "\"${ {x} }\"")));
    tc "a dollar not followed by a brace is literal text" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [ String_chunk "cost: $5"; String_end; Eof ]
          (kinds (lex_all "\"cost: $5\"")));
    tc "interpolation may contain operators" (fun () ->
        Alcotest.(check (list kind))
          "kinds"
          [
            Interp_open;
            Lower_ident "a";
            Op Plus;
            Lower_ident "b";
            Interp_close;
            String_end;
            Eof;
          ]
          (kinds (lex_all "\"${a + b}\"")));
    tc "an unterminated string at eof is an error" (fun () ->
        let diagnostic = lex_err "\"abc" in
        Alcotest.(check string) "code" "E1002" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "a raw newline inside a string is unterminated" (fun () ->
        let diagnostic = lex_err "\"a\nb\"" in
        Alcotest.(check string) "code" "E1002" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:1"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "an unterminated interpolation is an error" (fun () ->
        let diagnostic = lex_err "\"a ${x" in
        Alcotest.(check string) "code" "E1003" (code_of diagnostic);
        Alcotest.(check string)
          "span" "test.emo:1:4"
          (Span.to_string diagnostic.Diagnostic.span));
    tc "unknown escapes inside strings are rejected" (fun () ->
        let diagnostic = lex_err "\"\\q\"" in
        Alcotest.(check string) "code" "E1004" (code_of diagnostic));
  ]

let () =
  Alcotest.run "emo_lexer"
    [
      ("foundation", foundation_tests);
      ("ident", ident_tests);
      ("operator", operator_tests);
      ("literal", literal_tests);
      ("string", string_tests);
    ]
