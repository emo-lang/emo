" Vim syntax file
" Language:   Emo
" Maintainer: Emo contributors <https://github.com/emo-lang/emo>
" Filenames:  *.emo
"
" Emo's rules are simple enough to state directly: names are
" lower_case with predicates ending in `?`, types are UpperCase,
" blocks are braces, and `//` is the only comment. When the language
" server is running it refines these colours with semantic tokens;
" this file is what you get without it.

if exists('b:current_syntax')
  finish
endif

syn case match

" ---- Operators -------------------------------------------------------
" Defined before the comment rule below, because Vim gives the item
" defined last priority when two of them start at the same column: a
" lone `/` here would otherwise take the first two characters of `//`
" and the comment would never get to start.

syn match emoOperator '<-\|->\|==\|!=\|<=\|>=\|<<\|>>\|&&\|||\|[+\-*/%&|^~!=<>]'

" ---- Comments --------------------------------------------------------

syn keyword emoTodo contained TODO FIXME XXX NOTE
syn match emoComment '//.*$' contains=emoTodo,@Spell

" ---- Numbers ---------------------------------------------------------
" `_` separates digits, `0x`/`0b`/`0o` pick a radix, a trailing `B`
" makes the literal a Byte, and an exponent needs a digit after it.
" The bare decimal form is defined first because Vim gives the item
" defined last priority at the same position, which is how the radix
" and Byte forms below win.

syn match emoNumber '\<[0-9][0-9_]*\>'
syn match emoNumber '\<[0-9][0-9_]*B\>'
syn match emoFloat  '\<[0-9][0-9_]*\.[0-9][0-9_]*\>'
syn match emoFloat  '\<[0-9][0-9_]*\%(\.[0-9][0-9_]*\)\?[eE][+-]\?[0-9][0-9_]*\>'
syn match emoNumber '\<0[xX][0-9a-fA-F_]\+\>'
syn match emoNumber '\<0[bB][01_]\+\>'
syn match emoNumber '\<0[oO][0-7_]\+\>'

" ---- Strings and characters ------------------------------------------

syn match emoEscape '\\[nrt\\''"]' contained

" Interpolation holds a whole expression, so braces nest inside it —
" a map literal or a block. `emoInterpBlock` is what keeps the
" interpolation from ending at that inner `}`; it carries no colour of
" its own, and neither does `emoInterp`, whose contents are coloured
" by the items inside it. Only the `${` and `}` delimiters are
" highlighted, through `matchgroup`.

syn region emoInterpBlock start='{' end='}' contained contains=ALL
syn region emoInterp matchgroup=emoInterpDelim start='\${' end='}' contained contains=ALL
syn region emoString start='"' skip='\\.' end='"' contains=emoEscape,emoInterp,emoTodo
syn region emoCharacter start="'" skip='\\.' end="'" oneline

" ---- Names -----------------------------------------------------------
" A predicate's `?` is part of its name, so each pattern spells the
" trailing `?` out instead of leaning on 'iskeyword'.

syn match emoField '\.\zs[a-z_][A-Za-z0-9_]*?\?\%(\s*(\)\@!'
syn match emoFunctionCall '\<[a-z_][A-Za-z0-9_]*?\?\ze\s*('

" The `def` is matched behind a lookbehind rather than consumed with a
" `\zs`: a pattern that starts at `def` loses to the `def` keyword, and
" then it never reaches the name it was meant to colour.

syn match emoFunction '\%(\<def\>\s\+\)\@<=[a-z_][A-Za-z0-9_]*?\?'
syn match emoType '\<[A-Z][A-Za-z0-9_]*\>'

" ---- Keywords --------------------------------------------------------
" Keywords beat matches in Vim, so `if (` stays a keyword even though
" `emoFunctionCall` would match it, and the built-in types below win
" over the general `emoType` pattern.

syn keyword emoBoolean true false
syn keyword emoConditional if else case when
syn keyword emoKeyword const def class emo enum interface require var
syn keyword emoRepeat for while
syn keyword emoSelf self
syn keyword emoStatement break continue do raise receive return
syn keyword emoTypeBuiltin Array Block Bool Box Byte Bytes Char Exception
syn keyword emoTypeBuiltin Float64 Int64 List Map Pid R String TcpConn
syn keyword emoTypeBuiltin TcpListener UdpSocket Void

" `foreign` is a soft keyword: it introduces a `foreign def` and
" nothing else.
syn match emoKeyword '\<foreign\>\ze\s\+def\>'

" ---- Highlighting ----------------------------------------------------

hi def link emoBoolean Boolean
hi def link emoCharacter Character
hi def link emoComment Comment
hi def link emoConditional Conditional
hi def link emoEscape SpecialChar
hi def link emoField Identifier
hi def link emoFloat Float
hi def link emoFunction Function
hi def link emoFunctionCall Function
hi def link emoInterpDelim SpecialChar
hi def link emoKeyword Keyword
hi def link emoNumber Number
hi def link emoOperator Operator
hi def link emoRepeat Repeat
hi def link emoSelf Statement
hi def link emoStatement Statement
hi def link emoString String
hi def link emoTodo Todo
hi def link emoType Type
hi def link emoTypeBuiltin Type

let b:current_syntax = 'emo'
