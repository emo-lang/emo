[
  (block)
  (map)
  (array)
  (tuple)
  (tuple_type)
  (parameter_list)
  (argument_list)
] @indent.begin

(block
  "}" @indent.end)

(map
  "}" @indent.end)

(array
  "]" @indent.end)

(tuple
  ")" @indent.end)

(tuple_type
  ")" @indent.end)

(parameter_list
  ")" @indent.end)

(argument_list
  ")" @indent.end)

(comment) @indent.ignore
