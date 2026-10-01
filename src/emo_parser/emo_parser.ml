module Ast = Emo_ast
module Tok = Emo_lexer.Token

exception Error of Emo_support.Diagnostic.t

let error code span ?hint message =
  raise
    (Error
       Emo_support.Diagnostic.
         { severity = Error; code = Some code; message; span; hint })

let op_spelling = function
  | Tok.LParen -> "("
  | Tok.RParen -> ")"
  | Tok.LBrace -> "{"
  | Tok.RBrace -> "}"
  | Tok.LBracket -> "["
  | Tok.RBracket -> "]"
  | Tok.Comma -> ","
  | Tok.Colon -> ":"
  | Tok.Dot -> "."
  | Tok.Arrow -> "->"
  | Tok.Send -> "<-"
  | Tok.Assign -> "="
  | Tok.Eq -> "=="
  | Tok.Ne -> "!="
  | Tok.Lt -> "<"
  | Tok.Le -> "<="
  | Tok.Gt -> ">"
  | Tok.Ge -> ">="
  | Tok.Plus -> "+"
  | Tok.Minus -> "-"
  | Tok.Star -> "*"
  | Tok.Slash -> "/"
  | Tok.Percent -> "%"
  | Tok.AndAnd -> "&&"
  | Tok.OrOr -> "||"
  | Tok.Not -> "!"

let keyword_spelling = function
  | Tok.Def -> "def"
  | Tok.Const -> "const"
  | Tok.Var -> "var"
  | Tok.Class -> "class"
  | Tok.Interface -> "interface"
  | Tok.Enum -> "enum"
  | Tok.If -> "if"
  | Tok.Else -> "else"
  | Tok.Case -> "case"
  | Tok.When -> "when"
  | Tok.Receive -> "receive"
  | Tok.Return -> "return"
  | Tok.Raise -> "raise"
  | Tok.Self -> "self"
  | Tok.Do -> "do"

let describe_kind (k : Tok.kind) =
  match k with
  | Int n -> Printf.sprintf "integer `%d`" n
  | Float f -> Printf.sprintf "float `%g`" f
  | Char c -> Printf.sprintf "character %C" c
  | String_chunk _ | String_end | Interp_open | Interp_close -> "a string"
  | True -> "`true`"
  | False -> "`false`"
  | Lower_ident s -> Printf.sprintf "identifier `%s`" s
  | Upper_ident s -> Printf.sprintf "type name `%s`" s
  | Keyword k -> "`" ^ keyword_spelling k ^ "`"
  | Op o -> "`" ^ op_spelling o ^ "`"
  | Eof -> "end of input"

type parser = {
  stream : Emo_lexer.Stream.t;
  file : string;
  mutable in_init : bool; (* inside an init body, where self.x = ... is legal *)
}

let peek st = Emo_lexer.Stream.peek st.stream
let advance st = Emo_lexer.Stream.advance st.stream
let at_eof st = Emo_lexer.Stream.at_eof st.stream
let newline_before st = Emo_lexer.Stream.newline_before st.stream
let kind st = (peek st).Tok.kind
let span st = (peek st).Tok.span
let describe_here st = describe_kind (kind st)
let at_op st op = kind st = Tok.Op op
let at_keyword st k = kind st = Tok.Keyword k

let expect_op st op what =
  if at_op st op then advance st |> ignore
  else
    error "E2001" (span st)
      (Printf.sprintf "expected %s, found %s" what (describe_here st))

let merge_span a b = Emo_support.Span.merge a b
let node span desc = { Ast.span; desc }
let stmt span desc = { Ast.stmt_span = span; stmt_desc = desc }

let comparison_binop = function
  | Tok.Eq -> Some Ast.Eq
  | Tok.Ne -> Some Ast.Ne
  | Tok.Lt -> Some Ast.Lt
  | Tok.Le -> Some Ast.Le
  | Tok.Gt -> Some Ast.Gt
  | Tok.Ge -> Some Ast.Ge
  | _ -> None

let is_comparison_op = function
  | Tok.Eq | Tok.Ne | Tok.Lt | Tok.Le | Tok.Gt | Tok.Ge -> true
  | _ -> false

let rec parse_expr st = parse_or st

and parse_or st =
  let left = ref (parse_and st) in
  while at_op st Tok.OrOr do
    let op_span = (advance st).Tok.span in
    let right = parse_and st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (Ast.Or, !left, right))
  done;
  !left

and parse_and st =
  let left = ref (parse_comparison st) in
  while at_op st Tok.AndAnd do
    let op_span = (advance st).Tok.span in
    let right = parse_comparison st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (Ast.And, !left, right))
  done;
  !left

and parse_comparison st =
  let left = parse_additive st in
  match kind st with
  | Tok.Op op when is_comparison_op op ->
      let binop =
        match comparison_binop op with Some b -> b | None -> assert false
      in
      let op_span = (advance st).Tok.span in
      let right = parse_additive st in
      (match kind st with
      | Tok.Op op2 when is_comparison_op op2 ->
          error "E2002" (span st) "comparisons do not chain"
            ~hint:"combine separate comparisons with `&&`"
      | _ -> ());
      node
        (merge_span (merge_span left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (binop, left, right))
  | _ -> left

and parse_additive st =
  let left = ref (parse_multiplicative st) in
  let step () =
    let op, op_span =
      match kind st with
      | Tok.Op Tok.Plus -> (Ast.Add, (advance st).Tok.span)
      | Tok.Op Tok.Minus -> (Ast.Sub, (advance st).Tok.span)
      | _ -> assert false
    in
    let right = parse_multiplicative st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (op, !left, right))
  in
  while at_op st Tok.Plus || at_op st Tok.Minus do
    step ()
  done;
  !left

and parse_multiplicative st =
  let left = ref (parse_unary st) in
  let step () =
    let op, op_span =
      match kind st with
      | Tok.Op Tok.Star -> (Ast.Mul, (advance st).Tok.span)
      | Tok.Op Tok.Slash -> (Ast.Div, (advance st).Tok.span)
      | Tok.Op Tok.Percent -> (Ast.Mod, (advance st).Tok.span)
      | _ -> assert false
    in
    let right = parse_unary st in
    left :=
      node
        (merge_span (merge_span !left.Ast.span op_span) right.Ast.span)
        (Ast.Binary (op, !left, right))
  in
  while at_op st Tok.Star || at_op st Tok.Slash || at_op st Tok.Percent do
    step ()
  done;
  !left

and parse_unary st =
  match kind st with
  | Tok.Op Tok.Not ->
      let op_span = (advance st).Tok.span in
      let operand = parse_unary st in
      node (merge_span op_span operand.Ast.span) (Ast.Unary (Ast.Not, operand))
  | Tok.Op Tok.Minus ->
      let op_span = (advance st).Tok.span in
      let operand = parse_unary st in
      node (merge_span op_span operand.Ast.span) (Ast.Unary (Ast.Neg, operand))
  | _ -> parse_postfix st

and parse_postfix st =
  let e = ref (parse_primary st) in
  let continue = ref true in
  while !continue do
    match kind st with
    | Tok.Op Tok.Dot when not (newline_before st) -> (
        advance st |> ignore;
        match kind st with
        | Tok.Lower_ident name ->
            let name_span = (advance st).Tok.span in
            e := node (merge_span !e.Ast.span name_span) (Ast.Member (!e, name))
        | t ->
            error "E2001" (span st)
              (Printf.sprintf "expected a member name after `.`, found %s"
                 (describe_kind t)))
    | Tok.Op Tok.LBracket when not (newline_before st) ->
        advance st |> ignore;
        let index = parse_expr st in
        let close_span = span st in
        expect_op st Tok.RBracket "`]`";
        e := node (merge_span !e.Ast.span close_span) (Ast.Index (!e, index))
    | Tok.Op Tok.LParen when not (newline_before st) -> (
        let lparen = peek st in
        if
          lparen.Tok.span.Emo_support.Span.start
          > !e.Ast.span.Emo_support.Span.stop
        then
          error "E2003" lparen.Tok.span "call parentheses must touch the callee"
            ~hint:"write `f(a)`, never `f (a)`";
        advance st |> ignore;
        let args = parse_args st in
        let close_span = span st in
        expect_op st Tok.RParen "`)`" |> ignore;
        let call =
          node (merge_span !e.Ast.span close_span) (Ast.Call (!e, args))
        in
        e :=
          match kind st with
          | Tok.Op Tok.LBrace when not (newline_before st) ->
              let lbrace_span = span st in
              let body, close_span = parse_block st in
              let block =
                node
                  (merge_span lbrace_span close_span)
                  (Ast.Arrow_block ([], body))
              in
              node
                (merge_span call.Ast.span close_span)
                (Ast.Call
                   (!e, args @ [ { Ast.arg_name = None; arg_value = block } ]))
          | _ -> call)
    | _ -> continue := false
  done;
  !e

and parse_primary st =
  let tok = peek st in
  match tok.Tok.kind with
  | Tok.Int n ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Int n)
  | Tok.Float f ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Float f)
  | Tok.Char c ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Char c)
  | Tok.True ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Bool true)
  | Tok.False ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Bool false)
  | Tok.Lower_ident s ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Ident s)
  | Tok.Upper_ident s ->
      advance st |> ignore;
      node tok.Tok.span (Ast.Type_ident s)
  | Tok.Keyword Tok.Self ->
      advance st |> ignore;
      node tok.Tok.span Ast.Self
  | Tok.String_chunk _ | Tok.String_end | Tok.Interp_open -> parse_string st
  | Tok.Keyword Tok.Do -> (
      advance st |> ignore;
      let operand = parse_unary st in
      match operand.Ast.desc with
      | Ast.Call _ ->
          node (merge_span tok.Tok.span operand.Ast.span) (Ast.Do operand)
      | _ ->
          error "E2008" (span st) "the operand of `do` must be a call"
            ~hint:"write `do task(x)`")
  | Tok.Op Tok.Arrow ->
      advance st |> ignore;
      let params = parse_params st in
      let body, close_span = parse_block st in
      node (merge_span tok.Tok.span close_span) (Ast.Arrow_block (params, body))
  | Tok.Op Tok.LParen -> parse_paren st
  | t ->
      error "E2001" (span st)
        (Printf.sprintf "expected an expression, found %s" (describe_kind t))

and parse_paren st =
  let open_span = (advance st).Tok.span in
  if at_op st Tok.RParen then
    let close_span = (advance st).Tok.span in
    node (merge_span open_span close_span) (Ast.Tuple [])
  else
    let first = parse_expr st in
    if at_op st Tok.Comma then (
      let elems = ref [ first ] in
      while at_op st Tok.Comma do
        advance st |> ignore;
        if at_op st Tok.RParen then
          error "E2004" (span st) "tuples do not take a trailing comma"
            ~hint:"the one-element tuple is written `(a)`";
        elems := parse_expr st :: !elems
      done;
      let close_span = span st in
      expect_op st Tok.RParen "`)`" |> ignore;
      node (merge_span open_span close_span) (Ast.Tuple (List.rev !elems)))
    else
      let close_span = span st in
      expect_op st Tok.RParen "`)`" |> ignore;
      match first.Ast.desc with
      | Binary _ | Unary _ -> first
      | _ -> node (merge_span open_span close_span) (Ast.Tuple [ first ])

and parse_args st =
  if at_op st Tok.RParen then []
  else
    let args = ref [] in
    let rec loop () =
      let name =
        match kind st with
        | Tok.Lower_ident n
          when (Emo_lexer.Stream.peek_ahead st.stream 1).Tok.kind
               = Tok.Op Tok.Colon ->
            advance st |> ignore;
            advance st |> ignore;
            Some n
        | _ -> None
      in
      let value = parse_expr st in
      args := { Ast.arg_name = name; arg_value = value } :: !args;
      if at_op st Tok.Comma then (
        advance st |> ignore;
        if at_op st Tok.RParen then
          error "E2003" (span st) "argument lists do not take a trailing comma";
        loop ())
    in
    loop ();
    List.rev !args

and parse_block st =
  expect_op st Tok.LBrace "`{`" |> ignore;
  let stmts = ref [] in
  let rec loop () =
    if at_op st Tok.RBrace || at_eof st then ()
    else (
      stmts := parse_stmt st :: !stmts;
      loop ())
  in
  loop ();
  if at_eof st then error "E2001" (span st) "expected `}`, found end of input";
  let close_span = span st in
  expect_op st Tok.RBrace "`}`" |> ignore;
  (List.rev !stmts, close_span)

and parse_stmt st =
  let start_span = span st in
  match kind st with
  | Tok.Keyword Tok.If ->
      advance st |> ignore;
      let cond = parse_expr st in
      if at_op st Tok.LBrace && newline_before st then
        error "E2001" (span st)
          "the `if` body must open on the condition's line";
      let then_body, _ = parse_block st in
      let else_body =
        match kind st with
        | Tok.Keyword Tok.Else ->
            if newline_before st then
              error "E2005" (span st)
                "`else` must stay on the closing brace's line"
                ~hint:"write `} else {`";
            advance st |> ignore;
            let body, _ = parse_block st in
            Some body
        | _ -> None
      in
      stmt start_span (Ast.If { cond; then_body; else_body })
  | Tok.Keyword ((Tok.Const | Tok.Var) as kw) ->
      advance st |> ignore;
      let mutable_ = kw = Tok.Var in
      let name =
        match kind st with
        | Tok.Lower_ident n ->
            if n <> "" && n.[String.length n - 1] = '?' then
              error "E2007" (span st) "a binding name cannot end in `?`";
            advance st |> ignore;
            n
        | t ->
            error "E2007" (span st)
              (Printf.sprintf "expected a binding name, found %s"
                 (describe_kind t))
      in
      expect_op st Tok.Assign "`=`" |> ignore;
      if at_eof st || newline_before st then
        error "E2002" (span st)
          "the binding's initializer must stay on the `=`'s line";
      let init = parse_expr st in
      end_statement st;
      stmt start_span (Ast.Binding { mutable_; name; init })
  | Tok.Keyword Tok.Case ->
      advance st |> ignore;
      let scrutinee = parse_expr st in
      if at_op st Tok.LBrace && newline_before st then
        error "E2001" (span st)
          "the `case` branches must open on the scrutinee's line";
      expect_op st Tok.LBrace "`{`" |> ignore;
      let branches = parse_branches st in
      expect_op st Tok.RBrace "`}`" |> ignore;
      stmt start_span (Ast.Case { scrutinee; branches })
  | Tok.Keyword Tok.Receive ->
      advance st |> ignore;
      expect_op st Tok.LBrace "`{`" |> ignore;
      let branches = parse_branches st in
      expect_op st Tok.RBrace "`}`" |> ignore;
      stmt start_span (Ast.Receive branches)
  | Tok.Keyword Tok.Return ->
      advance st |> ignore;
      if at_op st Tok.RBrace || at_eof st || newline_before st then
        stmt start_span (Ast.Return None)
      else
        let e = parse_expr st in
        end_statement st;
        stmt start_span (Ast.Return (Some e))
  | _ ->
      let e = parse_expr st in
      let stmt_desc =
        match kind st with
        | Tok.Op Tok.Send when not (newline_before st) ->
            advance st |> ignore;
            let message = parse_expr st in
            end_statement st;
            Ast.Send { target = e; message }
        | Tok.Op Tok.Assign when not (newline_before st) ->
            advance st |> ignore;
            check_assign_target st e;
            let value = parse_expr st in
            end_statement st;
            Ast.Assign { target = e; value }
        | _ ->
            end_statement st;
            Ast.Expr_stmt e
      in
      stmt start_span stmt_desc

(* `x = v` rebinds a variable; `self.x = v` is a field assignment, legal
   only inside init. *)
and check_assign_target st target =
  match target.Ast.desc with
  | Ast.Ident _ -> ()
  | Ast.Member ({ Ast.desc = Ast.Self; _ }, _) ->
      if not st.in_init then
        error "E2016" target.Ast.span "fields are assigned only inside `init`"
          ~hint:"`init` is the only window where `self.x = ...` may appear"
  | _ ->
      error "E2015" target.Ast.span "invalid assignment target"
        ~hint:"assign to a variable or to a `self` field"

and end_statement st =
  match kind st with
  | Tok.Eof | Tok.Op Tok.RBrace -> ()
  | _ when newline_before st -> ()
  | _ ->
      error "E2002" (span st) "expressions cannot be juxtaposed"
        ~hint:"start a new statement on the next line"

and parse_item st =
  let item_span = span st in
  match kind st with
  | Tok.Keyword Tok.Def ->
      let d = parse_def st ~in_class:false in
      { Ast.item_span = d.Ast.def_span; item_desc = Ast.Item_def d }
  | Tok.Keyword Tok.Class ->
      let c = parse_class st in
      { Ast.item_span = c.Ast.class_span; item_desc = Ast.Item_class c }
  | Tok.Keyword Tok.Interface ->
      let i = parse_interface st in
      { Ast.item_span = i.Ast.interface_span; item_desc = Ast.Item_interface i }
  | _ -> { Ast.item_span; item_desc = Ast.Item_stmt (parse_stmt st) }

(* `true` when the current token can begin a type annotation. *)
and starts_type st =
  match kind st with
  | Tok.Upper_ident _ | Tok.Op Tok.LParen -> true
  | _ -> false

(* Type positions take UpperCamel names only. *)
and parse_type_name st what =
  match kind st with
  | Tok.Upper_ident name ->
      let tok = advance st in
      (name, tok.Tok.span)
  | t ->
      error "E2017" (span st)
        (Printf.sprintf "expected a %s name, found %s" what (describe_kind t))
        ~hint:"type names start with an uppercase letter"

and parse_def st ~in_class =
  let def_tok = peek st in
  advance st |> ignore;
  let name, name_span =
    match kind st with
    | Tok.Lower_ident n ->
        let tok = advance st in
        (n, tok.Tok.span)
    | t ->
        error "E2009" (span st)
          (Printf.sprintf "expected a def name, found %s" (describe_kind t))
  in
  if name = "init" then (
    if not in_class then
      error "E2010" name_span
        "`init` is a constructor; it can only be defined in a class body";
    let def_params = parse_params st in
    if (not (newline_before st)) && starts_type st then
      error "E2011" (span st) "`init` takes no return annotation"
        ~hint:"`init` returns the class it constructs";
    let saved_in_init = st.in_init in
    st.in_init <- true;
    let def_body, close_span = parse_def_body st in
    st.in_init <- saved_in_init;
    {
      Ast.def_span = merge_span def_tok.Tok.span close_span;
      def_name = name;
      def_params;
      def_return = None;
      def_body;
    })
  else
    let def_params = parse_params st in
    let def_return =
      if (not (newline_before st)) && starts_type st then
        Some (parse_type_ann st)
      else
        error "E2012" (span st) "a def must declare its return type"
          ~hint:"function signatures always carry explicit types"
    in
    let def_body, close_span = parse_def_body st in
    {
      Ast.def_span = merge_span def_tok.Tok.span close_span;
      def_name = name;
      def_params;
      def_return;
      def_body;
    }

and parse_def_body st =
  if at_op st Tok.LBrace && not (newline_before st) then parse_block st
  else
    error "E2001" (span st)
      "the def's body must open with `{` on the signature's line"

and parse_class st =
  let class_tok = peek st in
  advance st |> ignore;
  let class_name, name_span = parse_type_name st "class" in
  if at_op st Tok.LBrace && newline_before st then
    error "E2001" (span st) "the class body must open on the class's line";
  expect_op st Tok.LBrace "`{`" |> ignore;
  let inits = ref [] in
  let methods = ref [] in
  let rec members first =
    if at_op st Tok.RBrace || at_eof st then ()
    else (
      if (not first) && not (newline_before st) then
        error "E2001" (span st) "class members are separated by newlines";
      match kind st with
      | Tok.Keyword Tok.Def ->
          let d = parse_def st ~in_class:true in
          if d.Ast.def_name = "init" then inits := d :: !inits
          else methods := d :: !methods;
          members false
      | t ->
          error "E2001" (span st)
            (Printf.sprintf "expected a `def` in the class body, found %s"
               (describe_kind t)))
  in
  members true;
  if at_eof st then error "E2001" (span st) "expected `}`, found end of input";
  let close_span = span st in
  expect_op st Tok.RBrace "`}`" |> ignore;
  let class_init, class_methods =
    match List.rev !inits with
    | [ init ] -> (init, List.rev !methods)
    | [] ->
        error "E2013" name_span
          (Printf.sprintf "class `%s` must declare an `init`" class_name)
    | _ :: duplicate :: _ ->
        error "E2014" duplicate.Ast.def_span
          "a class can only declare one `init`"
          ~hint:"fields come into existence in `init`; merge the constructors"
  in
  let class_span = merge_span class_tok.Tok.span close_span in
  {
    Ast.class_span;
    class_name;
    class_init;
    class_methods;
    class_fields = collect_fields class_init.Ast.def_body;
  }

(* The field set is whatever init assigns via self.x = ..., in first-assignment
   order. Fields are not declared anywhere else. *)
and collect_fields stmts =
  let seen = Hashtbl.create 8 in
  let fields = ref [] in
  let rec walk stmts =
    List.iter
      (fun s ->
        match s.Ast.stmt_desc with
        | Ast.Assign
            {
              target =
                {
                  Ast.desc = Ast.Member ({ Ast.desc = Ast.Self; _ }, name);
                  span;
                  _;
                };
              _;
            } ->
            if not (Hashtbl.mem seen name) then (
              Hashtbl.add seen name ();
              fields := { Ast.field_name = name; field_span = span } :: !fields)
        | Ast.If { then_body; else_body; _ } ->
            walk then_body;
            Option.iter walk else_body
        | Ast.Case { branches; _ } ->
            List.iter (fun b -> walk b.Ast.body) branches
        | _ -> ())
      stmts
  in
  walk stmts;
  List.rev !fields

and parse_interface st =
  let kw_tok = peek st in
  advance st |> ignore;
  let interface_name, _ = parse_type_name st "interface" in
  if at_op st Tok.LBrace && newline_before st then
    error "E2001" (span st)
      "the interface body must open on the interface's line";
  expect_op st Tok.LBrace "`{`" |> ignore;
  let methods = ref [] in
  let rec members first =
    if at_op st Tok.RBrace || at_eof st then ()
    else (
      if (not first) && not (newline_before st) then
        error "E2001" (span st) "interface members are separated by newlines";
      match kind st with
      | Tok.Keyword Tok.Def ->
          methods := parse_method_sig st :: !methods;
          members false
      | t ->
          error "E2001" (span st)
            (Printf.sprintf "expected a `def` in the interface body, found %s"
               (describe_kind t)))
  in
  members true;
  if at_eof st then error "E2001" (span st) "expected `}`, found end of input";
  let close_span = span st in
  expect_op st Tok.RBrace "`}`" |> ignore;
  {
    Ast.interface_span = merge_span kw_tok.Tok.span close_span;
    interface_name;
    interface_methods = List.rev !methods;
  }

(* A method signature inside an interface: name, annotated parameters, and a
   required return type — never a body. *)
and parse_method_sig st =
  let def_tok = peek st in
  advance st |> ignore;
  let sig_name, name_span =
    match kind st with
    | Tok.Lower_ident n ->
        let tok = advance st in
        (n, tok.Tok.span)
    | t ->
        error "E2009" (span st)
          (Printf.sprintf "expected a def name, found %s" (describe_kind t))
  in
  if sig_name = "init" then
    error "E2019" name_span "an interface cannot declare `init`"
      ~hint:"interfaces describe shapes, not construction";
  let sig_params = parse_params st in
  let sig_return =
    if (not (newline_before st)) && starts_type st then parse_type_ann st
    else if at_op st Tok.LBrace && not (newline_before st) then
      error "E2018" (span st) "an interface method is a signature only"
        ~hint:"drop the body — a method's shape is its whole contract"
    else
      error "E2012" (span st) "an interface method must declare its return type"
  in
  if at_op st Tok.LBrace && not (newline_before st) then
    error "E2018" (span st) "an interface method is a signature only"
      ~hint:"drop the body — a method's shape is its whole contract";
  {
    Ast.sig_span = merge_span def_tok.Tok.span sig_return.Ast.type_span;
    sig_name;
    sig_params;
    sig_return;
  }

and parse_params st =
  if at_op st Tok.LParen then (
    advance st |> ignore;
    if at_op st Tok.RParen then (
      advance st |> ignore;
      [])
    else
      let params = ref [] in
      let rec loop () =
        let name =
          match kind st with
          | Tok.Lower_ident n ->
              if String.length n > 0 && n.[String.length n - 1] = '?' then
                error "E2006" (span st) "a parameter name cannot end in `?`";
              advance st |> ignore;
              n
          | t ->
              error "E2006" (span st)
                (Printf.sprintf "expected a parameter name, found %s"
                   (describe_kind t))
        in
        let param_type = parse_type_ann st in
        params := { Ast.param_name = name; param_type } :: !params;
        if at_op st Tok.Comma then (
          advance st |> ignore;
          if at_op st Tok.RParen then
            error "E2006" (span st)
              "parameter lists do not take a trailing comma";
          loop ())
      in
      loop ();
      expect_op st Tok.RParen "`)`" |> ignore;
      List.rev !params)
  else []

and parse_type_ann st =
  let tok = peek st in
  match tok.Tok.kind with
  | Tok.Upper_ident name ->
      advance st |> ignore;
      if at_op st Tok.LBracket then (
        advance st |> ignore;
        if at_op st Tok.RBracket then
          error "E2001" (span st) "a type application needs type arguments";
        let args = ref [] in
        let rec loop () =
          args := parse_type_ann st :: !args;
          if at_op st Tok.Comma then (
            advance st |> ignore;
            if at_op st Tok.RBracket then
              error "E2001" (span st)
                "type applications do not take a trailing comma");
          if not (at_op st Tok.RBracket) then loop ()
        in
        loop ();
        let close_span = span st in
        expect_op st Tok.RBracket "`]`" |> ignore;
        {
          Ast.type_span = merge_span tok.Tok.span close_span;
          type_desc = Ast.Applied_type (name, List.rev !args);
        })
      else { Ast.type_span = tok.Tok.span; type_desc = Ast.Named_type name }
  | Tok.Op Tok.LParen ->
      advance st |> ignore;
      let types = ref [] in
      let rec loop () =
        if at_op st Tok.RParen then ()
        else (
          types := parse_type_ann st :: !types;
          if at_op st Tok.Comma then (
            advance st |> ignore;
            if at_op st Tok.RParen then
              error "E2004" (span st) "type tuples do not take a trailing comma");
          loop ())
      in
      loop ();
      let close_span = span st in
      expect_op st Tok.RParen "`)`" |> ignore;
      {
        Ast.type_span = merge_span tok.Tok.span close_span;
        type_desc = Ast.Tuple_type (List.rev !types);
      }
  | t ->
      error "E2001" (span st)
        (Printf.sprintf "expected a type annotation, found %s" (describe_kind t))

and parse_string st =
  let start_span = span st in
  let parts = ref [] in
  let rec loop () =
    match kind st with
    | Tok.String_chunk text ->
        advance st |> ignore;
        parts := Ast.Literal_text text :: !parts;
        loop ()
    | Tok.Interp_open ->
        advance st |> ignore;
        let e = parse_expr st in
        (match kind st with
        | Tok.Interp_close -> advance st |> ignore
        | t ->
            error "E2001" (span st)
              (Printf.sprintf
                 "expected `}` to close the interpolation, found %s"
                 (describe_kind t)));
        parts := Ast.Part_expr e :: !parts;
        loop ()
    | Tok.String_end ->
        let close_span = span st in
        advance st |> ignore;
        let desc =
          match List.rev !parts with
          | [] -> Ast.String ""
          | [ Ast.Literal_text text ] -> Ast.String text
          | parts -> Ast.Interpolated parts
        in
        node (merge_span start_span close_span) desc
    | t ->
        error "E2001" (span st)
          (Printf.sprintf "expected the rest of the string, found %s"
             (describe_kind t))
  in
  loop ()

and parse_pattern st =
  let tok = peek st in
  match tok.Tok.kind with
  | Tok.Upper_ident tname -> (
      advance st |> ignore;
      if not (at_op st Tok.Dot) then
        error "E2007" (span st) "enum members are matched by qualified name"
          ~hint:"write `Color.red`, not a bare type name";
      expect_op st Tok.Dot "`.`" |> ignore;
      match kind st with
      | Tok.Lower_ident member ->
          let mspan = (advance st).Tok.span in
          {
            Ast.pattern_span = merge_span tok.Tok.span mspan;
            pattern_desc = Ast.Enum_member (tname, member);
          }
      | t ->
          error "E2007" (span st)
            (Printf.sprintf "expected an enum member after `%s.`, found %s"
               tname (describe_kind t)))
  | Tok.Int n ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_literal (Ast.L_int n);
      }
  | Tok.Float f ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_literal (Ast.L_float f);
      }
  | Tok.Char c ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_literal (Ast.L_char c);
      }
  | Tok.True ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_literal (Ast.L_bool true);
      }
  | Tok.False ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_literal (Ast.L_bool false);
      }
  | Tok.String_chunk _ | Tok.String_end | Tok.Interp_open -> (
      match (parse_string st).Ast.desc with
      | Ast.String text ->
          {
            Ast.pattern_span = tok.Tok.span;
            pattern_desc = Ast.Pattern_literal (Ast.L_string text);
          }
      | _ ->
          error "E2007" (span st) "patterns match plain strings only"
            ~hint:"interpolation in a pattern would never match a known value")
  | Tok.Lower_ident "_" ->
      advance st |> ignore;
      { Ast.pattern_span = tok.Tok.span; pattern_desc = Ast.Wildcard }
  | Tok.Lower_ident name ->
      advance st |> ignore;
      {
        Ast.pattern_span = tok.Tok.span;
        pattern_desc = Ast.Pattern_binding name;
      }
  | Tok.Op Tok.LParen ->
      advance st |> ignore;
      if at_op st Tok.RParen then
        { Ast.pattern_span = tok.Tok.span; pattern_desc = Ast.Tuple_pattern [] }
      else
        let patterns = ref [ parse_pattern st ] in
        while at_op st Tok.Comma do
          advance st |> ignore;
          if at_op st Tok.RParen then
            error "E2004" (span st) "patterns do not take a trailing comma";
          patterns := parse_pattern st :: !patterns
        done;
        let close_span = span st in
        expect_op st Tok.RParen "`)`" |> ignore;
        {
          Ast.pattern_span = merge_span tok.Tok.span close_span;
          pattern_desc = Ast.Tuple_pattern (List.rev !patterns);
        }
  | t ->
      error "E2007" (span st)
        (Printf.sprintf "expected a pattern, found %s" (describe_kind t))

and parse_branches st =
  let branches = ref [] in
  let first = ref true in
  let rec loop () =
    if at_op st Tok.RBrace || at_eof st then ()
    else (
      if (not !first) && not (newline_before st) then
        error "E2007" (span st) "branches are separated by newlines";
      first := false;
      let pattern = parse_pattern st in
      let guard =
        if at_keyword st Tok.When then (
          advance st |> ignore;
          Some (parse_expr st))
        else None
      in
      expect_op st Tok.Arrow "`->`" |> ignore;
      let body, _ = parse_block st in
      branches := { Ast.pattern; guard; body } :: !branches;
      loop ())
  in
  loop ();
  List.rev !branches

(* Parses a source that holds exactly one expression. *)
let parse_expr_source ~file ~source =
  let stream = Emo_lexer.lex ~file ~source in
  let st = { stream; file; in_init = false } in
  let e = parse_expr st in
  if not (at_eof st) then
    error "E2001" (span st)
      (Printf.sprintf "unexpected %s after the expression" (describe_here st));
  e

(* Parses a file: a sequence of top-level items ended by newlines. *)
let parse_program ~file ~source =
  let stream = Emo_lexer.lex ~file ~source in
  let st = { stream; file; in_init = false } in
  let items = ref [] in
  let rec loop () =
    if at_eof st then ()
    else (
      items := parse_item st :: !items;
      loop ())
  in
  loop ();
  List.rev !items
