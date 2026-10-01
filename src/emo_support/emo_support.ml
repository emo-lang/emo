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
