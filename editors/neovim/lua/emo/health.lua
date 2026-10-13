local config = require('emo.config')
local lsp = require('emo.lsp')

local M = {}

function M.check()
  vim.health.start('emo')

  if vim.fn.has('nvim-0.11') == 0 then
    vim.health.error('Neovim 0.11 or newer is required (vim.lsp.config is missing)')
  else
    vim.health.ok('Neovim ' .. vim.version().major .. '.' .. vim.version().minor)
  end

  local path = lsp.server_path()
  if path then
    vim.health.ok('emo-lsp: ' .. path)
  elseif config.get().server_path then
    vim.health.error(
      'server_path is set but not executable: ' .. vim.inspect(config.get().server_path)
    )
  else
    vim.health.error('emo-lsp not found', {
      'Install the toolchain with `dune install`, which puts `emo-lsp` on your PATH',
      'or build it here with editors/neovim/scripts/build-server.sh',
      'or point `server_path` at the binary: require("emo").setup({ server_path = ... })',
    })
  end

  local registry = config.get().registry
  if registry then
    vim.health.ok('registry: ' .. vim.fn.expand(registry))
  elseif (vim.env.EMO_REGISTRY or '') ~= '' then
    vim.health.ok('registry: ' .. vim.env.EMO_REGISTRY .. ' (from $EMO_REGISTRY)')
  else
    vim.health.info(
      'no registry configured; `require "..."` completion falls back to the server default'
    )
  end

  local emo = config.get().emo_path
  if emo then
    vim.health.ok('emo CLI: ' .. vim.fn.expand(emo))
  else
    local on_path = vim.fn.exepath(vim.env.EMO_BIN or 'emo')
    vim.health.info(
      on_path ~= '' and ('emo CLI: ' .. on_path)
        or 'emo CLI not found; the :Emo* commands will fail'
    )
  end

  if not config.get().lsp then
    vim.health.warn('the language server is disabled (lsp = false)')
  end

  local clients = vim.lsp.get_clients({ name = 'emo' })
  if #clients == 0 then
    vim.health.info('no emo client is running')
  else
    for _, client in ipairs(clients) do
      vim.health.ok(string.format('client %d running for %s', client.id, client.config.root_dir))
    end
  end
end

return M
