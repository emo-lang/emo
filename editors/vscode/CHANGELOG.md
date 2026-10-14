# Changelog

## 0.2.4

- Validate `package.emo` as a manifest instead of checking it as Emo
  source: `name`, `version`, `targets`, and `deps` are no longer reported
  as unbound names, and a malformed manifest reports the real manifest
  error.

## 0.2.3

- Resolve symbols for the standard library and dependencies: an unpinned
  `require "json"` (or any declared dependency) now feeds the checker and
  the index, so members resolve in diagnostics, completion, hover, and
  go-to-definition.
- Bundle the full standard-library registry (every package, not just
  `http` and `net`), so the standard library resolves out of the box.

## 0.2.2

- Fix language server startup: the extension registered the package
  commands that the server already advertises, so the duplicate
  registration threw during initialization and the server never started.

## 0.2.0

- Published under the `MindWork` publisher.
- Extension display name changed to "Emo Lsp".

## 0.1.0

- Initial release.
- Syntax highlighting (TextMate grammar) and semantic tokens.
- Completion: keywords, built-ins, project declarations, members, packages.
- Diagnostics from the compiler, plus a manifest/require pairing check.
- Hover, go-to-definition, document symbols, workspace symbols.
- Package management view and commands; quick fix to add a missing dependency.
