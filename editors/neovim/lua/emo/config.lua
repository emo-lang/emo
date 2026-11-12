local M = {}

local defaults = {
  -- Path to the `emo-lsp` executable. Unset means: look for `emo-lsp`
  -- on `PATH`, then for a build inside the Emo checkout.
  server_path = nil,
  -- Path to the `emo` CLI, used by the :Emo* commands. Unset means the
  -- server falls back to `$EMO_BIN`, then to `emo` on `PATH`.
  emo_path = nil,
  -- Directory holding the published package registry, used to complete
  -- names in `require "..."`. Unset means `$EMO_REGISTRY`.
  registry = nil,
  -- Pop up insert-mode completion as you type: the dot of `os.` and the
  -- quote inside `require "..."` open the menu, and typing on narrows it
  -- (`os.getp` leaves getpid and getppid). Set false when a completion
  -- plugin (nvim-cmp and friends) drives the server instead.
  completion = true,
  -- Start the language server for `.emo` buffers.
  lsp = true,
}

local state = vim.deepcopy(defaults)

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.get()
  return state
end

function M.setup(opts)
  state = vim.tbl_deep_extend('force', state, opts or {})
end

return M
