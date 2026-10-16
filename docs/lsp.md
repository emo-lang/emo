# The Emo Language Server

Emo ships with a Language Server Protocol implementation, `emo-lsp`, and editor
integrations that drive it: a Visual Studio Code extension and a Neovim plugin.
Together they provide syntax highlighting, completion, diagnostics, hover,
navigation, and package management for `.emo` sources.

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
npx @vscode/vsce package       # produces emo-tools-lsp-0.2.2.vsix
```

Install the resulting `.vsix` with
`code --install-extension emo-tools-lsp-0.2.2.vsix` or through the Extensions
view's *Install from VSIX*.

The client finds the server in this order:

1. the `emo.serverPath` setting,
2. the `server/emo-lsp` binary bundled in the extension,
3. `emo-lsp` on the `PATH`.

The registry used for package completion and dependency resolution comes from
`emo.registry`, then `EMO_REGISTRY`, then the bundled `server/registry`.

## The Neovim plugin

The plugin lives under [`editors/neovim`](../editors/neovim). It is a plain
Neovim package — a Vim syntax file, an indent expression, and a small LSP
client — and requires Neovim 0.11 or newer, for `vim.lsp.config` and
`vim.lsp.enable`.

```sh
editors/neovim/scripts/build-server.sh   # builds emo-lsp in this checkout
```

Put the plugin directory on the runtimepath and, optionally, configure it:

```lua
vim.opt.runtimepath:prepend('/path/to/emo/editors/neovim')
require('emo').setup({
  server_path = '/path/to/emo-lsp',
  emo_path = '/path/to/emo',
  registry = '/path/to/emo/stdlib/registry',
})
```

It finds the server in the `server_path` option, then `emo-lsp` on the `PATH`,
then a build inside the Emo checkout. The registry comes from `registry`, then
`EMO_REGISTRY`; the `emo` CLI behind the `:Emo*` commands comes from
`emo_path`, then `EMO_BIN`. `:checkhealth emo` reports what was resolved.

The commands mirror the extension's — `:EmoRestart`, `:EmoCheck`, `:EmoBuild`,
`:EmoRun`, `:EmoDepsResolve`, `:EmoDepsList`, `:EmoDepsUpdate`, and
`:EmoPackageInit`. See
[`editors/neovim/README.md`](../editors/neovim/README.md) for the full list and
the options table.

## Features

- **Syntax highlighting.** A TextMate grammar (VS Code) or a Vim syntax file
  (Neovim) covers keywords, declarations, string interpolation, `predicate?`
  names, and the language's case conventions. The server additionally emits
  semantic tokens so user-defined classes, enums, interfaces, functions, and
  parameters are coloured consistently.
- **Completion.** Keywords, built-in types and functions, declarations from
  the current file and the project, members after `.` (class fields and
  methods, function-group members, module members), and package names inside
  `require "..."`.
- **Diagnostics.** Lex, parse, and type-check errors, plus a check that every
  scoped `require` is paired with a `deps` entry in `package.emo` (E5006) and
  that an unscoped `require` names a published standard-library package
  (E5009). The pairing error carries a quick fix that adds the dependency. A
  buffer outside any package — no `package.emo` at the root the server was
  given — gets none of them: no project is indexed there, and one message
  says so rather than leaving the silence unexplained.
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

- **The directory tree is the module tree.** The server indexes a project only
  when the root it was given holds `package.emo` — the root the compiler would
  occupy, which is where you stand and never an ancestor it guesses at. It
  then indexes every `.emo` file under that root, skipping a nested directory
  that carries a manifest of its own, exactly as the compiler discovers
  modules. A root without a manifest is not a project: the server publishes no
  diagnostics for it and says so once — a `window/showMessage` warning when
  `initialize` finds none, and a deduplicated `window/logMessage` per
  manifest-less directory a buffer arrives in, pointing at `emo.package.init`.
- **Unsaved buffers win.** Completion, hover, and diagnostics use the open
  document's text; the on-disk project index supplies everything else.
- **Positions are UTF-16.** Emo spans are byte offsets into UTF-8 source; the
  server converts at every boundary, so non-ASCII sources (Emo examples
  include Chinese text) map correctly.
- **The client is optional.** Any LSP client can use `emo-lsp`; syntax
  highlighting lives in the grammar, not the server.
