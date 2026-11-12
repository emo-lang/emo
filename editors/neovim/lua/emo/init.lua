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

  -- Insert-mode completion rides Neovim's own `vim.lsp.completion`: the
  -- server's trigger characters — the dot of `os.` and the quote inside
  -- `require "..."` — open the menu, and typing on narrows it. The
  -- attach event fires whichever way the client was enabled, the `lsp`
  -- default or a user's own `vim.lsp.enable('emo')`, so one
  -- autocommand covers both; `completion = false` hands the server to a
  -- completion plugin instead.
  local group = vim.api.nvim_create_augroup('emo_completion', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    desc = 'emo: enable the language server\'s insert completion',
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if
        client ~= nil
        and client.name == 'emo'
        and config.get().completion
      then
        vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
      end
    end,
  })

  -- Registering through `vim.lsp.config` keeps this table the single
  -- source of truth: `vim.lsp.config('emo', ...)` from a user config
  -- merges on top of it, and `lsp/emo.lua` hands the same table to
  -- anyone who calls `vim.lsp.enable('emo')` themselves.
  vim.lsp.config('emo', lsp.config())
  vim.lsp.enable('emo', config.get().lsp)
end

return M
