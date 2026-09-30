module Token = struct
  type keyword =
    | Def
    | Const
    | Var
    | Class
    | Interface
    | Enum
    | If
    | Else
    | Case
    | When
    | Receive
    | Return
    | Raise
    | Self
    | Do

  type op =
    | LParen
    | RParen
    | LBrace
    | RBrace
    | LBracket
    | RBracket
    | Comma
    | Colon
    | Dot
    | Arrow
    | Send
    | Assign
    | Eq
    | Ne
    | Lt
    | Le
    | Gt
    | Ge
    | Plus
    | Minus
    | Star
    | Slash
    | Percent
    | AndAnd
    | OrOr
    | Not

  type kind =
    | Int of int
    | Float of float
    | Char of char
    | String_chunk of string
    | String_end
    | Interp_open
    | Interp_close
    | True
    | False
    | Lower_ident of string
    | Upper_ident of string
    | Keyword of keyword
    | Op of op
    | Eof

  type t = {
    kind : kind;
    span : Emo_support.Span.t;
    newline_before : bool;
        (* a newline separates this token from the previous one *)
  }
end

exception Error of Emo_support.Diagnostic.t

module Stream : sig
  type t

  val of_array : Token.t array -> t
  val peek : t -> Token.t
  val advance : t -> Token.t
  val at_eof : t -> bool
  val to_list : t -> Token.t list
end = struct
  type t = { toks : Token.t array; mutable cursor : int }

  let of_array toks = { toks; cursor = 0 }
  let clamp s i = min i (Array.length s.toks - 1)
  let peek s = s.toks.(clamp s s.cursor)

  let advance s =
    let tok = peek s in
    if (peek s).Token.kind <> Token.Eof then s.cursor <- s.cursor + 1;
    tok

  let at_eof s = (peek s).Token.kind = Token.Eof
  let to_list s = Array.to_list s.toks
end

let error code span ?hint message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

let lex ~file ~source =
  let len = String.length source in
  let line = ref 1 and col = ref 1 and offset = ref 0 in
  let bump () =
    if !offset < len then (
      if source.[!offset] = '\n' then (
        incr line;
        col := 1)
      else incr col;
      incr offset)
  in
  let eof () = !offset >= len in
  let cur () = source.[!offset] in
  let span_from start_line start_col start_off =
    Emo_support.Span.make ~file ~line:start_line ~col:start_col ~start:start_off
      ~stop:!offset
  in
  let here () =
    Emo_support.Span.make ~file ~line:!line ~col:!col ~start:!offset
      ~stop:!offset
  in
  let toks = ref [] in
  let newline_pending = ref false in
  let prev_was_lparen = ref false in
  let emit kind start_line start_col start_off =
    toks :=
      {
        Token.kind;
        span = span_from start_line start_col start_off;
        newline_before = !newline_pending;
      }
      :: !toks;
    newline_pending := false;
    prev_was_lparen := kind = Token.Op Token.LParen
  in
  let depth = ref 0 in
  let interp_start =
    ref (Emo_support.Span.make ~file ~line:0 ~col:0 ~start:0 ~stop:0)
  in
  let skip_trivia () =
    let rec go () =
      if eof () then ()
      else
        match cur () with
        | ' ' | '\t' | '\r' ->
            bump ();
            go ()
        | '\n' ->
            newline_pending := true;
            bump ();
            go ()
        | _ -> ()
    in
    go ()
  in
  let rec run () =
    skip_trivia ();
    if eof () then (
      if !depth > 0 then
        error "E1003" !interp_start "unterminated string interpolation";
      let l, c, o = (!line, !col, !offset) in
      emit Token.Eof l c o)
    else
      let l, c, o = (!line, !col, !offset) in
      let single kind =
        bump ();
        emit kind l c o
      in
      (match cur () with
      | '(' ->
          if !prev_was_lparen then
            error "E1009" (here ()) "a `(` cannot directly follow another `(`"
              ~hint:"bind the inner value to a name first";
          single (Token.Op Token.LParen)
      | ')' -> single (Token.Op Token.RParen)
      | '{' ->
          single (Token.Op Token.LBrace);
          if !depth > 0 then incr depth
      | '}' ->
          if !depth = 1 then (
            bump ();
            emit Token.Interp_close l c o;
            decr depth)
          else (
            single (Token.Op Token.RBrace);
            if !depth > 1 then decr depth)
      | '[' -> single (Token.Op Token.LBracket)
      | ']' -> single (Token.Op Token.RBracket)
      | ',' -> single (Token.Op Token.Comma)
      | ':' -> single (Token.Op Token.Colon)
      | '.' -> single (Token.Op Token.Dot)
      | c ->
          error "E1001" (here ()) (Printf.sprintf "unexpected character `%c`" c));
      run ()
  in
  run ();
  Stream.of_array (Array.of_list (List.rev !toks))
