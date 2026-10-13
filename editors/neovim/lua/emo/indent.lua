-- Indentation for Emo.
--
-- A statement ends at the newline, so a line's indent is its
-- predecessor's: one shift more when the predecessor leaves a brace
-- open, one shift less when the line opens with `}`. A continuation
-- line simply keeps the predecessor's indent, which is what returning
-- the same number gives us.

local M = {}

local function shiftwidth()
  return vim.bo.shiftwidth > 0 and vim.bo.shiftwidth or vim.bo.tabstop
end

-- The line with its comment and its string and character literals
-- blanked out, so a brace inside either does not read as a block
-- delimiter.
local function code_only(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '/' and line:sub(i + 1, i + 1) == '/' then
      break
    elseif c == '"' or c == "'" then
      i = i + 1
      while i <= n do
        local d = line:sub(i, i)
        if d == '\\' then
          i = i + 2
        elseif d == c then
          break
        else
          i = i + 1
        end
      end
      out[#out + 1] = ' '
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.expr(lnum)
  local prev = vim.fn.prevnonblank(lnum - 1)
  if prev == 0 then
    return 0
  end

  local step = shiftwidth()
  local indent = vim.fn.indent(prev)
  local before = code_only(vim.fn.getline(prev))
  local here = vim.trim(code_only(vim.fn.getline(lnum)))

  if here:sub(1, 1) == '}' then
    indent = indent - step
  end
  if before:match('{[%s]*$') then
    indent = indent + step
  end

  return math.max(indent, 0)
end

return M
