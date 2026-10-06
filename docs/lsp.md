# The Emo Language Server

Emo ships with a Language Server Protocol implementation, `emo-lsp`, and a
Visual Studio Code extension that drives it. Together they provide syntax
highlighting, completion, diagnostics, hover, navigation, and package
management for `.emo` sources.

## Building the server

The server is an OCaml executable in the same tree as the compiler:

```sh
dune build bin/emo_lsp_bin.exe        # produces _build/default/bin/emo_lsp_bin.exe
dune install                          # installs `emo-lsp` alongside `emo`
```

`emo-lsp` speaks LSP over stdio and is protocol-compatible with any LSP
client; the VS Code extension is one of them.

The server is a thin layer over the compiler's own libraries:

| Concern | Library used |
| --- | --- |
| Lexing and tokens | `emo_lexer` |
| Parsing | `emo_parser`, `emo_ast` |
| Diagnostics and signatures | `emo_check` |
| Manifests, registries, resolution | `emo_pkg` |
| Positions, URIs, spans | `emo_support`, `lsp_util` |

Because it reuses the compiler's passes, the diagnostics the editor shows are
the diagnostics `emo check` produces — there is no second, editor-only
analyzer to drift out of sync.

## The VS Code extension

The extension lives under [`editors/vscode`](../editors/vscode). It contains a
TextMate grammar (syntax highlighting), a language configuration, snippets,
and a small LSP client.

```sh
cd editors/vscode
npm install
npm run build                  # bundles the client into out/extension.js
bash scripts/install-server.sh # stages emo-lsp and the stdlib registry
npx @vscode/vsce package       # produces emo-lsp-0.1.0.vsix
```

Install the resulting `.vsix` with `code --install-extension emo-lsp-0.1.0.vsix`
or through the Extensions view's *Install from VSIX*.

The client finds the server in this order:

1. the `emo.serverPath` setting,
2. the `server/emo-lsp` binary bundled in the extension,
3. `emo-lsp` on the `PATH`.

The registry used for package completion and dependency resolution comes from
`emo.registry`, then `EMO_REGISTRY`, then the bundled `server/registry`.

## Features

- **Syntax highlighting.** A TextMate grammar covers keywords, declarations,
  string interpolation, `predicate?` names, and the language's case
  conventions. The server additionally emits semantic tokens so user-defined
  classes, enums, interfaces, functions, and parameters are coloured
  consistently.
- **Completion.** Keywords, built-in types and functions, declarations from
  the current file and the project, members after `.` (class fields and
  methods, function-group members, module members), and package names inside
  `require "..."`.
- **Diagnostics.** Lex, parse, and type-check errors, plus a check that every
  `require` is paired with a `deps` entry in `package.emo` (E5006). The
  pairing error carries a quick fix that adds the dependency.
- **Hover and go-to-definition.** Signatures and cross-module jumps.
- **Document and workspace symbols.** A file outline and project-wide symbol
  search.
- **Package management.** A *Emo Packages* view lists the manifest's
  dependencies, the locked versions, and the versions the registry publishes,
  and commands wrap `emo deps resolve` / `update` / `list`, `emo check`,
  `emo build`, and `emo run`.

## Protocol extensions

Beyond the standard methods, the server implements two Emo-specific ones used
by the extension's package view:

- `emo/packageInfo` — request. Takes `{ "root": string }` and returns the
  parsed manifest (name, version, targets, dependencies), each dependency's
  locked version and checksum from `package.lock`, and the versions available
  in the registry.
- `workspace/executeCommand` — the commands `emo.deps.resolve`,
  `emo.deps.update`, `emo.deps.list`, `emo.package.init`, `emo.check`,
  `emo.build`, and `emo.run`. Each returns `{ "ok": bool, "code": int,
  "output": string }`.

## Design notes

- **The directory tree is the module tree.** The server roots the project at
  the nearest `package.emo` (falling back to the client's workspace root) and
  indexes every `.emo` file under it, exactly as the compiler discovers
  modules.
- **Unsaved buffers win.** Completion, hover, and diagnostics use the open
  document's text; the on-disk project index supplies everything else.
- **Positions are UTF-16.** Emo spans are byte offsets into UTF-8 source; the
  server converts at every boundary, so non-ASCII sources (Emo examples
  include Chinese text) map correctly.
- **The client is optional.** Any LSP client can use `emo-lsp`; syntax
  highlighting lives in the grammar, not the server.
