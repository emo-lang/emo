-- The `emo-lsp` configuration in the `lsp/<name>.lua` form Neovim reads
-- for `vim.lsp.enable('emo')`. `require('emo').setup()` installs the
-- same table through `vim.lsp.config`, so either entry point works.
return require('emo.lsp').config()
