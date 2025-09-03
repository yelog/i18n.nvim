local parser = require('i18n.parser')
local utils = require('i18n.utils')
local config = require('i18n.config')

local source = {}

function source:new()
  local o = {}
  return setmetatable(o, { __index = self })
end

function source:is_available()
  return true
end

function source:get_keyword_pattern()
  return "[%w%._-]*"
end

local function extract_prefix()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local part = before:match("t%(['\"]([%w%._-]*)$")
  if not part then
    part = before:match("%$t%(['\"]([%w%._-]*)$")
  end
  return part
end

function source:complete(request, callback)
  local part = extract_prefix()
  if not part then
    return callback({ items = {}, isIncomplete = true })
  end
  local keys = parser.get_all_keys()
  local opts = config.options.completion or {}
  local filtered = utils.fuzzy_filter(keys, part, opts.max_items or 15)
  local items = {}
  for _, key in ipairs(filtered) do
    table.insert(items, {
      label = key,
      insertText = key,
      kind = 1, -- Text
    })
  end
  callback({ items = items, isIncomplete = true })
end

return source
