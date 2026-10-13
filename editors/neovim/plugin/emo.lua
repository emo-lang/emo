if vim.g.loaded_emo then
  return
end
vim.g.loaded_emo = 1

require('emo.commands').register()
require('emo').setup()
