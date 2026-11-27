(def_declaration
  body: (block) @function.inside) @function.around

(class_declaration) @class.around

(enum_declaration) @class.around

(interface_declaration) @class.around

(comment)+ @comment.around
