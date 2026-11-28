# tree-sitter-emo

Tree-sitter grammar for the Emo programming language, used by the Zed
extension in the parent directory.

```sh
npx --yes tree-sitter-cli@0.25.10 generate
```

The generated parser lives in `src/` and targets tree-sitter ABI 14. It parses
the Emo examples, standard library, and test corpus without errors.
