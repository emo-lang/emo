(* The Emo language server.

   Speaks LSP over stdio and serves:
   - diagnostics (lex, parse, check, and manifest/require pairing)
   - completion (keywords, built-ins, declarations, members, packages)
   - hover and go-to-definition
   - document and workspace symbols
   - semantic tokens
   - code actions (adding a missing dependency to package.emo)
   - package commands and a package-info request for the client's view *)

module Ast = Emo_ast
module Ix = Lsp_index
module Resolve = Lsp_resolve
module Completion = Lsp_completion
module Protocol = Lsp_protocol
module Span = Emo_support.Span
module Diagnostic = Emo_support.Diagnostic

type state = {
  oc : out_channel;
  mutable root : string option;
  mutable registry : string option;
  mutable emo_path : string;
  mutable shutdown : bool;
}

(* ---- Position helpers ----------------------------------------------- *)

let pos line character =
  `Assoc [ ("line", `Int line); ("character", `Int character) ]

let range_of_span text starts (span : Span.t) : Yojson.Safe.t =
  let sl, sc = Lsp_util.offset_to_position text starts span.Span.start in
  let el, ec = Lsp_util.offset_to_position text starts span.Span.stop in
  `Assoc [ ("start", pos sl sc); ("end", pos el ec) ]

let range_of_span2 text starts (a : Span.t) (b : Span.t) : Yojson.Safe.t =
  let sl, sc = Lsp_util.offset_to_position text starts a.Span.start in
  let el, ec = Lsp_util.offset_to_position text starts b.Span.stop in
  `Assoc [ ("start", pos sl sc); ("end", pos el ec) ]

(* ---- Loading documents ---------------------------------------------- *)

let path_of_uri (uri : string) : string option = Lsp_util.uri_to_path uri

(* The text to serve for a request: the open buffer, else the file. *)
let text_and_path (uri : string) : (string * string) option =
  match Lsp_document.find uri with
  | Some doc -> Some (doc.text, doc.path)
  | None -> (
      match path_of_uri uri with
      | Some path -> (
          match Lsp_util.read_file path with
          | Some text -> Some (text, path)
          | None -> None)
      | None -> None)

let parse (file : string) (text : string) : Ast.item list * Diagnostic.t list =
  match Emo_parser.parse_program_with_diagnostics ~file ~source:text with
  | items, diagnostics -> (items, diagnostics)
  | exception Emo_lexer.Error d -> ([], [ d ])

(* ---- Project root and module path ----------------------------------- *)

let root_for_file (state : state) (file : string) : string =
  Ix.find_root ?fallback:state.root file

let module_path_of_file (root : string) (file : string) : string list =
  let root = Lsp_util.normalize_path root in
  let file = Lsp_util.normalize_path file in
  if not (Lsp_util.is_within ~dir:root file) then []
  else
    let rel =
      if file = root then ""
      else
        let plen = String.length root in
        String.sub file (plen + 1) (String.length file - plen - 1)
    in
    if rel = "" then []
    else
      let no_ext = Filename.remove_extension rel in
      String.split_on_char '/' no_ext

let index_for_file (state : state) (file : string) : Ix.t =
  Ix.get ?registry:state.registry (root_for_file state file)

(* ---- Diagnostics ---------------------------------------------------- *)

let diagnostic_to_lsp (text : string) (starts : int array) (d : Diagnostic.t) :
    Yojson.Safe.t =
  let message =
    match d.Diagnostic.hint with
    | Some h -> d.Diagnostic.message ^ "\n\nhint: " ^ h
    | None -> d.Diagnostic.message
  in
  `Assoc
    [
      ("range", range_of_span text starts d.Diagnostic.span);
      ( "severity",
        `Int (match d.Diagnostic.severity with Error -> 1 | Warning -> 2) );
      ( "code",
        match d.Diagnostic.code with Some c -> `String c | None -> `Null );
      ("source", `String "emo");
      ("message", `String message);
    ]

(* Requires listed in a file, with their spans. *)
let requires_of (items : Ast.item list) : (string * Span.t) list =
  List.filter_map
    (fun (item : Ast.item) ->
      match item.Ast.item_desc with
      | Ast.Item_require name -> Some (name, item.Ast.item_span)
      | _ -> None)
    items

let manifest_deps (root : string) : (string * Emo_pkg.Version.t) list =
  let path = Filename.concat root "package.emo" in
  match Lsp_util.read_file path with
  | None -> []
  | Some source -> (
      match Emo_pkg.parse_manifest ~file:path ~source with
      | m -> m.Emo_pkg.deps
      | exception Emo_pkg.Manifest_error _ -> [])

(* A require with no manifest entry is a compile error in the compiler
   (E5006); surface it here as a quick-fixable diagnostic. *)
let missing_dep_diagnostics (root : string) (items : Ast.item list) :
    Diagnostic.t list =
  if not (Lsp_util.file_exists (Filename.concat root "package.emo")) then []
  else
    let deps = manifest_deps root in
    List.filter_map
      (fun (name, span) ->
        if List.mem_assoc name deps then None
        else
          Some
            {
              Diagnostic.severity = Error;
              code = Some "E5006";
              message =
                Printf.sprintf
                  "`require \"%s\"` is not listed in package.emo deps" name;
              span;
              hint = Some "add the package to the manifest's deps block";
            })
      (requires_of items)

let compute_diagnostics (state : state) (file : string) (text : string) :
    Diagnostic.t list =
  let items, parse_diags = parse file text in
  match parse_diags with
  | _ :: _ -> parse_diags
  | [] ->
      let root = root_for_file state file in
      let ix = Ix.get ?registry:state.registry root in
      let modules = List.map fst ix.modules in
      let current = module_path_of_file root file in
      let check_diags, _, _ = Emo_check.check_module ~modules ~current items in
      check_diags @ missing_dep_diagnostics root items

let publish_diagnostics (state : state) (uri : string) (file : string)
    (text : string) : unit =
  let starts = Lsp_util.line_starts text in
  let diagnostics =
    List.map
      (diagnostic_to_lsp text starts)
      (compute_diagnostics state file text)
  in
  Protocol.notify state.oc ~method_:"textDocument/publishDiagnostics"
    (`Assoc [ ("uri", `String uri); ("diagnostics", `List diagnostics) ])

(* ---- Semantic tokens ------------------------------------------------ *)

let semantic_token_types =
  [|
    "namespace";
    "type";
    "class";
    "enum";
    "interface";
    "struct";
    "typeParameter";
    "parameter";
    "variable";
    "property";
    "enumMember";
    "event";
    "function";
    "method";
    "macro";
    "keyword";
    "modifier";
    "comment";
    "string";
    "number";
    "regexp";
    "operator";
  |]

let semantic_token_modifiers =
  [|
    "declaration";
    "definition";
    "readonly";
    "static";
    "deprecated";
    "abstract";
    "async";
    "modification";
    "documentation";
    "defaultLibrary";
  |]

let token_type_of ~(ix : Ix.t) ~(file : string)
    ~(decl_offsets : (int, unit) Hashtbl.t) (tok : Emo_lexer.Token.t) :
    (int * int) option =
  let open Emo_lexer.Token in
  let declared name =
    (* Prefer a class/enum/interface/group declaration to give types a
       distinct colour. *)
    match
      List.filter
        (fun (s : Ix.symbol) -> s.Ix.file = file)
        (Ix.symbols_named ix name)
    with
    | s :: _ -> Some s
    | [] -> None
  in
  match tok.kind with
  | Keyword _ | True | False -> Some (15, 0)
  | Int64 _ | Byte _ | Float _ -> Some (19, 0)
  | Char _ | String_chunk _ | String_end | Interp_open | Interp_close ->
      Some (18, 0)
  | Upper_ident name -> (
      let mods =
        if Hashtbl.mem decl_offsets tok.span.Span.start then 1 else 0
      in
      match declared name with
      | Some s when s.Ix.kind = Ix.Kind.enum -> Some (3, mods)
      | Some s when s.Ix.kind = Ix.Kind.interface -> Some (4, mods)
      | Some s when s.Ix.kind = Ix.Kind.class_ -> Some (2, mods)
      | _ -> Some (1, mods))
  | Lower_ident name -> (
      let mods =
        if Hashtbl.mem decl_offsets tok.span.Span.start then 1 else 0
      in
      match declared name with
      | Some s when s.Ix.local -> Some (7, mods)
      | Some s when s.Ix.kind = Ix.Kind.namespace -> Some (0, mods)
      | Some s when s.Ix.kind = Ix.Kind.function_ -> Some (12, mods)
      | Some s when s.Ix.kind = Ix.Kind.method_ -> Some (13, mods)
      | Some s when s.Ix.kind = Ix.Kind.constant -> Some (8, mods)
      | Some s when s.Ix.kind = Ix.Kind.variable -> Some (8, mods)
      | _ -> Some (8, mods))
  | Op _ -> Some (21, 0)
  | Eof -> None

let semantic_tokens (state : state) (file : string) (text : string) :
    Yojson.Safe.t =
  let starts = Lsp_util.line_starts text in
  let ix = index_for_file state file in
  let items, _ = parse file text in
  let decl_offsets : (int, unit) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun (s : Ix.symbol) ->
      if s.Ix.file = file then
        Hashtbl.replace decl_offsets s.Ix.span.Span.start ())
    (Ix.symbols_in_file ix file);
  List.iter
    (fun (s : Ix.symbol) ->
      Hashtbl.replace decl_offsets s.Ix.span.Span.start ())
    (Ix.collect_items ~file ~module_path:[] items);
  let toks =
    try Emo_lexer.Stream.to_list (Emo_lexer.lex ~file ~source:text)
    with Emo_lexer.Error _ -> []
  in
  let data = ref [] in
  let prev_line = ref 0 and prev_char = ref 0 in
  List.iter
    (fun (tok : Emo_lexer.Token.t) ->
      match token_type_of ~ix ~file ~decl_offsets tok with
      | None -> ()
      | Some (ty, mods) ->
          let sl, sc =
            Lsp_util.offset_to_position text starts tok.span.Span.start
          in
          let el, ec =
            Lsp_util.offset_to_position text starts tok.span.Span.stop
          in
          let length = if el = sl then ec - sc else ec in
          let length = max 0 length in
          let delta_line = sl - !prev_line in
          let delta_char = if delta_line = 0 then sc - !prev_char else sc in
          data :=
            !data
            @ [
                `Int delta_line;
                `Int delta_char;
                `Int length;
                `Int ty;
                `Int mods;
              ];
          prev_line := sl;
          prev_char := sc)
    toks;
  `Assoc [ ("data", `List !data) ]

(* ---- Symbols -------------------------------------------------------- *)

let symbol_kind_of_lsp (s : Ix.symbol) = s.Ix.kind

let location_of_symbol (s : Ix.symbol) : Yojson.Safe.t =
  let file = s.Ix.file in
  match Lsp_util.read_file file with
  | None ->
      `Assoc
        [
          ("uri", `String (Lsp_util.path_to_uri file));
          ("range", `Assoc [ ("start", pos 0 0); ("end", pos 0 0) ]);
        ]
  | Some text ->
      let starts = Lsp_util.line_starts text in
      `Assoc
        [
          ("uri", `String (Lsp_util.path_to_uri file));
          ("range", range_of_span text starts s.Ix.span);
        ]

let document_symbols_of_items (text : string) (starts : int array)
    (items : Ast.item list) : Yojson.Safe.t list =
  let node ~name ~detail ~kind ~span ~children =
    `Assoc
      [
        ("name", `String name);
        ("detail", `String detail);
        ("kind", `Int kind);
        ("range", range_of_span text starts span);
        ("selectionRange", range_of_span text starts span);
        ("children", `List children);
      ]
  in
  List.filter_map
    (fun (item : Ast.item) ->
      match item.Ast.item_desc with
      | Ast.Item_def d ->
          Some
            (node ~name:d.Ast.def_name ~detail:(Ix.def_signature d)
               ~kind:Ix.Kind.function_ ~span:d.Ast.def_span ~children:[])
      | Ast.Item_foreign f ->
          Some
            (node ~name:f.Ast.foreign_name ~detail:(Ix.foreign_signature f)
               ~kind:Ix.Kind.function_ ~span:f.Ast.foreign_span ~children:[])
      | Ast.Item_class c ->
          let method_node (m : Ast.fun_def) =
            node ~name:m.Ast.def_name ~detail:(Ix.def_signature m)
              ~kind:Ix.Kind.method_ ~span:m.Ast.def_span ~children:[]
          in
          let field_node (f : Ast.field) =
            node ~name:f.Ast.field_name
              ~detail:("field " ^ f.Ast.field_name)
              ~kind:Ix.Kind.field ~span:f.Ast.field_span ~children:[]
          in
          let init_node =
            match c.Ast.class_init with
            | Some i ->
                [
                  node ~name:"init"
                    ~detail:
                      ("def init(" ^ Ix.params_to_string i.Ast.def_params ^ ")")
                    ~kind:Ix.Kind.constructor ~span:i.Ast.def_span ~children:[];
                ]
            | None -> []
          in
          let children =
            init_node
            @ List.map method_node c.Ast.class_methods
            @ List.map field_node c.Ast.class_fields
          in
          Some
            (node ~name:c.Ast.class_name
               ~detail:("class " ^ c.Ast.class_name)
               ~kind:Ix.Kind.class_ ~span:c.Ast.class_span ~children)
      | Ast.Item_interface i ->
          let children =
            List.map
              (fun (m : Ast.method_sig) ->
                node ~name:m.Ast.sig_name
                  ~detail:
                    (Printf.sprintf "def %s(%s) %s" m.Ast.sig_name
                       (Ix.params_to_string m.Ast.sig_params)
                       (Ix.type_decl_to_string m.Ast.sig_return))
                  ~kind:Ix.Kind.method_ ~span:m.Ast.sig_span ~children:[])
              i.Ast.interface_methods
          in
          Some
            (node ~name:i.Ast.interface_name
               ~detail:("interface " ^ i.Ast.interface_name)
               ~kind:Ix.Kind.interface ~span:i.Ast.interface_span ~children)
      | Ast.Item_enum e ->
          let children =
            List.map
              (fun (m : Ast.member) ->
                node ~name:m.Ast.member_name
                  ~detail:(e.Ast.enum_name ^ "." ^ m.Ast.member_name)
                  ~kind:Ix.Kind.enum_member ~span:m.Ast.member_span ~children:[])
              e.Ast.enum_members
          in
          Some
            (node ~name:e.Ast.enum_name
               ~detail:("enum " ^ e.Ast.enum_name)
               ~kind:Ix.Kind.enum ~span:e.Ast.enum_span ~children)
      | Ast.Item_emo_group g ->
          let children =
            List.map
              (fun d ->
                node ~name:d.Ast.def_name ~detail:(Ix.def_signature d)
                  ~kind:Ix.Kind.function_ ~span:d.Ast.def_span ~children:[])
              g.Ast.group_defs
            @ List.map
                (fun (span, name, init) ->
                  node ~name
                    ~detail:(Printf.sprintf "const %s" name)
                    ~kind:Ix.Kind.constant ~span ~children:[])
                g.Ast.group_consts
          in
          Some
            (node ~name:g.Ast.group_name
               ~detail:("emo " ^ g.Ast.group_name)
               ~kind:Ix.Kind.namespace ~span:g.Ast.group_span ~children)
      | Ast.Item_stmt
          { Ast.stmt_desc = Ast.Binding { mutable_; name; _ }; stmt_span } ->
          Some
            (node ~name
               ~detail:(if mutable_ then "var" else "const")
               ~kind:(if mutable_ then Ix.Kind.variable else Ix.Kind.constant)
               ~span:stmt_span ~children:[])
      | Ast.Item_stmt _ | Ast.Item_require _ -> None)
    items

(* ---- Running the CLI (package commands) ----------------------------- *)

let read_channel ic =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let n = input ic chunk 0 4096 in
    if n > 0 then (
      Buffer.add_subbytes buf chunk 0 n;
      loop ())
  in
  (try loop () with End_of_file -> ());
  Buffer.contents buf

let run_emo (state : state) ~(cwd : string) (args : string list) : int * string
    =
  let cmd =
    Printf.sprintf "cd %s && exec %s %s 2>&1" (Filename.quote cwd)
      (Filename.quote state.emo_path)
      (String.concat " " (List.map Filename.quote args))
  in
  try
    let ic = Unix.open_process_in cmd in
    let output = read_channel ic in
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> (code, output)
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> (128 + n, output)
  with e -> (127, Printexc.to_string e)

(* ---- Package info --------------------------------------------------- *)

let package_info (state : state) (root : string) : Yojson.Safe.t =
  let manifest_path = Filename.concat root "package.emo" in
  let manifest =
    match Lsp_util.read_file manifest_path with
    | None -> None
    | Some source -> (
        match Emo_pkg.parse_manifest ~file:manifest_path ~source with
        | m -> Some m
        | exception Emo_pkg.Manifest_error _ -> None)
  in
  let lock =
    match
      Emo_pkg.Lockfile.read (Filename.concat root Emo_pkg.Lockfile.filename)
    with
    | Ok entries -> entries
    | Error _ -> []
  in
  let registry =
    Option.map (fun r -> Emo_pkg.Registry.Fs_dir r) state.registry
  in
  let deps =
    match manifest with
    | None -> []
    | Some m ->
        List.map
          (fun (name, version) ->
            let locked =
              match
                List.find_opt (fun e -> e.Emo_pkg.Lockfile.dep = name) lock
              with
              | Some e ->
                  `Assoc
                    [
                      ( "version",
                        `String
                          (Emo_pkg.Version.to_string e.Emo_pkg.Lockfile.version)
                      );
                      ("checksum", `String e.Emo_pkg.Lockfile.checksum);
                    ]
              | None -> `Null
            in
            let available =
              match registry with
              | Some reg ->
                  `List
                    (List.map
                       (fun v -> `String (Emo_pkg.Version.to_string v))
                       (List.rev (Emo_pkg.Registry.versions reg ~name)))
              | None -> `List []
            in
            `Assoc
              [
                ("name", `String name);
                ("required", `String (Emo_pkg.Version.to_string version));
                ("locked", locked);
                ("available", available);
              ])
          m.Emo_pkg.deps
  in
  `Assoc
    [
      ("root", `String root);
      ( "manifest",
        match manifest with
        | None -> `Null
        | Some m ->
            `Assoc
              [
                ("path", `String manifest_path);
                ("name", `String m.Emo_pkg.name);
                ( "version",
                  `String (Emo_pkg.Version.to_string m.Emo_pkg.version) );
                ( "targets",
                  `List (List.map (fun t -> `String t) m.Emo_pkg.targets) );
                ("deps", `List deps);
              ] );
      ( "registry",
        match state.registry with Some r -> `String r | None -> `Null );
    ]

(* ---- Code actions: add a missing dependency ------------------------- *)

(* Find [needle] in [hay], returning its start offset. *)
let find_substring (hay : string) (needle : string) : int option =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then None
    else if String.sub hay i m = needle then Some i
    else go (i + 1)
  in
  if m = 0 then Some 0 else go 0

(* Where to insert a dependency line, and what text to insert. Prefers
   the `deps {` block; falls back to a fresh block before the closing
   brace. *)
let rec dep_insertion (source : string) (name : string) (version : string) :
    int * string =
  match find_substring source "deps" with
  | Some i -> (
      match String.index_from_opt source i '{' with
      | Some brace ->
          (brace + 1, Printf.sprintf "\n    %s = \"%s\"" name version)
      | None -> dep_block_insertion source name version)
  | None -> dep_block_insertion source name version

and dep_block_insertion (source : string) (name : string) (version : string) :
    int * string =
  let last_brace = String.rindex_opt source '}' in
  let offset =
    match last_brace with Some i -> i | None -> String.length source
  in
  (offset, Printf.sprintf "\n  deps {\n    %s = \"%s\"\n  }\n" name version)

let dep_edit (state : state) (root : string) (name : string) :
    Yojson.Safe.t option =
  let manifest_path = Filename.concat root "package.emo" in
  match Lsp_util.read_file manifest_path with
  | None -> None
  | Some source ->
      let version =
        match state.registry with
        | Some endpoint -> (
            let reg = Emo_pkg.Registry.Fs_dir endpoint in
            match List.rev (Emo_pkg.Registry.versions reg ~name) with
            | v :: _ -> Some (Emo_pkg.Version.to_string v)
            | [] -> None)
        | None -> None
      in
      let version = Option.value ~default:"0.1.0" version in
      let offset, insert = dep_insertion source name version in
      let starts = Lsp_util.line_starts source in
      let line, character = Lsp_util.offset_to_position source starts offset in
      Some
        (`Assoc
           [
             ( "changes",
               `Assoc
                 [
                   ( Lsp_util.path_to_uri manifest_path,
                     `List
                       [
                         `Assoc
                           [
                             ( "range",
                               `Assoc
                                 [
                                   ("start", pos line character);
                                   ("end", pos line character);
                                 ] );
                             ("newText", `String insert);
                           ];
                       ] );
                 ] );
           ])

let code_actions (state : state) (file : string) (text : string) :
    Yojson.Safe.t list =
  let _ = text in
  let root = root_for_file state file in
  if not (Lsp_util.file_exists (Filename.concat root "package.emo")) then []
  else
    let items, _ = parse file text in
    let deps = manifest_deps root in
    List.filter_map
      (fun (name, _) ->
        if List.mem_assoc name deps then None
        else
          match dep_edit state root name with
          | None -> None
          | Some edit ->
              Some
                (`Assoc
                   [
                     ( "title",
                       `String
                         (Printf.sprintf "Add `%s` to package.emo deps" name) );
                     ("kind", `String "quickfix");
                     ("edit", edit);
                   ]))
      (requires_of items)

(* ---- Capabilities --------------------------------------------------- *)

let commands =
  [
    "emo.deps.resolve";
    "emo.deps.update";
    "emo.deps.list";
    "emo.package.init";
    "emo.check";
    "emo.build";
    "emo.run";
  ]

let capabilities () : Yojson.Safe.t =
  `Assoc
    [
      ( "textDocumentSync",
        `Assoc
          [
            ("openClose", `Bool true); ("change", `Int 1); ("save", `Bool true);
          ] );
      ( "completionProvider",
        `Assoc
          [
            ("triggerCharacters", `List [ `String "."; `String "\"" ]);
            ("resolveProvider", `Bool false);
          ] );
      ("hoverProvider", `Bool true);
      ("definitionProvider", `Bool true);
      ("documentSymbolProvider", `Bool true);
      ("workspaceSymbolProvider", `Bool true);
      ( "semanticTokensProvider",
        `Assoc
          [
            ( "legend",
              `Assoc
                [
                  ( "tokenTypes",
                    `List
                      (Array.to_list
                         (Array.map (fun s -> `String s) semantic_token_types))
                  );
                  ( "tokenModifiers",
                    `List
                      (Array.to_list
                         (Array.map
                            (fun s -> `String s)
                            semantic_token_modifiers)) );
                ] );
            ("full", `Bool true);
            ("range", `Bool false);
          ] );
      ("codeActionProvider", `Bool true);
      ( "executeCommandProvider",
        `Assoc [ ("commands", `List (List.map (fun c -> `String c) commands)) ]
      );
      ( "workspace",
        `Assoc [ ("workspaceFolders", `Assoc [ ("supported", `Bool true) ]) ] );
    ]

(* The LSP InitializeResult wraps the capabilities; returning them bare is
   a protocol violation clients reject during initialization. *)
let initialize_result () : Yojson.Safe.t =
  `Assoc
    [
      ("capabilities", capabilities ());
      ("serverInfo", `Assoc [ ("name", `String "emo-lsp") ]);
    ]

(* ---- Request handlers ----------------------------------------------- *)

let completion_item_to_json (i : Completion.item) : Yojson.Safe.t =
  `Assoc
    ([
       ("label", `String i.Completion.label);
       ("kind", `Int i.Completion.kind);
       ("detail", `String i.Completion.detail);
       ("sortText", `String i.Completion.sort_text);
     ]
    @ (if i.Completion.insert_text = i.Completion.label then []
       else [ ("insertText", `String i.Completion.insert_text) ])
    @
    match i.Completion.documentation with
    | Some doc ->
        [
          ( "documentation",
            `Assoc [ ("kind", `String "markdown"); ("value", `String doc) ] );
        ]
    | None -> [])

let handle_completion (state : state) (params : Yojson.Safe.t) : Yojson.Safe.t =
  let uri =
    Lsp_util.string_field "uri" (Yojson.Safe.Util.member "textDocument" params)
  in
  let position = Yojson.Safe.Util.member "position" params in
  let line = Lsp_util.int_field "line" position in
  let character = Lsp_util.int_field "character" position in
  match text_and_path uri with
  | None -> `List []
  | Some (text, file) ->
      let starts = Lsp_util.line_starts text in
      let offset = Lsp_util.position_to_offset text starts ~line ~character in
      let ix = index_for_file state file in
      let items, _ = parse file text in
      let registry = state.registry in
      let result =
        Completion.items_for ~ix ~file ~items ~offset ~text ~registry
      in
      let start = Completion.replacement_start text offset in
      let sl, sc = Lsp_util.offset_to_position text starts start in
      let el, ec = Lsp_util.offset_to_position text starts offset in
      let range = `Assoc [ ("start", pos sl sc); ("end", pos el ec) ] in
      `List
        (List.map
           (fun (i : Completion.item) ->
             let json = completion_item_to_json i in
             match json with
             | `Assoc fields ->
                 `Assoc
                   (fields
                   @ [
                       ( "textEdit",
                         `Assoc
                           [
                             ("range", range);
                             ("newText", `String i.Completion.insert_text);
                           ] );
                     ])
             | other -> other)
           result)

let handle_hover (state : state) (params : Yojson.Safe.t) : Yojson.Safe.t =
  let td = Yojson.Safe.Util.member "textDocument" params in
  let uri = Lsp_util.string_field "uri" td in
  let position = Yojson.Safe.Util.member "position" params in
  let line = Lsp_util.int_field "line" position in
  let character = Lsp_util.int_field "character" position in
  match text_and_path uri with
  | None -> `Null
  | Some (text, file) -> (
      let starts = Lsp_util.line_starts text in
      let offset = Lsp_util.position_to_offset text starts ~line ~character in
      let ix = index_for_file state file in
      let items, _ = parse file text in
      let candidates =
        match Resolve.identifier_at text offset with
        | None -> []
        | Some (word, _, _) -> (
            let parts = String.split_on_char '.' word in
            match List.rev parts with
            | last :: rev_recv when rev_recv <> [] ->
                let recv = List.rev rev_recv in
                let members =
                  Resolve.resolve_receiver ix items file offset recv
                in
                let direct =
                  List.filter (fun (s : Ix.symbol) -> s.Ix.name = last) members
                in
                if direct <> [] then direct
                else Resolve.definitions_for_name ix items file word
            | _ -> Resolve.definitions_for_name ix items file word)
      in
      match candidates with
      | [] -> `Null
      | (s : Ix.symbol) :: _ ->
          let value =
            Printf.sprintf "```emo\n%s\n```\n\n`%s`" s.Ix.detail
              (Lsp_util.path_to_uri s.Ix.file)
          in
          `Assoc
            [
              ( "contents",
                `Assoc
                  [ ("kind", `String "markdown"); ("value", `String value) ] );
            ])

let handle_definition (state : state) (params : Yojson.Safe.t) : Yojson.Safe.t =
  let td = Yojson.Safe.Util.member "textDocument" params in
  let uri = Lsp_util.string_field "uri" td in
  let position = Yojson.Safe.Util.member "position" params in
  let line = Lsp_util.int_field "line" position in
  let character = Lsp_util.int_field "character" position in
  match text_and_path uri with
  | None -> `List []
  | Some (text, file) ->
      let starts = Lsp_util.line_starts text in
      let offset = Lsp_util.position_to_offset text starts ~line ~character in
      let ix = index_for_file state file in
      let items, _ = parse file text in
      let candidates =
        match Resolve.identifier_at text offset with
        | None -> []
        | Some (word, _, _) -> (
            let parts = String.split_on_char '.' word in
            match List.rev parts with
            | last :: rev_recv when rev_recv <> [] ->
                let recv = List.rev rev_recv in
                let members =
                  Resolve.resolve_receiver ix items file offset recv
                in
                let direct =
                  List.filter (fun (s : Ix.symbol) -> s.Ix.name = last) members
                in
                if direct <> [] then direct
                else Resolve.definitions_for_name ix items file word
            | _ -> Resolve.definitions_for_name ix items file word)
      in
      `List (List.map location_of_symbol candidates)

let handle_document_symbols (state : state) (params : Yojson.Safe.t) :
    Yojson.Safe.t =
  let _ = state in
  let uri =
    Lsp_util.string_field "uri" (Yojson.Safe.Util.member "textDocument" params)
  in
  match text_and_path uri with
  | None -> `List []
  | Some (text, file) ->
      let starts = Lsp_util.line_starts text in
      let items, _ = parse file text in
      `List (document_symbols_of_items text starts items)

let handle_workspace_symbols (state : state) (params : Yojson.Safe.t) :
    Yojson.Safe.t =
  let query = String.lowercase_ascii (Lsp_util.string_field "query" params) in
  let roots = match state.root with Some r -> [ r ] | None -> [] in
  let symbols =
    List.concat_map
      (fun root ->
        let ix = Ix.get ?registry:state.registry root in
        if query = "" then ix.Ix.symbols
        else
          List.filter
            (fun (s : Ix.symbol) ->
              Lsp_util.starts_with ~prefix:query
                (String.lowercase_ascii s.Ix.name))
            ix.Ix.symbols)
      roots
  in
  let symbols =
    if query = "" then symbols
    else
      List.filter
        (fun (s : Ix.symbol) ->
          let name = String.lowercase_ascii s.Ix.name in
          let q = query in
          let n = String.length q in
          let rec contains i =
            if i + n > String.length name then false
            else if String.sub name i n = q then true
            else contains (i + 1)
          in
          n = 0 || contains 0)
        symbols
  in
  let symbols = List.filteri (fun i _ -> i < 200) symbols in
  `List
    (List.map
       (fun (s : Ix.symbol) ->
         `Assoc
           [
             ("name", `String s.Ix.name);
             ("kind", `Int (symbol_kind_of_lsp s));
             ("location", location_of_symbol s);
             ( "containerName",
               match s.Ix.container with Some c -> `String c | None -> `Null );
           ])
       symbols)

(* ---- Package commands ----------------------------------------------- *)

let handle_execute_command (state : state) (params : Yojson.Safe.t) :
    Yojson.Safe.t =
  let command = Lsp_util.string_field "command" params in
  let args =
    match Yojson.Safe.Util.member "arguments" params with
    | `List xs ->
        List.filter_map (function `String s -> Some s | _ -> None) xs
    | _ -> []
  in
  let root = Option.value ~default:(Sys.getcwd ()) state.root in
  let result code output =
    `Assoc
      [
        ("ok", `Bool (code = 0)); ("code", `Int code); ("output", `String output);
      ]
  in
  match command with
  | "emo.deps.resolve" ->
      let code, output = run_emo state ~cwd:root [ "deps"; "resolve" ] in
      Ix.invalidate ~root ();
      result code output
  | "emo.deps.update" -> (
      match args with
      | name :: _ ->
          let code, output =
            run_emo state ~cwd:root [ "deps"; "update"; name ]
          in
          Ix.invalidate ~root ();
          result code output
      | [] -> result 1 "emo.deps.update needs a package name")
  | "emo.deps.list" ->
      let code, output = run_emo state ~cwd:root [ "deps"; "list" ] in
      result code output
  | "emo.package.init" ->
      let path = Filename.concat root "package.emo" in
      if Lsp_util.file_exists path then result 0 (path ^ " already exists")
      else
        let name =
          match args with
          | n :: _ -> n
          | [] -> "local/" ^ Filename.basename root
        in
        let template =
          Printf.sprintf
            "package {\n\
            \  name = \"%s\"\n\
            \  version = \"0.1.0\"\n\
            \  targets = [\"native\"]\n\n\
            \  deps {}\n\
             }\n"
            name
        in
        Lsp_util.write_file path template;
        result 0 ("created " ^ path)
  | "emo.check" | "emo.build" | "emo.run" -> (
      match args with
      | file :: _ ->
          let sub = String.sub command 4 (String.length command - 4) in
          let code, output = run_emo state ~cwd:root [ sub; file ] in
          result code output
      | [] -> result 1 (command ^ " needs a file path"))
  | other -> result 1 ("unknown command: " ^ other)

let handle_package_info (state : state) (params : Yojson.Safe.t) : Yojson.Safe.t
    =
  let root =
    match Lsp_util.string_field "root" params with
    | "" -> Option.value ~default:(Sys.getcwd ()) state.root
    | r -> r
  in
  package_info state root

(* ---- Dispatch ------------------------------------------------------- *)

let log_message state message =
  Protocol.notify state.oc ~method_:"window/logMessage"
    (`Assoc [ ("type", `Int 3); ("message", `String message) ])

let handle_request (state : state) ~(id : Yojson.Safe.t) ~(method_ : string)
    (params : Yojson.Safe.t) : unit =
  let reply json = Protocol.respond state.oc ~id json in
  match method_ with
  | "initialize" ->
      let options = Yojson.Safe.Util.member "initializationOptions" params in
      (match Yojson.Safe.Util.member "registry" options with
      | `String r -> state.registry <- Some r
      | _ -> ());
      let root =
        match Yojson.Safe.Util.member "rootUri" params with
        | `String uri -> Lsp_util.uri_to_path uri
        | _ -> (
            match Yojson.Safe.Util.member "workspaceFolders" params with
            | `List (first :: _) -> (
                match Yojson.Safe.Util.member "uri" first with
                | `String uri -> Lsp_util.uri_to_path uri
                | _ -> None)
            | _ -> (
                match Yojson.Safe.Util.member "rootPath" params with
                | `String p -> Some p
                | _ -> None))
      in
      state.root <- root;
      (* LSP InitializeResult: the capabilities must sit under a
         `capabilities` member, with optional serverInfo alongside. *)
      reply (initialize_result ())
  | "shutdown" ->
      state.shutdown <- true;
      reply `Null
  | "textDocument/completion" -> reply (handle_completion state params)
  | "textDocument/hover" -> reply (handle_hover state params)
  | "textDocument/definition" -> reply (handle_definition state params)
  | "textDocument/documentSymbol" ->
      reply (handle_document_symbols state params)
  | "workspace/symbol" -> reply (handle_workspace_symbols state params)
  | "textDocument/semanticTokens/full" -> (
      let uri =
        Lsp_util.string_field "uri"
          (Yojson.Safe.Util.member "textDocument" params)
      in
      match text_and_path uri with
      | None -> reply (`Assoc [ ("data", `List []) ])
      | Some (text, file) -> reply (semantic_tokens state file text))
  | "textDocument/codeAction" -> (
      let uri =
        Lsp_util.string_field "uri"
          (Yojson.Safe.Util.member "textDocument" params)
      in
      match text_and_path uri with
      | None -> reply (`List [])
      | Some (text, file) -> reply (`List (code_actions state file text)))
  | "workspace/executeCommand" -> reply (handle_execute_command state params)
  | "emo/packageInfo" -> reply (handle_package_info state params)
  | _ ->
      Protocol.respond_error state.oc ~id ~code:(-32601)
        ~message:("method not found: " ^ method_)

let handle_notification (state : state) ~(method_ : string)
    (params : Yojson.Safe.t) : unit =
  match method_ with
  | "initialized" -> log_message state "Emo language server started"
  | "exit" -> if state.shutdown then exit 0 else exit 1
  | "textDocument/didOpen" ->
      let td = Yojson.Safe.Util.member "textDocument" params in
      let uri = Lsp_util.string_field "uri" td in
      let text = Lsp_util.string_field "text" td in
      let version = Lsp_util.int_field "version" td in
      let path = Option.value ~default:"" (path_of_uri uri) in
      ignore (Lsp_document.open_ uri ~path ~version ~text);
      publish_diagnostics state uri path text
  | "textDocument/didChange" -> (
      let td = Yojson.Safe.Util.member "textDocument" params in
      let uri = Lsp_util.string_field "uri" td in
      let version = Lsp_util.int_field "version" td in
      let text =
        match Yojson.Safe.Util.member "contentChanges" params with
        | `List changes -> (
            match List.rev changes with
            | last :: _ -> Lsp_util.string_field "text" last
            | [] -> "")
        | _ -> ""
      in
      match Lsp_document.find uri with
      | Some doc ->
          doc.Lsp_document.text <- text;
          doc.Lsp_document.version <- version;
          publish_diagnostics state uri doc.Lsp_document.path text
      | None ->
          publish_diagnostics state uri
            (Option.value ~default:"" (path_of_uri uri))
            text)
  | "textDocument/didSave" -> (
      let uri =
        Lsp_util.string_field "uri"
          (Yojson.Safe.Util.member "textDocument" params)
      in
      match Lsp_document.find uri with
      | Some doc ->
          Ix.invalidate ~root:(root_for_file state doc.Lsp_document.path) ();
          publish_diagnostics state uri doc.Lsp_document.path
            doc.Lsp_document.text
      | None -> ())
  | "textDocument/didClose" ->
      let uri =
        Lsp_util.string_field "uri"
          (Yojson.Safe.Util.member "textDocument" params)
      in
      Lsp_document.close uri;
      Protocol.notify state.oc ~method_:"textDocument/publishDiagnostics"
        (`Assoc [ ("uri", `String uri); ("diagnostics", `List []) ])
  | "workspace/didChangeConfiguration" -> (
      let settings = Yojson.Safe.Util.member "settings" params in
      let emo = Yojson.Safe.Util.member "emo" settings in
      match Yojson.Safe.Util.member "registry" emo with
      | `String r -> state.registry <- Some r
      | _ -> ())
  | "$/cancelRequest" | "workspace/didChangeWatchedFiles" -> ()
  | _ -> ()

(* ---- Main loop ------------------------------------------------------ *)

let default_emo_path () =
  match Sys.getenv_opt "EMO_BIN" with Some p when p <> "" -> p | _ -> "emo"

let main () : unit =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let state =
    {
      oc = stdout;
      root = None;
      registry =
        (match Sys.getenv_opt "EMO_REGISTRY" with
        | Some r when r <> "" -> Some r
        | _ -> None);
      emo_path = default_emo_path ();
      shutdown = false;
    }
  in
  let rec loop () =
    match Protocol.read stdin with
    | None -> ()
    | Some (Protocol.Request { id; method_; params }) ->
        (try handle_request state ~id ~method_ params
         with e ->
           Protocol.respond_error state.oc ~id ~code:(-32603)
             ~message:(Printexc.to_string e));
        loop ()
    | Some (Protocol.Notification { method_; params }) ->
        (try handle_notification state ~method_ params with _ -> ());
        loop ()
  in
  loop ()
