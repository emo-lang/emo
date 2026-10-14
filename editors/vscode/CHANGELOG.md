# Changelog

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
