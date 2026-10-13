# Emo for Neovim

Language support for the [Emo programming language](https://github.com/emo-lang/emo):
syntax highlighting, indentation, code completion, live diagnostics, hover,
go-to-definition, document symbols, semantic tokens, and package management.

The plugin is a thin client for `emo-lsp`, the same language server the VS Code
extension drives, so the diagnostics you see are the ones `emo check` produces.

## Requirements

- Neovim 0.11 or newer, for `vim.lsp.config` and `vim.lsp.enable`.
- The `emo-lsp` language server.

The server is an OCaml executable in the Emo tree. Build it with the script
that ships here:

```sh
editors/neovim/scripts/build-server.sh   # prints the binary's path
```

or install it next to the compiler, which puts `emo-lsp` on your `PATH`:

```sh
dune build bin/emo_lsp_bin.exe
dune install
```

The plugin looks for the server in the `server_path` option, then for
`emo-lsp` on the `PATH`, then for a build inside the Emo checkout. When none
of the three resolves it falls back to the bare name `emo-lsp`, so the failure
surfaces as a missing executable in `:checkhealth emo` rather than as a
language server that quietly never starts.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim), pointing at the plugin
directory inside the Emo checkout:

```lua
{
  dir = '/path/to/emo/editors/neovim',
  main = 'emo',   -- the directory is named `neovim`, the module is not
  opts = {},
}
```

Load it at startup rather than on the `ft` event: the filetype is what starts
the language server, so a plugin loaded during that event has registered its
autocommand too late to catch the first `.emo` buffer.

Or without a plugin manager, before `filetype plugin indent on`:

```lua
vim.opt.runtimepath:prepend('/path/to/emo/editors/neovim')
require('emo').setup()
```

`setup` is optional; the plugin starts with its defaults on first load. Call it
to override any of the [options](#options) below.

## Features

- **Syntax highlighting.** A Vim syntax file covers keywords, declarations,
  numbers and their radixes, string interpolation (including nested braces),
  `predicate?` names, and the language's case conventions. There is no
  tree-sitter parser; the language server refines these colours with semantic
  tokens for user-defined classes, enums, interfaces, functions, and
  parameters.
- **Indentation.** `=`, `o`, and `O` indent by braces, and a brace inside a
  string, character, or comment does not open a block.
- **Code completion.** Keywords, built-in types and functions, declarations
  from the current file and the project, members after `.` (class methods and
  fields, group members, module members), and package names inside
  `require "..."`.
- **Diagnostics.** Lex, parse, and type errors from the compiler, plus
  manifest/`require` pairing errors, published as you type.
- **Hover and go-to-definition.** Signatures and jump-to-declaration across
  the project's module tree.
- **Document and workspace symbols.** An outline for the current file and a
  project-wide symbol search.
- **Package management.** Commands for `emo deps resolve` / `update` / `list`,
  `emo package init`, `emo check`, `emo build`, and `emo run`.

In an `.emo` buffer, `?` counts as part of a name, so `adult?` is one word for
motions, `*`, and completion.

## Commands

| Command | Description |
| --- | --- |
| `:EmoRestart` | Restart the language server |
| `:EmoCheck [file]` | Run `emo check` on the file, defaulting to the buffer's |
| `:EmoBuild [file]` | Run `emo build` |
| `:EmoRun [file]` | Run `emo run` |
| `:EmoDepsResolve` | Run `emo deps resolve` |
| `:EmoDepsList` | Run `emo deps list` |
| `:EmoDepsUpdate <name>` | Re-pin a dependency and regenerate `package.lock` |
| `:EmoPackageInit [name]` | Write a `package.emo` at the project root, naming the package `local/<directory>` unless told otherwise |

Each command asks the language server to run the compiler's own CLI from the
project root, so nothing is guessed from the buffer's path. Output is reported
through `vim.notify`.

## Options

```lua
require('emo').setup({
  server_path = '/path/to/emo-lsp',
  emo_path = '/path/to/emo',
  registry = '/path/to/emo/stdlib/registry',
  lsp = true,
})
```

| Option | Default | Description |
| --- | --- | --- |
| `server_path` | `nil` | Path to the `emo-lsp` executable |
| `emo_path` | `nil` | Path to the `emo` CLI, passed to the server as `EMO_BIN` |
| `registry` | `nil` | Registry endpoint, passed to the server as an initialization option |
| `lsp` | `true` | Start the language server for `.emo` buffers |

Every option defaults to the server's own behaviour when unset: `emo-lsp` is
looked up on the `PATH`, and `emo_path` and `registry` fall back to the
server's `$EMO_BIN` and `$EMO_REGISTRY`.

## Configuration

`:checkhealth emo` reports the Neovim version, the server path, the registry,
the `emo` CLI, and any running clients.

The language server is registered with `vim.lsp.config('emo', ...)`, so a
`vim.lsp.config('emo', { ... })` call of your own merges on top of it. Buffers
attach to the server automatically; if you would rather enable it yourself,
set `lsp = false` and call `vim.lsp.enable('emo')` when you want it. The plugin
ships an `lsp/emo.lua` for that path, so `vim.lsp.enable('emo')` alone is
enough.

The project root is the nearest `package.emo`, then the nearest `.git`, then
the file's own directory — the last so that a loose `.emo` file still gets a
server.

## Development

The plugin is plain Lua and Vim script; there is nothing to compile. Rebuild
the server after changing it, restart the client with `:EmoRestart`, and run
`:checkhealth emo` to see which binary, registry, and `emo` CLI the plugin
resolved.

```sh
editors/neovim/scripts/build-server.sh
```

## License

MIT — see the repository's [LICENSE](../../LICENSE)
