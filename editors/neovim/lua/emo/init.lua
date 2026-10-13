local config = require('emo.config')
local lsp = require('emo.lsp')

local M = {}

--- @param opts? table
function M.setup(opts)
  config.setup(opts)

  if vim.fn.has('nvim-0.11') == 0 then
    vim.notify_once('emo: Neovim 0.11 or newer is required', vim.log.levels.ERROR)
    return
  end

  -- Registering through `vim.lsp.config` keeps this table the single
  -- source of truth: `vim.lsp.config('emo', ...)` from a user config
  -- merges on top of it, and `lsp/emo.lua` hands the same table to
  -- anyone who calls `vim.lsp.enable('emo')` themselves.
  vim.lsp.config('emo', lsp.config())
  vim.lsp.enable('emo', config.get().lsp)
end

return M
