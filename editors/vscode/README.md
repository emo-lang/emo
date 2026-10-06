# Emo for Visual Studio Code

Language support for the [Emo programming language](https://github.com/emo-lang/emo):
syntax highlighting, code completion, live diagnostics, hover, go-to-definition,
document symbols, semantic tokens, and package management.

## Features

- **Syntax highlighting** — a TextMate grammar for `.emo` files, with string
  interpolation, `predicate?` names, and the language's case conventions.
- **Semantic tokens** — the language server refines the grammar's colours for
  user-defined classes, enums, interfaces, functions, and parameters.
- **Code completion** — keywords, built-in types and functions, declarations
  from the current file and the project, members after `.` (class methods and
  fields, group members, module members), and package names inside
  `require "..."`.
- **Diagnostics** — lex, parse, and type errors from the compiler, plus
  manifest/`require` pairing errors, published as you type.
- **Hover and go-to-definition** — signatures and jump-to-declaration across
  the project's module tree.
- **Document and workspace symbols** — an outline for the current file and
  fuzzy project-wide symbol search.
- **Package management** — an *Emo Packages* view, quick fixes that add a
  missing dependency to `package.emo`, and commands for
  `emo deps resolve` / `update` / `list`, `emo check`, `emo build`, and
  `emo run`.

## Requirements

The extension drives the `emo-lsp` language server. The server is written in
OCaml and ships with the Emo compiler. To build it:

```sh
dune build bin/emo_lsp_bin.exe
```

Then either stage it into the extension:

```sh
cd editors/vscode
bash scripts/install-server.sh   # copies the binary and stdlib registry
```

or tell the extension where it is:

```jsonc
{
  "emo.serverPath": "/path/to/emo-lsp",
  "emo.registry": "/path/to/emo/stdlib/registry"
}
```

If neither is set, the extension looks for `emo-lsp` on your `PATH`.

## Commands

| Command | Description |
| --- | --- |
| `Emo: Restart Language Server` | Restart the server |
| `Emo: Resolve Dependencies` | Run `emo deps resolve` |
| `Emo: Update Dependency` | Re-pin a dependency and regenerate `package.lock` |
| `Emo: List Dependencies` | Run `emo deps list` |
| `Emo: Initialize Package Manifest` | Create a `package.emo` |
| `Emo: Check File` | Run `emo check` |
| `Emo: Build` | Run `emo build` |
| `Emo: Run` | Run `emo run` |

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `emo.serverPath` | `""` | Path to the `emo-lsp` executable |
| `emo.emoPath` | `"emo"` | Path to the `emo` CLI |
| `emo.registry` | `""` | Registry endpoint (defaults to `EMO_REGISTRY`) |
| `emo.trace.server` | `"off"` | LSP trace level |

## Development

```sh
cd editors/vscode
npm install
npm run build          # bundles src/extension.ts into out/extension.js
bash scripts/install-server.sh
```

Press <kbd>F5</kbd> in VS Code to launch an Extension Development Host.

## License

MIT — see the repository's [LICENSE](https://github.com/emo-lang/emo/blob/main/LICENSE)
