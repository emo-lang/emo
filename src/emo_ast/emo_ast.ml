(** The Emo syntax tree. Every [expr], [stmt], [pattern], and [type_ann] node
    carries the span of the source it was parsed from. *)

type expr = { span : Emo_support.Span.t; desc : expr_desc }

and expr_desc =
  | Int of int
  | Float of float
  | Char of char
  | Bool of bool
  | String of string (* plain, interpolation-free *)
  | Interpolated of string_part list
  | Ident of string
  | Type_ident of string (* an upper ident in value position: Color, Greeter *)
  | Self
  | Member of expr * string (* x.y — also module paths: shop.order *)
  | Index of expr * expr (* a[i] *)
  | Call of expr * arg list
  | Arrow_block of
      param list * stmt list (* -> (x Int) { ... } and -> { ... } *)
  | Tuple of expr list
  | Unary of unop * expr
  | Binary of binop * expr * expr
  | Do of expr (* do <call> — the operand is always a Call node *)

and string_part = Literal_text of string | Part_expr of expr
and arg = { arg_name : string option; arg_value : expr }
and param = { param_name : string; param_type : type_ann }
and type_ann = { type_span : Emo_support.Span.t; type_desc : type_ann_desc }

and type_ann_desc =
  | Named_type of string (* Int, User *)
  | Applied_type of string * type_ann list (* Array[User], Box[Int] *)
  | Tuple_type of type_ann list (* (Int, String) *)

and unop = Not | Neg

and binop =
  | Eq
  | Ne
  | Lt
  | Le
  | Gt
  | Ge
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | And
  | Or

and stmt = { stmt_span : Emo_support.Span.t; stmt_desc : stmt_desc }

and stmt_desc =
  | Expr_stmt of expr
  | Binding of {
      mutable_ : bool; (* true = var, false = const *)
      name : string;
      init : expr;
    }
  | Return of expr option
  | If of { cond : expr; then_body : stmt list; else_body : stmt list option }
  | Case of { scrutinee : expr; branches : branch list }
  | Receive of branch list
  | Send of { target : expr; message : expr }

and branch = {
  pattern : pattern;
  guard : expr option; (* pattern when cond *)
  body : stmt list;
}

and pattern = { pattern_span : Emo_support.Span.t; pattern_desc : pattern_desc }

and pattern_desc =
  | Enum_member of string * string (* Color.red *)
  | Pattern_literal of literal
  | Pattern_binding of string
  | Wildcard
  | Tuple_pattern of pattern list

and literal =
  | L_int of int
  | L_float of float
  | L_char of char
  | L_string of string
  | L_bool of bool
