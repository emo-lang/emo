(def_declaration
  "def" @context
  name: (identifier) @name) @item

(foreign_def_declaration
  "def" @context
  name: (identifier) @name) @item

(method_signature
  "def" @context
  name: (identifier) @name) @item

(class_declaration
  "class" @context
  name: (type_identifier) @name) @item

(emo_declaration
  "emo" @context
  name: (type_identifier) @name) @item

(interface_declaration
  "interface" @context
  name: (type_identifier) @name) @item

(enum_declaration
  "enum" @context
  name: (type_identifier) @name) @item
