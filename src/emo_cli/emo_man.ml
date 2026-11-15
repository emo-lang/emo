(* The standard library's manual pages. The pages ride the binary as
   generated data (man_data.ml), the same route the stdlib sources take
   (T24.2), so an installed emo reads its own manual with nothing beside
   it. The docs under docs/stdlib/ stay the source of truth; the reader
   below handles the Markdown subset those pages are written in and
   lays the page out the way man lays out a page. *)

let overview = "stdlib"
let names : string list = List.map fst Man_data.pages
let find (name : string) : string option = List.assoc_opt name Man_data.pages

(* ---- the text ---- *)

let is_space c = c = ' ' || c = '\t' || c = '\r'

let is_alnum c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

let strip_cr line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line

let lines text = String.split_on_char '\n' text |> List.map strip_cr
let blank line = String.for_all (fun c -> c = ' ' || c = '\t') line

let starts_with prefix s =
  let n = String.length prefix in
  String.length s >= n && String.sub s 0 n = prefix

let rtrim s =
  let n = ref (String.length s) in
  while !n > 0 && is_space s.[!n - 1] do
    decr n
  done;
  String.sub s 0 !n

let split_ws s =
  let out = ref [] and cur = Buffer.create 16 in
  let flush () =
    if Buffer.length cur > 0 then begin
      out := Buffer.contents cur :: !out;
      Buffer.clear cur
    end
  in
  String.iter
    (fun c -> if is_space c then flush () else Buffer.add_char cur c)
    s;
  flush ();
  List.rev !out

let find_sub s ~(from : int) (needle : string) : int option =
  let n = String.length s and m = String.length needle in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = needle then Some i
    else go (i + 1)
  in
  if m = 0 then Some from else go from

(* ---- inline Markdown ---- *)

let link_at s i =
  let n = String.length s in
  let rec seek close j =
    if j >= n then None else if s.[j] = close then Some j else seek close (j + 1)
  in
  match seek ']' (i + 1) with
  | Some j when j + 1 < n && s.[j + 1] = '(' -> (
      match seek ')' (j + 2) with
      | Some k ->
          Some
            ( String.sub s (i + 1) (j - i - 1),
              String.sub s (j + 2) (k - j - 2),
              k + 1 )
      | None -> None)
  | _ -> None

let rec inline s =
  let n = String.length s in
  let out = Buffer.create n in
  let rec go i =
    if i >= n then ()
    else
      match s.[i] with
      | '`' -> (
          let j = ref (i + 1) in
          while !j < n && s.[!j] = '`' do
            incr j
          done;
          let run = !j - i in
          let fence = String.make run '`' in
          match find_sub s ~from:!j fence with
          | Some k ->
              Buffer.add_string out (String.sub s !j (k - !j));
              go (k + run)
          | None ->
              Buffer.add_string out fence;
              go !j)
      | '*' when i + 1 < n && s.[i + 1] = '*' -> (
          match find_sub s ~from:(i + 2) "**" with
          | Some k ->
              Buffer.add_string out (inline (String.sub s (i + 2) (k - i - 2)));
              go (k + 2)
          | None ->
              Buffer.add_char out '*';
              go (i + 1))
      | '*' when i + 1 < n && not (is_space s.[i + 1]) -> (
          let rec close j =
            if j >= n then None
            else if
              s.[j] = '*'
              && (not (is_space s.[j - 1]))
              && (j + 1 >= n || not (is_alnum s.[j + 1]))
            then Some j
            else close (j + 1)
          in
          match close (i + 1) with
          | Some k ->
              Buffer.add_string out (inline (String.sub s (i + 1) (k - i - 1)));
              go (k + 1)
          | None ->
              Buffer.add_char out '*';
              go (i + 1))
      | '[' -> (
          match link_at s i with
          | Some (label, target, next) ->
              Buffer.add_string out (link label target);
              go next
          | None ->
              Buffer.add_char out '[';
              go (i + 1))
      | c ->
          Buffer.add_char out c;
          go (i + 1)
  and link label target =
    let label = inline label in
    if
      (starts_with "http://" target || starts_with "https://" target)
      && label <> target
    then label ^ " (" ^ target ^ ")"
    else label
  in
  go 0;
  Buffer.contents out

(* ---- the page's own Markdown blocks ---- *)

let fence line = starts_with "```" line
let heading line = starts_with "#" line

let heading_level line =
  let rec count i =
    if i < String.length line && line.[i] = '#' then count (i + 1) else i
  in
  count 0

let bullet_prefix line =
  if starts_with "- " line then Some 2
  else if starts_with "* " line then Some 2
  else None

let number_prefix line =
  let n = String.length line in
  let rec digits i =
    if i < n && line.[i] >= '0' && line.[i] <= '9' then digits (i + 1) else i
  in
  let i = digits 0 in
  if i > 0 && i + 1 < n && line.[i] = '.' && line.[i + 1] = ' ' then Some (i + 2)
  else None

let split_row line =
  let line = String.trim line in
  let line =
    if starts_with "|" line then String.sub line 1 (String.length line - 1)
    else line
  in
  let line =
    if String.length line > 0 && line.[String.length line - 1] = '|' then
      String.sub line 0 (String.length line - 1)
    else line
  in
  String.split_on_char '|' line

let separator_cell cell =
  let cell = String.trim cell in
  cell <> "" && String.for_all (fun c -> c = '-' || c = ':' || c = ' ') cell

type block =
  | Code of string list
  | Heading of int * string
  | Table of string list list
  | Bullets of string list list
  | Numbered of (string * string list) list
  | Para of string list

let rec parse_blocks ls =
  match ls with
  | [] -> []
  | l :: rest when blank l -> parse_blocks rest
  | l :: rest when fence l ->
      let code, rest = take_code rest [] in
      Code code :: parse_blocks rest
  | l :: rest ->
      let chunk, rest = take_chunk (l :: rest) [] in
      classify chunk :: parse_blocks rest

and take_code ls acc =
  match ls with
  | [] -> (List.rev acc, [])
  | l :: rest when fence l -> (List.rev acc, rest)
  | l :: rest -> take_code rest (rtrim l :: acc)

and take_chunk ls acc =
  match ls with
  | [] -> (List.rev acc, [])
  | l :: rest when blank l -> (List.rev acc, l :: rest)
  | l :: rest -> take_chunk rest (l :: acc)

and classify chunk =
  match chunk with
  | [] -> Para []
  | first :: _ ->
      if heading first then
        let level = heading_level first in
        Heading
          ( level,
            String.sub first level (String.length first - level) |> String.trim
          )
      else if starts_with "|" first then Table (List.map split_row chunk)
      else if bullet_prefix first <> None then Bullets (take_items chunk)
      else if number_prefix first <> None then Numbered (take_numbers chunk)
      else Para chunk

and take_items chunk =
  let close items current =
    match current with [] -> items | _ -> List.rev current :: items
  in
  let rec go items current = function
    | [] -> List.rev (close items current)
    | l :: rest when bullet_prefix l <> None ->
        let body =
          match bullet_prefix l with
          | Some width -> String.sub l width (String.length l - width)
          | None -> l
        in
        go (close items current) [ body ] rest
    | l :: rest -> go items (l :: current) rest
  in
  go [] [] chunk

and take_numbers chunk =
  let close items current =
    match current with
    | None -> items
    | Some (marker, src) -> (marker, List.rev src) :: items
  in
  let rec go items current = function
    | [] -> List.rev (close items current)
    | l :: rest -> (
        match number_prefix l with
        | Some width ->
            let marker = String.sub l 0 (width - 2) in
            let body = String.sub l width (String.length l - width) in
            go (close items current) (Some (marker, [ body ])) rest
        | None -> (
            match current with
            | Some (marker, src) -> go items (Some (marker, l :: src)) rest
            | None -> go items current rest))
  in
  go [] None chunk

(* ---- layout ---- *)

let columns () =
  match
    Sys.getenv_opt "COLUMNS" |> Option.map int_of_string_opt |> Option.join
  with
  | Some n when n >= 40 -> min n 200
  | _ -> 80

let indent = "       "

let wrap ~(first : string) ~(rest : string) ~(width : int) (words : string list)
    : string list =
  let out = ref []
  and cur = Buffer.create 100
  and len = ref 0
  and started = ref false in
  let start prefix =
    Buffer.clear cur;
    Buffer.add_string cur prefix;
    len := String.length prefix;
    started := false
  in
  start first;
  List.iter
    (fun word ->
      let wl = String.length word in
      if !started && !len + 1 + wl > width then begin
        out := Buffer.contents cur :: !out;
        start rest
      end;
      if !started then begin
        Buffer.add_char cur ' ';
        incr len
      end;
      Buffer.add_string cur word;
      len := !len + wl;
      started := true)
    words;
  out := Buffer.contents cur :: !out;
  List.rev !out

let reflow ~first ~rest src =
  wrap ~first ~rest ~width:(columns ())
    (split_ws (inline (String.concat " " (List.map rtrim src))))

let render_table rows =
  let rows =
    List.filter (fun cells -> not (List.for_all separator_cell cells)) rows
  in
  let rows =
    List.map
      (List.map (fun cell -> String.trim (inline (String.trim cell))))
      rows
  in
  let ncols = List.fold_left (fun m r -> max m (List.length r)) 0 rows in
  let widths = Array.make (max ncols 1) 0 in
  List.iter
    (fun r ->
      List.iteri
        (fun i cell -> widths.(i) <- max widths.(i) (String.length cell))
        r)
    rows;
  (* A wide table shrinks to the page: the widest columns give up room
     until the row fits the terminal, never below a readable floor. *)
  let total () =
    Array.fold_left (fun m w -> m + w) 0 widths + (2 * (ncols - 1))
  in
  let avail = max 20 (columns () - 4) in
  let floor = 8 in
  while total () > avail && Array.exists (fun w -> w > floor) widths do
    let widest = ref 0 in
    Array.iteri (fun i w -> if w > widths.(!widest) then widest := i) widths;
    widths.(!widest) <- widths.(!widest) - 1
  done;
  let cell_lines i cell =
    if String.length cell <= widths.(i) then [ cell ]
    else wrap ~first:"" ~rest:"" ~width:widths.(i) (split_ws cell)
  in
  List.concat_map
    (fun r ->
      let wrapped =
        List.mapi (fun i cell -> cell_lines i cell) r
        |> List.map (fun lines -> if lines = [] then [ "" ] else lines)
      in
      let height =
        List.fold_left (fun m lines -> max m (List.length lines)) 1 wrapped
      in
      List.init height (fun line ->
          let b = Buffer.create 80 in
          Buffer.add_string b "    ";
          List.iteri
            (fun i lines ->
              if i > 0 then Buffer.add_string b "  ";
              let text =
                match List.nth_opt lines line with Some l -> l | None -> ""
              in
              Buffer.add_string b text;
              Buffer.add_string b
                (String.make (max 0 (widths.(i) - String.length text)) ' '))
            wrapped;
          rtrim (Buffer.contents b)))
    rows

let block_lines = function
  | Code code -> List.map (fun l -> if l = "" then "" else indent ^ l) code
  | Heading (level, text) ->
      if level <= 1 then [] else [ String.uppercase_ascii (inline text) ]
  | Table rows -> render_table rows
  | Bullets items ->
      List.concat_map
        (fun item -> reflow ~first:"    - " ~rest:"      " item)
        items
  | Numbered items ->
      List.concat_map
        (fun (marker, src) ->
          let first = "    " ^ marker ^ " " in
          reflow ~first ~rest:(String.make (String.length first) ' ') src)
        items
  | Para src -> reflow ~first:indent ~rest:indent src

let intersperse_blocks blocks =
  let rec go previous = function
    | [] -> []
    | (block, lines) :: rest ->
        let separator =
          match previous with None | Some (Heading _) -> [] | Some _ -> [ "" ]
        in
        separator @ lines @ go (Some block) rest
  in
  go None blocks

let render_body markdown =
  parse_blocks (lines markdown)
  |> List.map (fun block -> (block, block_lines block))
  |> List.filter (fun (_, lines) -> lines <> [])
  |> intersperse_blocks

(* ---- the overview's package table ---- *)

let cell_name cell =
  match String.index_opt cell '`' with
  | None -> None
  | Some i -> (
      match String.index_from_opt cell (i + 1) '`' with
      | None -> None
      | Some j -> Some (String.sub cell (i + 1) (j - i - 1)))

let overview_rows () =
  match find overview with
  | None -> []
  | Some markdown ->
      lines markdown
      |> List.filter_map (fun l ->
          if not (starts_with "|" l) then None
          else
            match split_row l |> List.map String.trim with
            | name_cell :: summary :: targets :: _ -> (
                match cell_name name_cell with
                | Some name when List.mem name names ->
                    Some (name, inline summary, inline targets)
                | _ -> None)
            | _ -> None)

let first_sentence markdown =
  let rec skip = function
    | [] -> []
    | l :: rest when blank l || heading l -> skip rest
    | ls -> ls
  in
  let rec until_blank acc = function
    | [] -> List.rev acc
    | l :: rest when blank l -> List.rev acc
    | l :: rest -> until_blank (l :: acc) rest
  in
  let text =
    inline (String.concat " " (until_blank [] (skip (lines markdown))))
  in
  match String.index_opt text '.' with
  | Some i -> String.trim (String.sub text 0 i)
  | None -> String.trim text

let summary_of name =
  if name = overview then "the standard library's packages and conventions"
  else
    match
      List.assoc_opt name
        (List.map (fun (n, s, _) -> (n, s)) (overview_rows ()))
    with
    | Some s -> s
    | None -> (
        match find name with Some md -> first_sentence md | None -> "")

let targets_of name =
  match List.find_opt (fun (n, _, _) -> n = name) (overview_rows ()) with
  | Some (_, _, targets) -> targets
  | None -> ""

(* ---- the pages ---- *)

let emit b line =
  Buffer.add_string b line;
  Buffer.add_char b '\n'

let header ~(title : string) ~(section : int) ~(center : string) =
  let width = columns () in
  let left = String.uppercase_ascii title ^ Printf.sprintf "(%d)" section in
  let right = left in
  let room =
    width - String.length left - String.length right - String.length center
  in
  if room < 2 then left ^ "  " ^ center
  else
    let lpad = room / 2 in
    left ^ String.make lpad ' ' ^ center ^ String.make (room - lpad) ' ' ^ right

let page ~(title : string) ~(name : string) ~(summary : string)
    ~(synopsis : string list) ~(body : string list) ~(see_also : string list) =
  let b = Buffer.create 8192 in
  emit b (header ~title ~section:3 ~center:"Emo Standard Library");
  emit b "";
  emit b "NAME";
  let name_line = indent ^ name ^ " — " in
  List.iter (emit b)
    (wrap ~first:name_line ~rest:indent ~width:(columns ()) (split_ws summary));
  emit b "";
  if synopsis <> [] then begin
    emit b "SYNOPSIS";
    List.iter (fun l -> emit b (indent ^ l)) synopsis;
    emit b ""
  end;
  emit b "DESCRIPTION";
  List.iter (emit b) body;
  emit b "";
  emit b "SEE ALSO";
  List.iter (fun l -> emit b (indent ^ l)) see_also;
  Buffer.contents b

let latest_version name =
  match Emo_pkg.Registry.versions Emo_pkg.Registry.Embedded ~name with
  | [] -> None
  | versions -> (
      match List.rev versions with
      | v :: _ -> Some (Emo_pkg.Version.to_string v)
      | [] -> None)

let package_page name markdown =
  let synopsis =
    match latest_version name with
    | Some version ->
        [
          Printf.sprintf "deps { \"%s\" = \"%s\" }" name version;
          Printf.sprintf "require \"%s\"" name;
        ]
    | None -> []
  in
  page ~title:name ~name ~summary:(summary_of name) ~synopsis
    ~body:(render_body markdown)
    ~see_also:
      [
        "emo man — list the bundled packages";
        "emo man stdlib — the standard library's overview";
      ]

let overview_page markdown =
  page ~title:overview ~name:overview ~summary:(summary_of overview)
    ~synopsis:[] ~body:(render_body markdown)
    ~see_also:
      [
        "emo man <package> — read a package's page";
        "emo man — list the bundled packages";
      ]

let list_page () =
  let width = columns () in
  let packages = List.sort String.compare names in
  let name_width =
    List.fold_left (fun m n -> max m (String.length n)) 0 packages
  in
  let entries =
    List.concat_map
      (fun name ->
        let summary = summary_of name in
        let targets = targets_of name in
        let text =
          if targets = "" then summary else summary ^ " (" ^ targets ^ ")"
        in
        let padded =
          if String.length name >= name_width then name ^ " "
          else name ^ String.make (name_width - String.length name) ' '
        in
        let first = indent ^ padded in
        wrap ~first
          ~rest:(String.make (String.length first) ' ')
          ~width (split_ws text))
      packages
  in
  let b = Buffer.create 4096 in
  emit b (header ~title:"emo-man" ~section:1 ~center:"Emo Toolchain");
  emit b "";
  emit b "NAME";
  List.iter (emit b)
    (reflow ~first:indent ~rest:indent
       [ "emo man — read the standard library's reference pages" ]);
  emit b "";
  emit b "SYNOPSIS";
  emit b (indent ^ "emo man");
  emit b (indent ^ "emo man <package>");
  emit b "";
  emit b "DESCRIPTION";
  List.iter (emit b)
    (reflow ~first:indent ~rest:indent
       [
         "The bundled standard library carries its reference inside the \
          binary: one page per package — the API it exports, every call's \
          parameters and result, and the examples. Without a package named, \
          the pages it carries are listed; with one, that package's page is \
          rendered.";
       ]);
  emit b "";
  emit b "PACKAGES";
  List.iter (emit b) entries;
  emit b "";
  emit b "SEE ALSO";
  emit b (indent ^ "emo man <package> — read a package's page");
  Buffer.contents b

let executable path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

(* The pager is used only when it can actually run: a stale or mistyped
   PAGER must not swallow the page. *)
let command_available command =
  match split_ws command with
  | [] -> false
  | word :: _ -> (
      if String.contains word '/' then executable word
      else
        match Sys.getenv_opt "PATH" with
        | None -> false
        | Some path ->
            String.split_on_char ':' path
            |> List.exists (fun dir ->
                executable
                  (Filename.concat (if dir = "" then "." else dir) word)))

let pager () =
  let set name =
    match Sys.getenv_opt name with
    | Some p when String.trim p <> "" && command_available p -> Some p
    | _ -> None
  in
  match set "MANPAGER" with Some _ as p -> p | None -> set "PAGER"

let show text =
  match pager () with
  | Some command when Unix.isatty Unix.stdout -> (
      try
        let oc = Unix.open_process_out command in
        (try output_string oc text with Sys_error _ -> ());
        try ignore (Unix.close_process_out oc) with Sys_error _ -> ()
      with _ ->
        print_string text;
        flush stdout)
  | _ ->
      print_string text;
      flush stdout

let run (arg : string option) : int =
  match arg with
  | None ->
      show (list_page ());
      0
  | Some name -> (
      match find name with
      | Some markdown when name = overview ->
          show (overview_page markdown);
          0
      | Some markdown ->
          show (package_page name markdown);
          0
      | None ->
          prerr_endline
            (Printf.sprintf "emo man: no manual entry for `%s`" name);
          prerr_endline
            "The bundled standard library carries the pages `emo man` lists.";
          65)
