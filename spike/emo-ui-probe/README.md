# EmoUI probes: what the language gives the declarative tree

Four small programs behind the findings in
[`docs/emo-ui.md`](../../docs/emo-ui.md). They are language probes, not
a UI — each answers one question about what the tree can be spelled
as today.

Run any of them with the repo's compiler, from this directory:

```sh
../../_build/default/src/emo_cli/emo.exe run probe1_block_children.emo
# or the installed binary:
emo run probe1_block_children.emo
```

- `probe1_block_children.emo` — a trailing block that returns an array
  delivers the children; a block of child-call statements delivers
  `void`, so the children are discarded. The README's illustrative tree
  is not executable as written.
- `probe2_recursive_node.emo` — a class naming itself in its own `init`
  (`children Array[Node]`) checks, and an interface naming itself in a
  signature checks. The spike's E4005 workaround is no longer forced.
- `probe3_iteration_and_messages.emo` — iteration blocks that `return`
  the per-element node work; an enum rides on a node as the event
  identity.
- `no-defaults/probe4_no_default_params.emo` — `hello("a")` for
  `def hello(name String, count Int64)` is E4009. The style story must
  use a factory plus `with_*` copies. It sits in a nested package (its
  own `package.emo`) so the other probes' `emo run` does not compile it.
- `first_class_def/probe5_first_class_defs.emo` — a bare def (`inc`) and
  a module-qualified one (`lib.inc`) are values that satisfy a `Block`
  parameter and are callable. A per-platform entry can pass `app.view` /
  `app.update` directly. Its own nested package, same reason.

## Expected output

```console
$ emo run probe1_block_children.emo
card got: [#VNode(kind: "text:a"), #VNode(kind: "text:b")]
card
card got: void
card

$ emo run probe2_recursive_node.emo
column
2
hi

$ emo run probe3_iteration_and_messages.emo
2
user: ada
increment

$ (cd first_class_def && emo run probe5_first_class_defs.emo)
2
11
```

`probe4` is a negative check: `cd no-defaults && emo check
probe4_no_default_params.emo` reports E4009.
