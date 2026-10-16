local config = require('emo.config')

local M = {}

local function expand(path)
  if not path or path == '' then
    return nil
  end
  return vim.fn.expand(path)
end

-- The server `dune build bin/emo_lsp_bin.exe` leaves in this checkout,
-- found relative to this file: <plugin>/lua/emo/lsp.lua.
local function in_tree_server()
  local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local path = vim.fn.simplify(
    vim.fs.joinpath(here, '..', '..', '..', '_build', 'default', 'bin', 'emo_lsp_bin.exe')
  )
  if vim.fn.executable(path) == 1 then
    return path
  end
  return nil
end

function M.server_path()
  local configured = expand(config.get().server_path)
  if configured then
    return configured
  end
  local on_path = vim.fn.exepath('emo-lsp')
  if on_path ~= '' then
    return on_path
  end
  return in_tree_server()
end

function M.config()
  local cfg = config.get()

  -- The project root is the directory the compiler would treat as the
  -- module tree: the nearest manifest, else the file's own directory.
  -- Nothing above a manifest-less directory is guessed — the compiler
  -- refuses such a tree (E5010) and the server says so rather than
  -- indexing one it would never build.
  local root_dir = function(bufnr, on_dir)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == '' then
      on_dir(vim.uv.cwd())
      return
    end
    local root = vim.fs.root(file, { 'package.emo' })
    on_dir(root or vim.fs.dirname(file))
  end

  local out = {
    cmd = { M.server_path() or 'emo-lsp' },
    filetypes = { 'emo' },
    root_dir = root_dir,
  }

  local registry = expand(cfg.registry)
  if registry then
    out.init_options = { registry = registry }
  end

  local emo = expand(cfg.emo_path)
  if emo then
    out.cmd_env = { EMO_BIN = emo }
  end

  return out
end

return M
