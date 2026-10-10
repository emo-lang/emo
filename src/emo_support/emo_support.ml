module Severity = struct
  type t = Error | Warning

  let to_string = function Error -> "error" | Warning -> "warning"
end

module Span = struct
  type t = {
    file : string;
    line : int; (* 1-based line of the start *)
    col : int; (* 1-based column of the start *)
    start : int; (* byte offset of the first character *)
    stop : int; (* byte offset one past the last character *)
  }

  let make ~file ~line ~col ~start ~stop =
    if stop < start then invalid_arg "Span.make: stop precedes start";
    { file; line; col; start; stop }

  (* A synthetic position for runtime-generated diagnostics (the compiled
     backend's operations carry no source spans). *)
  let zero = { file = "<runtime>"; line = 1; col = 1; start = 0; stop = 0 }
  let to_string t = Printf.sprintf "%s:%d:%d" t.file t.line t.col

  let merge a b =
    if not (String.equal a.file b.file) then
      invalid_arg "Span.merge: spans belong to different files";
    if b.start < a.start then { b with stop = max a.stop b.stop }
    else { a with stop = max a.stop b.stop }
end

module Diagnostic = struct
  type t = {
    severity : Severity.t;
    code : string option; (* stage-prefixed, e.g. "E2003" *)
    message : string;
    span : Span.t;
    hint : string option;
  }
end

module Render = struct
  let styled color code s =
    if color then "\027[" ^ code ^ "m" ^ s ^ "\027[0m" else s

  let source_line source line_no =
    let rec nth lines n =
      match (lines, n) with
      | [], _ -> ""
      | l :: _, 0 -> l
      | _ :: rest, k -> nth rest (k - 1)
    in
    nth (String.split_on_char '\n' source) (line_no - 1)

  let take n xs =
    let rec loop n xs acc =
      if n <= 0 then List.rev acc
      else
        match xs with
        | [] -> List.rev acc
        | x :: rest -> loop (n - 1) rest (x :: acc)
    in
    loop n xs []

  (* One diagnostic as a source excerpt:
        error[E2003]: message
          --> file:9:5
         |
         9 |     self.age = 36
         |     ^^^^^^^^^ hint *)
  let render ?(color = false) ~source (d : Diagnostic.t) : string =
    let label = styled color "31;1" (Severity.to_string d.severity) in
    let head =
      match d.code with
      | Some code -> Printf.sprintf "%s[%s]: %s" label code d.message
      | None -> Printf.sprintf "%s: %s" label d.message
    in
    (* The excerpt comes from the span's file when it exists on disk —
       eval-stage diagnostics can span any project file; the caller's
       source covers synthetic spans and in-memory text. *)
    let source =
      if Sys.file_exists d.span.file && not (Sys.is_directory d.span.file) then (
        let ic = open_in_bin d.span.file in
        let text = really_input_string ic (in_channel_length ic) in
        close_in ic;
        text)
      else source
    in
    let line_text = source_line source d.span.line in
    let line_len = String.length line_text in
    let number = string_of_int d.span.line in
    let width = String.length number in
    let blank_gutter = String.make width ' ' ^ " |" in
    let caret_column = min d.span.col (line_len + 1) - 1 in
    let span_len = max 1 (d.span.stop - d.span.start) in
    let caret_count = max 1 (min span_len (line_len - caret_column)) in
    let carets = styled color "31;1" (String.make caret_count '^') in
    let caret_tail = match d.hint with Some h -> " " ^ h | None -> "" in
    String.concat "\n"
      [
        head;
        "  --> " ^ Span.to_string d.span;
        blank_gutter;
        number ^ " | " ^ line_text;
        blank_gutter ^ " " ^ String.make caret_column ' ' ^ carets ^ caret_tail;
      ]

  (* Every recoverable error from one stage, sorted by position and capped at
     [limit] (None renders all). A suppressed remainder is noted at the end. *)
  let render_all ?(color = false) ~(limit : int option) ~source
      (diagnostics : Diagnostic.t list) : string =
    let sorted =
      List.sort
        (fun a b ->
          compare
            ( a.Diagnostic.span.line,
              a.Diagnostic.span.col,
              a.Diagnostic.span.start )
            ( b.Diagnostic.span.line,
              b.Diagnostic.span.col,
              b.Diagnostic.span.start ))
        diagnostics
    in
    let shown = match limit with Some n -> take n sorted | None -> sorted in
    let rendered = List.map (render ~color ~source) shown in
    match limit with
    | Some n when List.length sorted > n ->
        String.concat "\n"
          (rendered
          @ [
              Printf.sprintf
                "  ... %d more error(s) hidden; raise --error-limit"
                (List.length sorted - n);
            ])
    | _ -> String.concat "\n" rendered
end

(* The printf format grammar, parsed once and shared by the checker's
   static validation and the interpreter's renderer. The semantics anchor
   on C17 §7.21.6.1; the pieces of C that have no Emo meaning (length
   modifiers, %n, %p, hex floats) are parse errors, not silent drops. *)
module Printf_format = struct
  type size = Fixed of int | Star

  type spec = {
    minus : bool; (* '-' : left-align *)
    plus : bool; (* '+' : always show the sign *)
    space : bool; (* ' ' : sign position for non-negative values *)
    hash : bool; (* '#' : alternate form *)
    zero : bool; (* '0' : zero-fill *)
    width : size option;
    prec : size option; (* None = conversion default; Some (Fixed 0) = `.0` *)
    conv : char;
  }

  type part = Text of string | Spec of spec

  exception Bad of string

  let width_limit = 999_999_999
  let is_digit c = c >= '0' && c <= '9'

  let saturate digits =
    let n = String.length digits in
    if n > 10 then width_limit
    else
      let v = ref 0 in
      String.iter
        (fun d -> v := (!v * 10) + (Char.code d - Char.code '0'))
        digits;
      Int.min !v width_limit

  let parse (fmt : string) : part list =
    let parts = ref [] in
    let text_start = ref 0 in
    let flush_text stop =
      if !text_start < stop then
        parts :=
          Text (String.sub fmt !text_start (stop - !text_start)) :: !parts
    in
    let len = String.length fmt in
    let i = ref 0 in
    while !i < len do
      if fmt.[!i] <> '%' then incr i
      else begin
        flush_text !i;
        incr i;
        if !i >= len then raise (Bad "printf: the format ends with a lone `%`");
        if fmt.[!i] = '%' then begin
          parts :=
            Spec
              {
                minus = false;
                plus = false;
                space = false;
                hash = false;
                zero = false;
                width = None;
                prec = None;
                conv = '%';
              }
            :: !parts;
          incr i;
          text_start := !i
        end
        else begin
          let minus = ref false and plus = ref false and space = ref false in
          let hash = ref false and zero = ref false in
          let rec read_flags () =
            if !i < len then
              match fmt.[!i] with
              | '-' ->
                  minus := true;
                  incr i;
                  read_flags ()
              | '+' ->
                  plus := true;
                  incr i;
                  read_flags ()
              | ' ' ->
                  space := true;
                  incr i;
                  read_flags ()
              | '#' ->
                  hash := true;
                  incr i;
                  read_flags ()
              | '0' ->
                  zero := true;
                  incr i;
                  read_flags ()
              | _ -> ()
          in
          read_flags ();
          let width =
            if !i < len && fmt.[!i] = '*' then begin
              incr i;
              Some Star
            end
            else if !i < len && is_digit fmt.[!i] then begin
              let start = !i in
              while !i < len && is_digit fmt.[!i] do
                incr i
              done;
              Some (Fixed (saturate (String.sub fmt start (!i - start))))
            end
            else None
          in
          let prec =
            if !i < len && fmt.[!i] = '.' then begin
              incr i;
              if !i < len && fmt.[!i] = '*' then begin
                incr i;
                Some Star
              end
              else begin
                let start = !i in
                while !i < len && is_digit fmt.[!i] do
                  incr i
                done;
                (* `%.f` spells an explicit precision of zero in C. *)
                Some (Fixed (saturate (String.sub fmt start (!i - start))))
              end
            end
            else None
          in
          (* Length modifiers have no Emo reading: the numeric argument
             types are fixed-width already. Parse to reject, not to guess. *)
          if
            !i < len
            &&
            match fmt.[!i] with
            | 'h' | 'l' | 'L' | 'z' | 'j' | 't' -> true
            | _ -> false
          then
            raise
              (Bad
                 "printf: length modifiers (`h`, `l`, `ll`, `z`, ...) have no \
                  meaning in Emo");
          if !i < len && fmt.[!i] = '%' then
            raise (Bad "printf: `%%` cannot carry flags, width, or precision");
          if !i >= len then
            raise (Bad "printf: the format ends with a bare `%`");
          let conv = fmt.[!i] in
          incr i;
          (match conv with
          | 'd' | 'i' | 'u' | 'o' | 'x' | 'X' | 'c' | 's' | 'f' | 'F' | 'e'
          | 'E' | 'g' | 'G' ->
              parts :=
                Spec
                  {
                    minus = !minus;
                    plus = !plus;
                    space = !space;
                    hash = !hash;
                    zero = !zero;
                    width;
                    prec;
                    conv;
                  }
                :: !parts
          | 'a' | 'A' ->
              raise
                (Bad
                   (Printf.sprintf
                      "printf: hex-float conversion `%%%c` is not supported"
                      conv))
          | 'n' ->
              raise
                (Bad
                   "printf: `%n` is not supported (it writes through pointers)")
          | 'p' ->
              raise (Bad "printf: `%p` is not supported (Emo has no pointers)")
          | other ->
              raise
                (Bad (Printf.sprintf "printf: unknown conversion `%%%c`" other)));
          text_start := !i
        end
      end
    done;
    flush_text len;
    List.rev !parts

  (* How many array elements one format consumes: each conversion but
     `%%`, plus one per `*` width or precision. *)
  let rec consumed_slots (parts : part list) : int =
    match parts with
    | [] -> 0
    | Text _ :: rest -> consumed_slots rest
    | Spec s :: rest ->
        let star = function Some Star -> 1 | _ -> 0 in
        let own =
          (if s.conv = '%' then 0 else 1) + star s.width + star s.prec
        in
        own + consumed_slots rest
end
