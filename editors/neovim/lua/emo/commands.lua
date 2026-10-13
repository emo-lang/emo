-- The :Emo* commands. Each one is a `workspace/executeCommand` request,
-- so the language server runs the compiler's own CLI from the project
-- root instead of the editor guessing at paths.

local M = {}

local function attached(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'workspace/executeCommand' })
  if #clients == 0 then
    vim.notify('emo: no language server is attached to this buffer', vim.log.levels.WARN)
    return nil
  end
  return clients[1]
end

local function report(result)
  if type(result) ~= 'table' then
    return
  end
  local output = vim.trim(result.output or '')
  if result.ok then
    vim.notify(output ~= '' and output or 'emo: ok', vim.log.levels.INFO)
  else
    vim.notify(
      output ~= '' and output or string.format('emo: failed with exit code %s', vim.inspect(result.code)),
      vim.log.levels.ERROR
    )
  end
end

local function execute(command, arguments)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = attached(bufnr)
  if not client then
    return
  end
  --- @param err? table
  --- @param result? table
  client:exec_cmd({ command = command, arguments = arguments }, { bufnr = bufnr }, function(err, result)
    if err then
      vim.notify('emo: ' .. vim.inspect(err.message or err), vim.log.levels.ERROR)
      return
    end
    report(result)
  end)
end

-- `emo check`, `emo build`, and `emo run` each take one file, defaulting
-- to the buffer's own.
local function with_file(name)
  local file = name ~= '' and vim.fn.fnamemodify(name, ':p') or vim.api.nvim_buf_get_name(0)
  if file == '' then
    vim.notify('emo: this buffer has no file name', vim.log.levels.WARN)
    return nil
  end
  return { file }
end

local function file_command(name)
  return function(opts)
    local files = with_file(opts.args)
    if files then
      execute(name, files)
    end
  end
end

-- The old server has to exit before a new one can take over the same
-- root, and the exit is asynchronous, so the enable pass is deferred.
local function restart()
  for _, client in ipairs(vim.lsp.get_clients({ name = 'emo' })) do
    client:stop(true)
  end
  vim.defer_fn(function()
    vim.lsp.enable('emo')
  end, 100)
end

function M.register()
  local commands = {
    { 'EmoRestart', restart, {} },
    { 'EmoCheck', file_command('emo.check'), { nargs = '?', complete = 'file' } },
    { 'EmoBuild', file_command('emo.build'), { nargs = '?', complete = 'file' } },
    { 'EmoRun', file_command('emo.run'), { nargs = '?', complete = 'file' } },
    { 'EmoDepsResolve', function() execute('emo.deps.resolve', {}) end, {} },
    { 'EmoDepsList', function() execute('emo.deps.list', {}) end, {} },
    {
      'EmoDepsUpdate',
      function(opts)
        if opts.args == '' then
          vim.notify('emo: EmoDepsUpdate needs a package name', vim.log.levels.WARN)
          return
        end
        execute('emo.deps.update', { opts.args })
      end,
      { nargs = 1 },
    },
    {
      'EmoPackageInit',
      function(opts)
        execute('emo.package.init', opts.args ~= '' and { opts.args } or {})
      end,
      { nargs = '?' },
    },
  }

  for _, command in ipairs(commands) do
    vim.api.nvim_create_user_command(command[1], command[2], command[3])
  end
end

return M
