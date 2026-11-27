; Variables (specific captures below override this one)

(identifier) @variable

(member_expression
  property: (identifier) @property)

; Keywords

[
  "def"
  "const"
  "var"
  "class"
  "interface"
  "enum"
  "emo"
  "require"
] @keyword

[
  "if"
  "else"
  "for"
  "while"
  "case"
  "when"
  "then"
  "receive"
  "return"
  "raise"
  "do"
] @keyword.control

(break_statement) @keyword.control
(continue_statement) @keyword.control

(keyword) @keyword

(boolean) @boolean
(self_expression) @variable.builtin

; Comments

(comment) @comment

((comment) @comment.documentation
  (#match? @comment.documentation "^//\\s*[#@][A-Za-z_]"))

; Functions and methods

(def_declaration
  name: (identifier) @function)

(foreign_def_declaration
  name: (identifier) @function)

(method_signature
  name: (identifier) @function)

(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (member_expression
    property: (identifier) @function.method))

; Types

(type_identifier) @type

((type_identifier) @type.builtin
  (#match? @type.builtin "^(Int64|Int32|Byte|Float64|Float32|Bool|Char|String|Bytes|Pid|Void|Block|Box|Array|TcpConn|TcpListener|UdpSocket|Exception)$"))

(class_declaration
  name: (type_identifier) @type)

(interface_declaration
  name: (type_identifier) @type)

(enum_declaration
  name: (type_identifier) @type)

(emo_declaration
  name: (type_identifier) @type)

(member_expression
  property: (type_identifier) @type)

; Enum members

(enum_declaration
  (identifier) @constant)

(enum_pattern
  (identifier) @constant)

; Parameters

(parameter
  name: (identifier) @variable.parameter)

; Literals

(string) @string
(escape_sequence) @string.escape

(interpolation
  "${" @punctuation.special
  "}" @punctuation.special)

(char_literal) @character

(integer) @number
(float) @number
(byte_literal) @number

; Operators and punctuation

[
  "||"
  "&&"
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "+"
  "-"
  "*"
  "/"
  "%"
  "&"
  "|"
  "^"
  "~"
  "!"
  "<<"
  ">>"
  "="
  "<-"
  "->"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  ":"
  "."
  ";"
] @punctuation.delimiter
