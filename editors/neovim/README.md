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

The plugin is a plain Neovim runtime directory — `ftdetect/`, `ftplugin/`,
`indent/`, `lsp/`, `lua/`, `plugin/`, `syntax/` — at `<repo>/editors/neovim`.
There is nothing to compile; only the `emo-lsp` executable from
[Requirements](#requirements) has to exist. Put the directory on `runtimepath`
one of two ways.

### With lazy.nvim

Add this entry **inside the list passed to `require("lazy").setup({ ... })`**
in `init.lua`:

```lua
require("lazy").setup({
  -- ... your other plugins ...

  {
    dir = '/path/to/emo/editors/neovim',
    main = 'emo',   -- the directory is named `neovim`, the module is not
    opts = {},
  },
})
```

Placement is the part to get right: a spec written after the closing `})` of
`setup`, or in a file that never calls `setup`, is never read and never loads.
`dir` marks a plugin that is already on disk — lazy.nvim loads it in place and
never clones or updates it, so there is no sync and no network access. Point
`dir` at the checkout you actually edit.

Do **not** add `ft` or `event` to the spec. The `.emo` filetype is what starts
the language server, so a plugin loaded *during* that event registers its
autocommand too late to catch the first `.emo` buffer. A spec with no `ft` or
`event` loads at startup; add `lazy = false` if your lazy.nvim `defaults` would
otherwise defer it.

### Without a plugin manager

Prepend the directory to `runtimepath` early in `init.lua`, before filetype
detection sources any `ftdetect` or `ftplugin` script:

```lua
vim.opt.runtimepath:prepend('/path/to/emo/editors/neovim')
```

The plugin calls its own `setup` when `plugin/emo.lua` loads, so this line is
all that is required. Call `require('emo').setup({ ... })` yourself only to
override any of the [options](#options) below.

### Verifying

`:checkhealth emo` is the check that matters. It reports the Neovim version,
the resolved `server_path`, the registry, the `emo` CLI, and every running
client. A server that cannot be found shows up here as an unresolved
executable instead of a language server that quietly never starts. With
lazy.nvim, `:Lazy` also lists the plugin as a local plugin.

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

The language server is registered with `vim.lsp.config('emo', ...)`, so a
`vim.lsp.config('emo', { ... })` call of your own merges on top of it. Buffers
attach to the server automatically; if you would rather enable it yourself,
set `lsp = false` and call `vim.lsp.enable('emo')` when you want it. The plugin
ships an `lsp/emo.lua` for that path, so `vim.lsp.enable('emo')` alone is
enough.

The project root is the nearest `package.emo` above the buffer, or the file's
own directory when there is none — the last so that a loose `.emo` file still
attaches. The server indexes a project only when its root holds `package.emo`
(the directory the compiler would root at), so a buffer outside any package
gets no diagnostics and one message saying why.

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
