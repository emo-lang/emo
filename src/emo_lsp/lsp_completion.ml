(* Completion items: keywords, built-in types and functions, declarations
   from the current file and the project index, members after a dot, and
   package names inside a `require "..."`. *)

module Ix = Lsp_index
module Resolve = Lsp_resolve

type item = {
  label : string;
  kind : int;
  detail : string;
  insert_text : string;
  documentation : string option;
  sort_text : string;
}

let make ?(documentation = None) ?(insert_text = "") ~label ~kind ~detail
    ?(sort_text = "") () =
  {
    label;
    kind;
    detail;
    insert_text = (if insert_text = "" then label else insert_text);
    documentation;
    sort_text;
  }

let keyword_items : item list =
  let kw label detail =
    make ~label ~kind:14 (* Keyword = 14 in the LSP CompletionItemKind *)
      ~detail ~sort_text:("0" ^ label) ()
  in
  [
    kw "def" "declare a function or method";
    kw "const" "immutable binding";
    kw "var" "mutable, block-scoped binding";
    kw "class" "declare a class";
    kw "interface" "declare a structural interface";
    kw "enum" "declare an enum";
    kw "emo" "declare a function group";
    kw "if" "conditional statement";
    kw "else" "else branch";
    kw "case" "pattern match";
    kw "when" "branch guard";
    kw "receive" "receive a process message";
    kw "return" "return from a function";
    kw "raise" "raise an exception";
    kw "self" "the current instance";
    kw "do" "start a process";
    kw "require" "bring a package into scope";
    kw "true" "boolean literal";
    kw "false" "boolean literal";
    make ~label:"foreign" ~kind:12
      ~detail:"foreign def name(params) Ret = \"symbol\""
      ~insert_text:"foreign def name(args) Ret = \"symbol\""
      ~sort_text:"0foreign" ();
  ]

let builtin_type_items : item list =
  let ty name detail =
    make ~label:name ~kind:7 (* Class *) ~detail ~sort_text:("1" ^ name) ()
  in
  [
    ty "Int" "integer";
    ty "Float" "floating-point number";
    ty "Bool" "true or false";
    ty "Char" "a single character";
    ty "String" "UTF-8 text";
    ty "Pid" "a process id";
    ty "Void" "no value";
    ty "Block" "a block parameter";
    ty "Array" "Array[T] — fixed-length, immutable";
    ty "Box" "Box[T] — a mutable cell";
    ty "TcpConn" "a TCP connection";
    ty "TcpListener" "a TCP listener";
    ty "UdpSocket" "a UDP socket";
    ty "Exception" "the base exception class";
  ]

let builtin_function_items : item list =
  let fn label detail =
    make ~label ~kind:3 (* Function *) ~detail ~sort_text:("1" ^ label) ()
  in
  [
    fn "println" "println(value) — write one line";
    fn "self_pid" "self_pid() -> Pid";
    fn "halt" "halt() — stop the current process";
    fn "net_connect" "net_connect(host String, port Int, timeout Float) TcpConn";
    fn "net_listen" "net_listen(host String, port Int) TcpListener";
    fn "net_resolve" "net_resolve(host String) Array[String]";
    fn "net_udp_bind" "net_udp_bind(host String, port Int) UdpSocket";
    fn "net_connect_unix" "net_connect_unix(path String, timeout Float) TcpConn";
    fn "net_listen_unix" "net_listen_unix(path String) TcpListener";
    fn "net_tls_connect"
      "net_tls_connect(host String, port Int, timeout Float) TcpConn";
    fn "net_tls_connect_insecure"
      "net_tls_connect_insecure(host String, port Int, timeout Float) TcpConn";
    fn "net_listen_tls"
      "net_listen_tls(host String, port Int, cert_path String, key_path \
       String) TcpListener";
  ]

let symbol_item (s : Ix.symbol) : item =
  let kind = s.Ix.kind in
  (* For enum members the label is `Color.red`; insert the member alone. *)
  let label =
    match s.Ix.container with
    | Some c when kind = Ix.Kind.enum_member ->
        let prefix = c ^ "." in
        if Lsp_util.starts_with ~prefix s.Ix.name then
          String.sub s.Ix.name (String.length prefix)
            (String.length s.Ix.name - String.length prefix)
        else s.Ix.name
    | _ -> s.Ix.name
  in
  make ~label ~kind ~detail:s.Ix.detail
    ~documentation:(Some (Printf.sprintf "```emo\n%s\n```" s.Ix.detail))
    ~sort_text:("2" ^ s.Ix.name) ()

(* ---- Registry packages ---------------------------------------------- *)

let is_version_dir name =
  match Emo_pkg.Version.parse name with Ok _ -> true | Error _ -> false

(* Package names published at a filesystem registry endpoint. Handles both
   flat (`http`) and scoped (`acme/json_tools`) layouts. *)
let registry_packages (endpoint : string) : string list =
  let out = ref [] in
  let rec walk rel dir depth =
    if depth > 4 then ()
    else
      let entries = Lsp_util.readdir dir in
      if List.exists is_version_dir entries then
        out := String.concat "/" rel :: !out
      else
        List.iter
          (fun entry ->
            let path = Filename.concat dir entry in
            if Lsp_util.is_directory path then
              walk (rel @ [ entry ]) path (depth + 1))
          entries
  in
  walk [] endpoint 0;
  List.sort_uniq String.compare !out

let package_items (endpoint : string) : item list =
  let latest name =
    let dir = Filename.concat endpoint name in
    match
      Lsp_util.readdir dir
      |> List.filter_map (fun e ->
          match Emo_pkg.Version.parse e with Ok v -> Some v | Error _ -> None)
      |> List.sort Emo_pkg.Version.compare
      |> List.rev
    with
    | v :: _ -> Some (Emo_pkg.Version.to_string v)
    | [] -> None
  in
  List.map
    (fun name ->
      let detail =
        match latest name with
        | Some v -> Printf.sprintf "package %s@%s" name v
        | None -> "package " ^ name
      in
      make ~label:name ~kind:9 (* Module *)
        ~detail ~insert_text:name ~sort_text:("0" ^ name) ())
    (registry_packages endpoint)

(* ---- Context detection ---------------------------------------------- *)

(* True when [offset] sits inside the string of a `require "..."`. *)
let in_require_string (text : string) (offset : int) : bool =
  let line_start =
    let rec back i =
      if i <= 0 then 0 else if text.[i - 1] = '\n' then i else back (i - 1)
    in
    back (min offset (String.length text))
  in
  let prefix = String.sub text line_start (offset - line_start) in
  let trimmed = String.trim prefix in
  Lsp_util.starts_with ~prefix:"require" trimmed && String.contains trimmed '"'

(* ---- Public entry points -------------------------------------------- *)

let global_items ~(ix : Ix.t) ~(file : string) : item list =
  keyword_items @ builtin_type_items @ builtin_function_items
  @ List.map symbol_item (Ix.symbols_in_file ix file)

let member_items (ix : Ix.t) (items : Emo_ast.item list) (file : string)
    (offset : int) (segments : string list) : item list =
  let members = Resolve.resolve_receiver ix items file offset segments in
  let container = Resolve.resolve_container ix items ~file offset segments in
  let new_item =
    match container with
    | Some s when s.Ix.kind = Ix.Kind.class_ ->
        [
          make ~label:"new" ~kind:Ix.Kind.constructor
            ~detail:("new " ^ s.Ix.name) ~insert_text:"new()" ~sort_text:"0new"
            ();
        ]
    | _ -> []
  in
  new_item
  @ List.map symbol_item
      (List.filter
         (fun (s : Ix.symbol) -> s.Ix.kind <> Ix.Kind.constructor)
         members)

(* Items for a completion request selected by the cursor context. *)
let items_for ~(ix : Ix.t) ~(file : string) ~(items : Emo_ast.item list)
    ~(offset : int) ~(text : string) ~(registry : string option) : item list =
  if in_require_string text offset then
    match registry with Some endpoint -> package_items endpoint | None -> []
  else
    match Resolve.receiver_segments text offset with
    | Some segments -> member_items ix items file offset segments
    | None -> global_items ~ix ~file

(* Character offset at which the current completion token starts, so the
   client can replace exactly that range. *)
let replacement_start (text : string) (offset : int) : int =
  let i = ref (min offset (String.length text)) in
  let is_word c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '_'
  in
  while !i > 0 && is_word text.[!i - 1] do
    decr i
  done;
  !i
