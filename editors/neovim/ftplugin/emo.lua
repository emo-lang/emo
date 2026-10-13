if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

-- The predicate marker belongs to the name, so `adult?` is one word for
-- motions, `*`, and completion.
vim.opt_local.iskeyword:append('?')

vim.bo.commentstring = '// %s'
vim.bo.comments = '://'
if not vim.bo.formatoptions:find('o') then
  vim.bo.formatoptions = vim.bo.formatoptions .. 'o'
end

vim.b.undo_ftplugin = 'setlocal commentstring< comments< formatoptions< iskeyword<'
