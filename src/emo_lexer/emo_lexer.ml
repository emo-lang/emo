module Token = struct
  type keyword =
    | Def
    | Const
    | Var
    | Emo
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
    | Require

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
  val peek_ahead : t -> int -> Token.t
  val advance : t -> Token.t
  val at_eof : t -> bool
  val newline_before : t -> bool
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

  let peek_ahead s k = s.toks.(clamp s (s.cursor + k))
  let at_eof s = (peek s).Token.kind = Token.Eof
  let newline_before s = (peek s).Token.newline_before
  let to_list s = Array.to_list s.toks
end

let error code span ?hint message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

type frame =
  | String_frame of Emo_support.Span.t (* the opening quote *)
  | Interp_frame of
      Emo_support.Span.t (* the ${ that opened the interpolation *)
  | Block_frame

let is_ws c = c = ' ' || c = '\t' || c = '\r' || c = '\n'
let is_digit c = c >= '0' && c <= '9'
let is_lower c = c >= 'a' && c <= 'z'
let is_upper c = c >= 'A' && c <= 'Z'
let is_ident_letter c = is_digit c || is_lower c || is_upper c || c = '_'

let keyword_of_string = function
  | "def" -> Some Token.Def
  | "const" -> Some Token.Const
  | "var" -> Some Token.Var
  | "class" -> Some Token.Class
  | "emo" -> Some Token.Emo
  | "interface" -> Some Token.Interface
  | "enum" -> Some Token.Enum
  | "if" -> Some Token.If
  | "else" -> Some Token.Else
  | "case" -> Some Token.Case
  | "when" -> Some Token.When
  | "receive" -> Some Token.Receive
  | "return" -> Some Token.Return
  | "raise" -> Some Token.Raise
  | "self" -> Some Token.Self
  | "do" -> Some Token.Do
  | "require" -> Some Token.Require
  | _ -> None

let escape_char = function
  | 'n' -> Some '\n'
  | 'r' -> Some '\r'
  | 't' -> Some '\t'
  | '\\' -> Some '\\'
  | '\'' -> Some '\''
  | '"' -> Some '"'
  | _ -> None

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
  let char_at k =
    if !offset + k < len then Some source.[!offset + k] else None
  in
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
  let frames = ref [] in
  let current_string_span () =
    match !frames with String_frame span :: _ -> span | _ -> assert false
  in
  let ws_before = ref false in
  let skip_trivia () =
    let skipped = ref false in
    let rec go () =
      if eof () then ()
      else
        match cur () with
        | ' ' | '\t' | '\r' ->
            skipped := true;
            bump ();
            go ()
        | '\n' ->
            skipped := true;
            newline_pending := true;
            bump ();
            go ()
        | '/' when char_at 1 = Some '/' ->
            skipped := true;
            let rec line () =
              if eof () then ()
              else if cur () = '\n' then go ()
              else (
                bump ();
                line ())
            in
            line ()
        | _ -> ()
    in
    go ();
    ws_before := !skipped || !offset = 0
  in
  let scan_chunk () =
    let start_line, start_col, start_off = (!line, !col, !offset) in
    let buf = Buffer.create 16 in
    let finish () =
      if Buffer.length buf > 0 then
        emit
          (Token.String_chunk (Buffer.contents buf))
          start_line start_col start_off
    in
    let rec go () =
      if eof () then
        error "E1002" (current_string_span ()) "unterminated string literal"
      else
        match cur () with
        | '"' ->
            finish ();
            let l, c, o = (!line, !col, !offset) in
            bump ();
            emit Token.String_end l c o;
            frames := List.tl !frames
        | '$' when char_at 1 = Some '{' ->
            finish ();
            let l, c, o = (!line, !col, !offset) in
            bump ();
            bump ();
            emit Token.Interp_open l c o;
            frames :=
              Interp_frame
                (Emo_support.Span.make ~file ~line:l ~col:c ~start:o
                   ~stop:(o + 2))
              :: !frames
        | '\\' -> (
            match char_at 1 with
            | Some e -> (
                match escape_char e with
                | Some ec ->
                    bump ();
                    bump ();
                    Buffer.add_char buf ec;
                    go ()
                | None ->
                    error "E1004"
                      (Emo_support.Span.make ~file ~line:!line ~col:!col
                         ~start:!offset ~stop:(!offset + 2))
                      "invalid escape sequence"
                      ~hint:
                        "supported escapes are \\n \\r \\t \\\\ \\' and \\\"")
            | None ->
                error "E1002" (current_string_span ())
                  "unterminated string literal")
        | '\n' ->
            error "E1002" (current_string_span ()) "unterminated string literal"
        | ch ->
            Buffer.add_char buf ch;
            bump ();
            go ()
    in
    go ()
  in
  let rec run () =
    if match !frames with String_frame _ :: _ -> true | _ -> false then (
      scan_chunk ();
      run ())
    else (
      skip_trivia ();
      if eof () then (
        let rec unterminated = function
          | String_frame span :: _ ->
              Some (span, "unterminated string literal", "E1002")
          | Interp_frame span :: _ ->
              Some (span, "unterminated string interpolation", "E1003")
          | Block_frame :: rest -> unterminated rest
          | [] -> None
        in
        (match unterminated !frames with
        | Some (span, message, code) -> error code span message
        | None -> ());
        let l, c, o = (!line, !col, !offset) in
        emit Token.Eof l c o)
      else
        let l, c, o = (!line, !col, !offset) in
        let single kind =
          bump ();
          emit kind l c o
        in
        let double kind =
          bump ();
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
            frames := Block_frame :: !frames
        | '}' -> (
            match !frames with
            | Interp_frame _ :: rest ->
                bump ();
                emit Token.Interp_close l c o;
                frames := rest
            | Block_frame :: rest ->
                single (Token.Op Token.RBrace);
                frames := rest
            | _ -> single (Token.Op Token.RBrace))
        | '[' -> single (Token.Op Token.LBracket)
        | ']' -> single (Token.Op Token.RBracket)
        | ',' -> single (Token.Op Token.Comma)
        | ':' -> single (Token.Op Token.Colon)
        | '.' -> single (Token.Op Token.Dot)
        | '"' ->
            frames := String_frame (here ()) :: !frames;
            bump ()
        | '-' ->
            if char_at 1 = Some '>' then double (Token.Op Token.Arrow)
            else single (Token.Op Token.Minus)
        | '<' ->
            if char_at 1 = Some '-' then (
              let ws_after =
                match char_at 2 with Some c2 -> is_ws c2 | None -> true
              in
              if not (!ws_before && ws_after) then
                error "E1008"
                  (Emo_support.Span.make ~file ~line:l ~col:c ~start:o
                     ~stop:(o + 2))
                  "the send operator `<-` needs a space on each side"
                  ~hint:"write `a <- b`, never `a<-b`";
              double (Token.Op Token.Send))
            else if char_at 1 = Some '=' then double (Token.Op Token.Le)
            else single (Token.Op Token.Lt)
        | '=' ->
            if char_at 1 = Some '=' then double (Token.Op Token.Eq)
            else single (Token.Op Token.Assign)
        | '!' ->
            if char_at 1 = Some '=' then double (Token.Op Token.Ne)
            else single (Token.Op Token.Not)
        | '>' ->
            if char_at 1 = Some '=' then double (Token.Op Token.Ge)
            else single (Token.Op Token.Gt)
        | '&' ->
            if char_at 1 = Some '&' then double (Token.Op Token.AndAnd)
            else
              error "E1001" (here ()) "unexpected character `&`"
                ~hint:"Emo uses `&&` for logical and"
        | '|' ->
            if char_at 1 = Some '|' then double (Token.Op Token.OrOr)
            else
              error "E1001" (here ()) "unexpected character `|`"
                ~hint:"Emo uses `||` for logical or"
        | '+' -> single (Token.Op Token.Plus)
        | '*' -> single (Token.Op Token.Star)
        | '/' -> single (Token.Op Token.Slash)
        | '%' -> single (Token.Op Token.Percent)
        | dc when is_digit dc -> (
            let rec digits () =
              if (not (eof ())) && is_digit (cur ()) then (
                bump ();
                digits ())
            in
            digits ();
            match char_at 0 with
            | Some '.'
              when match char_at 1 with Some d -> is_digit d | None -> false ->
                bump ();
                digits ();
                emit
                  (Token.Float
                     (float_of_string (String.sub source o (!offset - o))))
                  l c o
            | _ -> (
                if (not (eof ())) && cur () = '_' then
                  error "E1006" (here ())
                    "a number cannot be directly followed by `_`"
                    ~hint:"digit separators are not supported";
                match int_of_string_opt (String.sub source o (!offset - o)) with
                | Some n -> emit (Token.Int n) l c o
                | None ->
                    error "E1006" (span_from l c o)
                      "integer literal out of range"))
        | '\'' ->
            let qline, qcol, qoff = (l, c, o) in
            let quoted_span =
              Emo_support.Span.make ~file ~line:qline ~col:qcol ~start:qoff
                ~stop:(qoff + 2)
            in
            bump ();
            if eof () then
              error "E1005"
                (span_from qline qcol qoff)
                "unterminated character literal";
            if cur () = '\'' then
              error "E1005" quoted_span
                "character literal must contain exactly one character";
            let content =
              if cur () = '\\' then
                match char_at 1 with
                | Some e -> (
                    match escape_char e with
                    | Some ec ->
                        bump ();
                        bump ();
                        ec
                    | None ->
                        error "E1004" quoted_span "invalid escape sequence"
                          ~hint:
                            "supported escapes are \\n \\r \\t \\\\ \\' and \
                             \\\"")
                | None ->
                    error "E1005"
                      (span_from qline qcol qoff)
                      "unterminated character literal"
              else (
                if cur () = '\n' then
                  error "E1005"
                    (span_from qline qcol qoff)
                    "unterminated character literal";
                let ch = cur () in
                bump ();
                ch)
            in
            if eof () || cur () <> '\'' then
              error "E1005"
                (span_from qline qcol qoff)
                "character literal must contain exactly one character";
            bump ();
            emit (Token.Char content) qline qcol qoff
        | ch when is_lower ch || ch = '_' -> (
            let rec ident_tail () =
              if (not (eof ())) && is_ident_letter (cur ()) then (
                bump ();
                ident_tail ())
            in
            ident_tail ();
            (if (not (eof ())) && cur () = '?' then
               match char_at 1 with
               | Some next when is_ident_letter next || next = '?' ->
                   error "E1007" (here ())
                     "a predicate name's `?` must be its last character"
               | _ -> bump ());
            let text = String.sub source o (!offset - o) in
            match text with
            | "true" -> emit Token.True l c o
            | "false" -> emit Token.False l c o
            | t -> (
                match keyword_of_string t with
                | Some k -> emit (Token.Keyword k) l c o
                | None -> emit (Token.Lower_ident t) l c o))
        | ch when is_upper ch ->
            let rec ident_tail () =
              if (not (eof ())) && is_ident_letter (cur ()) then (
                bump ();
                ident_tail ())
            in
            ident_tail ();
            emit (Token.Upper_ident (String.sub source o (!offset - o))) l c o
        | c ->
            if c = '@' || c = '$' || c = ';' || c = '#' then
              error "E1001" (here ())
                (Printf.sprintf "unexpected character `%c`" c)
                ~hint:"`@`, `$`, `;` and `#` have no meaning in Emo"
            else
              error "E1001" (here ())
                (Printf.sprintf "unexpected character `%c`" c));
        run ())
  in
  run ();
  Stream.of_array (Array.of_list (List.rev !toks))
