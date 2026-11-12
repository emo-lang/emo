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
    kw "for" "three-clause loop";
    kw "while" "condition-only loop";
    kw "break" "leave the nearest loop";
    kw "continue" "skip to the next iteration";
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

(* The `Syntax` blurb, shared by the completion list and the hover
   fallback below. *)
let syntax_type_detail : string =
  "the compile-time syntax tree — a macro's parameters and quotes"

let builtin_type_items : item list =
  let ty name detail =
    make ~label:name ~kind:7 (* Class *) ~detail ~sort_text:("1" ^ name) ()
  in
  [
    ty "Int64" "64-bit integer";
    ty "Float64" "floating-point number";
    ty "Bool" "true or false";
    ty "Char" "a single character";
    ty "String" "UTF-8 text";
    ty "Pid" "a process id";
    ty "Void" "no value";
    ty "Block" "a block parameter";
    ty "Array" "Array[T] — fixed-length, immutable";
    ty "Box" "Box[T] — a mutable cell";
    ty "List" "List[T] — a mutable double-ended queue";
    ty "ArrayBuilder"
      "ArrayBuilder[T] — a mutable buffer that grows into an Array[T]";
    ty "Bytes" "Bytes — a fixed-size mutable byte buffer";
    ty "Atomic" "Atomic[T] — a cell read and written atomically";
    ty "TcpConn" "a TCP connection";
    ty "TcpListener" "a TCP listener";
    ty "UdpSocket" "a UDP socket";
    ty "Exception" "the base exception class";
    ty "R" "the built-in result enum — (R.ok, value) beside (R.error, reason)";
    ty "Syntax" syntax_type_detail;
  ]

let builtin_function_items : item list =
  let fn label detail =
    make ~label ~kind:3 (* Function *) ~detail ~sort_text:("1" ^ label) ()
  in
  [
    fn "println" "println(value) — write one line";
    fn "printf" "printf(format String, data Array) — C-style formatting";
    fn "self_pid" "self_pid() -> Pid";
    fn "halt" "halt() — stop the current process";
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

(* The compile-time surface of `Syntax` — the readers, constructors, and
   statement wrappers a macro body builds its splice from, the same list
   design/macros.md documents and the evaluator implements. `Syntax` is
   the checker's reserved type, not a declaration any index carries, so
   member completion after `Syntax.` answers from this table. *)
let syntax_member_items : item list =
  let m label detail =
    make ~label ~kind:3 (* Function *) ~detail ~sort_text:("1" ^ label) ()
  in
  [
    m "name" "name(f) -> String — the def's name";
    m "params" "params(f) -> Array[Syntax] — the parameter trees";
    m "param_name" "param_name(p) -> String — a parameter's name";
    m "result" "result(f) -> Syntax — the result type tree";
    m "fields" "fields(cls) -> Array[Syntax] — the class's field trees";
    m "field_name" "field_name(fld) -> String — a field's name";
    m "rename" "rename(f, new_name) -> Syntax — the def tree, renamed";
    m "new_def" "new_def(name, params, result, body) -> Syntax — a new def";
    m "new_param" "new_param(name, ty) -> Syntax — a new parameter tree";
    m "seq" "seq(a, b) -> Syntax — a sequence of trees";
    m "ident" "ident(s) -> Syntax — an identifier expression";
    m "named_type" "named_type(s) -> Syntax — a named type tree";
    m "lit_string" "lit_string(s) -> Syntax — a string literal";
    m "interp" "interp(parts) -> Syntax — an interpolated string";
    m "lit_int" "lit_int(n) -> Syntax — an integer literal";
    m "lit_bool" "lit_bool(b) -> Syntax — a boolean literal";
    m "lit_float" "lit_float(f) -> Syntax — a float literal";
    m "call" "call(f, args) -> Syntax — a call expression";
    m "call_stmt" "call_stmt(f, args) -> Syntax — a call statement";
    m "expr_stmt" "expr_stmt(e) -> Syntax — an expression statement";
    m "const_stmt" "const_stmt(name, e) -> Syntax — a const statement";
    m "return_stmt" "return_stmt(e) -> Syntax — a return statement";
    m "gensym" "gensym(base) -> String — a fresh, collision-free name";
    m "empty_map" "empty_map() -> Syntax — an empty Map literal";
    m "const_item" "const_item(name, e) -> Syntax — a top-level const item";
    m "self_expr" "self_expr() -> Syntax — the self expression";
    m "member" "member(obj, name) -> Syntax — a member read";
    m "with_methods"
      "with_methods(cls, methods) -> Syntax — the class tree, methods attached";
    m "bin_and" "bin_and(a, b) -> Syntax — a && expression";
    m "bin_eq" "bin_eq(a, b) -> Syntax — an == expression";
  ]

let syntax_member_detail (label : string) : string option =
  List.find_map
    (fun (i : item) -> if i.label = label then Some i.detail else None)
    syntax_member_items

let is_word_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'

(* The hover for the reserved surface: a cursor over `Syntax` itself
   answers the type's blurb, a cursor over `Syntax.member` the member's
   signature — `None` for any other word, which leaves the index-based
   hover in charge. *)
let syntax_hover_at (text : string) (offset : int) : string option =
  let n = String.length text in
  let left = ref (min offset n) in
  while !left > 0 && is_word_char text.[!left - 1] do
    decr left
  done;
  let word_start = !left in
  let right = ref (min offset n) in
  while !right < n && is_word_char text.[!right] do
    incr right
  done;
  if word_start = !right then None
  else
    let word = String.sub text word_start (!right - word_start) in
    if word = "Syntax" then
      Some
        (Printf.sprintf
           "```emo\n\
            Syntax\n\
            ```\n\n\
            %s — the compile-time macro surface (design/macros.md)"
           syntax_type_detail)
    else if
      word_start >= 7
      && text.[word_start - 1] = '.'
      && String.sub text (word_start - 7) 6 = "Syntax"
      && (word_start = 7 || not (is_word_char text.[word_start - 8]))
    then
      match syntax_member_detail word with
      | None -> None
      | Some detail ->
          Some
            (Printf.sprintf
               "```emo\n\
                Syntax.%s\n\
                ```\n\n\
                the compile-time macro surface (design/macros.md)"
               detail)
    else None

(* ---- Registry packages ---------------------------------------------- *)

let is_version_dir name =
  match Emo_pkg.Version.parse name with Ok _ -> true | Error _ -> false

(* Package names published at a filesystem registry endpoint. Handles both
   flat (`http`) and scoped (`acme/json_tools`) layouts. An HTTP(S) endpoint
   contributes nothing: completion must never block on the network — the
   editor falls back to what the local tree and lockfile already name. *)
let registry_packages (endpoint : string) : string list =
  if
    String.starts_with ~prefix:"http://" endpoint
    || String.starts_with ~prefix:"https://" endpoint
  then []
  else begin
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
  end

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

(* The packages of the standard library bundled in the compiler binary,
   each with its newest version — what a require string offers when no
   filesystem registry is configured, the names a build resolves with
   nothing beside it. *)
let stdlib_package_items () : item list =
  List.map
    (fun name ->
      let detail =
        match
          List.rev (Emo_pkg.Registry.versions Emo_pkg.Registry.Embedded ~name)
        with
        | v :: _ ->
            Printf.sprintf "package %s@%s" name (Emo_pkg.Version.to_string v)
        | [] -> "package " ^ name
      in
      make ~label:name ~kind:9 (* Module *)
        ~detail ~insert_text:name ~sort_text:("0" ^ name) ())
    (Emo_pkg.Registry.embedded_names ())

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
  if segments = [ "Syntax" ] then syntax_member_items
  else
    let members = Resolve.resolve_receiver ix items file offset segments in
    let container = Resolve.resolve_container ix items ~file offset segments in
    let new_item =
      match container with
      | Some s when s.Ix.kind = Ix.Kind.class_ ->
          [
            make ~label:"new" ~kind:Ix.Kind.constructor
              ~detail:("new " ^ s.Ix.name) ~insert_text:"new()"
              ~sort_text:"0new" ();
          ]
      | _ -> []
    in
    new_item
    @ List.map symbol_item
        (List.filter
           (fun (s : Ix.symbol) -> s.Ix.kind <> Ix.Kind.constructor)
           members)

(* Items for a completion request selected by the cursor context. A
   require string offers package names the way a build routes them: a
   filesystem registry serves every name it publishes; with none — or an
   HTTP endpoint, which the editor never waits on — the bundled standard
   library's names. *)
let items_for ~(ix : Ix.t) ~(file : string) ~(items : Emo_ast.item list)
    ~(offset : int) ~(text : string) ~(registry : string option) : item list =
  if in_require_string text offset then
    match registry with
    | Some endpoint when not (Ix.is_http_endpoint endpoint) ->
        package_items endpoint
    | _ -> stdlib_package_items ()
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
