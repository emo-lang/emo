# The `template` Package

A text template engine in pure Emo: text with holes, rendered from a
`json` context — the shape of Go's `text/template` with Emo's own
surface, so every hosted target answers identically, byte for byte.
Server-rendered pages (`httpd`), emails, reports, and generated config
all render through it. There is no runtime `eval` anywhere in the
engine, and the checker never sees a template's expressions — a
template's expressions are data paths over the json tree, never Emo
code.

## Using the package

```emo
require "template"
```

with the manifest pinning the exact version:

```emo
deps {
  "json" = "0.1.0"
  "template" = "0.1.0"
}
```

## The surface

```emo
def render(text String, ctx json.Json) (R, String)   // one-shot: parse + render
def new() Set                                        // an empty set

// Set:
def with(name String, text String) (R, Set)          // parse `text` as `name`
def render(name String, ctx json.Json) (R, String)   // render one member
```

`template.render(text, ctx)` is the render-once door: it parses and
renders in one call. The `Set` is the parse-once-render-many shape —
build it at startup with `with` (each call parses, so a malformed
template refuses before the first render), then render by name per
request. `with` answers the new set (the builder-copy shape), and
redefining a name refuses — a silent replacement is a mistake the
caller should see.

A template is text with **actions**. `{{ user.name }}` renders a value
from the context; `{{ name | upper }}` runs a pipeline of filters over
it; `{{ if }}` / `{{ else if }}` / `{{ else }}` / `{{ end }}` choose;
`{{ for x in e }}` ranges an array or an object; `{{ template "name"
e? }}` includes a named template from the set; `{{- ` and ` -}}` trim
the neighboring whitespace; `{{! ... }}` comments.

```emo
const text = "Hello, {{ user.name | upper }} of {{ user.city }}!"
const ctx = json.object(entries: [
  ("user", json.object(entries: [
    ("name", json.string("ada")),
    ("city", json.string("上海"))
  ]))
])
case template.render(text, ctx) {
  (R.error, why) -> { println("refused: " + why) }
  (R.ok, out)    -> { println(out) }        // Hello, ADA of 上海!
}
```

## The context is the json tree

`ctx` is a `json.Json` — the value tree the `json` package decodes and
encodes — so `json.decode(text)` renders directly, and a program's own
records render through the same constructors (`json.string`,
`json.int64`, `json.object`, `json.array`, ...). The context root must
be an object: its keys are the paths a template names.

The value split — what a hole renders, and what it refuses:

- A **string** renders verbatim.
- An **integer** renders decimal (`3` → `3`).
- A **float** renders through the `float` package's exact-decimal text,
  the same text `json.encode` writes — `19.5` → `19.5`.
- A **boolean** renders `true` / `false`.
- A **null** refuses: `template: at byte 214, `user.nick` is null and
  cannot render`. A null hole is almost always a data-shape surprise;
  guard it (`{{ if user.nick }}...{{ end }}`) or supply a fallback
  (`{{ user.nick | default("anon") }}`).
- An **array or object** refuses (`... is an array and cannot render`)
  — iterate it with `{{ for }}`, or use `| length` / `| join`.

## Paths

A path is a bare dotted name with optional bracket accessors — no Go
dot, no `$`:

```emo
{{ title }}            // a root key
{{ user.name }}        // dotted: object key by key
{{ users[0].name }}    // array index (0-based, bounds-checked)
{{ m["a b"] }}         // a quoted key (the language's string escapes)
```

The **first segment** resolves to the nearest enclosing `for` binding
with that name, else the context root's key; deeper segments walk
data. There is no parent walking, no scope chain through data, and no
root escape: a binding shadows the root's same-named key, and the
author names bindings to avoid the collision. Inside a loop, bare
names still reach the root (`{{ title }}` works inside
`{{ for u in users }}`) — but the loop element needs its binding
spelled: `{{ u.name }}`.

Every resolution is checked at render time. A missing key, a wrong
kind mid-path, and an out-of-bounds index all answer
`(R.error, reason)` naming the path, the byte, and the fact:

```emo
{{ user.phone }}       // `user.phone`: the object holds no key `phone`
{{ user.name.first }}  // `user.name` is a string, not an object
{{ tags[5] }}          // `tags[5]`: index 5 of 2
```

## Truthiness

`{{ if }}` and `{{ for }}`'s emptiness follow one rule — **not the
zero value**: `null`, `false`, `0`, `0.0`, the empty string, an empty
array, and an empty object are false; everything else is true.

```emo
{{ if tags }}Tags: {{ tags | join(", ") }}{{ end }}
{{ if premium }}premium{{ else if trial }}trial{{ else }}free{{ end }}
```

`{{ for }}` takes a body and an optional `{{ else }}` for the empty
case (zero elements, or zero entries):

```emo
{{ for i, t in tags }}{{ i }}:{{ t }} {{ end }}     // 0:go 1:emo
{{ for k, v in flags }}{{ k }}={{ v }} {{ end }}    // bold=true italic=false
{{ for x in empty }}row{{ else }}nothing{{ end }}
```

The binding forms: **one name** binds the element (an array) or the
value (an object); **two names** bind the index and the element, or
the key and the value. Ranging anything but an array or an object
refuses — a null source included, so an optional list is guarded with
`{{ if }}` like a null hole is.

## Includes

`{{ template "name" }}` renders a named template from the same set.
With no pipeline, the included template's context root is the calling
template's root context; with one, the pipeline's value becomes the
included template's root — the dot semantics minus the dot. Bindings
never cross the edge: the included template sees only its root.

```emo
const (R.ok, s1) = template.new().with("page", "{{ template \"header\" }}{{ for r in rows }}{{ template \"row\" r }}{{ end }}{{ template \"footer\" }}")
const (R.ok, s2) = s1.with("header", "# {{ title }}\n")
const (R.ok, s3) = s2.with("row", "- {{ item }} x{{ qty }}\n")
const (R.ok, set) = s3.with("footer", "total: {{ rows | length }} rows\n")
```

An undefined name refuses at render (`no template named `ghost``), an
include cycle rides to the depth cap (64) and the reason names the
chain it refused, and a render error inside an included template
carries its name: `template: in `row`, ...`.

## Trim markers and comments

`{{- ` trims all trailing whitespace of the text before the action;
` -}}` trims all leading whitespace of the text after it. Both ride
the action they touch; the dash must touch the delimiter
(`{{- if x }}...{{ end -}}`). `{{! ... }}` is a comment — it renders
nothing and ends at the first `}}`.

```emo
"A\n  {{- if bold -}}\n  B\n  {{- end -}}\n  C"   // renders ABC
"x{{! a note }}y"                                  // renders xy
```

## The filters

Seven, fixed and ASCII-safe — the language's own `String.lower` is
ASCII, and a Unicode case mapper waits for cross-target-identical
tables:

```emo
{{ name | upper }}          // ASCII uppercase
{{ name | lower }}          // ASCII lowercase
{{ padded | trim }}         // ASCII whitespace off both ends
{{ tags | length }}         // an array's items, an object's entries, a string's bytes
{{ tags | join(", ") }}     // elements rendered by the hole rules, then joined
{{ nick | default("anon") }} // only null falls through — "" is a value
{{ bio | escape_html }}     // & < > " ' → &amp; &lt; &gt; &quot; &#39;
```

Pipelines chain left to right (`{{ tags | join("|") | lower }}`), and
a filter's arguments are paths or `String` / `Int64` / `Bool` literals
(`{{ scores[0] | default(0) }}`). A wrong kind refuses at render with
the filter's name and the kind it got
(`` `upper` expects a string, got a float ``).

There is no custom filter table, no arithmetic, and no comparison: a
filter argument can't compute, and `{{ a > b }}` is not a thing. The
template renders; the program computes — precompute in Emo and put the
result in the context.

## Errors

Every failure is the value `(R.error, reason)`; nothing raises. The
reason carries the package prefix, the fact, and the byte position in
the template; a render error inside an included template names it
(`in `row`, `); the include depth cap names the chain.

Parsing is strict (the `dom.parse` direction): an unclosed `{{`, an
empty action, an unmatched `{{ end }}` / `{{ else }}`, a `{{ for }}`
missing its `in`, an unknown filter name, a wrong filter arity, a
dangling `.` or `[`, an unclosed string or comment, a reserved word in
a path, and nesting deeper than 512 all refuse at parse — never a
repaired tree. A bare `}}` outside an action is text, not an error —
code-generation templates close nested braces in their static text.

## Boundaries

- **Targets:** all five — `ocaml`, `c`, `typescript`, `wasm`, `beam`
  (pure Emo over strings, arrays, and the json tree).
- **Templates live in strings** — a file's text rides `file.read` into
  the same `with` call; the package reads no filesystem of its own.
- **The language has no clock**, so there is no date filter; a
  timestamp arrives as data and is formatted by the program.
- `escape_html` is explicit, not automatic — contextual HTML
  auto-escaping (the `html/template` machine) is a later arc, with the
  `dom` package as the likely foundation.

Reference: [`docs/stdlib/template.md`](template.md) ·
Demo: `examples/template_demo`, `examples/template_edge`.
