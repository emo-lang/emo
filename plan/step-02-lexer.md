# Step 02 — Lexer

**Milestone:** M1 · **Prereq:** step 01 · **Status:** done

## Goal

A hand-written lexer that turns `.emo` source into a fully positioned token
stream, covering the whole surface the MVP needs: literals (including string
interpolation), two identifier classes, operators, and comments.

Hand-written rather than menhir/sedlex: newline sensitivity and interpolated
strings both want manual control, and the grammar has no LR hazards to offload
(calls always carry parentheses by design).

## Scope

### In

- **Token kinds**
  - Literals: `INT` (decimal), `FLOAT` (must contain a `.`, e.g. `1.0`),
    `CHAR` (`'a'`), string parts for interpolation (below), `true` / `false`.
  - Identifiers in two lexically distinct classes:
    `LOWER_IDENT` (`[a-z_][a-z0-9_]*`, may end in `?`, e.g. `is_older?`) and
    `UPPER_IDENT` (`[A-Z][A-Za-z0-9_]*`). The naming-convention enforcement
    itself happens in the parser/checker; the lexer only keeps the classes
    apart so later stages never have to re-derive them.
  - Keywords: `def const var class interface enum if else case when receive return raise self do`.
  - Operators / punctuation:
    `( ) { } [ ] , : . -> <- = == != < <= > >= + - * / % && || !`.
    `<-` (message send) is **space-delimited**: it is recognized as the
    send operator only with whitespace on both sides (`a <- b`). Every
    juxtaposed form — `a<-b`, `a <-b`, `a<- b` — is a lexical error with
    a hint toward the intended form; the lexer never guesses between send
    and less-than-negative. Comparison against a negated value is
    `a < -b`, where `<` and `-` are never adjacent.
- **String interpolation** — single form `"text ${expr} text"`. Lexer scheme:
  on `"`, scan literal chunks; on `${` emit a marker and switch to normal
  lexing until the matching `}` (brace-depth counted, so nested strings and
  blocks interpolate correctly), then resume chunk scanning until the closing
  `"`. The parser reassembles the pieces in step 03. Unterminated strings and
  unterminated `${` are lexical errors with precise spans.
- **Char escapes** — minimal provisional set: `\n \t \\ \' \"`. Anything else
  is an error (strictness first).
- **Comments** — `//` to end of line; no block comments.
- **No direct paren nesting (lexical law)** — a `(` token immediately
  followed by another `(` token is an error: `((x))` and `f((a, b))`
  never lex into valid programs. The error message suggests binding the
  inner value to a name. Patterns obey the same law; nesting after a
  comma (`(a, (b, c))`) is unaffected.
- **Newlines are not skipped**: every token carries `start`/`stop` positions,
  and the token stream exposes newline information so the parser can apply
  statement-termination rules (step 03).
- Reject clear lexical errors early: stray `@ $ ; #` (no semicolons in
  Emo; `#` has no meaning),
  illegal identifier shapes (`9x`, `CamelCase` in expression position is a
  parser matter, but `1_a` is lexical), unterminated char (`'ab'`).

### Out

- Number formats beyond decimal (hex, binary, separators) — undecided, not
  built.
- Raw strings — undecided (`CHECK.md`), not built.
- Block comments, doc comments.

## Tasks

- [x] Token type + positioned token stream in `emo_lexer`.
- [x] Identifier classes, keywords, operators.
- [x] Numeric and char literals with escape handling.
- [x] Interpolated-string token scheme with nesting tests.
- [x] Newline-preserving stream API.
- [x] Error cases: each rejects with correct line:col via `emo_support`.

## Acceptance

- Alcotest suites cover: every token kind, interpolation nesting
  (`"a ${ "b ${x}" } c"`), position fidelity on multi-line input, and every
  error case.
- `dune test` green.

## Open design items

- String escape rules are pending (`CHECK.md`). The minimal set above is the
  provisional decision; extend it when the design settles.
