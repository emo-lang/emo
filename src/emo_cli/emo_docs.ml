(* The language's introduction pages. The pages ride the binary as
   generated data (docs_data.ml), the same route the manual's pages take
   (emo_man), so an installed emo answers with nothing beside it. The
   docs under docs/intro/ stay the source of truth.

   Unlike `emo man`, which renders its pages for a terminal, `emo docs`
   serves the markdown verbatim: the pages are written for AI harnesses,
   which read markdown and pipe, so there is no pager and no layout. *)

let names : string list = List.map fst Docs_data.pages
let find (name : string) : string option = List.assoc_opt name Docs_data.pages

(* The page's first `# ` heading is the listing's description; a page
   without one is listed by name alone. *)
let title_of (markdown : string) : string =
  let rec go = function
    | [] -> ""
    | l :: rest ->
        if String.length l >= 2 && l.[0] = '#' && l.[1] = ' ' then
          String.trim (String.sub l 2 (String.length l - 2))
        else go rest
  in
  go (String.split_on_char '\n' markdown)

let list_page () : string =
  let width = 24 in
  let b = Buffer.create 1024 in
  Buffer.add_string b "emo docs — the language's introduction pages\n\n";
  List.iter
    (fun name ->
      let title = match find name with Some md -> title_of md | None -> "" in
      let padded =
        if String.length name >= width then name ^ " "
        else name ^ String.make (width - String.length name) ' '
      in
      Buffer.add_string b ("  " ^ padded);
      if title <> "" then Buffer.add_string b title;
      Buffer.add_char b '\n')
    names;
  Buffer.contents b

let run (topic : string option) : int =
  match topic with
  | None ->
      print_string (list_page ());
      flush stdout;
      0
  | Some name -> (
      match find name with
      | Some markdown ->
          print_string markdown;
          flush stdout;
          0
      | None ->
          prerr_endline (Printf.sprintf "emo docs: no page for `%s`" name);
          prerr_endline
            (Printf.sprintf "The pages it carries: %s"
               (String.concat ", " names));
          65)
