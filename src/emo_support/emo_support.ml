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
  let render d =
    let head =
      match d.Diagnostic.code with
      | Some code ->
          Printf.sprintf "%s[%s]: %s"
            (Severity.to_string d.Diagnostic.severity)
            code d.Diagnostic.message
      | None ->
          Printf.sprintf "%s: %s"
            (Severity.to_string d.Diagnostic.severity)
            d.Diagnostic.message
    in
    let location =
      Printf.sprintf "  --> %s" (Span.to_string d.Diagnostic.span)
    in
    match d.Diagnostic.hint with
    | Some hint -> String.concat "\n" [ head; location; "  hint: " ^ hint ]
    | None -> String.concat "\n" [ head; location ]

  let report d = prerr_endline (render d)
end
