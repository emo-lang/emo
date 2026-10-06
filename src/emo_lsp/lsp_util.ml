(* Shared helpers for the Emo language server: URIs, LSP positions
   (UTF-16 based), and small JSON accessors.

   The server speaks the LSP base protocol over stdio. Positions on the
   wire are (line, character) pairs where line is 0-based and character
   counts UTF-16 code units. Emo's own spans are byte offsets into UTF-8
   source, so every boundary is converted here. *)

(* ---- JSON accessors ------------------------------------------------- *)

let member key json = Yojson.Safe.Util.member key json

let to_string_option = function
  | `Null -> None
  | v -> Some (Yojson.Safe.to_string v)

let string_field key json =
  match Yojson.Safe.Util.member key json with `String s -> s | _ -> ""

let int_field key json =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | `Intlit s -> ( try int_of_string s with _ -> 0)
  | `Float f -> int_of_float f
  | _ -> 0

let bool_field key json =
  match Yojson.Safe.Util.member key json with `Bool b -> b | _ -> false

(* Object literal helpers, so request/response shapes read as data. *)
let obj fields = `Assoc fields
let arr xs = `List xs
let str s = `String s
let int n = `Int n
let nullable = function None -> `Null | Some v -> v

(* ---- Percent-encoding for file URIs --------------------------------- *)

let is_unreserved c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '-' || c = '_' || c = '.' || c = '~' || c = '/'

let percent_encode (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char buf c
      else Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents buf

let hex_value c =
  if c >= '0' && c <= '9' then Char.code c - Char.code '0'
  else if c >= 'a' && c <= 'f' then Char.code c - Char.code 'a' + 10
  else if c >= 'A' && c <= 'F' then Char.code c - Char.code 'A' + 10
  else -1

let percent_decode (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '%' && i + 2 < n then
      let hi = hex_value s.[i + 1] and lo = hex_value s.[i + 2] in
      if hi >= 0 && lo >= 0 then (
        Buffer.add_char buf (Char.chr ((hi * 16) + lo));
        go (i + 3))
      else (
        Buffer.add_char buf s.[i];
        go (i + 1))
    else (
      Buffer.add_char buf s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

(* A `file://` URI to a filesystem path. Non-file URIs (e.g. untitled
   buffers) return None. *)
let uri_to_path (uri : string) : string option =
  let lower = String.lowercase_ascii uri in
  let prefix = "file://" in
  let plen = String.length prefix in
  if String.length lower < plen || String.sub lower 0 plen <> prefix then None
  else
    let rest = String.sub uri plen (String.length uri - plen) in
    (* file:///a/b => rest = /a/b ; file://host/a/b is authority-form and
       not supported here. *)
    Some (percent_decode rest)

let path_to_uri (path : string) : string =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  (* Normalize `..` segments textually without touching the filesystem. *)
  let parts = String.split_on_char '/' path in
  let stack =
    List.fold_left
      (fun acc part ->
        match part with
        | "" | "." -> acc
        | ".." -> ( match acc with [] -> [] | _ :: rest -> rest)
        | p -> p :: acc)
      [] parts
  in
  let normalized = "/" ^ String.concat "/" (List.rev stack) in
  "file://" ^ percent_encode normalized

(* ---- UTF-8 / UTF-16 position conversion ----------------------------- *)

(* Decodes one UTF-8 scalar starting at [i]. Returns (codepoint, width).
   Invalid sequences decode as the raw byte with width 1. *)
let utf8_decode (s : string) (i : int) : int * int =
  let n = String.length s in
  let b0 = Char.code s.[i] in
  if b0 < 0x80 then (b0, 1)
  else if b0 land 0xE0 = 0xC0 && i + 1 < n then
    (((b0 land 0x1F) lsl 6) lor (Char.code s.[i + 1] land 0x3F), 2)
  else if b0 land 0xF0 = 0xE0 && i + 2 < n then
    ( ((b0 land 0x0F) lsl 12)
      lor ((Char.code s.[i + 1] land 0x3F) lsl 6)
      lor (Char.code s.[i + 2] land 0x3F),
      3 )
  else if b0 land 0xF8 = 0xF0 && i + 3 < n then
    ( ((b0 land 0x07) lsl 18)
      lor ((Char.code s.[i + 1] land 0x3F) lsl 12)
      lor ((Char.code s.[i + 2] land 0x3F) lsl 6)
      lor (Char.code s.[i + 3] land 0x3F),
      4 )
  else (b0, 1)

let utf16_code_units cp = if cp > 0xFFFF then 2 else 1

(* Byte offsets at which each line starts. *)
let line_starts (text : string) : int array =
  let starts = ref [ 0 ] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) text;
  Array.of_list (List.rev !starts)

let line_of_offset (starts : int array) (offset : int) : int =
  (* Binary search for the last line start <= offset. *)
  let lo = ref 0 and hi = ref (Array.length starts - 1) in
  while !lo < !hi do
    let mid = (!lo + !hi + 1) / 2 in
    if starts.(mid) <= offset then lo := mid else hi := mid - 1
  done;
  !lo

(* Byte offset -> (0-based line, 0-based UTF-16 character). *)
let offset_to_position (text : string) (starts : int array) (offset : int) :
    int * int =
  let offset = max 0 (min offset (String.length text)) in
  let line = line_of_offset starts offset in
  let line_start = starts.(line) in
  let units = ref 0 in
  let i = ref line_start in
  while !i < offset do
    let cp, w = utf8_decode text !i in
    units := !units + utf16_code_units cp;
    i := !i + w
  done;
  (line, !units)

(* (0-based line, 0-based UTF-16 character) -> byte offset, clamped. *)
let position_to_offset (text : string) (starts : int array) ~(line : int)
    ~(character : int) : int =
  let nlines = Array.length starts in
  if line < 0 then 0
  else if line >= nlines then String.length text
  else
    let line_start = starts.(line) in
    let line_end =
      if line + 1 < nlines then starts.(line + 1) - 1 (* exclude \n *)
      else String.length text
    in
    let target = max 0 character in
    let units = ref 0 in
    let i = ref line_start in
    while !i < line_end && !units < target do
      let cp, w = utf8_decode text !i in
      let cu = utf16_code_units cp in
      if !units + cu > target then units := target
      else (
        units := !units + cu;
        i := !i + w)
    done;
    if !units < target then line_end else !i

(* ---- Filesystem helpers --------------------------------------------- *)

let read_file (path : string) : string option =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (really_input_string ic (in_channel_length ic)))
  with Sys_error _ -> None

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let file_exists = Sys.file_exists
let is_directory path = try Sys.is_directory path with Sys_error _ -> false

(* Directory entries, sorted and without `.`/`..`. *)
let readdir (dir : string) : string list =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | raw -> raw |> Array.to_list |> List.sort compare

let basename_no_ext (path : string) : string =
  Filename.remove_extension (Filename.basename path)

(* ---- Path normalization / containment ------------------------------- *)

(* Splits a path into segments, dropping empty and `.` and resolving
   `..` textually. Result is absolute when the input was absolute. *)
let normalize_segments (path : string) : string list =
  let absolute = not (Filename.is_relative path) in
  let stack =
    List.fold_left
      (fun acc part ->
        match part with
        | "" | "." -> acc
        | ".." -> ( match acc with [] -> [] | _ :: rest -> rest)
        | p -> p :: acc)
      []
      (String.split_on_char '/' path)
  in
  let rev = List.rev stack in
  if absolute then "" :: rev else rev

let normalize_path (path : string) : string =
  let segs = normalize_segments path in
  match segs with
  | [] -> "."
  | "" :: rest -> "/" ^ String.concat "/" rest
  | _ -> String.concat "/" segs

let starts_with ~prefix (s : string) : bool =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* True when [path] is [dir] or lives under it. *)
let is_within ~(dir : string) (path : string) : bool =
  let dir = normalize_path dir and path = normalize_path path in
  path = dir || starts_with ~prefix:(dir ^ "/") path
