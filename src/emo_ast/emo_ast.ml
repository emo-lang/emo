(** The Emo syntax tree. Every [expr], [stmt], [pattern], [type_ann], and [item]
    node carries the span of the source it was parsed from. *)

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
  | Assign of {
      target : expr; (* a variable, or a self field inside init *)
      value : expr;
    }
  | Return of expr option
  | Raise of expr
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

type item = { item_span : Emo_support.Span.t; item_desc : item_desc }
(** A top-level item: a declaration, or a statement executed in order. *)

and item_desc =
  | Item_stmt of stmt
  | Item_def of fun_def
  | Item_class of class_def
  | Item_interface of interface_def
  | Item_enum of enum_def

and fun_def = {
  def_span : Emo_support.Span.t;
  def_name : string;
  def_params : param list;
  def_return : type_ann option;
  def_body : stmt list;
}
(** A `def` — at top level, in a class, or the class's `init` (whose return type
    is [None]; it returns the class it constructs). *)

and method_sig = {
  sig_span : Emo_support.Span.t;
  sig_name : string;
  sig_params : param list;
  sig_return : type_ann;
}
(** A method signature inside an `interface` — a name, parameters, and a
    required return type, with no body. *)

and class_def = {
  class_span : Emo_support.Span.t;
  class_name : string;
  class_init : fun_def option; (* None for stateless classes *)
  class_methods : fun_def list;
  class_fields : field list;
}
(** A `class`: at most one [class_init] (a duplicate is an error), any number of
    methods, and the fields [class_init] assigns. *)

and field = { field_name : string; field_span : Emo_support.Span.t }

and interface_def = {
  interface_span : Emo_support.Span.t;
  interface_name : string;
  interface_methods : method_sig list;
}

and enum_def = {
  enum_span : Emo_support.Span.t;
  enum_name : string;
  enum_members : member list;
}

and member = { member_name : string; member_span : Emo_support.Span.t }
