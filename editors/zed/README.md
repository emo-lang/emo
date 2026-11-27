# Emo for Zed

Zed extension for the [Emo](https://github.com/emo-lang/emo) programming language.

[中文说明](docs/zh-CN/README.md)

## Features

- `.emo` files are opened as Emo.
- Tree-sitter syntax highlighting for keywords, declarations, strings with
  `${}` interpolation, numbers, byte and character literals, comments, and
  `//#` / `//@` directives.
- Bracket matching, auto-closing pairs, indentation, document outline, and
  text objects.
- The Emo language server (`emo-lsp`) starts for Emo buffers.
- The server path and arguments can be overridden through Zed's `lsp` settings.

## Requirements

- Zed with extension API version 0.7.0 or newer.
- A Rust toolchain with the `wasm32-wasip1` target. Zed installs the target
  through `rustup` when it is missing.
- Node.js only when regenerating the tree-sitter parser.

## Install as a development extension

Zed fetches every extension grammar from a git repository; it cannot read the
grammar from the extension directory directly. This checkout therefore ships
the grammar source under `grammars/tree-sitter-emo` and a small script that
snapshots it into a local bare repository at `.grammar/emo.git`:

```sh
./scripts/prepare-grammar-repo.sh
```

Then, in Zed, run `zed: install dev extension` from the command palette and
select this directory (`editors/zed`). Zed builds the Rust extension, clones
the grammar from `.grammar/emo.git`, and compiles it to WASM.

The local grammar repository is a development convenience and is ignored by
git. To publish the extension, push the grammar to a git host (or use the Emo
monorepo with a `path` entry in `extension.toml`) and replace the
`[grammars.emo]` entry in `extension.toml` with that repository and revision.

## Configuring the language server

The extension starts `emo-lsp` from this default path:

```
/Users/daqing/mzevo/open-source/emo-lang/emo/editors/vscode/server/emo-lsp
```

To use another binary, set `lsp.emo-lsp.binary` in Zed's `settings.json`:

```json
{
  "lsp": {
    "emo-lsp": {
      "binary": {
        "path": "/path/to/emo-lsp",
        "arguments": [],
        "env": {}
      }
    }
  }
}
```

`path`, `arguments`, and `env` are all optional. A field that is omitted keeps
its default: the built-in path for `path`, and empty values for `arguments`
and `env`.

## Regenerating the parser

After editing `grammars/tree-sitter-emo/grammar.js`:

```sh
cd grammars/tree-sitter-emo
npx --yes tree-sitter-cli@0.25.10 generate
cd ../..
./scripts/prepare-grammar-repo.sh
```

The generated parser uses tree-sitter ABI 14. The grammar is tested against
the Emo repository's examples, standard library, and test corpus.

## Layout

```
extension.toml              Zed extension manifest
Cargo.toml / src/lib.rs     language server registration
languages/emo/              language configuration and tree-sitter queries
grammars/tree-sitter-emo/   grammar source and generated parser
scripts/                    local grammar repository setup
```
