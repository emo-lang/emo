const PREC = {
  or: 1,
  and: 2,
  comparison: 3,
  additive: 4,
  multiplicative: 5,
  unary: 6,
  postfix: 7,
};

module.exports = grammar({
  name: 'emo',

  word: $ => $.identifier,

  extras: $ => [/\s/, $.comment],

  supertypes: $ => [$._expression],

  conflicts: $ => [
    [$.return_statement],
    [$._path_segment, $._primary],
    [$.literal_pattern, $._primary],
    [$.binding_pattern, $._primary],
    [$.tuple_pattern, $.tuple],
    [$._primary, $._condition_primary],
  ],

  rules: {
    source_file: $ => repeat($._item),

    comment: $ => token(seq('//', /.*/)),

    _item: $ => choice(
      $.require_declaration,
      $.foreign_def_declaration,
      $.def_declaration,
      $.class_declaration,
      $.emo_declaration,
      $.interface_declaration,
      $.enum_declaration,
      $._statement,
    ),

    require_declaration: $ => seq('require', field('package', $.string)),

    foreign_def_declaration: $ => seq(
      alias('foreign', $.keyword),
      'def',
      field('name', $.identifier),
      field('parameters', $.parameter_list),
      field('return_type', $.type),
      '=',
      field('symbol', $.string),
    ),

    def_declaration: $ => seq(
      'def',
      field('name', $.identifier),
      field('parameters', $.parameter_list),
      optional(field('return_type', $.type)),
      field('body', $.block),
    ),

    class_declaration: $ => seq(
      'class',
      field('name', $.type_identifier),
      '{',
      repeat($.def_declaration),
      '}',
    ),

    emo_declaration: $ => prec(1, seq(
      'emo',
      field('name', $.type_identifier),
      '{',
      repeat(choice($.def_declaration, $.const_binding)),
      '}',
    )),

    interface_declaration: $ => seq(
      'interface',
      field('name', $.type_identifier),
      '{',
      repeat($.method_signature),
      '}',
    ),

    method_signature: $ => seq(
      'def',
      field('name', $.identifier),
      field('parameters', $.parameter_list),
      field('return_type', $.type),
    ),

    enum_declaration: $ => seq(
      'enum',
      field('name', $.type_identifier),
      '{',
      commaSep1($.identifier),
      '}',
    ),

    parameter_list: $ => seq('(', commaSep($.parameter), ')'),

    parameter: $ => seq(
      field('name', $.identifier),
      field('type', $.type),
    ),

    type: $ => choice(
      $._named_type_path,
      $.applied_type,
      $.tuple_type,
    ),

    _named_type_path: $ => choice(
      $.type_identifier,
      seq(field('module', $.identifier), '.', $._named_type_path),
    ),

    applied_type: $ => seq(
      $._named_type_path,
      '[',
      commaSep1($.type),
      ']',
    ),

    tuple_type: $ => seq('(', commaSep($.type), ')'),

    _statement: $ => choice(
      $.while_statement,
      $.for_statement,
      $.case_statement,
      $.receive_statement,
      $.binding_statement,
      $.send_statement,
      $.assignment,
      $.return_statement,
      $.raise_statement,
      $.break_statement,
      $.continue_statement,
      $.sugar_statement,
      $.expression_statement,
    ),

    expression_statement: $ => $._expression,

    if_expression: $ => seq(
      'if',
      field('condition', $._condition_expression),
      field('consequence', $.block),
      optional(seq('else', field('alternative', $.block))),
    ),

    while_statement: $ => seq(
      'while',
      field('condition', $._condition_expression),
      field('body', $.block),
    ),

    for_statement: $ => seq(
      'for',
      field('init', choice($.for_binding, $.for_assignment, $._condition_expression)),
      ';',
      field('condition', $._condition_expression),
      ';',
      field('post', choice($.for_assignment, $._condition_expression)),
      field('body', $.block),
    ),

    for_binding: $ => seq(
      choice('const', 'var'),
      field('pattern', $.pattern),
      '=',
      field('value', $._condition_expression),
    ),

    for_assignment: $ => seq(
      field('target', $._condition_expression),
      '=',
      field('value', $._condition_expression),
    ),

    case_statement: $ => seq(
      'case',
      field('value', $._condition_expression),
      '{',
      repeat($.branch),
      '}',
    ),

    receive_statement: $ => seq(
      'receive',
      '{',
      repeat($.branch),
      '}',
    ),

    branch: $ => seq(
      field('pattern', $.pattern),
      optional(seq('when', field('guard', $._expression))),
      'then',
      field('body', $.block),
    ),

    binding_statement: $ => seq(
      choice('const', 'var'),
      field('pattern', $.pattern),
      '=',
      field('value', $._expression),
    ),

    const_binding: $ => seq(
      'const',
      field('pattern', $.pattern),
      '=',
      field('value', $._expression),
    ),

    assignment: $ => seq(
      field('target', $._expression),
      '=',
      field('value', $._expression),
    ),

    send_statement: $ => seq(
      field('target', $._expression),
      '<-',
      field('message', $._expression),
    ),

    return_statement: $ => seq('return', optional(field('value', $._expression))),

    raise_statement: $ => seq('raise', field('value', $._expression)),

    break_statement: $ => 'break',

    continue_statement: $ => 'continue',

    sugar_statement: $ => choice(
      $.chain_sugar,
      $.foreach_sugar,
      $.raise_sugar,
      $.when_sugar,
    ),

    chain_sugar: $ => seq(
      ':',
      'chain',
      field('steps', $.chain_steps),
      optional(seq('then', field('then_body', $.block))),
      optional(seq('else', field('else_body', $.case_body))),
    ),

    chain_steps: $ => seq('{', repeat(choice($.chain_from_step, $._statement)), '}'),

    chain_from_step: $ => seq(
      field('pattern', $.pattern),
      'from',
      field('value', $._expression),
    ),

    case_body: $ => seq('{', repeat($.branch), '}'),

    foreach_sugar: $ => seq(
      ':',
      'foreach',
      field('element', $.pattern),
      'in',
      field('iterable', $._condition_expression),
      field('body', $.block),
    ),

    raise_sugar: $ => seq(
      ':',
      'raise',
      field('message', $._expression),
      optional(seq(',', field('data', $._expression))),
    ),

    when_sugar: $ => seq(
      ':',
      'when',
      field('value', $._condition_expression),
      '{',
      field('pattern', $.pattern),
      'then',
      field('body', $.block),
      '}',
    ),

    block: $ => seq('{', repeat($._statement), '}'),

    pattern: $ => choice(
      $.wildcard,
      $.binding_pattern,
      $.enum_pattern,
      $.literal_pattern,
      $.tuple_pattern,
    ),

    wildcard: $ => token(prec(1, '_')),

    binding_pattern: $ => $.identifier,

    enum_pattern: $ => prec(1, seq(
      $._path_segment,
      '.',
      $._path_segment,
      repeat(seq('.', $._path_segment)),
    )),

    _path_segment: $ => choice($.identifier, $.type_identifier),

    literal_pattern: $ => choice(
      $.integer,
      $.float,
      $.byte_literal,
      $.char_literal,
      $.boolean,
      $.string,
    ),

    tuple_pattern: $ => seq('(', commaSep($.pattern), ')'),

    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.attached_block,
      $.arrow_attached,
      $._primary,
    ),

    _primary: $ => choice(
      $.integer,
      $.float,
      $.byte_literal,
      $.char_literal,
      $.boolean,
      $.string,
      $.identifier,
      $.type_identifier,
      $.self_expression,
      $.emo_value,
      $.array,
      $.map,
      $.tuple,
      $.call_expression,
      $.member_expression,
      $.index_expression,
      $.if_expression,
      $.arrow_block,
      $.do_expression,
      $.interpolation,
    ),

    _condition_expression: $ => choice(
      $.condition_binary,
      $.condition_unary,
      $._condition_primary,
    ),

    _condition_primary: $ => choice(
      $.integer,
      $.float,
      $.byte_literal,
      $.char_literal,
      $.boolean,
      $.string,
      $.identifier,
      $.type_identifier,
      $.self_expression,
      $.emo_value,
      $.array,
      $.map,
      $.tuple,
      $.call_expression,
      $.member_expression,
      $.index_expression,
      $.if_expression,
      $.arrow_block,
      $.do_expression,
      $.interpolation,
    ),

    condition_binary: $ => choice(
      prec.left(PREC.or, seq(field('left', $._condition_expression), '||', field('right', $._condition_expression))),
      prec.left(PREC.and, seq(field('left', $._condition_expression), '&&', field('right', $._condition_expression))),
      prec.left(PREC.comparison, seq(field('left', $._condition_expression), field('operator', choice('==', '!=', '<', '<=', '>', '>=')), field('right', $._condition_expression))),
      prec.left(PREC.additive, seq(field('left', $._condition_expression), field('operator', choice('+', '-', '&', '|', '^')), field('right', $._condition_expression))),
      prec.left(PREC.multiplicative, seq(field('left', $._condition_expression), field('operator', choice('*', '/', '%', '<<', '>>')), field('right', $._condition_expression))),
    ),

    condition_unary: $ => prec(PREC.unary, seq(
      field('operator', choice('!', '-', '~')),
      field('operand', $._condition_expression),
    )),

    binary_expression: $ => choice(
      prec.left(PREC.or, seq(field('left', $._expression), '||', field('right', $._expression))),
      prec.left(PREC.and, seq(field('left', $._expression), '&&', field('right', $._expression))),
      prec.left(PREC.comparison, seq(field('left', $._expression), field('operator', choice('==', '!=', '<', '<=', '>', '>=')), field('right', $._expression))),
      prec.left(PREC.additive, seq(field('left', $._expression), field('operator', choice('+', '-', '&', '|', '^')), field('right', $._expression))),
      prec.left(PREC.multiplicative, seq(field('left', $._expression), field('operator', choice('*', '/', '%', '<<', '>>')), field('right', $._expression))),
    ),

    unary_expression: $ => prec(PREC.unary, seq(
      field('operator', choice('!', '-', '~')),
      field('operand', $._expression),
    )),

    call_expression: $ => prec(PREC.postfix, seq(
      field('function', $._expression),
      field('arguments', $.argument_list),
    )),

    member_expression: $ => prec(PREC.postfix, seq(
      field('object', $._expression),
      '.',
      field('property', choice($.identifier, $.type_identifier)),
    )),

    index_expression: $ => prec(PREC.postfix, seq(
      field('object', $._expression),
      '[',
      field('index', $._expression),
      ']',
    )),

    attached_block: $ => prec(PREC.postfix, seq(
      field('callee', $._expression),
      field('body', $.block),
    )),

    arrow_attached: $ => prec(PREC.postfix, seq(
      field('function', $.call_expression),
      field('block', $.arrow_block),
    )),

    argument_list: $ => seq('(', commaSep($.argument), ')'),

    argument: $ => seq(
      optional(seq(field('name', $.identifier), ':')),
      field('value', $._expression),
    ),

    array: $ => seq('[', commaSep($._expression), ']'),

    map: $ => seq('{', commaSep($.map_entry), '}'),

    map_entry: $ => seq(
      field('key', $._expression),
      ':',
      field('value', $._expression),
    ),

    tuple: $ => seq('(', commaSep($._expression), ')'),

    arrow_block: $ => seq(
      '->',
      field('parameters', $.parameter_list),
      field('body', $.block),
    ),

    do_expression: $ => seq('do', field('call', $._expression)),

    self_expression: $ => 'self',

    emo_value: $ => 'emo',

    interpolation: $ => seq('${', field('value', $._expression), '}'),

    boolean: $ => choice('true', 'false'),

    integer: $ => token(choice(
      /0[xX][0-9a-fA-F](_?[0-9a-fA-F])*/,
      /0[bB][01](_?[01])*/,
      /0[oO][0-7](_?[0-7])*/,
      /[0-9](_?[0-9])*/,
    )),

    float: $ => token(choice(
      seq(/[0-9](_?[0-9])*/, '.', /[0-9](_?[0-9])*/, optional(/[eE][+-]?[0-9](_?[0-9])*/)),
      seq(/[0-9](_?[0-9])*/, /[eE][+-]?[0-9](_?[0-9])*/),
    )),

    byte_literal: $ => token(prec(1, /[0-9](_?[0-9])*B/)),

    char_literal: $ => token(seq("'", choice(/\\./, /[^'\\\n]/), "'")),

    string: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        $.interpolation,
        token.immediate(prec(1, /[^"\\$\n]+/)),
        token.immediate('$'),
      )),
      '"',
    ),

    escape_sequence: $ => token.immediate(seq('\\', choice('n', 'r', 't', '\\', "'", '"'))),

    identifier: $ => /[a-z_][a-zA-Z0-9_]*\??/,

    type_identifier: $ => /[A-Z][a-zA-Z0-9_]*/,
  },
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
