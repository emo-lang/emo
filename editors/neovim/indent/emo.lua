if vim.b.did_indent then
  return
end
vim.b.did_indent = 1

vim.bo.indentexpr = "v:lua.require'emo.indent'.expr(v:lnum)"
vim.bo.indentkeys = '0{,0},0),0],!^F,o,O,e'
vim.b.undo_indent = 'setlocal indentexpr< indentkeys<'
